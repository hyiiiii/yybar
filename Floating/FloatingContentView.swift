import SwiftUI

// MARK: - FloatingContentView
//
// 见 docs/界面布局.md §2。
// 结构:14pt 圆角 HUD 容器 + .popover material 背景。
// 简略(默认):每行 18pt ServiceTile + flex 4pt bar + 34pt 百分比(状态色)。
// 详细：和菜单栏浮窗的账号块一样(QuotaEntryView:名字、套餐、5H / WK 各一条带重置倒计时)。

struct FloatingContentView: View {
    @Environment(AppState.self) private var appState
    let settings: SettingsStore

    /// 悬浮窗的一行：本机账号或勾选了「悬浮窗」的其他账号。
    private struct Row: Identifiable {
        let id: String
        let app: UsageApp
        let name: String
        let window: QuotaWindow?
    }

    /// 每个服务本机账号在前、其他账号在后;Codex → Claude → Grok → Grok Bot → Gemini → agy。
    /// Grok / Grok Bot 显示周期额度，其余显示 5H。
    private var rows: [Row] {
        var rows: [Row] = []
        for app in UsageApp.allCases {
            if settings.effectiveFloatingShow(app) {
                let snapshot = appState.localQuota(for: app)
                let email: String?
                switch app {
                case .codex: email = appState.codexAccount?.email
                case .claude: email = appState.claudeAccount?.email
                case .grok: email = appState.grokAccount?.email
                case .grokBot: email = appState.grokBotEmail
                case .gemini: email = appState.geminiAppEmail
                case .agy: email = appState.googleEmail
                }
                rows.append(Row(id: "local:\(app.rawValue)", app: app,
                                name: email.map { $0.components(separatedBy: "@").first ?? $0 } ?? app.displayName,
                                window: app.hasSinglePeriod ? snapshot?.primary : (snapshot?.fiveHour ?? snapshot?.weekly)))
            }
            for other in appState.otherAccountsShown(for: app, inMenuBar: false) {
                rows.append(Row(id: other.id, app: app, name: other.name,
                                window: app.hasSinglePeriod ? other.snapshot?.primary : (other.snapshot?.fiveHour ?? other.snapshot?.weekly)))
            }
        }
        return rows
    }

    var body: some View {
        if let edge = settings.floatingDockEdge {
            collapsedTab(edge: edge)
        } else {
            expandedPanel
        }
    }

    /// 拖出屏幕边缘后收起的窄条(像微信通话小窗):贴边一侧是直角，每行一个小图标 + 剩余百分比。
    /// 单击展开；拖动沿着屏幕边上下移动。
    private func collapsedTab(edge: FloatingDockEdge) -> some View {
        let rows = rows
        let radius: CGFloat = 10
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .right ? radius : 0,
            bottomLeadingRadius: edge == .right ? radius : 0,
            bottomTrailingRadius: edge == .left ? radius : 0,
            topTrailingRadius: edge == .left ? radius : 0,
            style: .continuous
        )
        return VStack(spacing: 7) {
            ForEach(rows) { row in
                VStack(spacing: 2) {
                    ServiceTile(logoName: row.app.rawValue, fallback: row.app.fallbackLetter, tint: row.app.accent,
                                size: 14, logoSize: 9, cornerRadius: 4)
                    Text(row.window.map { "\(Int($0.remainingPercent.rounded()))" } ?? "--")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(statusColor(remainingPercent: row.window?.remainingPercent, tint: row.app.accent))
                }
            }
            if rows.isEmpty {
                Image(systemName: edge == .right ? "chevron.left" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
        .frame(width: FloatingPanelController.tabWidth)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        // 窄条不加悬停提示(2026-10-28 起)
        .overlay(FloatingMouse(help: nil))
        .fixedSize()
    }

    @ViewBuilder
    private var expandedPanel: some View {
        Group {
            if settings.floatingStyle == .detailed {
                detailedRows
            } else {
                compactRows
            }
        }
        .background {
            // 三层叠加,解决 `.hudWindow` 在彩色桌面下前景被吃掉的问题:
            // 1) 实色窗背景压一层,使桌面像素不再直接透上来
            // 2) `.popover` material 接管毛玻璃质感(比 .hudWindow 厚)
            // 3) hairline 描边,任何背景下都能勾出 HUD 边缘
            ZStack {
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
                VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .overlay(FloatingMouse(help: tr("Drag to move · drag past the screen edge to tuck it away", "拖动可移动 · 拖出屏幕边缘可收起")))
        // 阴影交给 NSPanel 的 hasShadow,它按内容 alpha 自动取圆角形状,
        // SwiftUI 这层 shadow 会被 panel 边界裁掉而且和系统阴影叠加,所以移除。
        .fixedSize()
    }

    private var compactRows: some View {
        let rows = rows
        // 同一服务有不止一行时，所有行都加上账号名(统一占一列，保证进度条对齐)。
        let showNames = Dictionary(grouping: rows, by: \.app).values.contains { $0.count > 1 }
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                FloatingRow(
                    logoName: row.app.rawValue,
                    fallback: row.app.fallbackLetter,
                    tint: row.app.accent,
                    window: row.window,
                    name: showNames ? row.name : nil
                )
            }
            if rows.isEmpty { emptyText }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 168, alignment: .leading)
    }

    /// 详细：和菜单栏浮窗一样宽(320pt 浮窗去掉两边 16pt)，每个账号一块。
    private var detailedRows: some View {
        let entries = QuotaEntry.list(appState, inMenuBar: false)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(entries) { QuotaEntryView(entry: $0) }
            if entries.isEmpty { emptyText }
        }
        .frame(width: 288, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyText: some View {
        Text(tr("No services", "未启用"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }
}

private struct FloatingRow: View {
    let logoName: String
    let fallback: String
    let tint: Color
    let window: QuotaWindow?
    /// 多账号时显示的账号名(固定宽度列);nil 不显示。
    var name: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            ServiceTile(
                logoName: logoName,
                fallback: fallback,
                tint: tint,
                size: 18,
                logoSize: 12,
                cornerRadius: 5
            )

            if let name {
                Text(name)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 64, alignment: .leading)
            }

            ProgressBar(value: barValue, tint: barColor, height: 4)
                .frame(minWidth: 56)

            Text(percentText)
                .font(.system(size: 13, weight: .semibold))
                .kerning(-0.3)
                .monospacedDigit()
                .foregroundStyle(barColor)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    private var barValue: Double {
        guard let window else { return 0 }
        return window.remainingPercent / 100
    }

    private var percentText: String {
        guard let window else { return "--%" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }

    private var barColor: Color {
        statusColor(remainingPercent: window?.remainingPercent, tint: tint)
    }
}

/// 悬浮窗(展开和收起)上的鼠标处理：拖动时窗口跟着鼠标走，松手时告诉 controller 这次有没有拖动过
/// (见 FloatingPanelController.mouseReleased)。自己移窗口：SwiftUI 内容上「按背景拖动」在新系统上不触发，
/// performDrag 又立刻返回、拿不到松手的时刻。用 AppKit 视图接：非激活面板里第一下点击也能收到，
/// 鼠标拖出窗口外也一直收到拖动和松手。
private struct FloatingMouse: NSViewRepresentable {
    let help: String?

    func makeNSView(context: Context) -> FloatingMouseView {
        let view = FloatingMouseView()
        view.toolTip = help
        return view
    }

    func updateNSView(_ nsView: FloatingMouseView, context: Context) {
        nsView.toolTip = help
    }
}

final class FloatingMouseView: NSView {
    private var startMouse: NSPoint = .zero
    private var startOrigin: NSPoint = .zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = NSEvent.mouseLocation
        startOrigin = window.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - startMouse.x, p.y - startMouse.y) < 3 { return }
        dragging = true
        window.setFrameOrigin(NSPoint(x: startOrigin.x + p.x - startMouse.x, y: startOrigin.y + p.y - startMouse.y))
    }

    override func mouseUp(with event: NSEvent) {
        FloatingPanelController.shared.mouseReleased(moved: dragging)
        dragging = false
    }
}
