import AVFoundation
import CoreAudio

/// 系统内录：Core Audio Process Tap（macOS 14.2+）
///
/// 为什么不用 ScreenCaptureKit / BlackHole：
/// - 不需要"屏幕录制"权限，只需要"仅系统录音"权限
/// - 不需要用户装虚拟声卡、改输出设备
/// - 可以把本进程排除在外 —— Say 的 TTS 不会被内录回去，AI 不会自问自答
///
/// 流程：CATapDescription -> ProcessTap -> 私有聚合设备(挂上 tap) -> IOProc 回调拿 PCM
final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.api2human.system-tap", qos: .userInteractive)
    private var rateListener: AudioObjectPropertyListenerBlock?
    /// 当前实际格式；只在 queue 上修改（启动时除外，那时 IOProc 还没开始）
    nonisolated(unsafe) private var currentFormat: AVAudioFormat?
    /// 诊断：本轮收到的回调总数、第一次回调相对启动的延迟（只在 queue 上写；stop 里 queue.sync 之后读）
    nonisolated(unsafe) private var sessionCallbacks = 0
    nonisolated(unsafe) private var firstCallbackDelay: Double?
    private var startedAt = DispatchTime.now()

    /// 启动并返回 tap 的原生格式（通常 48kHz / 2ch / Float32）。
    /// - processes: 只录这些进程（会议软件）；nil = 录全部系统声音（排除本 App 自己）
    func start(processes: [AudioObjectID]? = nil, handler: @escaping Handler) throws -> AVAudioFormat {
        stop()
        do {
            return try startUnchecked(processes: processes, handler: handler)
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked(processes: [AudioObjectID]?, handler: @escaping Handler) throws -> AVAudioFormat {
        // 1. 立体声 tap：只录会议软件的进程；或者录全部、排除本进程（TTS 不被录回去）
        let tapDescription: CATapDescription
        if let processes, !processes.isEmpty {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processes)
        } else {
            let ownProcess = try HAL.processObject(for: getpid())
            let exclude = ownProcess == kAudioObjectUnknown ? [] : [ownProcess]
            if exclude.isEmpty { Log.info("⚠️ 未找到本进程音频对象，TTS 可能被内录") }
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        }
        tapDescription.uuid = UUID()
        tapDescription.name = "API2Human System Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted   // 只旁听，不影响你听到会议声音

        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "创建系统音频 Tap")

        // 2. 私有聚合设备：只挂 tap，不挂真实输出设备（时钟由 tap 自己提供）。
        //    之前把默认输出设备挂成主子设备：输出是蓝牙耳机时，耳机一切换模式，
        //    coreaudiod 配置数据流就会卡住（实测 CreateIOProc / DeviceStart 各卡 60 秒），
        //    而且采样率会跟着耳机在 44.1k / 16k 之间跳。
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "API2Human-SystemTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "创建聚合音频设备")

        // 3. 数据格式：声道/样本格式取 tap 的，采样率必须取聚合设备实际在跑的。
        //    蓝牙耳机进入通话模式（会议软件占用了耳机麦克风）时，输出设备只跑 16kHz，
        //    tap 的格式却仍报 48kHz；按 48k 解释会让 WAV 和 STT 都变成 3 倍速。
        var asbd = try HAL.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let tapRate = asbd.mSampleRate
        asbd.mSampleRate = try HAL.get(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
        guard asbd.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioCaptureError.unsupportedFormat
        }
        currentFormat = format
        if tapRate != asbd.mSampleRate {
            Log.info("tap 报告 \(Int(tapRate))Hz，设备实际 \(Int(asbd.mSampleRate))Hz，以设备为准")
        }

        // 4. 会议中途切换耳机模式时采样率会变：监听并更新（回调和 IOProc 在同一个串行 queue 上）
        var rateAddress = HAL.address(kAudioDevicePropertyNominalSampleRate)
        let aggregateDevice = aggregateID
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self,
                  var desc = self.currentFormat?.streamDescription.pointee,
                  let rate = try? HAL.get(aggregateDevice, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
                  rate > 0, rate != desc.mSampleRate else { return }
            Log.info("系统音频采样率变化：\(Int(desc.mSampleRate)) → \(Int(rate))Hz")
            desc.mSampleRate = rate
            // 新格式建不出来就保留旧的：置 nil 会让之后所有回调静默丢弃（系统音频永久无声）
            guard let newFormat = AVAudioFormat(streamDescription: &desc) else {
                Log.info("⚠️ 无法创建 \(Int(rate))Hz 的音频格式，沿用旧格式")
                return
            }
            self.currentFormat = newFormat
        }
        try check(AudioObjectAddPropertyListenerBlock(aggregateID, &rateAddress, queue, listener), "监听采样率变化")
        rateListener = listener

        // 5. IOProc：每个音频周期回调一次
        nonisolated(unsafe) var callbacks = 0, frames = 0, lastReport = DispatchTime.now().uptimeNanoseconds
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.currentFormat,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            if self.sessionCallbacks == 0 {
                self.firstCallbackDelay = Double(DispatchTime.now().uptimeNanoseconds - self.startedAt.uptimeNanoseconds) / 1e9
            }
            self.sessionCallbacks += 1
            // 诊断：每 30 秒记一次实际吞吐，帧数/秒 应该等于采样率
            callbacks += 1
            frames += Int(buffer.frameLength)
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastReport > 30_000_000_000 {
                let secs = Double(now - lastReport) / 1e9
                Log.info(String(format: "系统音频 tap：%.0f 次回调/秒，%.0f 帧/秒（格式 %.0fHz）",
                                Double(callbacks) / secs, Double(frames) / secs, format.sampleRate))
                callbacks = 0; frames = 0; lastReport = now
            }
            handler(buffer)
        }, "创建系统音频回调")
        Log.info("系统音频 tap 启动：\(format)")

        sessionCallbacks = 0
        firstCallbackDelay = nil
        startedAt = .now()
        try check(AudioDeviceStart(aggregateID, procID), "启动系统音频采集")
        return format
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, queue, rateListener)
            }
            if let procID { AudioDeviceStop(aggregateID, procID) }
            // 无论 IOProc 是否创建成功，都等 queue 上已排队的回调（IOProc / 采样率监听）跑完再销毁
            queue.sync {}
            Log.info("系统音频 tap 停止：本轮 \(sessionCallbacks) 次回调，首次回调延迟 \(firstCallbackDelay.map { String(format: "%.2fs", $0) } ?? "无（一次都没收到）")")
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        rateListener = nil
        currentFormat = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
