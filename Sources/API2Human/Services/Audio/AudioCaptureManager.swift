import AVFoundation

/// 同时管理 系统音频(.remote) + 麦克风(.local)：
/// - 各自写入 WAV（Step 2 验证用）
/// - 计算音量电平给 UI
/// - 通过 onBuffer 把 buffer 分发给 STT（Step 3）
final class AudioCaptureManager: @unchecked Sendable {
    struct Session: Sendable {
        let folder: URL
        let systemFormat: String
        var systemSource: String   // 正在录谁的声音：腾讯会议 / 全部系统声音
        var micFormat: String?     // nil = 麦克风还没启动好 / 不可用
        var micIssue: String?
        var micDevice: String?     // 选中的麦克风名称
    }

    /// 电平回调（0...1），已节流到约 20 次/秒，在任意线程调用
    var onLevel: (@Sendable (AudioSource, Float) -> Void)? {
        get { lock.withLock { _onLevel } }
        set { lock.withLock { _onLevel = newValue } }
    }

    /// 原始 PCM 回调（给 STT），在音频线程调用；buffer 只在回调期间有效，需要的话自己拷贝
    var onBuffer: (@Sendable (AudioSource, AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _onBuffer } }
        set { lock.withLock { _onBuffer = newValue } }
    }
    // 回调在主线程设置、在音频线程读取：都经过 lock
    private var _onLevel: (@Sendable (AudioSource, Float) -> Void)?
    private var _onBuffer: (@Sendable (AudioSource, AVAudioPCMBuffer) -> Void)?

    private let systemTap = SystemAudioTap()
    private let mic = MicrophoneCapture()

    private let micQueue = DispatchQueue(label: "com.api2human.mic-control", qos: .userInitiated)
    private let lock = NSLock()
    /// start/stop 串行：后台 stop、新一轮 start、退出时的 shutdown 不能并发操作 CoreAudio。
    /// 可重入：start 出错时会在持锁状态下调用 stop
    private let controlLock = NSRecursiveLock()

    /// 内录范围：只录会议软件时，会议软件中途启动/退出要重建 tap
    private var scope: AudioSourceScope = .meetingApps
    private var tappedProcesses: [AudioObjectID] = []      // 当前 tap 的进程（空 = 全部系统声音）
    private let processWatchQueue = DispatchQueue(label: "com.api2human.process-watch")
    private var processListener: AudioObjectPropertyListenerBlock?
    /// 内录范围变化时通知（在后台线程调用）：参数是给人看的描述
    var onSourceChange: (@Sendable (String) -> Void)? {
        get { lock.withLock { _onSourceChange } }
        set { lock.withLock { _onSourceChange = newValue } }
    }
    private var _onSourceChange: (@Sendable (String) -> Void)?
    /// 调试：额外当作"会议软件"的进程名（A2H_TAP_EXTRA_NAMES=say）
    private let extraMeetingNames = ProcessInfo.processInfo.environment["A2H_TAP_EXTRA_NAMES"]?
        .split(separator: ",").map(String.init) ?? []
    private var active = false
    /// 每次 start() 加一：迟到的 startMicrophone（比如卡在授权弹窗）不能在下一轮里再启动一次麦克风
    private var generation = 0
    private var systemFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var micMuted = false
    private var lastLevelTime: [AudioSource: UInt64] = [:]

    static var recordingsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("API2Human/Recordings", isDirectory: true)
    }

    /// 第一步：只启动系统音频（面试官的声音，必需），返回后即可开始识别。
    func start(scope: AudioSourceScope = .meetingApps) throws -> Session {
        controlLock.lock()
        defer { controlLock.unlock() }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)_\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits)",
                                                timeZone: .current, calendar: .current))
        let folder = Self.recordingsRoot.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lock.withLock { self.folder = folder; active = true; generation += 1; rollFailedRate = [:] }

        do {
            // 文件要等拿到格式才能建，此前的回调因 file 为 nil 被丢弃
            self.scope = scope
            tapBroken = false
            let (processes, source) = currentSource()
            let systemFormat = try startTap(processes: processes)
            appliedSource = source
            let systemFileHandle = try Self.makeWAV(at: folder.appendingPathComponent("system.wav"), format: systemFormat)
            lock.withLock { systemFile = systemFileHandle }
            unwatchProcessList()     // 防重复 start：旧监听不摘掉就再也摘不掉了
            if scope == .meetingApps {
                watchProcessList()
                processListChanged()   // 扫描进程到开始监听之间启动的会议软件：补查一次（集合没变就什么都不做）

            }
            Log.info("系统内录范围：\(appliedSource)")
            // 用"实际生效的范围"：补查时可能切换了、也可能退回全部系统声音或中断了
            return Session(folder: folder, systemFormat: Self.describe(systemFormat), systemSource: appliedSource)
        } catch {
            stop()
            throw error
        }
    }

    /// 第二步：启动麦克风（可选）。蓝牙耳机要先切到通话模式，可能要 10 秒左右，
    /// 所以放在系统音频之后、在专用队列上做，不拖慢面试官声音的识别。
    /// 返回 (格式描述, 问题描述)，二者恰有一个非 nil。
    /// 返回 (格式描述, 问题描述, 设备名)：录了就有 format 和 device；没录就有 issue（含原因）
    func startMicrophone(mode: MicrophoneSelector.Mode) async -> (format: String?, issue: String?, device: String?) {
        let myGeneration = lock.withLock { generation }
        @Sendable func stillCurrent() -> Bool { lock.withLock { active && generation == myGeneration } }
        guard mode != .off else { return (nil, AudioCaptureError.micDisabled.localizedDescription, nil) }

        // 选设备：优先会议软件没在用的；没有就共用；不碰正在放声音的蓝牙耳机的麦克风
        let choice = MicrophoneSelector.choose(HAL.inputDevices(), defaultOutputUID: HAL.defaultOutputInfo().uid)
        Log.info("麦克风选择：\(choice.reason)")
        guard let device = choice.device else { return (nil, choice.reason, nil) }

        do {
            try await MicrophoneCapture.requestPermission()
        } catch {
            return (nil, error.localizedDescription, nil)
        }
        return await withCheckedContinuation { continuation in
            micQueue.async { [self] in
                guard stillCurrent() else {
                    return continuation.resume(returning: (nil, "已停止", nil))
                }
                do {
                    let format = try mic.start(device: device) { [weak self] buffer in
                        self?.handle(buffer, from: .local)
                    }
                    let micURL = lock.withLock { folder }?.appendingPathComponent("mic.wav")
                    // 回调送来的是 firstChannel 拷出的单声道：文件也按单声道建，否则多声道麦克风每次写入都失败
                    let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 1, interleaved: false) ?? format
                    let file = try micURL.map { try Self.makeWAV(at: $0, format: mono) }
                    let stillActive = lock.withLock {
                        let current = active && generation == myGeneration
                        if current { micFile = file }
                        return current
                    }
                    if !stillActive {   // 启动期间用户已经点了停止：别留下空的 mic.wav
                        mic.stop()
                        if let micURL { try? FileManager.default.removeItem(at: micURL) }
                        return continuation.resume(returning: (nil, "已停止", nil))
                    }
                    continuation.resume(returning: (Self.describe(format), nil, device.name))
                } catch {
                    mic.stop()
                    Log.info("麦克风不可用，仅录制系统音频：\(error.localizedDescription)")
                    continuation.resume(returning: (nil, "「\(device.name)」打不开：\(error.localizedDescription)", nil))
                }
            }
        }
    }

    func stop() {
        controlLock.lock()
        defer { controlLock.unlock() }
        lock.withLock { active = false }
        unwatchProcessList()
        systemTap.stop()
        // 排在可能还没结束的 mic.start 之后执行，避免和它并发操作 AVAudioEngine
        micQueue.async { [mic] in mic.stop() }
        // 置 nil 即关闭文件，AVAudioFile 析构时会写好 WAV 头
        lock.withLock {
            systemFile = nil
            micFile = nil
            lastLevelTime.removeAll()
        }
    }

    // MARK: - 内录范围（只录会议软件）

    /// 现在应该录哪些进程：(进程对象列表（空 = 全部系统声音）, 给人看的描述)
    private func currentSource() -> ([AudioObjectID], String) {
        guard scope == .meetingApps else { return ([], "全部系统声音") }
        let meeting = AudioSourceScope.meetingProcesses(in: HAL.audioProcesses(), extraNames: extraMeetingNames)
        guard !meeting.isEmpty else { return ([], "全部系统声音（还没检测到会议软件，打开后自动切换）") }
        return (meeting.map(\.object).sorted(), "只录 \(AudioSourceScope.displayName(of: meeting))")
    }

    /// 重建 tap 两次都失败（旧 tap 已停）：下次进程列表变化时不管集合变没变都要重建
    private var tapBroken = false
    /// 当前 tap 实际生效的范围描述（受 controlLock 保护）
    private var appliedSource = ""

    private func startTap(processes: [AudioObjectID]) throws -> AVAudioFormat {
        let format = try systemTap.start(processes: processes.isEmpty ? nil : processes) { [weak self] buffer in
            self?.handle(buffer, from: .remote)
        }
        tappedProcesses = processes
        return format
    }

    /// 会议软件中途启动、退出、换了发声的辅助进程：重建 tap（进程列表变化很频繁，只在会议进程集合变了时才重建）
    private func watchProcessList() {
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.processListChanged() }
        if AudioObjectAddPropertyListenerBlock(HAL.system, &addr, processWatchQueue, listener) == noErr {
            processListener = listener
        }
    }

    private func unwatchProcessList() {
        guard let processListener else { return }
        var addr = HAL.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(HAL.system, &addr, processWatchQueue, processListener)
        self.processListener = nil
    }

    private func processListChanged() {
        controlLock.lock()
        defer { controlLock.unlock() }
        guard lock.withLock({ active }) else { return }
        let (processes, source) = currentSource()
        guard processes != tappedProcesses || tapBroken else { return }
        do {
            _ = try startTap(processes: processes)
            tapBroken = false
            appliedSource = source
            Log.info("系统内录范围变化：\(source)")
            onSourceChange?(source)
        } catch {
            Log.info("⚠️ 切换内录范围失败，改录全部系统声音：\(error.localizedDescription)")
            do {
                _ = try startTap(processes: [])
                tapBroken = false
                appliedSource = "全部系统声音（切换失败）"
                onSourceChange?(appliedSource)
            } catch {
                // 旧 tap 已经停了，兜底也起不来：如实报告，下次进程列表变化时强制重建
                tapBroken = true
                appliedSource = "⚠️ 系统内录中断，等待重试"
                Log.info("⚠️ 系统内录中断：\(error.localizedDescription)")
                onSourceChange?(appliedSource)
            }
        }
    }

    func setMicMuted(_ muted: Bool) {
        lock.withLock { micMuted = muted }
    }

    // MARK: - 音频回调（实时线程）

    private func handle(_ buffer: AVAudioPCMBuffer, from source: AudioSource) {
        let (file, muted) = lock.withLock { (source == .remote ? systemFile : micFile, micMuted) }

        // 静音：写入静音帧而不是跳过，保证两路文件时间轴对齐
        if source == .local && muted, let data = buffer.floatChannelData {
            for ch in 0..<Int(buffer.format.channelCount) {
                data[ch].update(repeating: 0, count: Int(buffer.frameLength))
            }
        }

        let rate = buffer.format.sampleRate
        let needsRoll = file.map { $0.processingFormat.sampleRate != rate } ?? false
        // 这个采样率已经建文件失败过：不写文件（格式不符写也会失败），识别照常
        // 采样率又变回来了（不需要换文件）：清掉失败记录，下次切到那个采样率时再试一次（磁盘可能腾出空间了）
        if !needsRoll { lock.withLock { if rollFailedRate[source] != nil { rollFailedRate[source] = nil } } }
        let skipWrite = needsRoll && lock.withLock { rollFailedRate[source] == rate }
        if !skipWrite {
            do {
                if needsRoll {
                    do {
                        try rollFile(for: source, format: buffer.format)
                        lock.withLock { rollFailedRate[source] = nil }
                    } catch {
                        lock.withLock { rollFailedRate[source] = rate }
                        throw error
                    }
                }
                try lock.withLock { source == .remote ? systemFile : micFile }?.write(from: buffer)
            } catch {
                Log.info("写入 \(source) 音频失败：\(error)")
            }
        }

        onBuffer?(source, buffer)
        emitLevel(buffer, source: source)
    }

    private func emitLevel(_ buffer: AVAudioPCMBuffer, source: AudioSource) {
        guard let onLevel else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldEmit = lock.withLock {
            if now - (lastLevelTime[source] ?? 0) < 50_000_000 { return false }
            lastLevelTime[source] = now
            return true
        }
        guard shouldEmit, let data = buffer.floatChannelData else { return }

        let n = Int(buffer.frameLength)
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n {
            let s = data[0][i * stride]
            sum += s * s
        }
        let rms = sqrt(sum / Float(n))
        // -60dB..0dB 映射到 0..1
        let db = 20 * log10(max(rms, 1e-6))
        onLevel(source, max(0, min(1, (db + 60) / 60)))
    }

    // MARK: - 文件

    /// 由 lock 保护：start 写，麦克风队列和音频回调读
    private var folder: URL?
    /// 某一路换文件失败过的采样率（磁盘满等）：同一采样率不再每个回调都重试、刷日志；只录识别不写文件
    private var rollFailedRate: [AudioSource: Double] = [:]

    /// 采样率中途变化（蓝牙耳机切换模式）：开一个新文件 system-16000Hz.wav，旧文件保持完好
    private func rollFile(for source: AudioSource, format: AVAudioFormat) throws {
        guard let folder = lock.withLock({ active ? folder : nil }) else { return }
        let url = Self.nextFileURL(in: folder, base: source == .remote ? "system" : "mic", sampleRate: format.sampleRate)
        Log.info("\(source) 采样率变为 \(Int(format.sampleRate))Hz，后续写入 \(url.lastPathComponent)")
        let file = try Self.makeWAV(at: url, format: format)
        // 建文件期间可能已经 stop：那就不再挂上去（否则文件一直开着、WAV 头写不完整）
        let attached = lock.withLock { () -> Bool in
            guard active else { return false }
            if source == .remote { systemFile = file } else { micFile = file }
            return true
        }
        if !attached { try? FileManager.default.removeItem(at: url) }
    }

    /// 采样率切换后的新文件名：system-16000Hz.wav；同名已存在（来回切换了几次）就加序号 -2、-3……，绝不覆盖
    static func nextFileURL(in folder: URL, base: String, sampleRate: Double) -> URL {
        let stem = "\(base)-\(Int(sampleRate))Hz"
        var url = folder.appendingPathComponent("\(stem).wav")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(n).wav")
            n += 1
        }
        return url
    }

    /// 16-bit PCM WAV；AVAudioFile 负责 Float32 -> Int16 转换
    static func makeWAV(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    private static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))Hz · \(f.channelCount)ch"
    }
}
