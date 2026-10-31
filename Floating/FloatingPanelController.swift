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
    /// 往屏幕里拉收起的窄条超过这么多(pt)才换成展开的内容、跟着鼠标拉出来；没到之前只沿着屏幕边上下挪
    private static let pullStart: CGFloat = 8
    /// 正在把窄条拉出来(像拉抽屉):窄条原来贴的边，和展开的内容量好尺寸后「只露窄条那么宽」的位置(拖动距离为 0 时的窗口原点)
    private struct Pull {
        let edge: FloatingDockEdge
        var base: NSPoint?
    }
    private var pull: Pull?
    /// 这次按下以来的拖动距离
    private var dragDelta: CGVector = .zero
    /// 按着时接拖动 / 松手的 app 内事件监听(pressBegan 装上，松手时拿掉)
    private var pressMonitor: Any?
    private var pressStartMouse: NSPoint = .zero
    private var pressStartOrigin: NSPoint = .zero
    private var pressMoved = false

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// 根据当前设置同步显示 / 隐藏 / 行刷新：设置 · 服务里有勾了「悬浮窗」的账号(本机账号看服务开关和悬浮窗勾选，
    /// 其他账号看它那一行的启用和勾选)就显示，一个都没有就关掉(2026-10-29 前另有「显示悬浮窗」总开关)。
    func sync() {
        guard let appState else { return }
        if QuotaEntry.list(appState, inMenuBar: false).isEmpty {
            hide()
        } else {
            show()
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
        if var current = pull {
            // 拉抽屉：内容换成展开的、量到尺寸后，放在只露窄条那么宽的位置(和单击展开滑出来的起点一样，顶边和窄条对齐)，
            // 再按拖动距离挪出来；之后由 drag(by:from:) 跟着鼠标走，这里不再动它
            guard current.base == nil, fit.width > Self.tabWidth + 10 else { return }
            let x = current.edge == .right ? visible.maxX - Self.tabWidth : visible.minX - fit.width + Self.tabWidth
            current.base = NSPoint(x: x, y: panel.frame.maxY - fit.height - dragDelta.dy)
            pull = current
            panel.setFrame(NSRect(origin: pullOrigin(current), size: fit), display: true)
            return
        }
        if let edge = SettingsStore.shared.floatingDockEdge {
            // 收起时贴住那条边
            frame.origin.x = edge == .left ? visible.minX : visible.maxX - fit.width
        } else if abs(frame.maxX - visible.maxX) < 1 {
            // 贴着右边时保持右边不动(往左长)
            frame.origin.x = visible.maxX - fit.width
        } else {
            // 展开时整块留在屏幕里(从右边拉出来的窄条往右长，会伸出屏幕)
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - fit.width))
        }
        // 上下也留在屏幕里(换成详细样式、账号多了变高时往下长，碰到 Dock 就整块往上挪)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - fit.height)
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

    /// 悬浮窗上按下(FloatingMouseView)：记下鼠标和窗口位置，之后的拖动和松手用 app 内的事件监听接——不靠按下的那个视图，
    /// 拉抽屉时 SwiftUI 把窄条换成展开的内容、那个视图被拿掉，靠它就收不到后面的拖动和松手(2026-10-31 收着时拖不动就是这个)。
    /// 移动超过 3pt 才算拖动(和以前一样)。
    func pressBegan() {
        guard let panel else { return }
        FloatingMenuController.shared.close()
        if let monitor = pressMonitor { NSEvent.removeMonitor(monitor) }
        pressStartMouse = NSEvent.mouseLocation
        pressStartOrigin = panel.frame.origin
        pressMoved = false
        pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let released = event.type == .leftMouseUp
            MainActor.assumeIsolated { self?.handlePress(released: released) }
            return event
        }
    }

    private func handlePress(released: Bool) {
        let p = NSEvent.mouseLocation
        if released {
            if let monitor = pressMonitor { NSEvent.removeMonitor(monitor) }
            pressMonitor = nil
            mouseReleased(moved: pressMoved)
            return
        }
        if !pressMoved, hypot(p.x - pressStartMouse.x, p.y - pressStartMouse.y) < 3 { return }
        pressMoved = true
        drag(by: CGVector(dx: p.x - pressStartMouse.x, dy: p.y - pressStartMouse.y), from: pressStartOrigin)
    }

    /// 按着拖动(delta 是这次按下以来鼠标挪了多少，startOrigin 是按下时的窗口原点)。
    /// 展开时整块跟着鼠标走。收起时：往屏幕里拉不到 8pt 只沿着屏幕边上下挪窄条；超过了就开始拉抽屉——
    /// 换成展开的内容、放在只露窄条那么宽的位置，跟着鼠标一点点拉出来(和单击时从屏幕边滑出来一样，只是由鼠标带着走)。
    /// 2026-10-31 前窄条整个跟着鼠标走，松手时才在原地一下子变成展开的。
    func drag(by delta: CGVector, from startOrigin: NSPoint) {
        guard let panel, !animating else { return }
        dragDelta = delta
        if let current = pull {
            if current.base != nil { panel.setFrameOrigin(pullOrigin(current)) }
            return
        }
        if let edge = SettingsStore.shared.floatingDockEdge {
            let away = edge == .right ? -delta.dx : delta.dx
            guard away >= Self.pullStart else {
                panel.setFrameOrigin(NSPoint(x: startOrigin.x, y: startOrigin.y + delta.dy))
                return
            }
            pull = Pull(edge: edge, base: nil)
            SettingsStore.shared.floatingDockEdge = nil
            resizeToFitContent()
            return
        }
        panel.setFrameOrigin(NSPoint(x: startOrigin.x + delta.dx, y: startOrigin.y + delta.dy))
    }

    /// 拉抽屉时窗口的位置：只能往屏幕里拉，往外推不动(露出来的至少是窄条那么宽)。
    private func pullOrigin(_ current: Pull) -> NSPoint {
        guard let base = current.base else { return panel?.frame.origin ?? .zero }
        let x = current.edge == .right ? min(base.x, base.x + dragDelta.dx) : max(base.x, base.x + dragDelta.dx)
        return NSPoint(x: x, y: base.y + dragDelta.dy)
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
        if let current = pull {
            pull = nil
            guard let base = current.base else {
                // 展开的内容还没换好就松手了：照旧收着
                settings.floatingDockEdge = current.edge
                resizeToFitContent()
                return
            }
            let frame = panel.frame
            let revealed = current.edge == .right ? base.x - frame.minX : frame.minX - base.x
            if revealed < (frame.width - Self.tabWidth) / 3 {
                // 拉出来不到三分之一：滑回去收着
                collapse(to: current.edge, visible: visible)
            } else {
                // 拉出来超过三分之一：整块滑进屏幕里，停在松手的高度
                var target = frame
                target.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                target.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                if target != frame { animate(to: target) } else { persistFrame() }
            }
            return
        }
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
            // 收着的窄条只沿着屏幕边上下挪(往里拉就成了上面的拉抽屉)，一般到不了这里；万一离边远了就地展开
            settings.floatingDockEdge = nil
            resizeToFitContent()
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

    // MARK: 右键菜单

    /// 右键悬浮窗(展开的、收起的窄条都一样):统计 / 设置 / bar,和悬浮窗样式(简略 / 详细，勾着当前的)。见 FloatingMenuController。
    func showContextMenu(at point: NSPoint) {
        FloatingMenuController.shared.show(at: point, style: SettingsStore.shared.floatingStyle) { [weak self] action in
            switch action {
            case .stats: WindowCoordinator.shared.showMain(.overview)
            case .settings: WindowCoordinator.shared.showMain(.settings)
            case .bar: WindowCoordinator.shared.showMain(.bar)
            case .style(let style):
                guard style != SettingsStore.shared.floatingStyle else { return }
                SettingsStore.shared.floatingStyle = style
                self?.sync()
            }
        }
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

// MARK: - FloatingMenuController
//
// 悬浮窗的右键菜单(2026-10-31):自己画的小浮层。本机 macOS 的系统右键菜单不画我们给的图标(只有系统认得的「设置」会
// 自己配齿轮，显式给了图标反而连齿轮也没了)，所以和 Windows 版一样自己画：底色、描边、圆角和悬浮窗一样，每项前面有图标，
// 悬停时强调色底白字(和系统菜单一样);点了某项、点到别处、按 Esc 就收起。

enum FloatingMenuAction {
    case stats, settings, bar
    case style(FloatingStyle)
}

@MainActor
final class FloatingMenuController {
    static let shared = FloatingMenuController()

    private var panel: FloatingMenuPanel?
    private var monitors: [Any] = []

    /// 左上角放在光标处(屏幕坐标)，右边 / 下边放不下就往左 / 往上翻。
    func show(at point: NSPoint, style: FloatingStyle, onPick: @escaping (FloatingMenuAction) -> Void) {
        close()
        let hosting = NSHostingView(rootView: FloatingMenuView(style: style) { [weak self] action in
            self?.close()
            onPick(action)
        })
        let size = hosting.fittingSize
        let panel = FloatingMenuPanel(size: size)
        panel.contentView = hosting
        let visible = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x, y: point.y - size.height)
        if origin.x + size.width > visible.maxX { origin.x = point.x - size.width }
        if origin.y < visible.minY { origin.y = point.y }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        // 点到本 app 别的窗口、按 Esc:收起(Esc 吃掉);点到别的 app:收起
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let (isKey, keyCode, windowNumber) = (event.type == .keyDown, event.keyCode, event.windowNumber)
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel else { return false }
                if isKey {
                    guard keyCode == 53 else { return false }
                    self.close()
                    return true
                }
                if windowNumber != panel.windowNumber { self.close() }
                return false
            }
            return swallow ? nil : event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 菜单浮层：能成为 key(收 Esc、第一下点击就生效),但不激活 App。
private final class FloatingMenuPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

private struct FloatingMenuView: View {
    let style: FloatingStyle
    let onPick: (FloatingMenuAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FloatingMenuRow(title: tr("Statistics", "统计"), action: { onPick(.stats) }) {
                Image(systemName: "chart.bar.xaxis")
            }
            FloatingMenuRow(title: tr("Settings", "设置"), action: { onPick(.settings) }) {
                Image(systemName: "gearshape")
            }
            FloatingMenuRow(title: "bar", action: { onPick(.bar) }) {
                PlayingCardsIcon(size: 10.5)
            }
            Divider()
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            ForEach([FloatingStyle.compact, .detailed], id: \.self) { option in
                FloatingMenuRow(title: option == .compact ? tr("Compact", "简略") : tr("Detailed", "详细"),
                                action: { onPick(.style(option)) }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(style == option ? 1 : 0)
                }
            }
        }
        .padding(5)
        .frame(minWidth: 150, alignment: .leading)
        .background {
            // 和悬浮窗同一底色
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .fixedSize()
    }
}

/// 菜单里的一项：16pt 图标列 + 13pt 文字，悬停时强调色底白字。
private struct FloatingMenuRow<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            icon
                .font(.system(size: 12))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(hovered ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovered ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}
