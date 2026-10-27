import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject {
    static let shared = FloatingPanelController()

    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var appState: AppState?
    private var observers: [NSObjectProtocol] = []
    private var snapTask: Task<Void, Never>?

    /// 默认窗口大小（实际大小由 SwiftUI fixedSize 收缩决定，这里只是初始 contentRect）
    private static let defaultSize = CGSize(width: 160, height: 64)
    private static let defaultMargin: CGFloat = 16
    /// 拖动到距屏幕边缘小于此阈值时自动吸附
    private static let snapThreshold: CGFloat = 20
    /// 拖出屏幕左 / 右边缘超过这么多时收起成贴边窄条(像微信通话小窗)
    private static let collapseOverhang: CGFloat = 12
    /// 收起时拖动窄条：开始拖动时的鼠标位置和窗口位置
    private var dockDragStart: (mouse: CGPoint, frame: CGRect)?

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// 根据当前设置同步显示 / 隐藏 / 行刷新
    func sync() {
        let settings = SettingsStore.shared
        if settings.floatingEnabled {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        guard let appState else { return }
        if panel == nil {
            buildPanel(appState: appState)
        }
        resizeToFitContent()
        panel?.orderFrontRegardless()
    }

    /// 用 SwiftUI 的 fittingSize 调整 panel 尺寸，保持左上角不动。
    /// 立即同步一次；再在下一帧补一次，覆盖 SwiftUI view 异步重渲染的情况。
    private func resizeToFitContent() {
        applyFitOnce()
        Task { @MainActor [weak self] in
            self?.applyFitOnce()
        }
    }

    private func applyFitOnce() {
        guard let panel, let hosting = hostingView else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        guard fit.width > 1, fit.height > 1 else { return }
        var frame = panel.frame
        let dh = fit.height - frame.height
        frame.origin.y -= dh
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            if let edge = SettingsStore.shared.floatingDockEdge {
                // 收起时贴住那条边
                frame.origin.x = edge == .left ? visible.minX : visible.maxX - fit.width
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - fit.height)
            } else if abs(frame.maxX - visible.maxX) < 1 {
                // 贴着右边时保持右边不动(从右边展开时往左长)
                frame.origin.x = visible.maxX - fit.width
            }
        }
        frame.size = fit
        panel.setFrame(frame, display: true)
    }

    /// 收起成贴在 edge 那条边上的窄条(只显示各行的剩余百分比)。
    private func collapse(to edge: FloatingDockEdge) {
        SettingsStore.shared.floatingDockEdge = edge
        panel?.isMovableByWindowBackground = false
        resizeToFitContent()
    }

    /// 点收起的窄条：展开回原来的悬浮窗，仍贴着那条边。
    func expand() {
        guard SettingsStore.shared.floatingDockEdge != nil else { return }
        SettingsStore.shared.floatingDockEdge = nil
        panel?.isMovableByWindowBackground = true
        resizeToFitContent()
    }

    /// 收起时拖动窄条：只沿着边上下移动。
    func dragDocked(ended: Bool) {
        guard let panel, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let mouse = NSEvent.mouseLocation
        let start = dockDragStart ?? (mouse, panel.frame)
        dockDragStart = ended ? nil : start
        var frame = panel.frame
        frame.origin.y = min(max(start.frame.origin.y + mouse.y - start.mouse.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
        if ended { SettingsStore.shared.floatingPanelFrame = frame }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func buildPanel(appState: AppState) {
        let settings = SettingsStore.shared
        let content = AnyView(
            FloatingContentView(settings: settings)
                .environment(appState)
        )
        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // hosting view 的 layer 默认会用系统底色填满矩形 content,会在 SwiftUI 圆角外露出"直角边"。
        // 强制 layer 透明,圆角外的像素就由窗口的透明背景接管,NSPanel 也会按真实 alpha 画阴影。
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let initialFrame = settings.floatingPanelFrame ?? Self.defaultFrame()
        let panel = FloatingPanel(contentRect: initialFrame)
        panel.contentView = hosting
        // 让窗口尺寸跟随 SwiftUI 内容收缩
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.setFrame(adjustedFrame(initialFrame), display: false)
        // 上次退出时是收起的：窄条自己处理拖动
        panel.isMovableByWindowBackground = settings.floatingDockEdge == nil

        self.panel = panel
        self.hostingView = hosting
        registerObservers(for: panel)
    }

    private func registerObservers(for panel: NSPanel) {
        let center = NotificationCenter.default
        let move = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistFrame()
            }
        }
        let resize = center.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.persistFrame()
            }
        }
        observers = [move, resize]
    }

    private func persistFrame() {
        guard let panel else { return }
        SettingsStore.shared.floatingPanelFrame = panel.frame

        // 拖动期间 didMove 会持续触发,延迟一小段时间没有新事件再吸附,
        // 用此 debounce 近似"拖动结束"语义(isMovableByWindowBackground 没有显式结束通知)
        snapTask?.cancel()
        snapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.snapToEdgeIfNeeded()
        }
    }

    private func snapToEdgeIfNeeded() {
        guard let panel else { return }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        // 已经收起：位置由 dragDocked 控制
        guard SettingsStore.shared.floatingDockEdge == nil else { return }
        // 拖出左 / 右屏幕边缘：收起成贴边的窄条
        let visible = screen.visibleFrame
        if panel.frame.minX < visible.minX - Self.collapseOverhang {
            collapse(to: .left)
            return
        }
        if panel.frame.maxX > visible.maxX + Self.collapseOverhang {
            collapse(to: .right)
            return
        }
        let snapped = snappedFrame(panel.frame, on: screen)
        guard snapped != panel.frame else { return }
        panel.setFrame(snapped, display: true, animate: true)
        // setFrame 会再次触发 didMove,但 snapped == snappedFrame(snapped),不会无限循环
        SettingsStore.shared.floatingPanelFrame = snapped
    }

    private func snappedFrame(_ frame: CGRect, on screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        let threshold = Self.snapThreshold
        var origin = frame.origin

        if abs(frame.minX - visible.minX) < threshold {
            origin.x = visible.minX
        } else if abs(visible.maxX - frame.maxX) < threshold {
            origin.x = visible.maxX - frame.width
        }

        if abs(frame.minY - visible.minY) < threshold {
            origin.y = visible.minY
        } else if abs(visible.maxY - frame.maxY) < threshold {
            origin.y = visible.maxY - frame.height
        }

        return CGRect(origin: origin, size: frame.size)
    }

    /// 若已保存的 frame 落在屏幕之外，回落到默认位置
    private func adjustedFrame(_ frame: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        let onScreen = screens.contains { $0.visibleFrame.intersects(frame) }
        return onScreen ? frame : Self.defaultFrame()
    }

    private static func defaultFrame() -> CGRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = defaultSize
        let origin = CGPoint(
            x: screenFrame.maxX - size.width - defaultMargin,
            y: screenFrame.maxY - size.height - defaultMargin
        )
        return CGRect(origin: origin, size: size)
    }
}
