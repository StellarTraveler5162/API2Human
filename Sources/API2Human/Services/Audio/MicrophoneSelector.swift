import CoreAudio

/// 一个可录音的输入设备（从 HAL 读出来的快照）
struct AudioInputDevice: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    /// 是否正被别的进程（通常是会议软件）使用
    let isRunningSomewhere: Bool

    var isBluetooth: Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }
    var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }
    /// 同一副蓝牙耳机的输入/输出设备 UID 形如 "A0-0C-E2-30-12-34:input" / ":output"，冒号前是蓝牙地址
    var physicalID: String { uid.split(separator: ":").first.map(String.init) ?? uid }
}

/// A2H 录哪个麦克风。A2H 的麦克风只用来存 mic.wav（复盘用），不参与识别和回答，
/// 所以原则是：别和会议软件抢，也别把蓝牙耳机切进通话模式。
enum MicrophoneSelector {
    enum Mode: String, CaseIterable, Sendable {
        case auto   // 自动选择（默认）
        case off    // 不录

        var title: String {
            switch self {
            case .auto: "自动选择（优先用会议软件没在用的麦克风）"
            case .off: "不录麦克风"
            }
        }
    }

    struct Choice: Equatable {
        let device: AudioInputDevice?
        let reason: String
    }

    /// 内置 > USB/有线 > 其他 > 蓝牙：内置麦克风开着不影响任何东西，蓝牙最容易出副作用
    private static func rank(_ d: AudioInputDevice) -> Int {
        if d.transport == kAudioDeviceTransportTypeBuiltIn { return 0 }
        if d.transport == kAudioDeviceTransportTypeUSB { return 1 }
        if d.isBluetooth { return 3 }
        return 2
    }

    /// - 优先用空闲的麦克风（会议软件没在用的）：MacBook 上会议用耳机 -> A2H 用内置；会议用内置 -> A2H 用耳机
    /// - 没有空闲的，就和会议软件共用正在用的那个（台式机只有耳机一个麦克风）
    /// - 例外：空闲的蓝牙耳机麦克风、而这副耳机正在播放声音时不打开——打开会把耳机切到通话模式，
    ///   面试官的声音会立刻变差
    static func choose(_ devices: [AudioInputDevice], defaultOutputUID: String?) -> Choice {
        let usable = devices.filter { !$0.isVirtual }
        guard !usable.isEmpty else { return Choice(device: nil, reason: "没有可用的麦克风") }

        let outputPhysical = defaultOutputUID.map { $0.split(separator: ":").first.map(String.init) ?? $0 }
        func wouldDowngradeHeadphones(_ d: AudioInputDevice) -> Bool {
            d.isBluetooth && !d.isRunningSomewhere && d.physicalID == outputPhysical
        }

        let idle = usable.filter { !$0.isRunningSomewhere && !wouldDowngradeHeadphones($0) }.sorted { rank($0) < rank($1) }
        if let pick = idle.first {
            return Choice(device: pick, reason: "用会议软件没在用的「\(pick.name)」")
        }
        let busy = usable.filter(\.isRunningSomewhere).sorted { rank($0) < rank($1) }
        if let pick = busy.first {
            return Choice(device: pick, reason: "和会议软件共用「\(pick.name)」")
        }
        if let bt = usable.first(where: wouldDowngradeHeadphones) {
            return Choice(device: nil, reason: "唯一的麦克风是正在播放声音的「\(bt.name)」，打开它会把耳机切到通话模式、面试官的声音会变差，所以不录（进入会议后再开始监听即可共用）")
        }
        return Choice(device: nil, reason: "没有可用的麦克风")
    }
}

/// 当前声音从哪里放出来：外放（扬声器、显示器、AirPlay）时"朗读回答"会被会议麦克风收进去
enum OutputRoute {
    /// 内置设备的数据源 'ispk' = 扬声器；'hdpn' = 耳机孔
    static func isSpeaker(transport: UInt32, dataSource: UInt32?) -> Bool {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return dataSource == nil || dataSource == fourCC("ispk")
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
            return true
        default:
            return false   // 蓝牙、USB 多半是耳机
        }
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
