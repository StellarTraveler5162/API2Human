import AppKit
import SwiftUI

/// 无边框、置顶、透明、可拖动、不抢焦点的悬浮面板。
final class FloatingPanel: NSPanel {
    init<Content: View>(contentRect: NSRect, @ViewBuilder content: () -> Content) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        // 跟随所有桌面空间，并能浮在全屏会议 App（Zoom/腾讯会议全屏）之上
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false          // 切到会议软件时不消失
        becomesKeyOnlyIfNeeded = true      // 点击不会把焦点从会议软件抢走
        isMovableByWindowBackground = true // 任意空白处拖动
        isExcludedFromWindowsMenu = true
        // 第 1 层防护：不参与屏幕捕获（会议软件共享屏幕、截图时拍不到）。调试用 --sharing-visible 关掉对比
        sharingType = CommandLine.arguments.contains("--sharing-visible") ? .readOnly : .none

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        minSize = NSSize(width: 320, height: 260)

        let hosting = NSHostingView(rootView: content().ignoresSafeArea())
        hosting.sizingOptions = []          // 窗口尺寸由用户拖拽决定，不由 SwiftUI 内容决定
        contentView = hosting
    }

    // 允许成为 key window，这样回复文本可以选中复制
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
