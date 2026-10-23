import SwiftUI

// MARK: - FloatingContentView
//
// 见 docs/04-界面布局.md §2。
// 默认变体:Two-row pill。
// 结构:14pt 圆角 HUD 容器 + .hudWindow material 背景 + 两行 pill。
// 每行:18pt ServiceTile + flex 4pt bar + 34pt 百分比(服务色)。

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
                                window: app.hasSinglePeriod ? snapshot?.primary : snapshot?.fiveHour))
            }
            for other in appState.otherAccountsShown(for: app, inMenuBar: false) {
                rows.append(Row(id: other.id, app: app, name: other.name,
                                window: app.hasSinglePeriod ? other.snapshot?.primary : other.snapshot?.fiveHour))
            }
        }
        return rows
    }

    var body: some View {
        let rows = rows
        // 同一服务有不止一行时，所有行都加上账号名(统一占一列，保证进度条对齐)。
        let showNames = Dictionary(grouping: rows, by: \.app).values.contains { $0.count > 1 }

        VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                FloatingRow(
                    logoName: row.app.rawValue,
                    fallback: row.app.fallbackLetter,
                    tint: row.app.accent,
                    window: row.window,
                    name: showNames ? row.name : nil
                )
            }
            if rows.isEmpty {
                Text(tr("No services", "未启用"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 168, alignment: .leading)
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
        // 阴影交给 NSPanel 的 hasShadow,它按内容 alpha 自动取圆角形状,
        // SwiftUI 这层 shadow 会被 panel 边界裁掉而且和系统阴影叠加,所以移除。
        .fixedSize()
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
