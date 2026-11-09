import CoreAudio
import Foundation

enum AudioCaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case unsupportedFormat
    case microphoneDenied
    case noMicrophone
    case micDisabled

    var errorDescription: String? {
        switch self {
        case .osStatus(let what, let status): "\(what)失败（OSStatus \(status)）"
        case .unsupportedFormat: "无法识别的音频格式"
        case .microphoneDenied: "麦克风权限被拒绝，请到 系统设置 › 隐私与安全性 › 麦克风 中开启"
        case .noMicrophone: "未检测到麦克风"
        case .micDisabled: "已关闭麦克风采集"
        }
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw AudioCaptureError.osStatus(what, status) }
}

/// Core Audio HAL 的薄封装
enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "读取音频属性 \(selector)")
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "读取音频字符串属性 \(selector)")
        guard let value else { throw AudioCaptureError.osStatus("读取音频字符串属性 \(selector)", -1) }
        return value.takeRetainedValue() as String
    }

    /// PID -> Core Audio 进程对象（用于把本 App 从系统内录里排除）
    static func processObject(for pid: pid_t) throws -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "查询本进程音频对象")
        return object
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        try get(system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    /// 某一侧（输入/输出）的声道总数；0 表示这个设备没有这一侧
    static func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func allDevices() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// 所有带输入声道的设备，含"是否正被别的进程使用"（会议软件开着麦克风时为 true）
    static func inputDevices() -> [AudioInputDevice] {
        allDevices().compactMap { id in
            guard channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                uid: (try? string(id, kAudioDevicePropertyDeviceUID)) ?? "",
                name: (try? string(id, kAudioObjectPropertyName)) ?? "未知设备",
                transport: (try? get(id, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0,
                isRunningSomewhere: ((try? get(id, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0))) ?? 0) != 0)
        }
    }

    /// 默认输出设备的 UID、传输方式、数据源（内置设备区分扬声器 / 耳机孔）
    static func defaultOutputInfo() -> (uid: String?, transport: UInt32, dataSource: UInt32?) {
        guard let device = try? get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              device != kAudioObjectUnknown else { return (nil, 0, nil) }
        return (try? string(device, kAudioDevicePropertyDeviceUID),
                (try? get(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0,
                try? get(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)))
    }
}
