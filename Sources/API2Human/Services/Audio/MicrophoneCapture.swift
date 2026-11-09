import AVFoundation
import CoreAudio

/// 麦克风采集：直接在**指定的输入设备**上开 IOProc（和系统内录同一种做法）。
///
/// 为什么不用 AVAudioEngine：哪怕只是读一下 `engine.inputNode`，它也会先绑定系统默认输入设备——
/// 蓝牙耳机会因此被切到通话模式（16kHz、面试官声音变差），偶尔还会卡死在 CoreAudio 里；
/// 而且没法可靠地指定"用内置麦克风、别碰耳机"。
/// 不做回声消除：戴耳机时没有回声；和会议软件共用麦克风时两边都开语音处理容易冲突（实测蓝牙耳机上两路都会没声音）。
final class MicrophoneCapture: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    private let queue = DispatchQueue(label: "com.api2human.mic", qos: .userInteractive)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    /// 当前输入格式；只在 queue 上修改（启动时除外，那时 IOProc 还没开始）
    nonisolated(unsafe) private var currentFormat: AVAudioFormat?

    static func requestPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw AudioCaptureError.microphoneDenied
        default:
            throw AudioCaptureError.microphoneDenied
        }
    }

    /// 在指定设备上开始录音，返回设备的输入格式（handler 收到的是第 0 声道的单声道 Float32）
    func start(device input: AudioInputDevice, handler: @escaping Handler) throws -> AVAudioFormat {
        stop()
        do {
            return try startUnchecked(device: input.id, handler: handler)
        } catch {
            stop()
            throw error
        }
    }

    /// 设备第一个输入流的实际格式（采样率随设备当前状态，蓝牙通话模式下是 16kHz）
    private static func inputFormat(of device: AudioObjectID) throws -> AVAudioFormat {
        var addr = HAL.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size), "查询麦克风输入流")
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        try check(AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams), "读取麦克风输入流")
        guard let stream = streams.first else { throw AudioCaptureError.noMicrophone }
        var asbd = try HAL.get(stream, kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd),
              format.commonFormat == .pcmFormatFloat32 else {   // 非 Float32 时 floatChannelData 为 nil，会一直静音
            throw AudioCaptureError.unsupportedFormat
        }
        return format
    }

    private func startUnchecked(device id: AudioObjectID, handler: @escaping Handler) throws -> AVAudioFormat {
        device = id
        let format = try Self.inputFormat(of: id)
        currentFormat = format

        // 采样率变化（蓝牙耳机进出通话模式）：重新读格式
        var rateAddress = HAL.address(kAudioDevicePropertyNominalSampleRate)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let newFormat = try? Self.inputFormat(of: id) else { return }
            Log.info("麦克风采样率变化：\(Int(self.currentFormat?.sampleRate ?? 0)) → \(Int(newFormat.sampleRate))Hz")
            self.currentFormat = newFormat
        }
        try check(AudioObjectAddPropertyListenerBlock(id, &rateAddress, queue, listener), "监听麦克风采样率")
        rateListener = listener

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue) { [weak self] _, inputData, _, _, _ in
            guard let format = self?.currentFormat, inputData.pointee.mNumberBuffers > 0 else { return }
            // 多输入流的设备只取第一个流（和 currentFormat 对应）
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: inputData.pointee.mBuffers)
            withUnsafeMutablePointer(to: &single) { list in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil),
                      let mono = Self.firstChannel(of: buffer) else { return }   // firstChannel 会拷贝出来
                handler(mono)
            }
        }, "创建麦克风回调")
        try check(AudioDeviceStart(id, procID), "启动麦克风")
        return format
    }

    func stop() {
        guard device != kAudioObjectUnknown else { return }
        if let rateListener {
            var addr = HAL.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &addr, queue, rateListener)
        }
        if let procID { AudioDeviceStop(device, procID) }
        queue.sync {}   // 等已排队的回调跑完
        if let procID { AudioDeviceDestroyIOProcID(device, procID) }
        procID = nil
        rateListener = nil
        currentFormat = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// 取第 0 声道转成单声道；格式按这个 buffer 的实际采样率建（输入采样率中途变化时不能整批丢弃）
    static func firstChannel(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: 1, interleaved: false),
              let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        if buffer.format.isInterleaved {
            let stride = Int(buffer.format.channelCount)
            for i in 0..<n { dst[0][i] = src[0][i * stride] }
        } else {
            dst[0].update(from: src[0], count: n)
        }
        out.frameLength = buffer.frameLength
        return out
    }
}
