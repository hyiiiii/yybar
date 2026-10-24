import SwiftUI

// MARK: - MenuBarPopoverView
//
// 左键点菜单栏图标弹出的额度浮窗(320pt)。只放一眼要看的东西：
// 顶部 yybar + 统计 / 设置 / bar 三个按钮(bar 用两张扑克牌的图标，打开主窗口的 bar 页，从那里进 yybar 网站的德州大厅，见 YYBarWeb);
// 中间是菜单栏上显示的每个账号(顺序同菜单栏):图标、名称、套餐、官方状态点，下面 5H / WK 的剩余条和重置倒计时
// (标签和菜单栏一样用 5H / WK;Antigravity 按池写成「Gemini 5H」),刷新失败时名称旁一个小警告(悬停看原因);
// 底部左边刷新按钮 +「x 前更新」,右边今日花费 / Token。

/// yybar 网站(Cloudflare Workers,代码在仓库 web/ 目录，web-mvp 分支)。首页就是德州酒吧大厅。
enum YYBarWeb {
    static let url = URL(string: "https://yybar-web.hyi030618.workers.dev")!
}

struct MenuBarPopoverView: View {
    @Environment(AppState.self) private var appState
    let openStats: () -> Void
    let openSettings: () -> Void
    let openBar: () -> Void

    @State private var refreshRotation: Double = 0

    /// 浮窗里的一个账号。
    private struct Entry: Identifiable {
        let id: String
        let app: UsageApp
        let title: String
        let plan: String?
        let snapshot: QuotaSnapshot?
        let error: String?
        let status: ServiceStatus?
        let isLocal: Bool
    }

    private var entries: [Entry] {
        let settings = SettingsStore.shared
        var result: [Entry] = []
        for app in UsageApp.allCases {
            if settings.effectiveMenuBarShow(app) {
                result.append(Entry(
                    id: "local:\(app.rawValue)", app: app, title: app.displayName,
                    plan: appState.localPlan(for: app), snapshot: appState.localQuota(for: app),
                    error: appState.localQuotaError(for: app),
                    status: settings.showServiceStatus ? appState.serviceStatus(for: app) : nil,
                    isLocal: true))
            }
            for other in appState.otherAccountsShown(for: app, inMenuBar: true) {
                result.append(Entry(id: "other:\(other.id)", app: app, title: "\(app.displayName) · \(other.name)",
                                    plan: nil, snapshot: other.snapshot, error: nil, status: nil, isLocal: false))
            }
        }
        return result
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            if entries.isEmpty {
                Text(tr("No services in the menu bar. Choose them in Settings › Services.",
                        "菜单栏没有显示任何服务，可在 设置 · 服务 里勾选。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .padding(.horizontal, 16)
            } else {
                VStack(spacing: 12) {
                    ForEach(entries) { entryView($0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("yybar")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                headerButton(tr("Stats", "统计"), action: openStats) {
                    Image(systemName: "chart.bar.xaxis")
                }
                headerButton(tr("Settings", "设置"), action: openSettings) {
                    Image(systemName: "gearshape")
                }
                headerButton("bar", action: openBar) {
                    PlayingCardsIcon(size: 11.5)
                }
                .help(tr("Open the bar: yybar's poker tavern", "打开 bar:yybar 的德州小酒馆"))
            }
        }
    }

    /// 今日花费(已知定价部分)和全部 Token(含缓存)。Gemini App 没有 token / 花费，不计入。
    private var todaySummary: String {
        let (_, today, tomorrow) = QuotaCardView.dayAndWeekBounds()
        var totals = UsageTotals.zero
        for app in UsageApp.allCases where app != .gemini {
            let t = appState.usageService.aggregator.totals(app: app, from: today, to: tomorrow)
            totals.inputTokens += t.inputTokens
            totals.outputTokens += t.outputTokens
            totals.cacheReadTokens += t.cacheReadTokens
            totals.cacheCreationTokens += t.cacheCreationTokens
            totals.costUSD += t.costUSD
        }
        let cost = StatsFormatter.cost(totals.costUSD)
        let tokens = StatsFormatter.compactToken(totals.totalTokens)
        return tr("Today \(cost) · \(tokens) tokens", "今日 \(cost) · \(tokens) Token")
    }

    // MARK: Entry

    private func entryView(_ entry: Entry) -> some View {
        let windows = entry.app == .grok || entry.app == .grokBot
            ? QuotaCardView.grokWindows(entry.snapshot)
            : QuotaCardView.standardWindows(entry.snapshot)
        let pools = entry.snapshot?.pools
        // Antigravity 的行标签带池名(Gemini 5H …),标签列放宽。
        let labelWidth: CGFloat = pools != nil ? 92 : 30
        return HStack(alignment: .top, spacing: 10) {
            ServiceTile(logoName: entry.app.rawValue, fallback: entry.app.fallbackLetter, tint: entry.app.accent,
                        size: 22, logoSize: 13, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = entry.plan {
                        Text(plan)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .lineLimit(1)
                    }
                    if let error = entry.error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                            .help(error)
                    }
                    Spacer(minLength: 0)
                    if let status = entry.status, status.indicator != .unknown {
                        Circle()
                            .fill(status.indicator.dotColor)
                            .frame(width: 6, height: 6)
                            .help(status.description ?? status.indicator.label)
                    }
                }
                .frame(height: 22)
                ForEach(windows) { window in
                    LimitBarRow(label: Self.shortLabel(window, pools: pools), window: window.window,
                                tint: entry.app.accent, labelWidth: labelWidth)
                        .padding(.vertical, -2)
                }
            }
        }
    }

    // MARK: Footer

    /// 额度标签：和菜单栏一样写 5H / WK(按窗口实际长度：不到一天写「N H」,一天 1D,两周内 WK,更长 MO);
    /// Antigravity 的池子前面加池名。
    static func shortLabel(_ item: QuotaCardView.Window, pools: [QuotaPool]?) -> String {
        let code: String
        if let seconds = item.window?.windowSeconds, seconds > 0 {
            let hours = Double(seconds) / 3600
            switch hours {
            case ..<24: code = "\(Int(hours.rounded()))H"
            case ..<48: code = "1D"
            case ..<(24 * 14): code = "WK"
            default: code = "MO"
            }
        } else {
            code = item.id.hasSuffix("5h") ? "5H" : "WK"
        }
        guard let pool = pools?.first(where: { item.id.hasPrefix($0.label + "-") }) else { return code }
        return "\(pool.label) \(code)"
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.7)) { refreshRotation += 360 }
                Task { await appState.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
                    .rotationEffect(.degrees(refreshRotation))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(tr("Refresh now", "立即刷新"))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(refreshedText(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(todaySummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    /// 顶部三个按钮一样宽：图标都放在同样大小的框里，文字居中，看起来间距均匀。
    private func headerButton(_ title: String, action: @escaping () -> Void, @ViewBuilder icon: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                icon()
                    .font(.system(size: 11.5))
                    .frame(width: 15, height: 13)
                Text(title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .frame(width: L10n.current == .zh ? 52 : 66)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// 菜单栏上这些账号里最近一次成功刷新的时间。
    private func refreshedText(now: Date) -> String {
        let shown = UsageApp.allCases.filter { SettingsStore.shared.effectiveMenuBarShow($0) }
        let apps = shown.isEmpty ? [UsageApp.codex, .claude, .grok] : shown
        guard let latest = apps.compactMap({ appState.localRefreshState(for: $0).lastSuccessAt }).max() else {
            return tr("Waiting for data", "等待数据")
        }
        let age = RelativeTime.short(from: latest, now: now)
        return tr("Updated \(age) ago", "\(age) 前更新")
    }
}
