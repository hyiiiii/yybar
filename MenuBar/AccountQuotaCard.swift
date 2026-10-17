import SwiftUI
import AppKit

// MARK: - AccountQuotaCard
//
// 设置 · 账号里每行的「查看额度」浮层内容(取代原来点菜单栏图标弹出的额度窗口)。
// 本机账号和其他账号用同一张卡(QuotaCardView):
// 头部 tile + 服务名(本机账号带「使用中」)+ 邮箱 · 订阅 + 官方状态点;
// 中间 5H | WK 两块并列(Grok 只有一个周期，占满一行);底部 今日 / 本周花费(仅本机，来自本地日志)+ 更新时间。

struct LocalQuotaCard: View {
    @Environment(AppState.self) private var appState
    let provider: AccountProvider

    var body: some View {
        let status = SettingsStore.shared.showServiceStatus
        switch provider {
        case .codex:
            QuotaCardView(
                title: "Codex", subtitle: subtitle(email: appState.codexAccount?.email, plan: appState.codexAccount?.planType, fallback: "OpenAI"),
                tint: .codexAccent, logoName: "codex", fallback: "C",
                windows: QuotaCardView.standardWindows(appState.codexQuota),
                inUse: true,
                costs: (appState.codexTodayCost, weekSpend(for: .codex)),
                serviceStatus: status ? appState.codexServiceStatus : nil,
                refreshState: appState.codexRefreshState, error: appState.codexQuotaError
            )
        case .claude:
            QuotaCardView(
                title: "Claude Code", subtitle: subtitle(email: appState.claudeAccount?.email, plan: appState.claudeAccount?.subscriptionType, fallback: "Anthropic"),
                tint: .claudeAccent, logoName: "claude", fallback: "K",
                windows: QuotaCardView.standardWindows(appState.claudeQuota),
                inUse: true,
                costs: (appState.claudeTodayCost, weekSpend(for: .claude)),
                serviceStatus: status ? appState.claudeServiceStatus : nil,
                refreshState: appState.claudeRefreshState, error: appState.claudeQuotaError
            )
        case .grok:
            QuotaCardView(
                title: "Grok", subtitle: subtitle(email: appState.grokAccount?.email, plan: appState.grokPlan, fallback: "xAI"),
                tint: .grokAccent, logoName: "grok", fallback: "G",
                windows: QuotaCardView.grokWindows(appState.grokQuota),
                inUse: true,
                costs: (appState.grokTodayCost, weekSpend(for: .grok)),
                serviceStatus: status ? appState.grokServiceStatus : nil,
                refreshState: appState.grokRefreshState, error: appState.grokQuotaError
            )
        }
    }

    /// 本周(周一起)已知定价部分的花费;有未知定价模型时返回 nil(显示 —)。
    private func weekSpend(for app: UsageApp) -> Decimal? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let to = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        let from = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? startOfToday
        let unknown = appState.usageService.aggregator.snapshot().contains {
            $0.app == app && $0.day >= from && $0.day < to && $0.app != .grok && !Pricing.hasPrice(model: $0.model)
        }
        if unknown { return nil }
        return appState.usageService.aggregator.totals(app: app, from: from, to: to).costUSD
    }
}

/// 其他账号的额度浮层(和本机账号同一张卡，没有花费)。
struct OtherAccountQuotaCard: View {
    enum Account {
        case codex(ImportedCodexAccount)
        case extra(ExtraAccount)
    }

    @Environment(AppState.self) private var appState
    let account: Account

    var body: some View {
        let status = SettingsStore.shared.showServiceStatus
        switch account {
        case .codex(let imported):
            QuotaCardView(
                title: "Codex", subtitle: subtitle(email: imported.email, plan: imported.planType, fallback: imported.alias),
                tint: .codexAccent, logoName: "codex", fallback: "C",
                windows: QuotaCardView.standardWindows(appState.importedCodexQuota(for: imported)),
                serviceStatus: status ? appState.codexServiceStatus : nil,
                refreshState: appState.importedCodexRefreshState(for: imported),
                error: appState.importedCodexError(for: imported)
            )
        case .extra(let extra):
            let isClaude = extra.provider == .claude
            let snapshot = appState.extraQuotas[extra.id]
            QuotaCardView(
                title: isClaude ? "Claude Code" : "Grok",
                subtitle: subtitle(email: extra.email, plan: extra.plan, fallback: extra.displayName),
                tint: isClaude ? .claudeAccent : .grokAccent, logoName: extra.provider.rawValue, fallback: isClaude ? "K" : "G",
                windows: isClaude ? QuotaCardView.standardWindows(snapshot) : QuotaCardView.grokWindows(snapshot),
                serviceStatus: status ? (isClaude ? appState.claudeServiceStatus : appState.grokServiceStatus) : nil,
                refreshState: appState.extraRefreshStates[extra.id] ?? QuotaRefreshState(),
                error: appState.extraErrors[extra.id]
            )
        }
    }
}

/// 「邮箱 · 订阅」。
private func subtitle(email: String?, plan: String?, fallback: String) -> String {
    let parts = [email, plan.map { $0.prefix(1).uppercased() + $0.dropFirst() }].compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? fallback : parts.joined(separator: " · ")
}

// MARK: - RelativeTime

enum RelativeTime {
    /// 相对时间字符串:`45s` / `12m` / `3h` / `2d`。
    static func short(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - QuotaCardView

struct QuotaCardView: View {
    /// 一个额度窗口(5H / WK / Grok 当前周期)。
    struct Window: Identifiable {
        let id: String
        let label: String
        let window: QuotaWindow?
    }

    let title: String
    let subtitle: String
    let tint: Color
    let logoName: String
    let fallback: String
    let windows: [Window]
    /// 本机 CLI 正在使用的账号：标题旁显示「使用中」。
    var inUse: Bool = false
    /// 今日 / 本周花费(本机账号，来自本地日志);nil 不显示这一组。
    var costs: (today: Decimal?, week: Decimal?)? = nil
    var serviceStatus: ServiceStatus? = nil
    var refreshState: QuotaRefreshState? = nil
    var error: String? = nil

    /// Codex / Claude:5H 与 WK 并列。标签按窗口实际长度取(如 Codex 免费账号只有一个 30 天窗口，显示「每月」);
    /// 有窗口有数据时，没有数据的那块不显示，剩下的占满一行。
    static func standardWindows(_ snapshot: QuotaSnapshot?) -> [Window] {
        let all = [
            Window(id: "5h", label: label(snapshot?.fiveHour, fallback: tr("5-hour", "5 小时")), window: snapshot?.fiveHour),
            Window(id: "wk", label: label(snapshot?.weekly, fallback: tr("Weekly", "每周")), window: snapshot?.weekly)
        ]
        let present = all.filter { $0.window != nil }
        return present.isEmpty ? all : present
    }

    private static func label(_ window: QuotaWindow?, fallback: String) -> String {
        guard let seconds = window?.windowSeconds, seconds > 0 else { return fallback }
        let hours = Double(seconds) / 3600
        switch hours {
        case ..<24: return tr("\(Int(hours.rounded()))-hour", "\(Int(hours.rounded())) 小时")
        case ..<(24 * 2): return tr("Daily", "每天")
        case ..<(24 * 14): return tr("Weekly", "每周")
        default: return tr("Monthly", "每月")
        }
    }

    /// Grok:只有云端当前周期一个窗口。标签形如 "WEEK · 本周",按界面语言取一半。
    static func grokWindows(_ snapshot: QuotaSnapshot?) -> [Window] {
        let parts = (snapshot?.primaryLabel ?? "PERIOD · 当前周期").components(separatedBy: " · ")
        let label = parts.count == 2 ? tr(parts[0].capitalized, parts[1]) : parts[0]
        return [Window(id: "period", label: label, window: snapshot?.primary ?? snapshot?.weekly)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 10) {
                ForEach(windows) { windowBlock($0) }
            }
            footer
            if let message = shortError(error) {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ServiceTile(logoName: logoName, fallback: fallback, tint: tint, size: 30, logoSize: 17, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    if inUse {
                        Text(tr("In use", "使用中"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.green)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.14)))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let status = serviceStatus, status.indicator != .unknown {
                Circle()
                    .fill(status.indicator.dotColor)
                    .frame(width: 7, height: 7)
                    .help(serviceStatusTooltip(status))
            }
        }
    }

    // MARK: Window block

    /// 一块额度：标签 / 大号剩余百分比 / 进度条 / 重置时间。两块等宽并列，内容左对齐。
    private func windowBlock(_ item: Window) -> some View {
        let remaining = item.window?.remainingPercent
        let color = item.window == nil ? Color.secondary : statusColor(remainingPercent: remaining, tint: tint)
        return VStack(alignment: .leading, spacing: 7) {
            Text(item.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(remaining.map { "\(Int($0.rounded()))" } ?? "--")
                    .font(.system(size: 26, weight: .semibold))
                    .kerning(-0.6)
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(color)
            ProgressBar(value: (remaining ?? 0) / 100, tint: color, height: 5)
            HStack(spacing: 4) {
                Text(tr("Resets", "重置"))
                ResetTimeText(resetsAt: item.window?.resetsAt)
                    .foregroundStyle(.primary.opacity(0.75))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let costs {
                costItem(tr("Today", "今日"), costs.today)
                costItem(tr("This week", "本周"), costs.week)
            }
            Spacer(minLength: 8)
            if let refreshState {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(refreshText(refreshState, now: context.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
    }

    private func costItem(_ label: String, _ value: Decimal?) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(formatCostInt(value))
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
        }
    }

    private func refreshText(_ state: QuotaRefreshState, now: Date) -> String {
        if state.inFlight { return tr("Refreshing…", "正在刷新…") }
        if let until = state.backoffUntil, until > now {
            return tr("Retry in \(Int(until.timeIntervalSince(now)))s", "\(Int(until.timeIntervalSince(now))) 秒后重试")
        }
        guard let last = state.lastSuccessAt else { return tr("Not updated yet", "尚未更新") }
        let age = RelativeTime.short(from: last, now: now)
        return tr("Updated \(age) ago", "\(age) 前更新")
    }

    private func serviceStatusTooltip(_ status: ServiceStatus) -> String {
        let trimmed = status.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = trimmed.isEmpty ? status.indicator.label : trimmed
        guard let updatedAt = status.updatedAt else { return head }
        let age = RelativeTime.short(from: updatedAt)
        return tr("\(head) · updated \(age) ago", "\(head) · \(age) 前更新")
    }

    /// 取整美元金额:`<$1` 用于 0 ~ 0.99,`$0` 仅在 0 时显示,nil 显示 —。
    private func formatCostInt(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d <= 0 { return "$0" }
        if d < 1 { return "<$1" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.maximumFractionDigits = 0
        return "$\(formatter.string(from: NSDecimalNumber(decimal: value)) ?? "0")"
    }

    private func shortError(_ error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        let oneLine = error.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count <= 110 ? oneLine : String(oneLine.prefix(107)) + "…"
    }
}
