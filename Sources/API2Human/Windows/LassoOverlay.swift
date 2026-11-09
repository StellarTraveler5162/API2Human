import AppKit

/// "即圈即搜"的圈选覆盖层：在定格的屏幕截图上，按住鼠标拖动圈出一块区域。
/// - 每块屏幕一个全屏窗口，显示定格画面并压暗；圈中的部分恢复亮度
/// - 松开鼠标完成；单击、右键或 Esc 取消
/// - 覆盖层同样不参与屏幕捕获：共享屏幕时对方看不到你在圈选
@MainActor
final class LassoOverlay {
    typealias Completion = (CGImage?) -> Void

    private static var current: LassoOverlay?

    private var windows: [NSWindow] = []
    private var completion: Completion?
    private var keyMonitor: Any?

    static func present(shots: [ScreenCapture.Shot], completion: @escaping Completion) {
        current?.finish(nil)
        let overlay = LassoOverlay()
        overlay.completion = completion
        for shot in shots {
            let window = OverlayWindow(screen: shot.screen)
            let view = LassoView(frame: NSRect(origin: .zero, size: shot.screen.frame.size), shot: shot) { [weak overlay] image in
                overlay?.finish(image)
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            overlay.windows.append(window)
        }
        // 本 App 在后台时窗口拿不到键盘焦点，用本地监听兜底 Esc
        overlay.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak overlay] event in
            if event.keyCode == 53 { overlay?.finish(nil); return nil }
            return event
        }
        NSApp.activate()
        overlay.windows.first?.makeKey()
        NSCursor.crosshair.set()
        current = overlay
    }

    private func finish(_ image: CGImage?) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSCursor.arrow.set()
        LassoOverlay.current = nil
        completion(image)
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = CommandLine.arguments.contains("--sharing-visible") ? .readOnly : .none
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
}

private final class LassoView: NSView {
    private let shot: ScreenCapture.Shot
    private let done: (CGImage?) -> Void
    private var path = NSBezierPath()
    private var points: [NSPoint] = []

    init(frame: NSRect, shot: ScreenCapture.Shot, done: @escaping (CGImage?) -> Void) {
        self.shot = shot
        self.done = done
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(shot.image, in: bounds)
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        if points.count > 2 {
            // 圈中的部分恢复原样
            ctx.saveGState()
            ctx.addPath(path.cgPathClosed)
            ctx.clip()
            ctx.draw(shot.image, in: bounds)
            ctx.restoreGState()
            NSColor.systemOrange.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
        hint.draw(at: NSPoint(x: bounds.midX - hint.size().width / 2, y: bounds.maxY - 80))
    }

    private lazy var hint = NSAttributedString(
        string: "  按住鼠标圈出代码或题目 · 松开即搜 · Esc / 右键取消  ",
        attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                     .foregroundColor: NSColor.white,
                     .backgroundColor: NSColor.black.withAlphaComponent(0.6)])

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        points = [p]
        path = NSBezierPath()
        path.move(to: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        points.append(p)
        path.line(to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = boundingRect()
        guard rect.width > 12, rect.height > 12 else { done(nil); return }   // 单击 = 取消
        done(crop(rect))
    }

    override func rightMouseDown(with event: NSEvent) { done(nil) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { done(nil) } else { super.keyDown(with: event) } }

    private func boundingRect() -> NSRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    /// 视图坐标（左下原点、点）-> 截图像素坐标（左上原点）
    private func crop(_ rect: NSRect) -> CGImage? {
        let scaleX = CGFloat(shot.image.width) / bounds.width
        let scaleY = CGFloat(shot.image.height) / bounds.height
        let pixel = CGRect(x: rect.minX * scaleX, y: (bounds.height - rect.maxY) * scaleY,
                           width: rect.width * scaleX, height: rect.height * scaleY).integral
        return shot.image.cropping(to: pixel)
    }
}

private extension NSBezierPath {
    var cgPathClosed: CGPath {
        let p = CGMutablePath()
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo: p.move(to: pts[0])
            case .lineTo: p.addLine(to: pts[0])
            case .curveTo, .cubicCurveTo: p.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .quadraticCurveTo: p.addQuadCurve(to: pts[1], control: pts[0])
            case .closePath: p.closeSubpath()
            @unknown default: break
            }
        }
        p.closeSubpath()
        return p
    }
}
