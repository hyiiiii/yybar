import AppKit
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject {
    static let shared = FloatingPanelController()

    private var panel: FloatingPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var appState: AppState?
    private var observers: [NSObjectProtocol] = []

    /// 默认窗口大小（实际大小由 SwiftUI fixedSize 收缩决定，这里只是初始 contentRect）
    private static let defaultSize = CGSize(width: 160, height: 64)
    private static let defaultMargin: CGFloat = 16
    /// 松手时离屏幕上 / 下边缘小于此距离就吸附过去
    private static let snapThreshold: CGFloat = 20
    /// 松手时窗口离屏幕左 / 右边缘不到这么远(或已经伸出边外)就收起成贴边窄条(像微信通话小窗)
    private static let dockDistance: CGFloat = 24
    /// 拖完收起的窄条，离屏幕左 / 右边不超过这么远就重新贴边，拖得更远就在那里展开
    private static let redockDistance: CGFloat = 60
    /// 收起的窄条宽度(和 FloatingContentView.collapsedTab 一致)
    static let tabWidth: CGFloat = 30
    /// 滑入 / 滑出屏幕边的动画时长
    private static let slideDuration: TimeInterval = 0.22

    /// 正在播放滑入 / 滑出动画：期间不按内容量尺寸，免得打断动画
    private var animating = false
    /// 刚点了展开：等 SwiftUI 换成展开的内容、量到它的尺寸后，从这条边滑出来
    private var pendingSlideOut: FloatingDockEdge?

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
    /// 立即同步一次，再在之后几帧补几次：SwiftUI 按设置变化重画内容是异步的(收起 / 展开时尤其明显),
    /// 只补一次有时还量到旧内容的尺寸，窗口就没变成窄条。
    private func resizeToFitContent() {
        applyFitOnce()
        Task { @MainActor [weak self] in
            for delay: UInt64 in [0, 50, 150, 400] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                self?.applyFitOnce()
            }
        }
    }

    private func applyFitOnce() {
        guard let panel, let hosting = hostingView, !animating else { return }
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        guard fit.width > 1, fit.height > 1 else { return }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        let dh = fit.height - frame.height
        frame.origin.y -= dh
        if let edge = pendingSlideOut {
            // 展开：先摆成「只露出贴边那一条」的位置，再滑出来(内容还没换成展开的就等下一次)
            guard fit.width > Self.tabWidth + 10 else { return }
            pendingSlideOut = nil
            frame.size = fit
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - fit.height)
            frame.origin.x = edge == .left ? visible.minX - fit.width + Self.tabWidth : visible.maxX - Self.tabWidth
            panel.setFrame(frame, display: true)
            var target = frame
            target.origin.x = edge == .left ? visible.minX : visible.maxX - fit.width
            animate(to: target)
            return
        }
        if let edge = SettingsStore.shared.floatingDockEdge {
            // 收起时贴住那条边
            frame.origin.x = edge == .left ? visible.minX : visible.maxX - fit.width
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - fit.height)
        } else if abs(frame.maxX - visible.maxX) < 1 {
            // 贴着右边时保持右边不动(往左长)
            frame.origin.x = visible.maxX - fit.width
        } else {
            // 展开时整块留在屏幕里(从右边拉出来的窄条往右长，会伸出屏幕)
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - fit.width))
        }
        frame.size = fit
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    /// 窗口位置 / 大小的过渡动画(滑入 / 滑出 / 贴回边)。
    private func animate(to frame: CGRect, completion: (@MainActor () -> Void)? = nil) {
        guard let panel else { return }
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            Task { @MainActor [weak self] in
                self?.animating = false
                self?.persistFrame()
                completion?()
            }
        }
    }

    /// 收起：整块滑进屏幕边，只剩贴边的一条，再换成窄条(只显示各行的剩余百分比)。
    private func collapse(to edge: FloatingDockEdge, visible: CGRect) {
        guard let panel else { return }
        var target = panel.frame
        target.origin.x = edge == .left ? visible.minX - target.width + Self.tabWidth : visible.maxX - Self.tabWidth
        target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height)
        animate(to: target) { [weak self] in
            SettingsStore.shared.floatingDockEdge = edge
            self?.resizeToFitContent()
        }
    }

    /// 点收起的窄条：换回展开的内容，从那条边滑出来。
    func expand() {
        guard let edge = SettingsStore.shared.floatingDockEdge else { return }
        pendingSlideOut = edge
        SettingsStore.shared.floatingDockEdge = nil
        resizeToFitContent()
    }

    /// 悬浮窗上的一次按下 → 松开(拖动由 FloatingMouseView 跟着鼠标移窗口)。
    /// 展开时：拖动过就看松手位置：靠近 / 伸出左右边 → 收起；靠近上下边 → 吸附。
    /// 收起时：没拖动 = 单击展开；拖动过 = 放回屏幕边附近继续收着，拖远了就在那里展开。
    func mouseReleased(moved: Bool) {
        guard let panel, !animating else { return }
        let settings = SettingsStore.shared
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? panel.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        guard settings.floatingDockEdge != nil else {
            if moved { releaseExpanded(on: screen) }
            return
        }
        guard moved else {
            expand()
            return
        }
        var frame = panel.frame
        let edge: FloatingDockEdge? = frame.midX - visible.minX < Self.redockDistance ? .left
            : visible.maxX - frame.midX < Self.redockDistance ? .right : nil
        guard let edge else {
            // 拖离了屏幕边：在松手的地方展开(淡入)
            panel.alphaValue = 0
            settings.floatingDockEdge = nil
            resizeToFitContent()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
            return
        }
        // 放回屏幕边：滑回去贴好
        settings.floatingDockEdge = edge
        frame.origin.x = edge == .left ? visible.minX : visible.maxX - frame.width
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        animate(to: frame)
    }

    /// 展开的悬浮窗松手：离屏幕左 / 右边不到 24pt 或伸出边外就收起(那一边接着另一块屏幕时只吸附)，
    /// 离上 / 下边 20pt 内吸附。
    private func releaseExpanded(on screen: NSScreen) {
        guard let panel else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        let hasNeighbor = { (x: CGFloat) in NSScreen.screens.contains { $0 != screen && $0.frame.contains(CGPoint(x: x, y: frame.midY)) } }
        let nearLeft = frame.minX < visible.minX + Self.dockDistance
        let nearRight = frame.maxX > visible.maxX - Self.dockDistance
        if nearLeft || nearRight {
            // 两边都靠(窗口比屏幕还宽)时看鼠标在哪半边
            let edge: FloatingDockEdge = nearLeft && nearRight
                ? (NSEvent.mouseLocation.x < visible.midX ? .left : .right)
                : (nearLeft ? .left : .right)
            if !hasNeighbor(edge == .left ? screen.frame.minX - 1 : screen.frame.maxX + 1) {
                collapse(to: edge, visible: visible)
                return
            }
            frame.origin.x = edge == .left ? visible.minX : visible.maxX - frame.width
        }
        if abs(frame.minY - visible.minY) < Self.snapThreshold {
            frame.origin.y = visible.minY
        } else if abs(visible.maxY - frame.maxY) < Self.snapThreshold {
            frame.origin.y = visible.maxY - frame.height
        }
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        if frame != panel.frame {
            animate(to: frame)
        } else {
            persistFrame()
        }
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

    /// 记住位置(吸附 / 收起在松手时由 mouseReleased 处理)。
    private func persistFrame() {
        guard let panel else { return }
        SettingsStore.shared.floatingPanelFrame = panel.frame
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
