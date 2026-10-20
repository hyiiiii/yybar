import SwiftUI
import AppKit

// MARK: - StatusItemController
//
// 菜单栏图标(NSStatusItem)。左键：打开主窗口的统计概览;右键：小菜单。
// 图标由 MenuBarBadgeImage 绘制;数据变化时通过 Observation 重绘。
// 服务使用中时图标呼吸(1.6s 一周期):静态底图只在数据变化时画一次，呼吸中的图标以识别色单独画成一层，
// 交给按钮上的 CALayer 做透明度动画(Core Animation 在系统渲染进程里播放，不占 App 的 CPU)。
// 等待审批的服务保持识别色。
// 设置里勾选了「菜单栏」的其他账号排在同服务本机账号之后，只显示额度，不呼吸。

final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var item: NSStatusItem?
    private var appState: AppState?
    /// 叠在按钮上的呼吸层(只在有服务使用中时存在)。
    private var breathLayer: CALayer?
    private var frameObserver: NSObjectProtocol?
    private var appearanceObserver: NSKeyValueObservation?
    /// 上次画图时菜单栏是否深色(彩色模式下文字色据此选择)。
    private var drawnDark: Bool?

    func attach(appState: AppState) {
        self.appState = appState
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageOnly
        self.item = item
        if let button = item.button {
            button.wantsLayer = true
            // 按钮宽度随文字变化，呼吸层跟着重新对齐。
            button.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: button, queue: .main
            ) { _ in
                MainActor.assumeIsolated { StatusItemController.shared.layoutBreathLayer() }
            }
            // 彩色模式下文字色按菜单栏明暗自己选，菜单栏随壁纸变色时重画。
            // 注意：每次换图 NSStatusItem 都会给其他显示器渲染副本(replicant),期间临时切换按钮外观并触发这个通知;
            // 所以不在通知里直接重画，而是稍后在正常上下文里重新判断明暗，真的变了才重画，否则会自己无限循环。
            appearanceObserver = button.observe(\.effectiveAppearance) { _, _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { StatusItemController.shared.menuBarAppearanceMayHaveChanged() }
                }
            }
        }
        render()
    }

    // MARK: Click

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            WindowCoordinator.shared.showMain(.overview)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Open Statistics", "打开统计"), action: #selector(openStats), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Settings…", "设置…"), action: #selector(openSettings), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Refresh Now", "立即刷新"), action: #selector(refreshNow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Quit yybar", "退出 yybar"), action: #selector(quit), keyEquivalent: "q").target = self
        guard let button = item?.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openStats() { WindowCoordinator.shared.showMain(.overview) }
    @objc private func openSettings() { WindowCoordinator.shared.showMain(.settings) }
    @objc private func refreshNow() { Task { await appState?.refreshNow() } }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Drawing

    /// 在 Observation 跟踪下绘制，依赖的数据(额度、设置、活动状态)一变就重新绘制并重新跟踪。
    private func render() {
        withObservationTracking {
            draw()
        } onChange: {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { StatusItemController.shared.render() }
            }
        }
    }

    private func menuBarAppearanceMayHaveChanged() {
        guard drawnDark != nil, MenuBarBadgeImage.menuBarIsDark() != drawnDark else { return }
        draw()
    }

    private func draw() {
        guard let appState, let button = item?.button else { return }
        drawnDark = MenuBarBadgeImage.menuBarIsDark()
        let settings = SettingsStore.shared
        let shown = Set(UsageApp.allCases.filter { settings.effectiveMenuBarShow($0) })
        let monitor = UsageActivityMonitor.shared
        let waiting = settings.menuBarHoldColorWhileWaiting ? monitor.waitingApps.intersection(shown) : []
        let breathing = settings.menuBarBreatheWhenActive ? monitor.activeApps.intersection(shown).subtracting(waiting) : []

        // 每个服务：本机账号在前，勾选了「菜单栏」的其他账号紧随其后;Codex → Claude → Grok → Grok Bot → Gemini → agy。
        var entries: [MenuBarBadgeImage.Entry] = []
        for app in UsageApp.allCases {
            if shown.contains(app) { entries.append(.init(app: app, snapshot: appState.localQuota(for: app), isLocal: true)) }
            for other in appState.otherAccountsShown(for: app, inMenuBar: true) {
                entries.append(.init(app: app, snapshot: other.snapshot, isLocal: false))
            }
        }

        let badge = MenuBarBadgeImage.make(
            entries: entries,
            window: settings.menuBarWindow,
            breathing: breathing,
            waiting: waiting
        )
        button.image = badge.image
        button.setAccessibilityLabel(MenuBarBadgeImage.accessibilityLabel(entries: entries, window: settings.menuBarWindow))
        updateBreathLayer(badge.breathOverlay, in: button)
    }

    /// 有呼吸中的服务时，在按钮上叠一层识别色图标，透明度 0 → 1 → 0 循环(0.8s 渐入 + 0.8s 渐出);
    /// 没有时移除。数据变化只换这层的内容，不打断正在进行的动画。
    private func updateBreathLayer(_ overlay: NSImage?, in button: NSStatusBarButton) {
        guard let overlay, let host = button.layer else {
            breathLayer?.removeFromSuperlayer()
            breathLayer = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer: CALayer
        if let existing = breathLayer {
            layer = existing
        } else {
            layer = CALayer()
            // 模型值取 1:主菜单栏上看到的是动画；其他显示器菜单栏上的副本是按模型值截的静态图，显示识别色，同样能看出在用。
            layer.opacity = 1
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0
            pulse.toValue = 1
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            // 缓入缓出接近原来的 (1 - cos) / 2 呼吸曲线。
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "breath")
            host.addSublayer(layer)
            breathLayer = layer
        }
        let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer.contentsScale = scale
        layer.contents = overlay.layerContents(forContentsScale: scale)
        CATransaction.commit()
        layoutBreathLayer()
    }

    /// 呼吸层与按钮画底图的位置严格重合。
    fileprivate func layoutBreathLayer() {
        guard let layer = breathLayer, let button = item?.button, let image = button.image else { return }
        let rect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
        let frame = NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                           width: image.size.width, height: image.size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = button.backingAlignedRect(frame, options: .alignAllEdgesNearest)
        CATransaction.commit()
    }
}

enum MenuBarLogo {
    private static let cache = NSCache<NSString, NSImage>()
    private static let size = NSSize(width: 18, height: 18)

    static func rawImage(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.size = size
        cache.setObject(img, forKey: name as NSString)
        return img
    }
}

enum MenuBarBadgeImage {
    private static let iconSize: CGFloat = 18
    private static let height: CGFloat = 22
    private static let iconTextGap: CGFloat = 3
    private static let segmentGap: CGFloat = 9
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    /// 菜单栏上的一个账号。呼吸 / 等待审批只作用于本机账号(只有本机 CLI 的日志能看出是否在用)。
    struct Entry {
        let app: UsageApp
        let snapshot: QuotaSnapshot?
        let isLocal: Bool
    }

    /// 菜单栏图标：静态底图，加上呼吸中的图标单独画成的同尺寸透明图(没有呼吸时为 nil)。
    struct Badge {
        let image: NSImage
        let breathOverlay: NSImage?
    }

    static func make(
        entries: [Entry],
        window: MenuBarWindowChoice,
        breathing: Set<UsageApp> = [],
        waiting: Set<UsageApp> = []
    ) -> Badge {
        let items: [BadgeItem] = entries.map { entry in
            let text = entry.app.hasSinglePeriod ? pctOrPlaceholder(entry.snapshot?.primary) : pctText(entry.snapshot, window: window)
            return BadgeItem(app: entry.app, logo: entry.app.rawValue,
                             fallback: entry.app.fallbackLetter,
                             text: text, isLocal: entry.isLocal)
        }
        let attrs = textAttributes
        let textWidths = items.map { $0.text.size(withAttributes: attrs).width }
        let width = items.enumerated().reduce(CGFloat.zero) { partial, entry in
            let gap = entry.offset == 0 ? CGFloat.zero : segmentGap
            let textPart = entry.element.text.isEmpty ? 0 : iconTextGap + ceil(textWidths[entry.offset])
            return partial + gap + iconSize + textPart
        }

        // 没有任何 item 时仍要返回一个最小图像（至少留一个 logo 占位以免菜单栏图标完全消失）
        if items.isEmpty {
            return Badge(image: placeholderImage(), breathOverlay: nil)
        }

        // 呼吸时需要彩色，不能再用 template 图(系统会把它统一染成黑/白),
        // 改为按菜单栏当前明暗自己选文字色。
        let colored = !breathing.isEmpty || !waiting.isEmpty
        let dark = colored && menuBarIsDark()
        let baseColor: NSColor = dark ? .white : NSColor.black.withAlphaComponent(0.85)
        let textAttrs: [NSAttributedString.Key: Any] = colored
            ? [.font: font, .foregroundColor: baseColor]
            : attrs

        let size = NSSize(width: max(ceil(width), iconSize), height: height)
        // 每个图标的 x 位置，底图和呼吸层共用。
        var iconX: [CGFloat] = []
        var cursor: CGFloat = 0
        for (index, item) in items.enumerated() {
            if index > 0 { cursor += segmentGap }
            iconX.append(cursor)
            cursor += iconSize
            if !item.text.isEmpty { cursor += iconTextGap + ceil(textWidths[index]) }
        }

        // 底图：呼吸中的图标停在底色(呼吸层透明度为 0 时的样子),等待审批的保持识别色。
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, item) in items.enumerated() {
            let x = iconX[index]
            if colored {
                let hold = item.isLocal && waiting.contains(item.app)
                drawIcon(item, x: x, tint: hold ? breatheColor(item.app, dark: dark) : baseColor)
            } else {
                drawIcon(item, x: x)
            }
            if !item.text.isEmpty {
                let textX = x + iconSize + iconTextGap
                let textSize = item.text.size(withAttributes: textAttrs)
                item.text.draw(at: NSPoint(x: textX, y: floor((height - textSize.height) / 2)),
                               withAttributes: textAttrs)
            }
        }
        image.unlockFocus()
        image.isTemplate = !colored

        // 呼吸层：只有呼吸中的图标，画成识别色，其余透明。
        let breathingItems = items.indices.filter { items[$0].isLocal && breathing.contains(items[$0].app) }
        guard !breathingItems.isEmpty else { return Badge(image: image, breathOverlay: nil) }
        let overlay = NSImage(size: size)
        overlay.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        for index in breathingItems {
            drawIcon(items[index], x: iconX[index], tint: breatheColor(items[index].app, dark: dark), rainbow: true)
        }
        overlay.unlockFocus()
        return Badge(image: image, breathOverlay: overlay)
    }

    /// 呼吸到的识别色。深色菜单栏上用提亮版本，保证能看出变化。
    private static func breatheColor(_ app: UsageApp, dark: Bool) -> NSColor {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        }
        switch app {
        // 深色栏上用更深的石墨灰(白 → #48484A),浅色栏上用浅灰(黑 → #AEAEB2),呼吸幅度更明显。
        case .codex: return dark ? rgb(72, 72, 74) : rgb(174, 174, 178)      // 石墨灰
        case .claude: return dark ? rgb(232, 134, 95) : rgb(217, 119, 87)    // 桃橙
        case .grok, .grokBot: return dark ? rgb(29, 29, 31) : rgb(161, 161, 166)       // 黑(浅色栏上淡出)
        // agy 实际画彩虹色 logo(见 drawIcon),这里的蓝色只在找不到彩色版时用。
        case .gemini, .agy: return dark ? rgb(106, 158, 240) : rgb(74, 134, 232)      // Google 蓝
        }
    }

    /// 菜单栏当前是否深色。菜单栏明暗跟随壁纸，和 App 外观无关，
    /// 因此读状态栏窗口自身的 effectiveAppearance。
    static func menuBarIsDark() -> Bool {
        let window = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBar") }
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight]).map {
            $0 == .darkAqua || $0 == .vibrantDark
        } ?? false
    }

    static func accessibilityLabel(entries: [Entry], window: MenuBarWindowChoice) -> String {
        let parts = entries.map { entry -> String in
            switch entry.app {
            case .codex: return "Codex \(pctText(entry.snapshot, window: window))"
            case .claude: return "Claude \(pctText(entry.snapshot, window: window))"
            case .grok, .grokBot: return "\(entry.app.displayName) \(pctOrPlaceholder(entry.snapshot?.primary)) remaining"
            case .gemini, .agy: return "\(entry.app.displayName) \(pctText(entry.snapshot, window: window))"
            }
        }
        return parts.isEmpty ? "yybar" : parts.joined(separator: ", ")
    }

    private static var textAttributes: [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.black
        ]
    }

    private static func pctText(_ snap: QuotaSnapshot?, window: MenuBarWindowChoice) -> String {
        switch window {
        case .fiveHour:
            return pctOrPlaceholder(snap?.fiveHour)
        case .weekly:
            return pctOrPlaceholder(snap?.weekly)
        case .both:
            let a = pctOrPlaceholder(snap?.fiveHour)
            let b = pctOrPlaceholder(snap?.weekly)
            return "\(a)/\(b)"
        }
    }

    private static func pctOrPlaceholder(_ window: QuotaWindow?) -> String {
        guard let window else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private static func placeholderImage() -> NSImage {
        let image = NSImage(size: NSSize(width: iconSize, height: height))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        if let img = MenuBarLogo.rawImage(named: "codex") {
            img.draw(in: NSRect(x: 0, y: floor((height - iconSize) / 2),
                                width: iconSize, height: iconSize))
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// rainbow:呼吸层里 Antigravity 画彩虹色版 logo。
    private static func drawIcon(_ item: BadgeItem, x: CGFloat, tint: NSColor? = nil, rainbow: Bool = false) {
        let rect = NSRect(x: x, y: floor((height - iconSize) / 2), width: iconSize, height: iconSize)
        // Antigravity 呼吸时用 App 里的彩虹色版 logo,不染单一识别色。
        if rainbow, item.app == .agy, let color = MenuBarLogo.rawImage(named: "agy-color") {
            color.draw(in: rect)
            return
        }
        if let img = MenuBarLogo.rawImage(named: item.logo) {
            if let tint {
                tinted(img, color: tint).draw(in: rect)
            } else {
                img.draw(in: rect)
            }
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let size = item.fallback.size(withAttributes: attrs)
        item.fallback.draw(at: NSPoint(x: x + floor((iconSize - size.width) / 2),
                                       y: floor((height - size.height) / 2)),
                           withAttributes: attrs)
    }

    /// 把单色 logo 染成指定颜色(logo 本身是白色 SVG,只取其 alpha)。
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private struct BadgeItem {
        let app: UsageApp
        let logo: String
        let fallback: String
        let text: String
        let isLocal: Bool
    }
}
