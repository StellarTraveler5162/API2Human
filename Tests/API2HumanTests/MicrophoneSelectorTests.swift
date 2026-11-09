import XCTest
import CoreAudio
@testable import API2Human

/// 麦克风选择规则：台式机 / MacBook 的各种会议设备组合
final class MicrophoneSelectorTests: XCTestCase {
    private func dev(_ name: String, _ uid: String, _ transport: UInt32, busy: Bool = false, id: AudioObjectID = 1) -> AudioInputDevice {
        AudioInputDevice(id: id, uid: uid, name: name, transport: transport, isRunningSomewhere: busy)
    }
    private lazy var builtIn = dev("MacBook 麦克风", "BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn, id: 10)
    private lazy var airpods = dev("AirPods", "AA-BB-CC:input", kAudioDeviceTransportTypeBluetooth, id: 20)
    private lazy var teams = dev("Microsoft Teams Audio", "MSLoopbackDriverDevice_UID", kAudioDeviceTransportTypeVirtual, id: 30)

    // MARK: 台式机（只有耳机麦克风）

    func testDesktopSharesHeadsetWithMeeting() {
        let headset = dev("Shokz", "A0-0C:input", kAudioDeviceTransportTypeBluetooth, busy: true)
        let c = MicrophoneSelector.choose([headset, teams], defaultOutputUID: "A0-0C:output")
        XCTAssertEqual(c.device?.name, "Shokz")
        XCTAssertTrue(c.reason.contains("共用"))
    }

    func testDesktopBeforeMeetingDoesNotForceHandsFreeMode() {
        // 会议还没开麦克风，耳机正在放音乐/会议声音：打开耳机麦克风会切通话模式 -> 不录
        let headset = dev("Shokz", "A0-0C:input", kAudioDeviceTransportTypeBluetooth, busy: false)
        let c = MicrophoneSelector.choose([headset], defaultOutputUID: "A0-0C:output")
        XCTAssertNil(c.device)
        XCTAssertTrue(c.reason.contains("通话模式"))
    }

    func testDesktopWithoutAnyMicrophone() {
        XCTAssertNil(MicrophoneSelector.choose([teams], defaultOutputUID: "BuiltInSpeakerDevice").device)
        XCTAssertNil(MicrophoneSelector.choose([], defaultOutputUID: nil).device)
    }

    // MARK: MacBook：和会议软件用相反的麦克风

    func testMeetingUsesHeadsetSoA2HUsesBuiltIn() {
        let busyAirpods = dev("AirPods", "AA-BB-CC:input", kAudioDeviceTransportTypeBluetooth, busy: true, id: 20)
        let c = MicrophoneSelector.choose([builtIn, busyAirpods], defaultOutputUID: "AA-BB-CC:output")
        XCTAssertEqual(c.device?.name, "MacBook 麦克风")
    }

    func testMeetingUsesBuiltInAndHeadsetIsOnlyForListening() {
        // 会议用内置麦克风、AirPods 只用来听：不能打开 AirPods 麦克风（会降音质）-> 共用内置
        let busyBuiltIn = dev("MacBook 麦克风", "BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn, busy: true, id: 10)
        let c = MicrophoneSelector.choose([busyBuiltIn, airpods], defaultOutputUID: "AA-BB-CC:output")
        XCTAssertEqual(c.device?.name, "MacBook 麦克风")
        XCTAssertTrue(c.reason.contains("共用"))
    }

    func testMeetingUsesBuiltInAndHeadsetNotPlaying() {
        // 会议用内置麦克风 + 内置扬声器，AirPods 连着但没在放声音：A2H 可以用 AirPods 麦克风
        let busyBuiltIn = dev("MacBook 麦克风", "BuiltInMicrophoneDevice", kAudioDeviceTransportTypeBuiltIn, busy: true, id: 10)
        let c = MicrophoneSelector.choose([busyBuiltIn, airpods], defaultOutputUID: "BuiltInSpeakerDevice")
        XCTAssertEqual(c.device?.name, "AirPods")
    }

    func testBeforeMeetingPrefersBuiltInOverBluetooth() {
        let c = MicrophoneSelector.choose([airpods, builtIn], defaultOutputUID: "BuiltInSpeakerDevice")
        XCTAssertEqual(c.device?.name, "MacBook 麦克风")
    }

    func testVirtualDevicesAreNeverChosen() {
        let busyTeams = dev("Microsoft Teams Audio", "MSLoopbackDriverDevice_UID", kAudioDeviceTransportTypeVirtual, busy: true)
        XCTAssertNil(MicrophoneSelector.choose([busyTeams], defaultOutputUID: nil).device)
    }

    // MARK: 外放判断（朗读回答会被会议麦克风收进去）

    func testOutputRoute() {
        XCTAssertTrue(OutputRoute.isSpeaker(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: OutputRoute.fourCC("ispk")))
        XCTAssertFalse(OutputRoute.isSpeaker(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: OutputRoute.fourCC("hdpn")))
        XCTAssertTrue(OutputRoute.isSpeaker(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil))
        XCTAssertFalse(OutputRoute.isSpeaker(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil))
        XCTAssertFalse(OutputRoute.isSpeaker(transport: kAudioDeviceTransportTypeUSB, dataSource: nil))
        XCTAssertEqual(OutputRoute.fourCC("ispk"), 0x6973_706B)
    }
}
