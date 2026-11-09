import AppKit
import ScreenCaptureKit

/// 屏幕截图（ScreenCaptureKit）：用于"即圈即搜"的定格画面。
/// 需要"屏幕与系统录音"权限；截图时排除本 App 自己的窗口（悬浮窗本来也设了不参与捕获）。
enum ScreenCapture {
    struct Shot {
        let screen: NSScreen
        let image: CGImage      // 像素尺寸 = 屏幕点数 × backingScaleFactor
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹出系统权限请求（只在第一次有效；之后需要用户到系统设置里手动打开）
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor
    static func captureAllScreens() async throws -> [Shot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let own = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        var shots: [Shot] = []
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: own)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(Shot(screen: screen, image: image))
        }
        return shots
    }
}
