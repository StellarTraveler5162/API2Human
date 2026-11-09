import XCTest
@testable import API2Human

final class AudioSourceScopeTests: XCTestCase {
    private func p(_ name: String, _ bundle: String, _ id: UInt32) -> AudioProcess {
        AudioProcess(object: id, pid: pid_t(id), bundleID: bundle, name: name)
    }

    private lazy var all = [
        p("TencentMeeting", "com.tencent.meeting", 1),
        p("Feishu", "com.electron.lark", 2),
        p("Lark Helper", "com.electron.lark.helper", 3),
        p("WeChat", "com.tencent.xinWeChat", 4),
        p("com.apple.WebKit.GPU", "com.apple.WebKit.GPU", 5),
        p("say", "", 6),
        p("Teams", "com.microsoft.teams2", 7),
    ]

    func testPicksMeetingAppsIncludingHelpers() {
        let picked = AudioSourceScope.meetingProcesses(in: all).map(\.object)
        XCTAssertEqual(picked, [1, 2, 3, 7])
    }

    func testWeChatAndBrowsersAreNotMeetingApps() {
        let picked = AudioSourceScope.meetingProcesses(in: all).map(\.name)
        XCTAssertFalse(picked.contains("WeChat"), "微信提示音从微信进程发出，不能算会议软件")
        XCTAssertFalse(picked.contains("com.apple.WebKit.GPU"))
    }

    func testExtraNamesForDebugging() {
        XCTAssertTrue(AudioSourceScope.meetingProcesses(in: all, extraNames: ["say"]).contains { $0.name == "say" })
    }

    func testDisplayNameDeduplicates() {
        let picked = AudioSourceScope.meetingProcesses(in: all)
        XCTAssertEqual(AudioSourceScope.displayName(of: picked), "腾讯会议、飞书、Teams")
    }
}
