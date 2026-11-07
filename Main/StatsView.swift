import SwiftUI
import Charts

// MARK: - StatsRange

enum StatsRange: Hashable, CaseIterable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    case thisYear
    case last7
    case last30
    case all
    case custom

    var englishLabel: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "Week"
        case .thisMonth: return "Month"
        case .thisYear: return "Year"
        case .last7: return "7d"
        case .last30: return "30d"
        case .all: return "All"
        case .custom: return "Custom"
        }
    }

    var chineseLabel: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨日"
        case .thisWeek: return "本周"
        case .thisMonth: return "本月"
        case .thisYear: return "本年"
        case .last7: return "7 天"
        case .last30: return "30 天"
        case .all: return "全部"
        case .custom: return "自定义"
        }
    }

    private static var weekStartMondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    func bounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date) {
        let cal = Self.weekStartMondayCalendar
        let startOfToday = cal.startOfDay(for: now)
        let startOfTomorrow = cal.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday

        switch self {
        case .today:
            return (startOfToday, startOfTomorrow)
        case .yesterday:
            let yesterdayStart = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return (yesterdayStart, startOfToday)
        case .thisWeek:
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            let weekStart = cal.date(from: comps) ?? startOfToday
            return (weekStart, startOfTomorrow)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: comps) ?? startOfToday
            return (monthStart, startOfTomorrow)
        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let yearStart = cal.date(from: comps) ?? startOfToday
            return (yearStart, startOfTomorrow)
        case .last7:
            let from = cal.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .last30:
            let from = cal.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            return (from, startOfTomorrow)
        case .all:
            return (.distantPast, .distantFuture)
        case .custom:
            let from = cal.startOfDay(for: customFrom)
            let toBase = cal.startOfDay(for: customTo)
            let to = cal.date(byAdding: .day, value: 1, to: toBase) ?? toBase
            return (from, max(from, to))
        }
    }

    /// 上一个等长区间(用于 delta 对比)。`.all` / `.custom` 返回 nil(无法对比)。
    func previousBounds(now: Date = Date(), customFrom: Date, customTo: Date) -> (from: Date, to: Date)? {
        switch self {
        case .all, .custom:
            return nil
        default:
            break
        }
        let current = bounds(now: now, customFrom: customFrom, customTo: customTo)
        let length = current.to.timeIntervalSince(current.from)
        guard length > 0, length.isFinite else { return nil }
        return (current.from.addingTimeInterval(-length), current.from)
    }
}

// MARK: - Service filter (toolbar chips)

enum StatsServiceFilter: Hashable, CaseIterable {
    case all
    case codex
    case claude
    case grok
    case grokBot
    case gemini
    case agy
    /// 两两合并的标签(和「今天」面板一样可拆开):Grok + Grok Bot、Gemini + Antigravity。
    case grokPair
    case googlePair

    /// 单个服务的筛选对应的服务;「全部」和合并标签为 nil。
    var app: UsageApp? {
        switch self {
        case .all, .grokPair, .googlePair: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .grokBot: return .grokBot
        case .gemini: return .gemini
        case .agy: return .agy
        }
    }

    /// 合并标签包含的两个服务。
    var pairApps: [UsageApp]? {
        switch self {
        case .grokPair: return [.grok, .grokBot]
        case .googlePair: return [.gemini, .agy]
        default: return nil
        }
    }

    var englishLabel: String {
        app?.displayName ?? pairApps.map { $0.map(\.displayName).joined(separator: " · ") } ?? "All"
    }

    var chineseLabel: String {
        switch self {
        case .all: return "全部"
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        case .grok: return "xAI"
        case .grokBot: return "Cursor"
        case .gemini, .agy, .googlePair: return "Google"
        case .grokPair: return "xAI · Cursor"
        }
    }

    /// 工具栏筛选按钮上的文字。
    var chipLabel: String {
        if let pairApps { return pairApps.map(\.displayName).joined(separator: " · ") }
        guard let app else { return tr("All", "全部") }
        return app == .claude ? "Claude" : app.displayName
    }

    var tint: Color? {
        app?.accent ?? pairApps?.first?.accent
    }
}

/// 每日图表 / 当日对比 用的度量。
enum StatsMetric: Hashable {
    case cost
    case tokens
    /// Gemini App 的回答次数。不在切换器里：只看 Gemini 时自动使用(见 StatsView.answersOnly)。
    case answers
}

/// 单日视图的对比基准。
enum StatsBaseline: Hashable, CaseIterable {
    case yesterday
    case sevenDays
    case thirtyDays
    case all

    var shortLabel: String {
        switch self {
        case .yesterday: return tr("Yesterday", "昨日")
        case .sevenDays: return tr("7d", "7 天")
        case .thirtyDays: return tr("30d", "30 天")
        case .all: return tr("All", "全部")
        }
    }

    /// 竖线含义(脚注用)。
    var lineDescription: String {
        switch self {
        case .yesterday: return tr("yesterday", "昨日")
        case .sevenDays: return tr("prior 7-day daily average", "前 7 日日均")
        case .thirtyDays: return tr("prior 30-day daily average", "前 30 日日均")
        case .all: return tr("daily average since first use", "首次使用以来的日均")
        }
    }

    /// KPI 卡上的对比文字。
    var compareLabel: String {
        switch self {
        case .yesterday: return tr("vs yesterday", "较昨日")
        case .sevenDays: return tr("vs 7-day avg", "较 7 日均")
        case .thirtyDays: return tr("vs 30-day avg", "较 30 日均")
        case .all: return tr("vs all-time avg", "较历史日均")
        }
    }
}

// MARK: - StatsView
//
// 统计页三个子页面(见 docs/界面布局.md §3):
// - 概览:顶部时间范围 + 服务筛选、3 张 KPI、每日用量(单日时改为「今天」各服务对比基准)、当前额度(整宽 2 列)
// - 额度变化:今日 5H 额度变化时间线
// - 模型明细:按模型的可排序表格

/// 统计页上用户选过的视图状态(时间范围、服务筛选、排序等)。主窗口关闭时窗口连同视图一起释放以省内存，
/// 再次打开时从这里恢复，和关窗前一样。只存在内存里，退出 App 后回到默认。
fileprivate struct StatsSelections: Equatable {
    var range: StatsRange = .today
    var serviceFilter: StatsServiceFilter = .all
    var metric: StatsMetric = .cost
    var baseline: StatsBaseline = .sevenDays
    var mergeTokens = false
    /// 「今天」面板里 Grok + Grok Bot、Gemini + agy 两行是否拆成并列两条(默认合并)。
    var splitGrokPair = false
    var splitGooglePair = false
    /// 工具栏服务筛选里 Grok + Grok Bot、Gemini + Antigravity 两个合并标签是否拆开(默认合并)。
    var splitGrokChips = false
    var splitGoogleChips = false
    var hiddenTimelineAccounts: Set<String> = []
    var expandedTimelineAccounts: Set<String> = []
    var timelineWindow: QuotaHistoryWindow = .fiveHour
    var modelSortKey: StatsView.ModelSortKey = .cost
    var modelSortAscending = false
    var customFrom = Calendar.current.startOfDay(for: Date().addingTimeInterval(-7 * 86400))
    var customTo = Calendar.current.startOfDay(for: Date())
    /// Token 活动的「按日 / 按周 / 累计」。
    var activityMode = "daily"

    static var current = StatsSelections()
}

struct StatsView: View {
    @Environment(AppState.self) private var appState
    /// 图表坐标轴文字不是普通视图，用不了 scaledFont,直接乘字号倍数。
    @Environment(\.textScale) private var textScale
    /// 顶部按钮改变内容前记下正在看的位置，排版后补回，页面不跳。
    @State private var anchorKeeper = ScrollAnchorKeeper()
    /// 用量数据的按天索引，数据变化时才重建(避免每次重绘对全部记录反复扫描)。
    @State private var dataIndex = StatsDataIndex()
    /// 正在看下面的部分时点顶部按钮：把它上方各部分的高度冻结在当前值，
    /// 这样正在看的部分完全不动(不需要滚动补偿，也就没有补偿前那一帧的闪动)。
    /// 往上滚到某个冻结的部分(它成为侧边栏选中项)时再解冻它及其下方的部分。
    @State private var frozenHeights: [MainTab: CGFloat] = [:]

    // 以下用户选择的初始值取自 StatsSelections(关窗再开时恢复),变化时写回(见 body 末尾)。
    @State private var range = StatsSelections.current.range
    @State private var serviceFilter = StatsSelections.current.serviceFilter
    @State private var metric = StatsSelections.current.metric
    /// 单日视图的对比基准(今天面板和 KPI 卡上的竖线)。
    @State private var baseline = StatsSelections.current.baseline
    /// Tokens 与缓存读取合并为一张「全部 Tokens」卡;合并后页面上的 Tokens 口径都含缓存读取。
    @State private var mergeTokens = StatsSelections.current.mergeTokens
    @State private var splitGrokPair = StatsSelections.current.splitGrokPair
    @State private var splitGooglePair = StatsSelections.current.splitGooglePair
    @State private var splitGrokChips = StatsSelections.current.splitGrokChips
    @State private var splitGoogleChips = StatsSelections.current.splitGoogleChips
    @State private var kpiRowWidth: CGFloat = 0
    @State private var selectedDay: Date?
    /// 额度变化页：隐藏曲线的账号 / 展开详情的账号(QuotaHistoryAccountKey)。
    @State private var hiddenTimelineAccounts = StatsSelections.current.hiddenTimelineAccounts
    @State private var expandedTimelineAccounts = StatsSelections.current.expandedTimelineAccounts
    @State private var timelineWindow = StatsSelections.current.timelineWindow
    @State private var modelSortKey = StatsSelections.current.modelSortKey
    @State private var modelSortAscending = StatsSelections.current.modelSortAscending
    /// 模型明细数据更新时的淡入提示。
    @State private var modelsRowsOpacity: Double = 1
    /// 每日用量柱子的高度比例(0~1)。切换时间范围 / 服务筛选后从 0 长到 1,见 replayBarRise。
    @State private var barReveal: Double = 1
    @State private var customFrom = StatsSelections.current.customFrom
    @State private var customTo = StatsSelections.current.customTo

    private var selections: StatsSelections {
        StatsSelections(range: range, serviceFilter: serviceFilter, metric: metric, baseline: baseline,
                        mergeTokens: mergeTokens, splitGrokPair: splitGrokPair, splitGooglePair: splitGooglePair,
                        splitGrokChips: splitGrokChips, splitGoogleChips: splitGoogleChips,
                        hiddenTimelineAccounts: hiddenTimelineAccounts,
                        expandedTimelineAccounts: expandedTimelineAccounts, timelineWindow: timelineWindow,
                        modelSortKey: modelSortKey, modelSortAscending: modelSortAscending,
                        customFrom: customFrom, customTo: customTo,
                        activityMode: StatsSelections.current.activityMode)
    }

    /// 费用 / Tokens、对比基准、合并 Tokens 共用的切换动画。
    private static let switchAnimation = Animation.spring(response: 0.45, dampingFraction: 0.86)
    /// 每日用量柱子从底部长出来的动画。
    private static let barRiseAnimation = Animation.spring(response: 0.55, dampingFraction: 0.8)

    /// 工具栏上提供的时间范围。其余 StatsRange case 保留但不再展示。
    private static let toolbarRanges: [StatsRange] = [.today, .yesterday, .last7, .last30, .all, .custom]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                // 侧边栏选中项变到某个冻结的部分(往上滚到了它)或更上面时，解冻它及下方的部分。
                .onChange(of: appState.mainTab) { _, active in
                    guard let index = MainTab.statsPages.firstIndex(of: active) else { return }
                    for tab in MainTab.statsPages[index...] where frozenHeights[tab] != nil {
                        frozenHeights[tab] = nil
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            Divider()
            SectionedScrollPage(sections: MainTab.statsPages, keeper: anchorKeeper) {
                overviewSection.sectionAnchor(.overview).frozenHeight(frozenHeights[.overview])
                timelineContent.sectionAnchor(.quota).frozenHeight(frozenHeights[.quota])
                modelsSection.sectionAnchor(.models).frozenHeight(frozenHeights[.models])
                activitySection.sectionAnchor(.activity)
            }
        }
        .onChange(of: selections) { _, new in StatsSelections.current = new }
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: tr("Overview", "概览"))
            kpiRow
            if answersOnly {
                Text(tr("Gemini Apps doesn't report tokens or cost, so Gemini is counted by answers, read from your Gemini web chats since yybar started recording.",
                        "Gemini App 不提供 token 和费用，这里按回答次数统计(从 Gemini 网页会话读取，从 yybar 开始记录起)。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isSingleDay {
                singleDayPanel
            } else {
                dailyUsagePanel
            }
            currentLimitsPanel
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: tr("Models", "模型明细"),
                           subtitle: tr("Uses the time range and service filter above. Click a column to sort.",
                                        "跟随上方时间范围和服务筛选，点击表头排序。"))
            modelsTable
            Text(tr("Unknown prices show as — and are excluded from estimated cost.",
                    "未知定价的模型显示为 —，不计入估算费用。"))
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: tr("Token activity", "Token 活动"),
                           subtitle: tr("All tokens including cache, over the last year. Uses the service filter above.",
                                        "最近一年的全部 Token(含缓存),跟随上方服务筛选。"))
            TokenActivityPanel(daily: answersOnly ? appState.geminiAnswerLog.daily : activityDaily,
                               filter: serviceFilter, answers: answersOnly)
        }
    }

    // MARK: Toolbar

    /// 工具栏：一行放得下就单行(选「自定义」时日期字段也在同一行);窗口太窄时服务筛选换到第二行。
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                rangeControls
                Spacer(minLength: 12)
                serviceChips
            }
            VStack(alignment: .leading, spacing: 8) {
                rangeControls
                serviceChips
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rangeControls: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { range },
                set: { newValue in applyFilterChange { range = newValue } }
            )) {
                ForEach(Self.toolbarRanges, id: \.self) { r in
                    Text(tr(r.englishLabel, r.chineseLabel)).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if range == .custom { customRangeFields }
        }
        .fixedSize()
    }

    private var serviceChips: some View {
        HStack(spacing: 6) {
            ForEach([StatsServiceFilter.all, .codex, .claude], id: \.self) { item in
                serviceChip(item)
            }
            pairChips(.grokPair)
            pairChips(.googlePair)
        }
        .fixedSize()
        // 选中背景 / 描边总是平滑切换(只作用于按钮本身，不影响页面内容)。
        .animation(.easeOut(duration: 0.2), value: serviceFilter)
    }

    /// 时间范围 / 服务筛选 / 自定义日期：会改变各部分高度。
    /// 正在看概览(页面最上面)时用弹簧动画;看下面的部分时瞬时切换，由 anchorKeeper 精确补回滚动位置。
    private func applyFilterChange(_ change: () -> Void) {
        let chartKey = dailyChartKey
        defer { if dailyChartKey != chartKey { replayBarRise() } }
        if let reading = anchorKeeper.readingSection,
           let readingIndex = MainTab.statsPages.firstIndex(of: reading), readingIndex > 0 {
            // 冻结上方各部分(已冻结的保持原高度)。
            for tab in MainTab.statsPages[..<readingIndex] where frozenHeights[tab] == nil {
                frozenHeights[tab] = anchorKeeper.height(of: tab)
            }
        }
        if anchorKeeper.preserveReadingPosition() {
            withAnimation(Self.switchAnimation) { change() }
        } else {
            change()
        }
    }

    /// 只看 Gemini 时：Gemini App 没有 token / 费用，统计页改按回答次数显示(GeminiAnswerLog)。
    private var answersOnly: Bool { visibleApps == [.gemini] }

    /// 实际用的口径：只看 Gemini 时是回答次数，否则是用户选的 费用 / Tokens。
    private var effectiveMetric: StatsMetric { answersOnly ? .answers : metric }

    /// 每日用量图的数据口径：时间范围(含自定义日期)和显示的服务。变了就换一张新图，柱子重新长出来。
    private var dailyChartKey: String {
        "\(range)|\(customFrom.timeIntervalSince1970)|\(customTo.timeIntervalSince1970)|\(visibleApps)"
    }

    /// 柱子先瞬间收到 0(新图第一帧就是空的)，下一轮再用弹簧动画长到实际高度。
    /// 只靠 Swift Charts 自己的过渡不够：换时间范围时新出现的日期会直接冒出来，看不出动画。
    private func replayBarRise() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { barReveal = 0 }
        DispatchQueue.main.async {
            withAnimation(Self.barRiseAnimation) { barReveal = 1 }
        }
    }

    private static func singleFilter(_ app: UsageApp) -> StatsServiceFilter {
        StatsServiceFilter.allCases.first { $0.app == app } ?? .all
    }

    /// Grok + Grok Bot / Gemini + Antigravity 两两一组：合并时一个标签，拆开时两个，后面跟拆分 / 合并按钮(同「今天」面板)。
    /// Grok 总是显示，Grok Bot / Gemini / Antigravity 只在设置里启用时出现;一组只剩一个服务时不显示按钮。
    @ViewBuilder
    private func pairChips(_ pair: StatsServiceFilter) -> some View {
        let apps = (pair.pairApps ?? []).filter { $0 == .grok || SettingsStore.shared.isEnabled($0) }
        if apps.count == 2 {
            let split = pair == .grokPair ? splitGrokChips : splitGoogleChips
            if split {
                serviceChip(Self.singleFilter(apps[0]))
                chipPairButton(pair, split: true)
                serviceChip(Self.singleFilter(apps[1]))
            } else {
                serviceChip(pair)
                chipPairButton(pair, split: false)
            }
        } else {
            ForEach(apps, id: \.self) { serviceChip(Self.singleFilter($0)) }
        }
    }

    private func chipPairButton(_ pair: StatsServiceFilter, split: Bool) -> some View {
        let names = (pair.pairApps ?? []).map(\.displayName).joined(separator: tr(" and ", " 和 "))
        return Button {
            applyFilterChange {
                if pair == .grokPair { splitGrokChips.toggle() } else { splitGoogleChips.toggle() }
                // 选中的标签被拆开 / 合并掉时，改选对应的新标签。
                let apps = pair.pairApps ?? []
                if split, let app = serviceFilter.app, apps.contains(app) {
                    serviceFilter = pair
                } else if !split, serviceFilter == pair, let first = apps.first {
                    serviceFilter = Self.singleFilter(first)
                }
            }
        } label: {
            Image(systemName: split ? "arrow.triangle.merge" : "arrow.triangle.branch")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(split ? tr("Merge \(names)", "合并 \(names)") : tr("Show \(names) separately", "拆开 \(names)"))
    }

    private func serviceChip(_ item: StatsServiceFilter) -> some View {
        let active = serviceFilter == item
        return Button {
            applyFilterChange { serviceFilter = item }
        } label: {
            HStack(spacing: 5) {
                if item.tint != nil {
                    statusDot(for: item)
                }
                // 字重固定：选中只改背景和描边，切换时按钮宽度不变，工具栏不会左右跳。
                Text(item.chipLabel)
                    .scaledFont(size: 11.5)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(active ? Color.primary.opacity(0.1) : Color.clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(active ? 0.28 : 0.14), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    /// 筛选按钮上的服务状态圆点(取代原来的色块)。关闭「服务状态圆点」或还没拉到状态时显示灰点。
    @ViewBuilder
    private func statusDot(for item: StatsServiceFilter) -> some View {
        let status: ServiceStatus? = {
            guard SettingsStore.shared.showServiceStatus else { return nil }
            switch item {
            case .all: return nil
            case .codex: return appState.codexServiceStatus
            case .claude: return appState.claudeServiceStatus
            case .grok: return appState.grokServiceStatus
            case .grokBot: return appState.cursorServiceStatus
            case .gemini, .agy, .googlePair: return appState.googleServiceStatus
            // Grok + Grok Bot:取两者里更严重的。
            case .grokPair: return Self.worse(appState.grokServiceStatus, appState.cursorServiceStatus)
            }
        }()
        Circle()
            .fill(status.map { $0.indicator == .unknown ? Color.secondary.opacity(0.4) : $0.indicator.dotColor }
                  ?? Color.secondary.opacity(0.4))
            .frame(width: 7, height: 7)
            .help(statusHelp(for: item, status: status))
    }

    /// 圆点的悬停说明。Grok Bot 是 Anysphere(Cursor)的 App,状态取 Cursor 状态页的「Grok Bot」组件，
    /// 和 xAI 的 Grok 不是同一个服务;合并的「Grok · Grok Bot」圆点取更严重的那个，说明里两个都写。
    private func statusHelp(for item: StatsServiceFilter, status: ServiceStatus?) -> String {
        func text(_ s: ServiceStatus?) -> String { s.map { $0.description ?? $0.indicator.label } ?? tr("Status unavailable", "暂无状态") }
        guard SettingsStore.shared.showServiceStatus else { return tr("Status unavailable", "暂无状态") }
        switch item {
        case .grokPair:
            return tr("Grok (xAI status): \(text(appState.grokServiceStatus))\nGrok Bot (Cursor status): \(text(appState.cursorServiceStatus))",
                      "Grok(xAI 状态页):\(text(appState.grokServiceStatus))\nGrok Bot(Cursor 状态页):\(text(appState.cursorServiceStatus))")
        case .grokBot:
            return tr("Cursor status: ", "Cursor 状态页：") + text(status)
        default:
            return text(status)
        }
    }

    private static func worse(_ a: ServiceStatus?, _ b: ServiceStatus?) -> ServiceStatus? {
        let rank: [ServiceStatusIndicator: Int] = [.unknown: -1, .none: 0, .maintenance: 1, .minor: 2, .major: 3, .critical: 4]
        guard let a else { return b }
        guard let b else { return a }
        return (rank[b.indicator] ?? 0) > (rank[a.indicator] ?? 0) ? b : a
    }

    private var customRangeFields: some View {
        HStack(spacing: 4) {
            DatePicker("", selection: Binding(get: { customFrom }, set: { value in applyFilterChange { customFrom = value } }),
                       displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .help(tr("From", "起"))
            Text("–").foregroundStyle(.secondary)
            DatePicker("", selection: Binding(get: { customTo }, set: { value in applyFilterChange { customTo = value } }),
                       in: customFrom..., displayedComponents: .date)
                .datePickerStyle(.field)
                .labelsHidden()
                .help(tr("To", "止"))
        }
        .scaledFont(size: 12)
        .fixedSize()
    }

    // MARK: KPI row

    @ViewBuilder
    private var kpiRow: some View {
        if answersOnly { answersKPIRow } else { tokensKPIRow }
    }

    /// 只看 Gemini 时的三张卡：回答次数(环比 / 对比基准)、最常用模型、用过的模型。
    private var answersKPIRow: some View {
        let log = appState.geminiAnswerLog
        let bounds = rangeBounds
        let total = log.total(from: bounds.from, to: bounds.to)
        let models = log.byModel(from: bounds.from, to: bounds.to)
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        let detail: String?
        let line: Double?
        if isSingleDay {
            let day = Calendar.current.startOfDay(for: bounds.from)
            let base = baselineAverage(apps: [.gemini], before: day) { Double(log.total(from: $0, to: $1)) }
            detail = deltaText(current: Double(total), previous: base, label: baseline.compareLabel)
            line = base
        } else {
            detail = deltaText(current: Double(total),
                               previous: previousRangeBounds.map { Double(log.total(from: $0.from, to: $0.to)) },
                               label: tr("vs previous", "较上期"))
            line = nil
        }
        let top = models.first
        return HStack(alignment: .top, spacing: 12) {
            KPICard(
                title: tr("Answers", "回答次数"),
                value: tr("\(total)", "\(total) 次"),
                detail: detail,
                segments: isSingleDay ? [KPISegment(id: UsageApp.gemini.rawValue, color: UsageApp.gemini.statsTint, value: Double(total))] : [],
                baselineLine: line
            )
            KPICard(
                title: tr("Top model", "最常用模型"),
                value: top?.key ?? "—",
                detail: top.map { item in
                    let share = total > 0 ? Int((Double(item.value) / Double(total) * 100).rounded()) : 0
                    return tr("\(item.value) answers · \(share)%", "\(item.value) 次 · 占 \(share)%")
                },
                segments: []
            )
            KPICard(
                title: tr("Models used", "用过的模型"),
                value: tr("\(models.count)", "\(models.count) 个"),
                detail: models.isEmpty ? nil : models.prefix(3).map(\.key).joined(separator: " · "),
                segments: []
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var tokensKPIRow: some View {
        let current = totals(for: visibleApps, in: rangeBounds)
        let previous = previousRangeBounds.map { totals(for: visibleApps, in: $0) }
        let currentCost = knownCost(for: visibleApps, in: rangeBounds)
        let previousCost = previousRangeBounds.map { knownCost(for: visibleApps, in: $0) }
        let allTokens = current.totalTokens
        let cacheShare = allTokens > 0 ? Double(current.cacheReadTokens) / Double(allTokens) * 100 : 0
        let shareText = tr("cache reads \(Int(cacheShare.rounded()))% of all", "缓存读取占 \(Int(cacheShare.rounded()))%")
        let singleDay = isSingleDay
        let day = Calendar.current.startOfDay(for: rangeBounds.from)
        let apps = visibleApps

        // 单日：和所选对比基准比较(文字 + 卡片细条上的竖线);多日：和上一同长度区间比较。
        func comparison(current value: Double, previous: Double?, baselineValue: () -> Double) -> (text: String?, line: Double?) {
            if singleDay {
                let base = baselineValue()
                return (deltaText(current: value, previous: base, label: baseline.compareLabel), base)
            }
            return (deltaText(current: value, previous: previous, label: tr("vs previous", "较上期")), nil)
        }

        let cost = comparison(current: currentCost.value.doubleValue, previous: previousCost?.value.doubleValue) {
            baselineAverage(apps: apps, before: day) { knownCost(for: apps, in: ($0, $1)).value.doubleValue }
        }
        let tokens = comparison(current: Double(current.nonCacheReadTokens), previous: previous.map { Double($0.nonCacheReadTokens) }) {
            baselineAverage(apps: apps, before: day) { Double(totals(for: apps, in: ($0, $1)).nonCacheReadTokens) }
        }
        let cache = comparison(current: Double(current.cacheReadTokens), previous: previous.map { Double($0.cacheReadTokens) }) {
            baselineAverage(apps: apps, before: day) { Double(totals(for: apps, in: ($0, $1)).cacheReadTokens) }
        }
        let all = comparison(current: Double(allTokens), previous: previous.map { Double($0.totalTokens) }) {
            baselineAverage(apps: apps, before: day) { Double(totals(for: apps, in: ($0, $1)).totalTokens) }
        }

        let costCard = KPICard(
            title: tr("Estimated cost", "估算费用"),
            value: StatsFormatter.cost(currentCost.value) + (currentCost.hasUnknown ? "+" : ""),
            detail: cost.text,
            segments: segments { knownCost(for: [$0], in: rangeBounds).value.doubleValue },
            baselineLine: cost.line
        )
        let tokensCard = KPICard(
            title: mergeTokens ? tr("All tokens (incl. cache)", "全部 Tokens（含缓存）") : tr("Tokens (excl. cache reads)", "Tokens（不含缓存读取）"),
            value: StatsFormatter.compactToken(mergeTokens ? allTokens : current.nonCacheReadTokens),
            detail: mergeTokens
                ? [all.text, allTokens > 0 ? shareText : nil].compactMap { $0 }.joined(separator: " · ")
                : tokens.text,
            segments: segments { Double(tokenCount(totals(for: [$0], in: rangeBounds))) },
            baselineLine: mergeTokens ? all.line : tokens.line,
            accessory: AnyView(mergeButton)
        )
        let cacheCard = KPICard(
            title: tr("Cache reads", "缓存读取"),
            value: StatsFormatter.compactToken(current.cacheReadTokens),
            detail: singleDay ? cache.text : (allTokens > 0 ? tr("\(Int(cacheShare.rounded()))% of all tokens", "占全部 Token \(Int(cacheShare.rounded()))%") : nil),
            segments: segments { Double(totals(for: [$0], in: rangeBounds).cacheReadTokens) },
            baselineLine: cache.line
        )

        let gap: CGFloat = 12
        let width = max(0, (kpiRowWidth - gap * 2) / 3)
        return Group {
            if kpiRowWidth > 0 {
                // 固定三列宽度：合并时 Tokens 卡展开盖住缓存卡的位置，缓存卡宽度收为 0 并淡出(弹簧动画)。
                HStack(alignment: .top, spacing: 0) {
                    costCard.frame(width: width)
                    Color.clear.frame(width: gap, height: 1)
                    tokensCard.frame(width: mergeTokens ? width * 2 + gap : width)
                    Color.clear.frame(width: mergeTokens ? 0 : gap, height: 1)
                    cacheCard
                        .frame(width: mergeTokens ? 0 : width)
                        .opacity(mergeTokens ? 0 : 1)
                        .clipped()
                        .allowsHitTesting(!mergeTokens)
                }
            } else {
                HStack(spacing: gap) { costCard; tokensCard; cacheCard }
            }
        }
        // 卡片 maxHeight: .infinity + 这里固定垂直尺寸 → 三张卡等高。
        .fixedSize(horizontal: false, vertical: true)
        // minWidth: 0 让外框宽度只取可用宽度、不被里面按旧宽度排好的卡片撑大;
        // 否则窗口变窄 / 侧边栏展开时测到的仍是旧宽度，整页内容会比窗口宽。
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { kpiRowWidth = $0 }
    }

    /// Tokens 卡右上角：合并 / 拆分 Tokens 与缓存读取。
    private var mergeButton: some View {
        Button {
            anchorKeeper.preserveReadingPosition()
            withAnimation(Self.switchAnimation) {
                mergeTokens.toggle()
            }
        } label: {
            Image(systemName: mergeTokens ? "arrow.triangle.branch" : "arrow.triangle.merge")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mergeTokens
              ? tr("Show tokens and cache reads separately", "拆开 Tokens 和缓存读取")
              : tr("Merge tokens and cache reads", "合并 Tokens 和缓存读取"))
    }

    /// 「全部」时画按服务拆分的细条;单日视图下单个服务也画(用来对照基准竖线)。
    private func segments(_ value: (UsageApp) -> Double) -> [KPISegment] {
        guard visibleApps.count > 1 || isSingleDay else { return [] }
        return visibleApps.map { KPISegment(id: $0.rawValue, color: $0.statsTint, value: value($0)) }
    }

    /// 环比用中性灰显示(用得多不代表"坏"),上期基数极小时封顶为 >999%。
    private func deltaText(current: Double, previous: Double?, label: String) -> String? {
        guard let previous, previous > 0 else { return nil }
        let delta = (current - previous) / previous * 100
        let arrow = delta >= 0 ? "↑" : "↓"
        let magnitude = abs(delta)
        let number = magnitude >= 1000 ? ">999" : String(format: "%.0f", magnitude)
        return "\(arrow) \(number)% \(label)"
    }

    // MARK: Daily usage panel

    /// 只看 Gemini 时没有 费用 / Tokens 可切换，换成「回答次数」标签。
    @ViewBuilder
    private var metricControl: some View {
        if answersOnly {
            Text(tr("Answers", "回答次数"))
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
        } else {
            metricPicker
        }
    }

    private var metricPicker: some View {
        // 切换时条形、竖线、柱状图平滑过渡，数字滚动(与合并 Tokens 同一套弹簧动画)。
        Picker("", selection: Binding(
            get: { metric },
            set: { newValue in withAnimation(Self.switchAnimation) { metric = newValue } }
        )) {
            Text(tr("Cost", "费用")).tag(StatsMetric.cost)
            Text("Tokens").tag(StatsMetric.tokens)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var dailyUsagePanel: some View {
        let samples = dailySamples
        let average = samples.isEmpty ? 0 : samples.map(\.total).reduce(0, +) / Double(samples.count)
        // 纵轴固定在最终高度：柱子长出来时刻度不跟着缩放(自动刻度会随柱子一起变，看起来像没动)。
        let yTop = Self.niceCeiling(max(samples.map(\.total).max() ?? 0, average))

        // Gemini 是次数，不和 token / 费用叠在柱子里：柱子下面留一条窄道，有回答的那天放一颗 Gemini 小星，
        // 回答越多星越大(面积 ∝ 次数),具体次数在悬停浮层里。只看 Gemini 时柱子本身就是次数，不画这条道。
        let chartApps = answersOnly ? [UsageApp.gemini] : visibleApps.filter { $0 != .gemini }
        let laneDays: [GeminiLaneDay] = answersOnly || !visibleApps.contains(.gemini) ? [] : samples.compactMap { sample in
            let count = Int(dayValue(app: .gemini, day: sample.day))
            return count > 0 ? GeminiLaneDay(day: sample.day, count: count) : nil
        }
        let laneMax = laneDays.map(\.count).max() ?? 0
        let lane = laneMax > 0 ? yTop * 0.18 : 0
        // 日均写在标题旁(一小段虚线 + 数值，和图里的虚线对应)，不再标在图里：范围长时柱子密，图内标注会压在柱子上。
        let averageLegend = AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                DashedLegendLine()
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: 14, height: 1)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3.5 }
                Text("\(tr("avg", "日均")) \(formatMetric(average))")
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
            }
            .opacity(samples.allSatisfy({ $0.total == 0 }) ? 0 : 1)
        )
        return Panel(title: "Daily usage", chinese: "每日用量", right: AnyView(
            HStack(spacing: 12) {
                // 放得下就写服务名，窗口窄时只留图标(悬停看名字)，不折行。
                ViewThatFits(in: .horizontal) {
                    serviceLegend(names: true)
                    serviceLegend(names: false)
                }
                metricControl
            }
        ), titleAccessory: averageLegend) {
            if samples.allSatisfy({ $0.total == 0 }) && laneDays.isEmpty {
                placeholderHeight(104, message: tr("No usage in this range", "这段时间没有用量"))
            } else {
                Chart {
                    ForEach(laneDays) { item in
                        PointMark(x: .value("Day", item.day, unit: .day), y: .value("Gemini", -lane / 2))
                            .symbol { ServiceLogo(app: .gemini, size: Self.laneSymbolSize(item.count, max: laneMax)) }
                            .opacity((selectedSample == nil || selectedSample?.day == item.day ? 1 : 0.45) * barReveal)
                    }

                    ForEach(samples) { sample in
                        ForEach(chartApps, id: \.self) { app in
                            BarMark(
                                x: .value("Day", sample.day, unit: .day),
                                y: .value("Value", sample.value(for: app) * barReveal),
                                width: barWidth(dayCount: samples.count),
                                stacking: .standard
                            )
                            .foregroundStyle(app.statsTint)
                            .cornerRadius(2)
                            .opacity(selectedSample == nil || selectedSample?.day == sample.day ? 1 : 0.45)
                        }
                    }

                    RuleMark(y: .value("Average", average * barReveal))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

                    if let selected = selectedSample {
                        RuleMark(x: .value("Selected", selected.day, unit: .day))
                            .foregroundStyle(Color.clear)
                            .annotation(
                                position: .top,
                                spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                dayTooltip(selected)
                            }
                    }
                }
                .chartXSelection(value: $selectedDay)
                .chartXAxis {
                    // 日期标签放在当天的刻度上、不做居中，正对它那天的柱子。
                    // (原来 stride 每 N 天 + centered 会把标签居中到 N 天区间里，偏到后面两天多。)
                    AxisMarks(values: Self.dayLabelTicks(samples.map(\.day))) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), anchor: .top)
                            .font(.system(size: 10 * textScale))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    // 刻度只标 0 以上(下面的 Gemini 窄道不标);0 那条网格线就是柱子和窄道的分界。
                    AxisMarks(position: .leading, values: Self.axisTicks(top: yTop)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatMetricAxis(v))
                                    .scaledFont(size: 10)
                                    .foregroundStyle(Color.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .chartYScale(domain: -lane...yTop)
                // 与「今天」面板同高。
                .frame(height: 104)
                // 换时间范围 / 服务时换一张新图(旧图立即移走，不做淡出叠在一起)，柱子从 0 长出来。
                .id(dailyChartKey)
                .transition(.identity)
            }
        }
    }

    /// 横轴日期标签：大约 6 个，每 N 天一个，从最后一天往前数(最后一天总有标签)。
    private static func dayLabelTicks(_ days: [Date]) -> [Date] {
        guard !days.isEmpty else { return [] }
        let step = max(1, days.count / 6)
        var picked = stride(from: days.count - 1, through: 0, by: -step).map { days[$0] }
        picked.reverse()
        return picked
    }

    /// 每日用量右上角的服务图例。
    private func serviceLegend(names: Bool) -> some View {
        HStack(spacing: names ? 10 : 8) {
            ForEach(visibleApps, id: \.self) { app in
                HStack(spacing: 5) {
                    ServiceLogo(app: app, size: 11)
                    if names {
                        Text(app.statsShortTitle)
                            .scaledFont(size: 11)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .help(app.statsShortTitle)
            }
        }
    }

    /// 纵轴刻度：0 到 top,步长取约 top / 3 的整齐数(1、2、2.5、5 × 10ⁿ)。
    private static func axisTicks(top: Double) -> [Double] {
        guard top > 0, top.isFinite else { return [0] }
        let raw = top / 3
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw * 0.999_999 } ?? raw
        return stride(from: 0, through: top * 1.000_001, by: step).map { $0 }
    }

    /// Gemini 窄道上小星的大小：7~13pt,面积按当天回答次数 / 这段时间单日最多。
    private static func laneSymbolSize(_ count: Int, max: Int) -> CGFloat {
        7 + 6 * CGFloat((Double(count) / Double(Swift.max(max, 1))).squareRoot())
    }

    /// 纵轴上限取不小于 value 的「整齐」数(1、1.2、1.5、2、2.5、3、4、5、6、8 × 10ⁿ)。
    private static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where step * magnitude >= value * 0.999_999 {
            return step * magnitude
        }
        return 10 * magnitude
    }

    private func barWidth(dayCount: Int) -> MarkDimension {
        if dayCount <= 10 { return .fixed(16) }
        if dayCount <= 31 { return .fixed(10) }
        return .ratio(0.7)
    }

    private var selectedSample: DailySample? {
        guard let selectedDay else { return nil }
        let day = Calendar.current.startOfDay(for: selectedDay)
        return dailySamples.first { $0.day == day }
    }

    private func dayTooltip(_ sample: DailySample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(StatsFormatter.day(sample.day))
                .scaledFont(size: 11, weight: .semibold)
            ForEach(visibleApps, id: \.self) { app in
                HStack(spacing: 5) {
                    ServiceLogo(app: app, size: 10)
                    Text(app.statsShortTitle)
                    Spacer(minLength: 10)
                    Text(app == .gemini
                         ? Self.answersText(dayValue(app: .gemini, day: sample.day))
                         : formatMetric(sample.value(for: app)))
                        .monospacedDigit()
                }
                .scaledFont(size: 11)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: Single-day panel (今天 / 昨天)
    //
    // 只有一天时柱状图只剩一根占满全宽的柱子，没有参考意义;
    // 改为每个服务「当天 vs 前 7 日均值」的横向对比。

    /// 「今天」面板的行:Codex、Claude Code 各一行;Grok + Grok Bot 一行、Gemini + agy 一行(可拆成并列两条)。
    /// 只出现当前服务筛选里可见的服务;一组里只剩一个服务时就是普通的一行。
    private var singleDayGroups: [[UsageApp]] {
        let groups: [[UsageApp]] = [[.codex], [.claude], [.grok, .grokBot], [.gemini, .agy]]
        return groups.map { $0.filter(visibleApps.contains) }.filter { !$0.isEmpty }
    }

    private var singleDayPanel: some View {
        let day = Calendar.current.startOfDay(for: rangeBounds.from)
        let rows = Dictionary(uniqueKeysWithValues: visibleApps.map { app -> (UsageApp, SingleDayRow) in
            (app, SingleDayRow(app: app, value: dayValue(app: app, day: day),
                               average: baselineAverage(apps: [app], before: day) { metricValue(app: app, from: $0, to: $1) }))
        })
        let groups = singleDayGroups
        // 合并行按两者之和计，比例尺取各行(合并后)的最大值。Gemini 是次数，不参与(只看 Gemini 时除外)。
        let maxValue = max(groups.map { group in
            let same = group.filter(sharesUnit)
            return max(same.compactMap { rows[$0]?.value }.reduce(0, +), same.compactMap { rows[$0]?.average }.reduce(0, +))
        }.max() ?? 0, 0.0001)
        // 合并的 Gemini · Antigravity 行右侧要写两种单位，所有行的数值列一起加宽，条形右端仍对齐。
        let hasMixedMerged = groups.contains { group in
            group.count == 2 && !isPairSplit(group[0]) && group.contains { !sharesUnit($0) }
        }
        let valueWidth: CGFloat = hasMixedMerged ? 200 : 150
        let sameUnitRows = rows.values.filter { sharesUnit($0.app) }
        let todayTotal = sameUnitRows.map(\.value).reduce(0, +)
        let averageTotal = sameUnitRows.map(\.average).reduce(0, +)
        let isToday = range == .today

        return Panel(
            title: isToday ? "Today" : (range == .yesterday ? "Yesterday" : "This day"),
            chinese: isToday ? "今天" : (range == .yesterday ? "昨日" : "当天"),
            right: AnyView(HStack(spacing: 10) {
                baselinePicker
                metricControl
            }),
            // 火苗参与标题的基线布局；昨日保留同尺寸占位，避免标题行变矮带动面板晃动。
            titleAccessory: AnyView(todayFlame.opacity(isToday ? 1 : 0)
                .allowsHitTesting(isToday).accessibilityHidden(!isToday))
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups, id: \.self) { group in
                    let groupRows = group.compactMap { rows[$0] }
                    // Gemini(次数)和 Antigravity(token / 费用)单位不同：拆开时各用自己的比例尺;
                    // 合并时条形只算 Antigravity(和其他行同一比例尺)，Gemini 的次数写在右侧数值里。
                    let mixedUnits = group.count == 2 && group.contains { !sharesUnit($0) }
                    if group.count == 2, isPairSplit(group[0]) {
                        // 拆开：同一行变成并列两条，各占半宽，各有自己的基准竖线和数值(比例尺取这两条自己的最大值)。
                        let pairMax = max(groupRows.map { max($0.value, $0.average) }.max() ?? 0, 0.0001)
                        HStack(spacing: 24) {
                            ForEach(Array(groupRows.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        ServiceLogo(app: row.app, size: 14)
                                        Text(row.app.statsShortTitle)
                                            .scaledFont(size: 12)
                                            .lineLimit(1)
                                        if index == 0 { pairButton(group) }
                                    }
                                    .fixedSize()
                                    singleDayBar(value: row.value, average: row.average,
                                                 maxValue: mixedUnits ? max(row.value, row.average, 0.0001) : pairMax, tint: row.app.statsTint)
                                    singleDayValue(value: row.value, average: row.average, app: row.app)
                                        .fixedSize()
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .transition(Self.pairTransition)
                    } else {
                        // 条形用同单位的行;整组都是次数(单独的 Gemini)时就用它自己。
                        let sameRows = groupRows.filter { sharesUnit($0.app) }
                        let countRows = groupRows.filter { !sharesUnit($0.app) }
                        let barRows = sameRows.isEmpty ? countRows : sameRows
                        let value = barRows.map(\.value).reduce(0, +)
                        let average = barRows.map(\.average).reduce(0, +)
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                HStack(spacing: -4) {
                                    ForEach(group, id: \.self) { ServiceLogo(app: $0, size: 14) }
                                }
                                Text(group.count == 2 ? group.map(\.statsShortTitle).joined(separator: " · ") : group[0].statsTitle)
                                    .scaledFont(size: 12)
                                    .lineLimit(1)
                                if group.count == 2 { pairButton(group) }
                            }
                            .frame(width: 196, alignment: .leading)

                            // 合并时一整条(两者相加，单色)。单独一行的 Gemini(次数)用自己的比例尺。
                            singleDayBar(value: value, average: average,
                                         maxValue: sameRows.isEmpty ? max(value, average, 0.0001) : maxValue,
                                         tint: group[0].statsTint)

                            Group {
                                if mixedUnits, let count = countRows.first {
                                    mixedPairValue(value: value, average: average, count: count)
                                } else {
                                    singleDayValue(value: value, average: average, app: barRows.first?.app ?? group[0])
                                }
                            }
                            .frame(width: valueWidth, alignment: .trailing)
                        }
                        .help(mixedUnits
                              ? tr("The bar is Antigravity only. Gemini Apps is counted in answers (shown on the right).",
                                   "条形只算 Antigravity;Gemini App 按回答次数，写在右侧。")
                              : "")
                        .transition(Self.pairTransition)
                    }
                }

                Text(singleDayFootnote(total: todayTotal, average: averageTotal, isToday: isToday))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    /// 拆开 / 合并时新出现的行从左侧轻微展开并淡入。
    private static let pairTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.9, anchor: .leading))

    private func isPairSplit(_ first: UsageApp) -> Bool {
        first == .grok ? splitGrokPair : splitGooglePair
    }

    /// 两个服务合并行 / 拆开行名字后面的按钮，和「全部 Tokens」卡的合并按钮同一套图标与弹簧动画。
    private func pairButton(_ group: [UsageApp]) -> some View {
        let split = isPairSplit(group[0])
        let names = group.map(\.statsShortTitle).joined(separator: tr(" and ", " 和 "))
        return Button {
            anchorKeeper.preserveReadingPosition()
            withAnimation(Self.switchAnimation) {
                if group[0] == .grok { splitGrokPair.toggle() } else { splitGooglePair.toggle() }
            }
        } label: {
            Image(systemName: split ? "arrow.triangle.merge" : "arrow.triangle.branch")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(split ? tr("Merge \(names)", "合并 \(names)") : tr("Show \(names) separately", "拆开 \(names)"))
    }

    /// 「今天」的横条：当天数值 + 对比基准竖线。
    private func singleDayBar(value: Double, average: Double, maxValue: Double, tint: Color) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 10)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint)
                    .frame(width: max(0, min(width, width * value / maxValue)), height: 10)
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 1.5, height: 18)
                    .offset(x: max(0, min(width - 1.5, width * average / maxValue)))
                    .opacity(average > 0 ? 1 : 0)
            }
            .frame(height: 18)
        }
        .frame(height: 18)
    }

    /// 合并的 Gemini · Antigravity:「Antigravity 数值 · Gemini 次数 / 均 … · …」。
    private func mixedPairValue(value: Double, average: Double, count: SingleDayRow) -> some View {
        Text("\(formatMetric(value)) · \(Self.answersText(count.value)) / \(tr("avg", "均")) \(formatMetric(average)) · \(Self.answersText(count.average))")
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .contentTransition(.numericText())
    }

    private func singleDayValue(value: Double, average: Double, app: UsageApp) -> some View {
        Text("\(formatValue(value, app: app)) / \(tr("avg", "均")) \(formatValue(average, app: app))")
            .scaledFont(size: 11)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    /// 「今天」旁的火苗：按今天全部服务的全部 Token(含缓存)落在热力图哪一档(和 Token 活动 ·「全部」同一套分档)。
    /// 火苗底部和「今天」两个字的底部对齐：把火苗的基线放在它的底部往上 baseInset - titleDescent 处。
    private var todayFlame: some View {
        let daily = allAppsDaily
        let today = TokenHeat.calendar.startOfDay(for: Date())
        let total = daily[today] ?? 0
        let thresholds = TokenHeat.thresholds(daily: daily, since: TokenHeat.windowStart())
        let level = TokenHeat.level(total, thresholds: thresholds)
        let titleDescent: CGFloat = 1.0
        let help: String = {
            let amount = StatsFormatter.compactToken(total)
            switch level {
            case 0: return tr("No tokens yet today", "今天还没有用量")
            case 4: return tr("Today: \(amount) tokens · level 4 (above 75% of days)", "今天全部 Token \(amount) · 第 4 档(超过 75% 的日子)")
            default: return tr("Today: \(amount) tokens · level \(level) of 4", "今天全部 Token \(amount) · 第 \(level) 档(共 4 档)")
            }
        }()
        return TodayFlame(level: level)
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - TodayFlame.baseInset + titleDescent }
            .help(help)
    }

    private func singleDayFootnote(total: Double, average: Double, isToday: Bool) -> String {
        let legend = tr("Line = \(baseline.lineDescription).", "竖线 = \(baseline.lineDescription)。")
        guard average > 0 else { return legend }
        let pct = Int((total / average * 100).rounded())
        let progress = isToday
            ? tr(" So far today: \(pct)% of it.", " 今天到目前为止为它的 \(pct)%。")
            : (range == .yesterday
                ? tr(" Yesterday: \(pct)% of it.", " 昨日为它的 \(pct)%。")
                : tr(" That day: \(pct)% of it.", " 当天为它的 \(pct)%。"))
        return legend + progress
    }

    /// 对比基准选择(昨日 / 7 天 / 30 天 / 全部)。
    private var baselinePicker: some View {
        Picker("", selection: Binding(
            get: { baseline },
            set: { newValue in withAnimation(Self.switchAnimation) { baseline = newValue } }
        )) {
            ForEach(StatsBaseline.allCases, id: \.self) { item in
                Text(item.shortLabel).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help(tr("Compare against", "对比基准"))
    }

    /// 某一天之前的基准值：昨日 = 前一天;7 / 30 天 = 前 N 天日均;全部 = 首次使用以来的日均。
    /// `value(from, to)` 返回区间合计。
    private func baselineAverage(apps: [UsageApp], before day: Date, _ value: (Date, Date) -> Double) -> Double {
        let cal = Calendar.current
        // 顶部选「昨日」只切换展示的用量，下方对比选项仍沿用「今天」的基准。
        let day = range == .yesterday ? cal.startOfDay(for: Date()) : day
        switch baseline {
        case .yesterday:
            let from = cal.date(byAdding: .day, value: -1, to: day) ?? day
            return value(from, day)
        case .sevenDays, .thirtyDays:
            let days = baseline == .sevenDays ? 7 : 30
            let from = cal.date(byAdding: .day, value: -days, to: day) ?? day
            return value(from, day) / Double(days)
        case .all:
            let set = Set(apps)
            let earliest = set == [.gemini]
                ? appState.geminiAnswerLog.firstDay(before: day)
                : index.firstDay(for: set, before: day)
            guard let first = earliest else { return 0 }
            let days = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: first), to: day).day ?? 1)
            return value(first, day) / Double(days)
        }
    }

    /// Tokens 口径：未合并时不含缓存读取，合并后为全部 token。
    private func tokenCount(_ t: UsageTotals) -> Int {
        mergeTokens ? t.totalTokens : t.nonCacheReadTokens
    }

    private func dayValue(app: UsageApp, day: Date) -> Double {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        return metricValue(app: app, from: day, to: next)
    }

    /// 某服务在区间内的数值。Gemini App 没有 token / 费用，不管当前口径都按回答次数。
    private func metricValue(app: UsageApp, from: Date, to: Date) -> Double {
        if app == .gemini { return Double(appState.geminiAnswerLog.total(from: from, to: to)) }
        switch effectiveMetric {
        case .cost:
            return knownCost(for: [app], in: (from, to)).value.doubleValue
        case .tokens:
            return Double(tokenCount(totals(for: [app], in: (from, to))))
        case .answers:
            return 0
        }
    }

    /// 和当前口径同单位才能放在一起加、共用比例尺:只看 Gemini 时是 Gemini,否则是 Gemini 以外的服务。
    private func sharesUnit(_ app: UsageApp) -> Bool {
        answersOnly || app != .gemini
    }

    /// 某服务数值的文字：Gemini 写次数，其他按当前口径。
    private func formatValue(_ value: Double, app: UsageApp) -> String {
        app == .gemini ? Self.answersText(value) : formatMetric(value)
    }

    private func formatMetric(_ value: Double) -> String {
        switch effectiveMetric {
        case .cost: return StatsFormatter.cost(Decimal(value))
        case .tokens: return StatsFormatter.compactToken(Int(value.rounded()))
        case .answers: return Self.answersText(value)
        }
    }

    private func formatMetricAxis(_ value: Double) -> String {
        switch effectiveMetric {
        case .cost: return "$\(Int(value.rounded()))"
        case .tokens: return StatsFormatter.compactToken(Int(value.rounded()))
        case .answers: return "\(Int(value.rounded()))"
        }
    }

    /// 回答次数:日均可能是小数，保留一位(整数不带小数点)。
    static func answersText(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        return tr("\(number) answers", "\(number) 次")
    }

    // MARK: Current limits panel

    /// 整宽 2 列 6 格:Codex | Claude、Grok | Grok Bot、Gemini | agy。每格左侧图标，右侧 5H / WK 行。
    /// 只显示当前服务筛选里可见的服务(Grok Bot / Gemini / agy 还要在设置里启用)。
    private var currentLimitsPanel: some View {
        let apps = UsageApp.allCases.filter(visibleApps.contains)
        let columns = [GridItem(.flexible(), spacing: 28, alignment: .top), GridItem(.flexible(), spacing: 28, alignment: .top)]
        return Panel(title: "Current limits", chinese: "当前额度") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                ForEach(Array(apps.enumerated()), id: \.element) { index, app in
                    QuotaTile(app: app, lanes: quotaLanes(for: app), note: quotaNote(for: app),
                              unavailable: false)
                        .help(quotaNote(for: app) ?? (app == .gemini
                            ? tr("Models of the latest replies read from your recent Gemini chats. Gemini Apps doesn't report tokens or cost; answers are counted in stats (filter by Gemini).",
                                 "最近读到的几条回答用的模型。Gemini App 不提供 token 和费用，统计里按回答次数算(服务筛选选 Gemini)。")
                            : app.displayName))
                        .padding(.vertical, 8)
                        .overlay(alignment: .top) {
                            if index >= 2 { Divider() }
                        }
                }
            }
        }
    }

    private func quotaLanes(for app: UsageApp) -> [(label: String, window: QuotaWindow?)] {
        let snapshot = appState.localQuota(for: app)
        if app.hasSinglePeriod {
            // Grok 按云端计费周期(多为周);标签取周期名的英文缩写。
            let period = (snapshot?.primaryLabel ?? "WEEK · 本周").components(separatedBy: " · ").first ?? "WEEK"
            let label: String
            switch period {
            case "MONTH": label = "MO"
            case "DAY": label = "DAY"
            case "PERIOD": label = tr("Period", "周期")
            default: label = "WK"
            }
            return [(label, snapshot?.primary ?? snapshot?.weekly)]
        }
        if let pools = snapshot?.pools {
            return pools.flatMap { [("\($0.label) 5H", $0.fiveHour), ("\($0.label) WK", $0.weekly)] }
        }
        // 标签按窗口长度写(免费 ChatGPT 账号的长窗口是每月，写 MO);没有 5H 的只列长窗口
        let five = QuotaCardView.Window(id: "5h", label: "", window: snapshot?.fiveHour)
        let long = QuotaCardView.Window(id: "wk", label: "", window: snapshot?.weekly)
        let lanes = [(MenuBarPopoverView.shortLabel(five, pools: nil), snapshot?.fiveHour),
                     (MenuBarPopoverView.shortLabel(long, pools: nil), snapshot?.weekly)]
        let present = lanes.filter { $0.1 != nil }
        return present.isEmpty ? lanes : present
    }

    private func quotaNote(for app: UsageApp) -> String? {
        switch app {
        case .codex, .claude, .grok, .agy: return nil
        case .grokBot: return appState.grokBotQuotaError
        case .gemini: return appState.geminiAppQuotaError
        }
    }

    // MARK: Models table

    fileprivate enum ModelSortKey {
        case model, input, output, cacheRead, cacheWrite, cost
    }

    /// 可排序的模型列表(自绘，便于放进统计大页的 ScrollView)。
    private var modelsTable: some View {
        let rows = sortedModelRows
        // 用量(全部 Token,含缓存)最多的模型旁加一个跳动的小火苗;只有一个模型时不加。
        // 只看 Gemini 时按回答次数比。
        let score: (ModelRow) -> Int = answersOnly ? { $0.answers ?? 0 } : { $0.totalTokens }
        let hottest = rows.count > 1 ? rows.filter { score($0) > 0 }.max { score($0) < score($1) }?.id : nil
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                modelHeader(tr("Model", "模型"), .model, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                modelHeader(tr("Input", "输入"), .input).frame(width: 96, alignment: .trailing)
                modelHeader(tr("Output", "输出"), .output).frame(width: 96, alignment: .trailing)
                modelHeader(tr("Cache reads", "缓存读取"), .cacheRead).frame(width: 104, alignment: .trailing)
                modelHeader(tr("Cache writes", "缓存写入"), .cacheWrite).frame(width: 104, alignment: .trailing)
                modelHeader(tr("Cost", "费用"), .cost).frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.03))

            VStack(spacing: 0) {
                if rows.isEmpty {
                    Divider()
                    placeholderHeight(80, message: tr("No usage in this range", "这段时间没有用量"))
                }
                ForEach(rows) { row in
                    Divider()
                    modelRow(row, isHottest: row.id == hottest)
                }
            }
            .opacity(modelsRowsOpacity)
            if rows.contains(where: { $0.answers != nil }) {
                Text(tr("Gemini Apps reports answers only (read from your Gemini web chats); no tokens or cost.",
                        "Gemini App 只有回答次数(从 Gemini 网页会话读取)，没有 token 和费用。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            if rows.contains(where: { $0.app == .grokBot }) {
                Text(tr("Grok Bot reports total tokens (shown in Input); no input/output/cache breakdown. — means no model cost estimate is available.",
                        "Grok Bot 仅提供总 token（暂列在输入列），没有输入／输出／缓存拆分；费用 — 表示暂无模型成本估值。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .frame(maxWidth: .infinity)
        .ccPanel(cornerRadius: 12)
        // 顶部按钮改变数据时表格不做任何位移 / 尺寸动画(否则行会「飞」过 Token 活动，看模型明细时也会晃),
        // 只把行瞬时换掉，再做一次 0.3s 的淡入提示数据已更新。点表头排序(数据不变)仍有行移动动画。
        .transaction(value: filterKey) { $0.animation = nil }
        .onChange(of: filterKey) { _, _ in
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { modelsRowsOpacity = 0.35 }
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) { modelsRowsOpacity = 1 }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ row: ModelRow, isHottest: Bool) -> some View {
        if let answers = row.answers {
            answersModelRow(row, answers: answers, isHottest: isHottest)
        } else {
            tokenModelRow(row, isHottest: isHottest)
        }
    }

    private func modelNameCell(_ row: ModelRow, isHottest: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 7) {
            ServiceLogo(app: row.app, size: 13)
            Text(row.model)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            if isHottest {
                HotFlame()
                    .padding(.leading, -2)
                    .help(answersOnly ? tr("Most answers in this range", "这段时间回答最多") : tr("Most tokens in this range", "这段时间用量最多"))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Gemini App 的行：模型名后写回答次数，token / 费用列都是 —。
    private func answersModelRow(_ row: ModelRow, answers: Int, isHottest: Bool) -> some View {
        HStack(spacing: 0) {
            modelNameCell(row, isHottest: isHottest, detail: tr("\(answers) answers", "\(answers) 次回答"))
            ForEach(Array(([96, 96, 104, 104, 96] as [CGFloat]).enumerated()), id: \.offset) { _, width in
                numberCell("—")
                    .foregroundStyle(.secondary)
                    .frame(width: width, alignment: .trailing)
            }
        }
        .help(tr("Gemini Apps doesn't report tokens or cost", "Gemini App 不提供 token 和费用"))
        .scaledFont(size: 12)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func tokenModelRow(_ row: ModelRow, isHottest: Bool) -> some View {
        HStack(spacing: 0) {
            modelNameCell(row, isHottest: isHottest)
            numberCell(StatsFormatter.tableToken(row.inputTokens)).frame(width: 96, alignment: .trailing)
            numberCell(StatsFormatter.tableToken(row.outputTokens)).frame(width: 96, alignment: .trailing)
            numberCell(StatsFormatter.tableToken(row.cacheReadTokens)).frame(width: 104, alignment: .trailing)
            // Codex / Grok 的日志不单独记缓存写入(字段恒为 0),显示 — 而不是 0。
            Group {
                if row.app != .claude && row.cacheCreationTokens == 0 {
                    numberCell("—")
                        .foregroundStyle(.secondary)
                        .help(tr("Not reported in this service's logs", "该服务的日志不单独记录缓存写入"))
                } else {
                    numberCell(StatsFormatter.tableToken(row.cacheCreationTokens))
                }
            }
            .frame(width: 104, alignment: .trailing)
            numberCell(row.isPriced ? StatsFormatter.cost(row.cost) : "—")
                .fontWeight(.medium)
                .frame(width: 96, alignment: .trailing)
                .help(row.app == .grokBot
                    ? tr("Grok Bot billing reports total tokens only. No model cost estimate is available for rows without a positive reported amount.",
                         "Grok Bot 账单只给总 token；未返回正数金额的行暂无模型成本估值，不代表免费调用。")
                    : tr("Estimated cost", "估算费用"))
        }
        .scaledFont(size: 12)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 时间范围 / 自定义日期 / 服务筛选 / Tokens 合并的组合标识，用于部分内部的局部动画。
    private var filterKey: String {
        "\(range)|\(customFrom.timeIntervalSince1970)|\(customTo.timeIntervalSince1970)|\(serviceFilter)|\(mergeTokens)"
    }

    private func modelHeader(_ title: String, _ key: ModelSortKey, alignment: HorizontalAlignment = .trailing) -> some View {
        Button {
            // 行按新顺序平滑移动(不带回弹，避免表格晃)。
            withAnimation(.easeInOut(duration: 0.25)) {
                if modelSortKey == key {
                    modelSortAscending.toggle()
                } else {
                    modelSortKey = key
                    modelSortAscending = key == .model
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if modelSortKey == key {
                    Image(systemName: modelSortAscending ? "chevron.up" : "chevron.down")
                        .scaledFont(size: 8, weight: .bold)
                }
            }
            .scaledFont(size: 11, weight: modelSortKey == key ? .semibold : .regular)
            .foregroundStyle(modelSortKey == key ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var sortedModelRows: [ModelRow] {
        func less(_ a: ModelRow, _ b: ModelRow) -> Bool {
            // 只看 Gemini 时 token 列全是 —，除按名称外都按回答次数排。
            if answersOnly && modelSortKey != .model { return (a.answers ?? 0) < (b.answers ?? 0) }
            switch modelSortKey {
            case .model: return a.model.localizedStandardCompare(b.model) == .orderedAscending
            case .input: return a.inputTokens < b.inputTokens
            case .output: return a.outputTokens < b.outputTokens
            case .cacheRead: return a.cacheReadTokens < b.cacheReadTokens
            case .cacheWrite: return a.cacheCreationTokens < b.cacheCreationTokens
            case .cost: return a.costSortValue < b.costSortValue
            }
        }
        return modelRows.sorted { a, b in
            // 排序列相同(比如 Gemini 各行的 token / 费用都是 —)时，回答次数多的在前。
            if less(a, b) == less(b, a) { return (a.answers ?? 0) > (b.answers ?? 0) }
            return modelSortAscending ? less(a, b) : less(b, a)
        }
    }

    private func numberCell(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
    }

    private var modelRows: [ModelRow] {
        var byKey: [String: (app: UsageApp, model: String, totals: UsageTotals)] = [:]
        for b in filteredBuckets {
            let key = "\(b.app.rawValue)|\(b.model)"
            var entry = byKey[key] ?? (b.app, b.model, .zero)
            entry.totals.add(b)
            byKey[key] = entry
        }
        var geminiRows: [ModelRow] = []
        if visibleApps.contains(.gemini) {
            let (from, to) = rangeBounds
            for (model, count) in appState.geminiAnswerLog.byModel(from: from, to: to) where count > 0 {
                geminiRows.append(ModelRow(id: "gemini-answers|\(model)", app: .gemini, model: model,
                                           inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                                           cost: 0, isPriced: false, answers: count))
            }
        }
        return geminiRows + byKey.map { key, entry in
            ModelRow(
                id: key,
                app: entry.app,
                model: entry.model,
                inputTokens: entry.totals.inputTokens,
                outputTokens: entry.totals.outputTokens,
                cacheReadTokens: entry.totals.cacheReadTokens,
                cacheCreationTokens: entry.totals.cacheCreationTokens,
                cost: entry.totals.costUSD,
                isPriced: Pricing.hasDisplayableCost(app: entry.app, model: entry.model, cost: entry.totals.costUSD)
            )
        }
    }

    // MARK: Timeline

    private var timelineContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            timelineHeader
            if timelineSections.isEmpty {
                placeholderHeight(220, message: tr("No accounts", "暂无账号"))
                    .ccPanel(cornerRadius: 12)
            } else {
                QuotaTimelineOverview(
                    sections: timelineSections,
                    hidden: $hiddenTimelineAccounts,
                    expanded: $expandedTimelineAccounts
                )
            }
        }
    }

    private var timelineHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text(timelineWindow == .fiveHour
                     ? tr("Today 5H Quota", "今日 5H 额度")
                     : tr("Today WK Quota", "今日 WK 额度"))
                    .scaledFont(size: 18, weight: .semibold)
                // 只在今天中途才开始记录时提示一句(说明曲线为什么不是从 0 点开始)。
                if let note = timelineRecordingNote {
                    Text(note)
                        .scaledFont(size: 11.5)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // 切换时曲线和账号行平滑过渡(Grok 只在 WK 下出现，淡入淡出)。
            Picker("", selection: Binding(
                get: { timelineWindow },
                set: { newValue in withAnimation(QuotaTimelineOverview.animation) { timelineWindow = newValue } }
            )) {
                Text("5H").tag(QuotaHistoryWindow.fiveHour)
                Text("WK").tag(QuotaHistoryWindow.weekly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(StatsFormatter.day(Date()))
                .scaledFont(size: 11, design: .monospaced)
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
        }
    }

    /// 额度变化页的账号：本机账号在前，各服务的其他账号紧随其后;Grok 只有周额度，仅在 WK 下出现。
    private var timelineSections: [QuotaTimelineSection] {
        var sections: [QuotaTimelineSection] = []
        let weekly = timelineWindow == .weekly

        func add(base: String, provider: String, plan: String?, email: String?, index: Int?,
                 tint: Color, snapshot: QuotaSnapshot?, accountExists: Bool) {
            let key = weekly ? QuotaHistoryAccountKey.weekly(base) : base
            guard accountExists || snapshot != nil || appState.quotaHistory.lastSamples[key] != nil
                    || !timelineEvents(for: key).isEmpty else { return }
            sections.append(timelineSection(
                key: key,
                title: timelineTitle(provider: provider, plan: plan, email: email, index: index),
                tint: tint,
                snapshot: snapshot
            ))
        }

        add(base: QuotaHistoryAccountKey.codexPrimary(accountId: appState.codexAccount?.accountId),
            provider: "Codex", plan: appState.codexAccount?.planType, email: appState.codexAccount?.email, index: nil,
            tint: .codexAccent, snapshot: appState.codexQuota, accountExists: appState.codexAccount != nil)
        for (idx, account) in appState.importedCodexAccounts.enumerated() {
            add(base: QuotaHistoryAccountKey.codexImported(id: account.id),
                provider: "Codex", plan: account.planType, email: account.email, index: idx + 1,
                tint: .codexAccent, snapshot: appState.importedCodexQuota(for: account), accountExists: true)
        }

        add(base: QuotaHistoryAccountKey.claudePrimary(),
            provider: "Claude Code", plan: appState.localClaudePlan.map { PlanTag.displayName($0, service: "claude") },
            email: appState.claudeAccount?.email,
            index: nil, tint: .claudeAccent, snapshot: appState.claudeQuota, accountExists: appState.claudeAccount != nil)
        for (idx, account) in appState.extraAccounts(for: .claude).enumerated() {
            add(base: QuotaHistoryAccountKey.extra(id: account.id),
                provider: "Claude Code",
                plan: YYBarWebAccount.AccountPlan.claudePlan(account.plan, account.rateLimitTier).map { PlanTag.displayName($0, service: "claude") },
                email: account.email, index: idx + 1,
                tint: .claudeAccent, snapshot: appState.extraQuotas[account.id], accountExists: true)
        }

        if weekly {
            add(base: QuotaHistoryAccountKey.grokPrimary(),
                provider: "Grok", plan: appState.grokPlan, email: appState.grokAccount?.email, index: nil,
                tint: .grokAccent, snapshot: appState.grokQuota, accountExists: appState.grokAccount != nil)
            for (idx, account) in appState.extraAccounts(for: .grok).enumerated() {
                add(base: QuotaHistoryAccountKey.extra(id: account.id),
                    provider: "Grok", plan: account.plan, email: account.email, index: idx + 1,
                    tint: .grokAccent, snapshot: appState.extraQuotas[account.id], accountExists: true)
            }
            // Grok Bot 只有周额度。
            add(base: QuotaHistoryAccountKey.grokBotPrimary(),
                provider: "Grok Bot", plan: appState.grokBotQuota?.planType, email: appState.grokBotEmail, index: nil,
                tint: .grokAccent, snapshot: appState.grokBotQuota,
                accountExists: SettingsStore.shared.showGrokBot)
        }

        add(base: QuotaHistoryAccountKey.geminiApp(email: appState.geminiAppEmail),
            provider: "Gemini", plan: appState.geminiAppQuota?.planType, email: appState.geminiAppEmail, index: nil,
            tint: .googleAccent, snapshot: appState.geminiAppQuota, accountExists: SettingsStore.shared.showGemini)

        // Antigravity:agy 的 Gemini 池和 Claude·GPT 池各一条。
        let agyShown = SettingsStore.shared.showAgy
        for (pool, label, snapshot) in [("gemini", "Antigravity · Gemini", appState.geminiQuota),
                                        ("3p", "Antigravity · Claude·GPT", appState.agyQuota)] {
            add(base: QuotaHistoryAccountKey.agyPrimary(pool: pool),
                provider: label, plan: appState.googlePlan, email: appState.googleEmail, index: nil,
                tint: .googleAccent, snapshot: agyShown ? snapshot : nil, accountExists: agyShown && snapshot != nil)
        }
        for (idx, account) in appState.extraAccounts(for: .google).enumerated() {
            add(base: QuotaHistoryAccountKey.extra(id: account.id),
                provider: "Antigravity · Gemini", plan: nil, email: account.email, index: idx + 1,
                tint: .googleAccent, snapshot: appState.extraQuotas[account.id], accountExists: true)
            add(base: QuotaHistoryAccountKey.extra(id: account.antigravityQuotaKey),
                provider: "Antigravity · Claude·GPT", plan: nil, email: account.email, index: idx + 1,
                tint: .googleAccent, snapshot: appState.extraQuotas[account.antigravityQuotaKey], accountExists: true)
        }
        return sections
    }

    /// 账号名统一为「服务商 · 订阅等级 · 登录邮箱」;没有邮箱时用「账号 N」区分同一服务的多个账号。
    private func timelineTitle(provider: String, plan: String?, email: String?, index: Int?) -> String {
        var parts = [provider]
        if let plan, !plan.isEmpty { parts.append(plan.prefix(1).uppercased() + plan.dropFirst()) }
        if let email, !email.isEmpty {
            parts.append(email)
        } else if let index {
            parts.append(tr("Account \(index)", "账号 \(index)"))
        }
        return parts.joined(separator: " · ")
    }

    private func timelineSection(
        key: String,
        title: String,
        tint: Color,
        snapshot: QuotaSnapshot?
    ) -> QuotaTimelineSection {
        let events = timelineEvents(for: key)
        let sample = appState.quotaHistory.lastSamples[key]
        return QuotaTimelineSection(
            accountKey: key,
            title: title,
            tint: tint,
            currentRemaining: sample?.remainingPercent ?? roundedRemaining(snapshot),
            totalDelta: events.reduce(0) { $0 + $1.deltaPercent },
            latestEventAt: events.last?.sampledAt,
            events: events,
            recordingStartedAt: recordingStart(key: key, events: events)
        )
    }

    /// 曲线起点：今天第一次采样的时间。旧文件没有记录时，有变动就从 0 点开始(以前从早上就在记录),
    /// 没有变动则从最近一次采样开始，不凭空画出更早的数据。
    private func recordingStart(key: String, events: [QuotaChangeEvent]) -> Date? {
        let history = appState.quotaHistory
        if let first = history.firstSampledAt?[key] {
            return min(first, events.first?.sampledAt ?? first)
        }
        if !events.isEmpty { return nil }
        return history.lastSamples[key]?.sampledAt
    }

    /// 只有所有账号都是今天中途才开始记录时(如刚加的周窗口记录),副标题才说明从几点开始;
    /// 有账号从 0 点就有记录时不提示，避免误导。
    private var timelineRecordingNote: String? {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let sections = timelineSections
        guard !sections.isEmpty,
              sections.allSatisfy({ ($0.recordingStartedAt?.timeIntervalSince(dayStart) ?? 0) > 60 }),
              let earliest = sections.compactMap(\.recordingStartedAt).min() else { return nil }
        let time = StatsFormatter.time(earliest)
        return tr("Recording started at \(time) today; earlier changes aren't available.",
                  "今天从 \(time) 开始记录，更早的变化没有数据。")
    }

    private func timelineEvents(for key: String) -> [QuotaChangeEvent] {
        appState.quotaHistory.events
            .filter { $0.accountKey == key }
            .sorted { $0.sampledAt < $1.sampledAt }
    }

    private func roundedRemaining(_ snapshot: QuotaSnapshot?) -> Int? {
        guard let snapshot, let remaining = timelineWindow.window(in: snapshot)?.remainingPercent else { return nil }
        return max(0, min(100, Int(remaining.rounded())))
    }

    // MARK: Data helpers

    /// 「今天」火苗用：全部服务，按天汇总全部 token(含缓存读写),不受服务筛选影响。
    private var allAppsDaily: [Date: Int] {
        var result: [Date: Int] = [:]
        for b in index.buckets {
            result[Calendar.current.startOfDay(for: b.day), default: 0]
                += b.inputTokens + b.outputTokens + b.cacheReadTokens + b.cacheCreationTokens
        }
        return result
    }

    /// Token 活动页用：所选服务的全部历史，按天汇总全部 token(含缓存读写)。
    private var activityDaily: [Date: Int] {
        let apps = Set(visibleApps)
        var result: [Date: Int] = [:]
        for b in index.buckets where apps.contains(b.app) {
            result[Calendar.current.startOfDay(for: b.day), default: 0]
                += b.inputTokens + b.outputTokens + b.cacheReadTokens + b.cacheCreationTokens
        }
        return result
    }

    private var visibleApps: [UsageApp] {
        switch serviceFilter {
        // Grok Bot / Gemini / agy 只有在设置里启用(默认：本机装了才启用)时才出现。
        case .all: return UsageApp.allCases.filter { [.codex, .claude, .grok].contains($0) || SettingsStore.shared.isEnabled($0) }
        case .codex, .claude, .grok, .grokBot, .gemini, .agy:
            return serviceFilter.app.map { [$0] } ?? []
        case .grokPair, .googlePair:
            return (serviceFilter.pairApps ?? []).filter { $0 == .grok || SettingsStore.shared.isEnabled($0) }
        }
    }

    private var rangeBounds: (from: Date, to: Date) {
        range.bounds(customFrom: customFrom, customTo: customTo)
    }

    private var previousRangeBounds: (from: Date, to: Date)? {
        range.previousBounds(customFrom: customFrom, customTo: customTo)
    }

    /// 今天 / 昨天 / 自定义同一天 → 单日视图。
    private var isSingleDay: Bool {
        let (from, to) = rangeBounds
        guard from != .distantPast else { return false }
        return to.timeIntervalSince(from) <= 25 * 3600
    }

    private var filteredBuckets: [UsageBucket] {
        let (from, to) = rangeBounds
        let apps = Set(visibleApps)
        return index.buckets.filter { apps.contains($0.app) && $0.day >= from && $0.day < to }
    }

    /// 当前数据的按天索引(数据版本没变就直接复用)。
    private var index: StatsDataIndex {
        dataIndex.refresh(from: appState.usageService.aggregator)
        return dataIndex
    }

    private func totals(for apps: [UsageApp], in bounds: (from: Date, to: Date)) -> UsageTotals {
        index.sum(apps: apps, from: bounds.from, to: bounds.to).totals
    }

    /// 已知定价部分的费用。Grok 的费用由云端账单给出，视为已知。
    private func knownCost(for apps: [UsageApp], in bounds: (from: Date, to: Date)) -> (value: Decimal, hasUnknown: Bool) {
        let day = index.sum(apps: apps, from: bounds.from, to: bounds.to)
        return (day.knownCost, day.hasUnknown)
    }

    /// 连续的每日序列(范围内没有用量的日子补 0),图表横轴不跳日。
    private var dailySamples: [DailySample] {
        let cal = Calendar.current
        var byDay: [Date: [UsageApp: Double]] = [:]
        let (rangeFrom, rangeTo) = rangeBounds
        if effectiveMetric == .answers {
            for (day, count) in appState.geminiAnswerLog.daily where day >= rangeFrom && day < rangeTo {
                byDay[day, default: [:]][.gemini, default: 0] += Double(count)
            }
        }
        for b in filteredBuckets {
            let value: Double
            switch effectiveMetric {
            case .cost:
                guard Pricing.hasDisplayableCost(app: b.app, model: b.model, cost: b.costUSD) else { continue }
                value = b.costUSD.doubleValue
            case .tokens:
                value = Double(b.inputTokens + b.outputTokens + b.cacheCreationTokens + (mergeTokens ? b.cacheReadTokens : 0))
            case .answers:
                continue
            }
            byDay[b.day, default: [:]][b.app, default: 0] += value
        }

        let today = cal.startOfDay(for: Date())
        let firstDataDay = byDay.keys.min() ?? today
        var day = rangeFrom == .distantPast ? firstDataDay : cal.startOfDay(for: rangeFrom)
        let lastDay = min(cal.startOfDay(for: rangeTo.addingTimeInterval(-1)), today)

        var samples: [DailySample] = []
        while day <= lastDay {
            samples.append(DailySample(day: day, values: byDay[day] ?? [:]))
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return samples
    }

    private func placeholderHeight(_ height: CGFloat, message: String) -> some View {
        Text(message)
            .scaledFont(size: 12)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

// MARK: - Stats data index

/// 用量记录按 (服务, 天) 预先汇总。统计页的卡片、对比基准、按服务等要算几十次区间合计，
/// 每次都对全部记录过滤会让点击后卡顿半秒以上;这里只在数据版本变化时重建一次。
final class StatsDataIndex {
    struct DayTotals {
        var totals = UsageTotals.zero
        var knownCost: Decimal = 0
        var hasUnknown = false
        var hasKnown = false

        mutating func add(_ other: DayTotals) {
            totals.inputTokens += other.totals.inputTokens
            totals.outputTokens += other.totals.outputTokens
            totals.cacheReadTokens += other.totals.cacheReadTokens
            totals.cacheCreationTokens += other.totals.cacheCreationTokens
            totals.costUSD += other.totals.costUSD
            knownCost += other.knownCost
            hasUnknown = hasUnknown || other.hasUnknown
            hasKnown = hasKnown || other.hasKnown
        }
    }

    private(set) var buckets: [UsageBucket] = []
    private var perDay: [UsageApp: [(day: Date, totals: DayTotals)]] = [:]
    private var version = -1

    func refresh(from aggregator: UsageAggregator) {
        guard aggregator.version != version || version == -1 else { return }
        version = aggregator.version
        buckets = aggregator.snapshot()
        var grouped: [UsageApp: [Date: DayTotals]] = [:]
        for b in buckets {
            var day = grouped[b.app]?[b.day] ?? DayTotals()
            day.totals.add(b)
            if Pricing.hasDisplayableCost(app: b.app, model: b.model, cost: b.costUSD) {
                day.knownCost += b.costUSD
                day.hasKnown = true
            } else {
                day.hasUnknown = true
            }
            grouped[b.app, default: [:]][b.day] = day
        }
        perDay = grouped.mapValues { days in
            days.map { (day: $0.key, totals: $0.value) }.sorted { $0.day < $1.day }
        }
    }

    /// [from, to) 区间内所选服务的合计。
    func sum(apps: [UsageApp], from: Date, to: Date) -> DayTotals {
        var result = DayTotals()
        for app in apps {
            for entry in perDay[app] ?? [] where entry.day >= from && entry.day < to {
                result.add(entry.totals)
            }
        }
        return result
    }

    /// 所选服务在 `day` 之前最早有用量的一天。
    func firstDay(for apps: Set<UsageApp>, before day: Date) -> Date? {
        apps.compactMap { perDay[$0]?.first?.day }.filter { $0 < day }.min()
    }
}

// MARK: - Service logo

/// 统计页里的服务标识：菜单栏同款 logo,染成服务识别色。
private struct ServiceLogo: View {
    let app: UsageApp
    var size: CGFloat = 14

    var body: some View {
        ServiceLogoImage(logoName: app.rawValue, tint: app.statsTint, size: size)
    }
}

// MARK: - UsageApp display helpers

private extension UsageApp {
    var statsTitle: String { displayName }

    var statsShortTitle: String { self == .claude ? "Claude" : displayName }

    var statsTint: Color { accent }
}

private extension UsageTotals {
    /// 不含缓存读取的 token(输入 + 输出 + 缓存写入)。缓存读取单独展示，避免总量被它撑大。
    var nonCacheReadTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens
    }
}

// MARK: - Panel container

private struct Panel<Content: View>: View {
    let title: String
    let chinese: String
    var right: AnyView? = nil
    /// 标题右侧的小装饰(「今天」旁的火苗),按文字基线对齐。
    var titleAccessory: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(tr(title, chinese))
                        .scaledFont(size: 12.5, weight: .semibold)
                    if let titleAccessory { titleAccessory }
                }
                Spacer()
                if let right { right }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }
}

// MARK: - Token activity
//
// 统计 ·「Token 活动」页：最近 53 周，列 = 周(周一开头),全部 token(含缓存),跟随服务筛选。
// - 每天：日历热力格，按当日 token 分 4 级着色
// - 每周：每列像柱子一样从下往上填，格数 ∝ 当周合计
// - 累计总量：每列填到截至该周的累计
// 悬停立即显示深色浮层(日期 / 周 + token 数),每周 / 累计模式下悬停列变深。

private struct TokenActivityPanel: View {
    /// 本地 0 点 → 当日 token。
    let daily: [Date: Int]
    /// 上方服务筛选：全部用火苗同色系的暖色，单个服务用它的识别色。
    let filter: StatsServiceFilter
    /// 只看 Gemini 时 daily 是回答次数(不是 token),标题和数字单位跟着换。
    var answers = false

    private enum Mode: String, Hashable {
        case daily
        case weekly
        case cumulative
    }

    /// 关窗再开时恢复(见 StatsSelections)。
    @State private var mode = Mode(rawValue: StatsSelections.current.activityMode) ?? .daily
    @State private var hover: (column: Int, row: Int)?

    private static let weeks = 53
    private static let spacing: CGFloat = 3
    private static let maxCell: CGFloat = 14

    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        cal.firstWeekday = 2
        return cal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryRow
            HStack {
                Text(answers ? tr("Answer activity", "回答活动") : tr("Token activity", "Token 活动"))
                    .scaledFont(size: 13, weight: .semibold)
                Spacer()
                HStack(spacing: 14) {
                    modeButton(.daily, tr("Daily", "每天"))
                    modeButton(.weekly, tr("Weekly", "每周"))
                    modeButton(.cumulative, tr("Cumulative", "累计总量"))
                }
            }
            grid
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
        // 切换服务筛选时格子颜色渐变、汇总数字滚动(面板尺寸不变，只做局部动画)。
        .animation(.easeInOut(duration: 0.35), value: daily)
        .animation(.easeInOut(duration: 0.35), value: filter)
    }

    private func modeButton(_ value: Mode, _ title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { mode = value }
            StatsSelections.current.activityMode = value.rawValue
            hover = nil
        } label: {
            Text(title)
                .scaledFont(size: 12.5, weight: mode == value ? .semibold : .regular)
                .foregroundStyle(mode == value ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: Summary

    private var summaryRow: some View {
        let streaks = streaks
        return HStack(spacing: 0) {
            summaryCell(amount(daily.values.reduce(0, +)), answers ? tr("Total answers", "累计回答次数") : tr("Total tokens", "累计 Token 数"))
            Divider().frame(height: 34)
            summaryCell(amount(daily.values.max() ?? 0), answers ? tr("Peak day", "单日最多回答") : tr("Peak day", "Token 使用峰值"))
            Divider().frame(height: 34)
            summaryCell(tr("\(streaks.longest) days", "\(streaks.longest) 天"), tr("Longest streak", "最长连续天数"))
            Divider().frame(height: 34)
            summaryCell(tr("\(streaks.current) days", "\(streaks.current) 天"), tr("Current streak", "当前连续天数"))
        }
        .padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func summaryCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .scaledFont(size: 16, weight: .medium)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .scaledFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// 有 token 的日子算「用了」。当前连续：从今天往回数，今天还没用就从昨天开始数。
    private var streaks: (longest: Int, current: Int) {
        let cal = Self.calendar
        let used = Set(daily.filter { $0.value > 0 }.keys.map { cal.startOfDay(for: $0) })
        var longest = 0
        for day in used where !used.contains(cal.date(byAdding: .day, value: -1, to: day) ?? day) {
            var length = 1
            var next = cal.date(byAdding: .day, value: 1, to: day) ?? day
            while used.contains(next) {
                length += 1
                next = cal.date(byAdding: .day, value: 1, to: next) ?? next
            }
            longest = max(longest, length)
        }
        let today = cal.startOfDay(for: Date())
        var cursor = used.contains(today) ? today : (cal.date(byAdding: .day, value: -1, to: today) ?? today)
        var current = 0
        while used.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return (longest, current)
    }

    // MARK: Data

    private struct Model {
        let weekStarts: [Date]
        let today: Date
        /// 每列(周)的合计 / 截至该列的累计。
        let weekTotals: [Int]
        let cumulative: [Int]
        let thresholds: [Int]
    }

    private var model: Model {
        let cal = Self.calendar
        let today = cal.startOfDay(for: Date())
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today)
        let thisWeek = cal.date(from: comps) ?? today
        let starts = (0..<Self.weeks).reversed().compactMap { cal.date(byAdding: .weekOfYear, value: -$0, to: thisWeek) }
        let totals = starts.map { start in
            (0..<7).reduce(0) { sum, offset in
                sum + (cal.date(byAdding: .day, value: offset, to: start).flatMap { daily[$0] } ?? 0)
            }
        }
        var running = daily.filter { $0.key < (starts.first ?? today) }.values.reduce(0, +)
        let cumulative = totals.map { total -> Int in
            running += total
            return running
        }
        let thresholds = TokenHeat.thresholds(daily: daily, since: starts.first ?? today)
        return Model(weekStarts: starts, today: today, weekTotals: totals, cumulative: cumulative, thresholds: thresholds)
    }

    // MARK: Grid

    private var grid: some View {
        let model = model
        let palette = palette
        return GeometryReader { proxy in
            let cell = max(6, min(Self.maxCell, (proxy.size.width - CGFloat(Self.weeks - 1) * Self.spacing) / CGFloat(Self.weeks)))
            let pitch = cell + Self.spacing
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(Array(model.weekStarts.enumerated()), id: \.offset) { column, _ in
                        VStack(spacing: Self.spacing) {
                            ForEach(0..<7, id: \.self) { row in
                                RoundedRectangle(cornerRadius: cell * 0.24, style: .continuous)
                                    .fill(fill(column: column, row: row, model: model, palette: palette))
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let column = Int(point.x / pitch)
                        let row = Int(point.y / pitch)
                        if (0..<Self.weeks).contains(column), (0..<7).contains(row) {
                            hover = (column, row)
                        } else {
                            hover = nil
                        }
                    case .ended:
                        hover = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    let anchorRow = mode == .daily ? (hover?.row ?? 0) : 0
                    if let hover, let text = tooltip(column: hover.column, row: hover.row, model: model) {
                        TooltipBubble(lines: text)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                let center = CGFloat(hover.column) * pitch + cell / 2
                                let left = min(max(0, center - d.width / 2), proxy.size.width - d.width)
                                return -left
                            }
                            .alignmentGuide(.top) { d in
                                d.height + 6 - CGFloat(anchorRow) * pitch
                            }
                            .allowsHitTesting(false)
                    }
                }

                monthLabels(starts: model.weekStarts, pitch: pitch)
            }
        }
        .frame(height: 7 * Self.maxCell + 6 * Self.spacing + 26)
        .padding(.top, 4)
    }

    private func monthLabels(starts: [Date], pitch: CGFloat) -> some View {
        let columns = Self.monthLabelColumns(starts: starts, calendar: Self.calendar)
        return ZStack(alignment: .topLeading) {
            ForEach(columns, id: \.self) { index in
                let start = starts[index]
                Text(tr(start.formatted(.dateTime.month(.abbreviated)), "\(Self.calendar.component(.month, from: start))月"))
                    .scaledFont(size: 11)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(index) * pitch)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 标月份的列：每月 1 号所在的那一周(列的周一已进入新月份，或第一列的那一周包含 1 号)。
    /// 53 周比一年多一点，最左边常是去年同月只剩几天的残段——它不标，免得挤在下个月旁边;
    /// 若最左边标出的月份和最右边的相同(去年同月几乎完整时)，也只留右边今年的。最后两列放不下文字，不标。
    static func monthLabelColumns(starts: [Date], calendar cal: Calendar) -> [Int] {
        var columns: [Int] = []
        for (index, start) in starts.enumerated() where index < starts.count - 2 {
            let month = cal.component(.month, from: start)
            if index == 0 {
                if cal.component(.day, from: start) <= 7 { columns.append(index) }
            } else if month != cal.component(.month, from: starts[index - 1]) {
                columns.append(index)
            }
        }
        if columns.count > 1, let first = columns.first, let last = columns.last,
           cal.component(.month, from: starts[first]) == cal.component(.month, from: starts[last]) {
            columns.removeFirst()
        }
        return columns
    }

    // MARK: Colors

    private static let empty = Color.primary.opacity(0.06)
    /// 「全部」用火苗同色系的暖色四档(和概览「今天」旁的火苗一一对应)。
    private static let warm: [Color] = [
        Color(red: 1.00, green: 0.85, blue: 0.63),   // #FFD9A1 1 档
        Color(red: 1.00, green: 0.66, blue: 0.30),   // #FFA94D 2 档
        Color(red: 1.00, green: 0.42, blue: 0.07),   // #FF6A13 3 档
        Color(red: 0.89, green: 0.20, blue: 0.11)    // #E3341C 4 档
    ]

    private struct Palette {
        /// 每天模式 1~4 档。
        let levels: [Color]
        /// 每周 / 累计模式的柱，悬停列用 barHover。
        let bar: Color
        let barHover: Color
    }

    /// 全部：火苗同色系暖色四档(浅琥珀 → 橙 → 深橙 → 红);单个服务：识别色按 22% / 45% / 72% / 100% 不透明度分 4 档，
    /// Codex 石墨灰、Claude 桃橙、Grok 黑(深色模式近白)。
    private var palette: Palette {
        guard let tint = filter.tint else {
            return Palette(levels: Self.warm, bar: Self.warm[2], barHover: Self.warm[3])
        }
        return Palette(levels: [tint.opacity(0.22), tint.opacity(0.45), tint.opacity(0.72), tint],
                       bar: tint.opacity(0.72), barHover: tint)
    }

    private func fill(column: Int, row: Int, model: Model, palette: Palette) -> Color {
        let cal = Self.calendar
        switch mode {
        case .daily:
            guard let day = cal.date(byAdding: .day, value: row, to: model.weekStarts[column]) else { return Self.empty }
            if day > model.today { return .clear }
            let level = level(daily[day] ?? 0, thresholds: model.thresholds)
            return level == 0 ? Self.empty : palette.levels[level - 1]
        case .weekly, .cumulative:
            let values = mode == .weekly ? model.weekTotals : model.cumulative
            let maxValue = max(values.max() ?? 0, 1)
            let value = values[column]
            let filled = value > 0 ? max(1, Int((Double(value) / Double(maxValue) * 7).rounded())) : 0
            guard row >= 7 - filled else { return Self.empty }
            return hover?.column == column ? palette.barHover : palette.bar
        }
    }

    private func level(_ value: Int, thresholds: [Int]) -> Int {
        TokenHeat.level(value, thresholds: thresholds)
    }

    // MARK: Tooltip

    private func tooltip(column: Int, row: Int, model: Model) -> [String]? {
        let cal = Self.calendar
        let start = model.weekStarts[column]
        switch mode {
        case .daily:
            guard let day = cal.date(byAdding: .day, value: row, to: start), day <= model.today else { return nil }
            let date = tr(day.formatted(.dateTime.month(.abbreviated).day()), "\(cal.component(.month, from: day))月\(cal.component(.day, from: day))日")
            return [date, tokens(daily[day] ?? 0)]
        case .weekly:
            return [tr("Week of \(longDate(start))", "\(longDate(start)) 起的一周"), tokens(model.weekTotals[column])]
        case .cumulative:
            return [tr("Total through week of \(longDate(start))", "累计至 \(longDate(start)) 起的一周"), tokens(model.cumulative[column])]
        }
    }

    private func longDate(_ date: Date) -> String {
        let cal = Self.calendar
        return tr(date.formatted(.dateTime.year().month(.abbreviated).day()),
                  "\(cal.component(.year, from: date))年\(cal.component(.month, from: date))月\(cal.component(.day, from: date))日")
    }

    /// 汇总里的数字：token 用紧凑写法，回答次数直接写次数。
    private func amount(_ value: Int) -> String {
        answers ? tr("\(value)", "\(value) 次") : StatsFormatter.compactToken(value)
    }

    private func tokens(_ value: Int) -> String {
        if answers { return tr("\(value) answers", "\(value) 次回答") }
        let compact = StatsFormatter.compactToken(value).replacingOccurrences(of: " ", with: "")
        return tr("\(compact) tokens", "\(compact) 个 Token")
    }
}

/// 深色圆角浮层(热力图悬停用)。
private struct TooltipBubble: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .scaledFont(size: 11.5, weight: .medium)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.88)))
    }
}

// MARK: - KPI card

private struct KPISegment: Identifiable {
    let id: String
    let color: Color
    let value: Double
}

private struct KPICard: View {
    let title: String
    let value: String
    let detail: String?
    let segments: [KPISegment]
    /// 单日视图下对比基准的值(和 segments 同一量纲),在细条上画竖线。
    var baselineLine: Double? = nil
    /// 标题行右侧的小按钮(Tokens 卡的合并 / 拆分)。
    var accessory: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 小按钮放在 overlay 里，不撑高标题行，三张卡的数字保持对齐。
            Text(title)
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.trailing, accessory == nil ? 0 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if let accessory { accessory }
                }
            // 数值单行 + 按宽度缩放,窄窗口下不折行;合并 / 拆分时数字滚动过渡。
            Text(value)
                .scaledFont(size: 22, weight: .semibold)
                .kerning(-0.5)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(detail ?? " ")
                .scaledFont(size: 11)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            segmentBar
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ccPanel(cornerRadius: 10)
    }

    /// 按服务拆分的细条。有对比基准时：细条按「当前 / max(当前, 基准)」缩放，竖线标出基准。
    @ViewBuilder
    private var segmentBar: some View {
        let total = segments.map(\.value).reduce(0, +)
        let line = baselineLine ?? 0
        if total > 0 || line > 0 {
            GeometryReader { proxy in
                let width = proxy.size.width
                let scale = max(total, line, 0.0001)
                let filled = baselineLine == nil ? width : width * total / scale
                let visible = segments.filter { $0.value > 0 }
                let gaps = CGFloat(max(visible.count - 1, 0)) * 2
                ZStack(alignment: .leading) {
                    if baselineLine != nil {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 4)
                    }
                    HStack(spacing: 2) {
                        ForEach(visible) { segment in
                            Capsule()
                                .fill(segment.color)
                                .frame(width: max(2, (filled - gaps) * segment.value / max(total, 0.0001)), height: 4)
                        }
                    }
                    if line > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5, height: 12)
                            .offset(x: min(width - 1.5, width * line / scale))
                    }
                }
                .frame(height: 12)
            }
            .frame(height: 12)
        } else {
            Color.clear.frame(height: 12)
        }
    }
}

// MARK: - Quota tile

/// 「当前额度」的一格：左侧服务图标，右侧 5H / WK 行(Grok / Grok Bot 只有一行),下方可有一行小注。
private struct QuotaTile: View {
    let app: UsageApp
    let lanes: [(label: String, window: QuotaWindow?)]
    let note: String?
    /// 额度还没接通(Gemini app):不画额度行。
    var unavailable = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ServiceLogo(app: app, size: 20)
                .padding(.top, 4)
                .help(app.displayName)
            VStack(alignment: .leading, spacing: 0) {
                if !unavailable {
                    ForEach(lanes, id: \.label) { lane in
                        LimitBarRow(label: lane.label, window: lane.window, tint: app.accent,
                                    labelWidth: lanes.count > 2 ? 100 : 40)
                    }
                }
                if let note {
                    Text(note)
                        .scaledFont(size: 10.5)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.top, unavailable ? 6 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Limit bar row

/// 条用服务识别色;剩余 ≤50% 时百分比文字转为状态色(黄 / 橙 / 红),保留预警。
/// 一行额度：标签 / 进度条 / 剩余百分比 / 重置倒计时。统计页「当前额度」和菜单栏浮窗共用。
struct LimitBarRow: View {
    let label: String
    let window: QuotaWindow?
    let tint: Color
    var labelWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .scaledFont(size: 12)
                .frame(width: labelWidth, alignment: .leading)
            ProgressBar(value: (window?.remainingPercent ?? 0) / 100, tint: window == nil ? .secondary : tint, height: 6)
            Text(percentText)
                .scaledFont(size: 11.5, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(percentColor)
                .frame(width: 36, alignment: .trailing)
            ResetTimeText(resetsAt: window?.resetsAt)
                .scaledFont(size: 10.5)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private var percentColor: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        return remaining > 50 ? .primary : statusColor(remainingPercent: remaining, tint: tint)
    }

    private var percentText: String {
        guard let window else { return "--" }
        return "\(Int(window.remainingPercent.rounded()))%"
    }
}

// MARK: - Quota timeline
//
// 额度变化页：所有账号的今日 5H 剩余额度画在一张图里(阶梯线：两次采样之间额度不变),
// 悬停显示该时刻各账号的剩余;下方账号列表可逐个开关曲线，「详情」展开该账号的变动记录。

private struct QuotaTimelineOverview: View {
    @Environment(\.textScale) private var textScale
    /// 显示曲线 / 展开详情 / 5H·WK 切换的动画(与概览的切换动画一致)。
    static let animation = Animation.spring(response: 0.45, dampingFraction: 0.86)

    let sections: [QuotaTimelineSection]
    @Binding var hidden: Set<String>
    @Binding var expanded: Set<String>
    @State private var selectedTime: Date?
    /// 账号列表收起(记住状态)。
    @AppStorage("yybar.settings.quotaTimelineAccountsCollapsed") private var accountsCollapsed = false

    private struct Point: Identifiable {
        var id: String { "\(accountKey)-\(time.timeIntervalSince1970)" }
        let accountKey: String
        let time: Date
        let value: Int
        let isSample: Bool
    }

    /// 同一服务的第一个账号用服务识别色，其余账号依次取调色板，保证多条线能区分。
    private var colors: [String: Color] {
        let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .mint, .brown]
        var result: [String: Color] = [:]
        var usedTints: [String] = []
        var paletteIndex = 0
        for section in sections {
            let tintKey = section.title.components(separatedBy: " ").first ?? section.title
            if !usedTints.contains(tintKey) {
                usedTints.append(tintKey)
                result[section.accountKey] = section.tint
            } else {
                result[section.accountKey] = palette[paletteIndex % palette.count]
                paletteIndex += 1
            }
        }
        return result
    }

    private var visibleSections: [QuotaTimelineSection] {
        sections.filter { !hidden.contains($0.accountKey) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartPanel
            accountsPanel
        }
    }

    // MARK: Chart

    private var chartPanel: some View {
        let colors = colors
        let series = visibleSections.map { ($0, points(for: $0)) }
        let hasData = series.contains { !$0.1.isEmpty }

        return VStack(alignment: .leading, spacing: 10) {
            if !hasData {
                Text(visibleSections.isEmpty
                     ? tr("Turn on an account below to show its line.", "在下方打开账号即可显示曲线。")
                     : tr("No quota data yet", "还没有额度数据"))
                    .scaledFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
            } else {
                Chart {
                    ForEach(series, id: \.0.accountKey) { section, points in
                        ForEach(points) { point in
                            LineMark(
                                x: .value("Time", point.time),
                                y: .value("Remaining", point.value),
                                series: .value("Account", section.accountKey)
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(colors[section.accountKey] ?? section.tint)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

                            if point.isSample {
                                PointMark(x: .value("Time", point.time), y: .value("Remaining", point.value))
                                    .foregroundStyle(colors[section.accountKey] ?? section.tint)
                                    .symbolSize(18)
                            }
                        }
                    }

                    if let selectedTime {
                        RuleMark(x: .value("Selected", selectedTime))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(
                                position: .top,
                                spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                tooltip(at: selectedTime, colors: colors)
                            }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXSelection(value: $selectedTime)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel(format: .dateTime.hour().minute())
                            .font(.system(size: 10 * textScale))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)%")
                                    .scaledFont(size: 10)
                                    .foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
                .frame(height: 260)
                .padding(.top, 34)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }

    /// 曲线点：从今天开始记录的时刻起(值为第一次变动前的剩余;没有变动则为当前剩余),
    /// 接着是每次变动后的剩余，最后补一个「现在」的点，让线延伸到当前时刻。
    /// 只记录变化点，所以两次变动之间额度不变，阶梯线如实反映这一点;记录开始前不画。
    private func points(for section: QuotaTimelineSection) -> [Point] {
        let start = section.recordingStartedAt ?? Calendar.current.startOfDay(for: Date())
        guard let startValue = section.events.first?.beforeRemainingPercent ?? section.currentRemaining else { return [] }
        var result = [Point(accountKey: section.accountKey, time: start, value: startValue, isSample: false)]
        result += section.events.map {
            Point(accountKey: section.accountKey, time: $0.sampledAt, value: $0.afterRemainingPercent, isSample: true)
        }
        result.append(Point(accountKey: section.accountKey, time: Date(),
                            value: section.currentRemaining ?? result.last?.value ?? startValue, isSample: false))
        return result
    }

    /// 某时刻的剩余：该时刻之前最近一次变动后的值;早于第一次变动时为变动前的值;记录开始前没有数据。
    private func value(of section: QuotaTimelineSection, at time: Date) -> Int? {
        if let start = section.recordingStartedAt, time < start { return nil }
        if let event = section.events.last(where: { $0.sampledAt <= time }) { return event.afterRemainingPercent }
        return section.events.first?.beforeRemainingPercent ?? section.currentRemaining
    }

    private func tooltip(at time: Date, colors: [String: Color]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(StatsFormatter.time(time))
                .scaledFont(size: 11, weight: .semibold)
                .monospacedDigit()
            ForEach(visibleSections) { section in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(colors[section.accountKey] ?? section.tint)
                        .frame(width: 10, height: 3)
                    Text(section.title)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                    Text(value(of: section, at: time).map { "\($0)%" } ?? "—")
                        .monospacedDigit()
                }
                .scaledFont(size: 11)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 210)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }

    // MARK: Accounts

    private var accountsPanel: some View {
        let colors = colors
        return VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(QuotaTimelineOverview.animation) { accountsCollapsed.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(accountsCollapsed ? 0 : 90))
                        Text(tr("Accounts", "账号"))
                            .scaledFont(size: 12.5, weight: .semibold)
                        Text("\(sections.count)")
                            .scaledFont(size: 11)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(accountsCollapsed ? tr("Show accounts", "展开账号列表") : tr("Hide accounts", "收起账号列表"))
                Spacer()
                if !accountsCollapsed {
                    Text(tr("Show in chart", "显示曲线"))
                        .scaledFont(size: 10.5)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(accountsCollapsed ? [] : sections) { section in
                Divider()
                accountRow(section, color: colors[section.accountKey] ?? section.tint)
                if expanded.contains(section.accountKey) {
                    Group {
                        if section.events.isEmpty {
                            Text(tr("No changes today", "今天暂无变动"))
                                .scaledFont(size: 11.5)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            QuotaTimelineTable(events: section.events)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .ccPanel(cornerRadius: 12)
    }

    private func accountRow(_ section: QuotaTimelineSection, color: Color) -> some View {
        let isExpanded = expanded.contains(section.accountKey)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 14, height: 4)
            Text(section.title)
                .scaledFont(size: 12.5, weight: .medium)
                .lineLimit(1)
            Spacer(minLength: 12)
            metric(tr("Now", "当前"), section.currentRemaining.map { "\($0)%" } ?? "--")
            metric(tr("Today", "今日"), StatsFormatter.quotaDelta(section.totalDelta))
            metric(tr("Latest", "最近"), section.latestEventAt.map { StatsFormatter.time($0) } ?? "--")
            Button {
                withAnimation(QuotaTimelineOverview.animation) {
                    if isExpanded { expanded.remove(section.accountKey) } else { expanded.insert(section.accountKey) }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(tr("Details", "详情"))
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .scaledFont(size: 11.5)
            }
            .buttonStyle(.borderless)
            .frame(width: 56)
            Toggle("", isOn: Binding(
                get: { !hidden.contains(section.accountKey) },
                set: { show in
                    withAnimation(QuotaTimelineOverview.animation) {
                        if show { hidden.remove(section.accountKey) } else { hidden.insert(section.accountKey) }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .scaledFont(size: 9.5)
                .foregroundStyle(.tertiary)
            Text(value)
                .scaledFont(size: 11.5, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, alignment: .trailing)
    }
}

private struct QuotaTimelineTable: View {
    let events: [QuotaChangeEvent]

    private var rows: [QuotaChangeEvent] {
        events.sorted { $0.sampledAt > $1.sampledAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            ForEach(rows) { event in
                Divider()
                row(event)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.14), lineWidth: 0.5)
        )
    }

    private var headerRow: some View {
        HStack {
            tableHeader("Time", "时间", width: 82, alignment: .leading)
            tableHeader("Change", "变动值", width: 82, alignment: .trailing)
            tableHeader("After", "变动后剩余", width: 104, alignment: .trailing)
            tableHeader("Reset", "重置时间", width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06))
    }

    private func row(_ event: QuotaChangeEvent) -> some View {
        HStack {
            tableText(StatsFormatter.time(event.sampledAt), width: 82, alignment: .leading)
            tableText(StatsFormatter.quotaDelta(event.deltaPercent), width: 82, alignment: .trailing)
                .foregroundStyle(event.deltaPercent < 0 ? Color.red : Color.green)
            tableText("\(event.afterRemainingPercent)%", width: 104, alignment: .trailing)
                .foregroundStyle(statusColor(remainingPercent: Double(event.afterRemainingPercent), tint: .secondary))
            tableText(StatsFormatter.resetTime(event.resetsAt), width: 96, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func tableHeader(
        _ english: String,
        _ chinese: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(tr(english, chinese))
            .scaledFont(size: 10.5, weight: .semibold)
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .scaledFont(size: 11.5, design: .monospaced)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Daily / Model row models

/// 标题旁日均图例里的一小段水平虚线(和图里的日均线同样式)。
private struct DashedLegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 每日用量图下方 Gemini 窄道的一天。
private struct GeminiLaneDay: Identifiable {
    var id: Date { day }
    let day: Date
    let count: Int
}

private struct DailySample: Identifiable {
    var id: Date { day }
    let day: Date
    /// 按服务的当日数值(费用 USD 或 token,取决于当前 StatsMetric)。
    let values: [UsageApp: Double]

    func value(for app: UsageApp) -> Double { values[app] ?? 0 }
    var total: Double { values.values.reduce(0, +) }
}

private struct SingleDayRow: Identifiable {
    var id: UsageApp { app }
    let app: UsageApp
    let value: Double
    let average: Double
}

private struct ModelRow: Identifiable {
    let id: String
    let app: UsageApp
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let cost: Decimal
    let isPriced: Bool
    /// Gemini App 的行：回答次数(没有 token / 费用)。其他服务为 nil。
    var answers: Int? = nil

    /// 排序用:未知定价排在最后。
    var costSortValue: Double { isPriced ? NSDecimalNumber(decimal: cost).doubleValue : -1 }

    /// 全部 Token(含缓存),用于找「最热」的模型。
    var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

/// 模型明细里用量最多的模型旁的小火苗：一跳一落再左右摇一下，循环。
/// 动画交给 Core Animation(HotFlameNSView),不再用 SwiftUI 的 phaseAnimator——那样每帧都会让整个统计大页重新布局，
/// 窗口开着时持续占用约三成 CPU。
private struct HotFlame: View {
    var body: some View {
        HotFlameIcon()
            .frame(width: 12, height: 14)
    }
}

private struct QuotaTimelineSection: Identifiable {
    var id: String { accountKey }
    let accountKey: String
    let title: String
    let tint: Color
    let currentRemaining: Int?
    let totalDelta: Int
    let latestEventAt: Date?
    let events: [QuotaChangeEvent]
    /// 今天开始记录该账号的时间;nil 表示旧数据(从 0 点起就有记录)。
    var recordingStartedAt: Date? = nil
}

// MARK: - Formatter

enum StatsFormatter {
    static func cost(_ value: Decimal) -> String {
        let ns = NSDecimalNumber(decimal: value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return "$\(f.string(from: ns) ?? "0.00")"
    }

    static func token(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 紧凑显示。中文用 万 / 亿,英文用 k / M / B。
    /// zh:  6772.37 万  /  1.23 亿  /  1,234
    /// en:  67.7M  /  248.3k  /  1,234
    @MainActor
    /// 模型明细表格用：中文下不足 1 万的数也带单位(如「850 个」),和「65.3 万」「2.04 亿」一致;0 不带单位。
    static func tableToken(_ value: Int) -> String {
        if L10n.current == .zh, value > 0, value < 10_000 {
            return "\(compactToken(value)) 个"
        }
        return compactToken(value)
    }

    static func compactToken(_ value: Int) -> String {
        let v = Double(value)
        switch L10n.current {
        case .zh:
            if v >= 100_000_000 {
                return "\(trimTrailingZeros(v / 100_000_000)) 亿"
            }
            if v >= 10_000 {
                return "\(trimTrailingZeros(v / 10_000)) 万"
            }
            return token(value)
        case .en:
            if v >= 1_000_000_000 {
                return String(format: "%.2fB", v / 1_000_000_000)
            }
            if v >= 1_000_000 {
                return String(format: "%.2fM", v / 1_000_000)
            }
            if v >= 1_000 {
                return String(format: "%.1fk", v / 1_000)
            }
            return "\(value)"
        }
    }

    /// 保留两位小数,去掉末尾多余的 0(如 6772.30 → 6772.3,1234.00 → 1234)。
    private static func trimTrailingZeros(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        var trimmed = s
        if trimmed.contains(".") {
            while trimmed.hasSuffix("0") { trimmed.removeLast() }
            if trimmed.hasSuffix(".") { trimmed.removeLast() }
        }
        return trimmed
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func day(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func resetTime(_ date: Date?) -> String {
        guard let date else { return "--" }
        return time(date)
    }

    static func quotaDelta(_ value: Int) -> String {
        if value > 0 { return "+\(value)%" }
        return "\(value)%"
    }
}

// MARK: - Decimal helper

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}
