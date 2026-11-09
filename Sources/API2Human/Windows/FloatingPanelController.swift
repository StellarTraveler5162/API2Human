import AppKit
import SwiftUI
import Observation

@MainActor
final class FloatingPanelController {
    private let state: AppState
    private let panel: FloatingPanel
    private static let autosaveName = "API2Human.FloatingPanel"

    init(state: AppState) {
        self.state = state
        panel = FloatingPanel(contentRect: Self.defaultFrame()) {
            FloatingAssistantView().environment(state)
        }
        // 有保存过的位置就恢复，否则贴在屏幕右侧（左边留给会议窗口）
        if !panel.setFrameUsingName(Self.autosaveName) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
    }

    /// 默认：屏幕右侧一条竖栏，宽 400，几乎满高
    private static func defaultFrame() -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 400
        let margin: CGFloat = 12
        return NSRect(x: screen.maxX - width - margin,
                      y: screen.minY + margin,
                      width: width,
                      height: screen.height - margin * 2)
    }

    /// 用 Observation 监听 state，驱动面板显隐 / 透明度 / 位置重置（Step 5 的防共享隐藏也走这里）
    func startObserving() {
        withObservationTracking {
            apply(visible: state.isPanelVisible, opacity: state.panelOpacity)
            _ = state.resetPanelPositionToken
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleResetIfNeeded()
                self.startObserving()
            }
        }
    }

    private var lastResetToken = 0
    private func handleResetIfNeeded() {
        guard state.resetPanelPositionToken != lastResetToken else { return }
        lastResetToken = state.resetPanelPositionToken
        panel.setFrame(Self.defaultFrame(), display: true, animate: true)
        state.isPanelVisible = true
    }

    private func apply(visible: Bool, opacity: Double) {
        panel.alphaValue = opacity
        if visible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }
}
