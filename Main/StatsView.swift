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
        case .yesterday: return "昨天"
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

    /// 单个服务的筛选对应的服务;「全部」为 nil。
    var app: UsageApp? {
        switch self {
        case .all: return nil
        case .codex: return .codex
        case .claude: return .claude
        case .grok: return .grok
        case .grokBot: return .grokBot
        case .gemini: return .gemini
        case .agy: return .agy
        }
    }

    var englishLabel: String {
        app?.displayName ?? "All"
    }

    var chineseLabel: String {
        switch self {
        case .all: return "全部"
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        case .grok: return "xAI"
        case .grokBot: return "Cursor"
        case .gemini, .agy: return "Google"
        }
    }

    /// 工具栏筛选按钮上的文字。
    var chipLabel: String {
        guard let app else { return tr("All", "全部") }
        return app == .claude ? "Claude" : app.displayName
    }

    var tint: Color? {
        app?.accent
    }
}

/// 每日图表 / 当日对比 用的度量。
enum StatsMetric: Hashable {
    case cost
    case tokens
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
    @State private var customFrom = StatsSelections.current.customFrom
    @State private var customTo = StatsSelections.current.customTo

    private var selections: StatsSelections {
        StatsSelections(range: range, serviceFilter: serviceFilter, metric: metric, baseline: baseline,
                        mergeTokens: mergeTokens, splitGrokPair: splitGrokPair, splitGooglePair: splitGooglePair,
                        hiddenTimelineAccounts: hiddenTimelineAccounts,
                        expandedTimelineAccounts: expandedTimelineAccounts, timelineWindow: timelineWindow,
                        modelSortKey: modelSortKey, modelSortAscending: modelSortAscending,
                        customFrom: customFrom, customTo: customTo,
                        activityMode: StatsSelections.current.activityMode)
    }

    /// 费用 / Tokens、对比基准、合并 Tokens 共用的切换动画。
    private static let switchAnimation = Animation.spring(response: 0.45, dampingFraction: 0.86)

    /// 工具栏上提供的时间范围。其余 StatsRange case 保留但不再展示。
    private static let toolbarRanges: [StatsRange] = [.today, .last7, .last30, .thisMonth, .all, .custom]

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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: tr("Token activity", "Token 活动"),
                           subtitle: tr("All tokens including cache, over the last year. Uses the service filter above.",
                                        "最近一年的全部 Token(含缓存),跟随上方服务筛选。"))
            TokenActivityPanel(daily: activityDaily, filter: serviceFilter)
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
            // Grok Bot / Gemini / Antigravity 的按钮只在设置里启用时出现。
            ForEach(StatsServiceFilter.allCases.filter { $0.app.map { [.codex, .claude, .grok].contains($0) || SettingsStore.shared.isEnabled($0) } ?? true },
                    id: \.self) { item in
                serviceChip(item)
            }
        }
        .fixedSize()
        // 选中背景 / 描边总是平滑切换(只作用于按钮本身，不影响页面内容)。
        .animation(.easeOut(duration: 0.2), value: serviceFilter)
    }

    /// 时间范围 / 服务筛选 / 自定义日期：会改变各部分高度。
    /// 正在看概览(页面最上面)时用弹簧动画;看下面的部分时瞬时切换，由 anchorKeeper 精确补回滚动位置。
    private func applyFilterChange(_ change: () -> Void) {
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
                    .font(.system(size: 11.5))
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
            // 这三个没有接官方状态源，显示灰点。
            case .grokBot, .gemini, .agy: return nil
            }
        }()
        Circle()
            .fill(status.map { $0.indicator == .unknown ? Color.secondary.opacity(0.4) : $0.indicator.dotColor }
                  ?? Color.secondary.opacity(0.4))
            .frame(width: 7, height: 7)
            .help(status.map { $0.description ?? $0.indicator.label } ?? tr("Status unavailable", "暂无状态"))
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
        .font(.system(size: 12))
        .fixedSize()
    }

    // MARK: KPI row

    private var kpiRow: some View {
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
                .font(.system(size: 11, weight: .medium))
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

        return Panel(title: "Daily usage", chinese: "每日用量", right: AnyView(
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(visibleApps, id: \.self) { app in
                        HStack(spacing: 5) {
                            ServiceLogo(app: app, size: 11)
                            Text(app.statsShortTitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                metricPicker
            }
        )) {
            if samples.allSatisfy({ $0.total == 0 }) {
                placeholderHeight(104, message: tr("No usage in this range", "这段时间没有用量"))
            } else {
                Chart {
                    ForEach(samples) { sample in
                        ForEach(visibleApps, id: \.self) { app in
                            BarMark(
                                x: .value("Day", sample.day, unit: .day),
                                y: .value("Value", sample.value(for: app)),
                                width: barWidth(dayCount: samples.count),
                                stacking: .standard
                            )
                            .foregroundStyle(app.statsTint)
                            .cornerRadius(2)
                            .opacity(selectedSample == nil || selectedSample?.day == sample.day ? 1 : 0.45)
                        }
                    }

                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("\(tr("avg", "日均")) \(formatMetric(average))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

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
                    AxisMarks(values: .stride(by: .day, count: max(1, samples.count / 6))) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatMetricAxis(v))
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                // 与「今天」面板同高。
                .frame(height: 104)
            }
        }
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
                .font(.system(size: 11, weight: .semibold))
            ForEach(visibleApps, id: \.self) { app in
                HStack(spacing: 5) {
                    ServiceLogo(app: app, size: 10)
                    Text(app.statsShortTitle)
                    Spacer(minLength: 10)
                    Text(formatMetric(sample.value(for: app)))
                        .monospacedDigit()
                }
                .font(.system(size: 11))
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
        // 合并行按两者之和计，比例尺取各行(合并后)的最大值。
        let maxValue = max(groups.map { group in
            max(group.compactMap { rows[$0]?.value }.reduce(0, +), group.compactMap { rows[$0]?.average }.reduce(0, +))
        }.max() ?? 0, 0.0001)
        let todayTotal = rows.values.map(\.value).reduce(0, +)
        let averageTotal = rows.values.map(\.average).reduce(0, +)
        let isToday = range == .today

        return Panel(
            title: isToday ? "Today" : "This day",
            chinese: isToday ? "今天" : "当天",
            right: AnyView(HStack(spacing: 10) {
                baselinePicker
                metricPicker
            }),
            titleAccessory: isToday ? AnyView(todayFlame) : nil
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groups, id: \.self) { group in
                    let groupRows = group.compactMap { rows[$0] }
                    if group.count == 2, isPairSplit(group[0]) {
                        // 拆开：同一行变成并列两条，各占半宽，各有自己的基准竖线和数值(比例尺取这两条自己的最大值)。
                        let pairMax = max(groupRows.map { max($0.value, $0.average) }.max() ?? 0, 0.0001)
                        HStack(spacing: 24) {
                            ForEach(Array(groupRows.enumerated()), id: \.element.id) { index, row in
                                HStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        ServiceLogo(app: row.app, size: 14)
                                        Text(row.app.statsShortTitle)
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                        if index == 0 { pairButton(group) }
                                    }
                                    .fixedSize()
                                    singleDayBar(value: row.value, average: row.average, maxValue: pairMax, tint: row.app.statsTint)
                                    singleDayValue(value: row.value, average: row.average)
                                        .fixedSize()
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .transition(Self.pairTransition)
                    } else {
                        let value = groupRows.map(\.value).reduce(0, +)
                        let average = groupRows.map(\.average).reduce(0, +)
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                HStack(spacing: -4) {
                                    ForEach(group, id: \.self) { ServiceLogo(app: $0, size: 14) }
                                }
                                Text(group.count == 2 ? group.map(\.statsShortTitle).joined(separator: " · ") : group[0].statsTitle)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                if group.count == 2 { pairButton(group) }
                            }
                            .frame(width: 196, alignment: .leading)

                            // 合并时一整条(两者相加，单色)。
                            singleDayBar(value: value, average: average, maxValue: maxValue, tint: group[0].statsTint)

                            singleDayValue(value: value, average: average)
                                .frame(width: 150, alignment: .trailing)
                        }
                        .transition(Self.pairTransition)
                    }
                }

                Text(singleDayFootnote(total: todayTotal, average: averageTotal, isToday: isToday))
                    .font(.system(size: 11))
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
                .font(.system(size: 11, weight: .medium))
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

    private func singleDayValue(value: Double, average: Double) -> some View {
        Text("\(formatMetric(value)) / \(tr("avg", "均")) \(formatMetric(average))")
            .font(.system(size: 11))
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
            : tr(" That day: \(pct)% of it.", " 当天为它的 \(pct)%。")
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
            guard let first = index.firstDay(for: set, before: day) else { return 0 }
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

    private func metricValue(app: UsageApp, from: Date, to: Date) -> Double {
        switch metric {
        case .cost:
            return knownCost(for: [app], in: (from, to)).value.doubleValue
        case .tokens:
            return Double(tokenCount(totals(for: [app], in: (from, to))))
        }
    }

    private func formatMetric(_ value: Double) -> String {
        switch metric {
        case .cost: return StatsFormatter.cost(Decimal(value))
        case .tokens: return StatsFormatter.compactToken(Int(value.rounded()))
        }
    }

    private func formatMetricAxis(_ value: Double) -> String {
        switch metric {
        case .cost: return "$\(Int(value.rounded()))"
        case .tokens: return StatsFormatter.compactToken(Int(value.rounded()))
        }
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
                              unavailable: app == .grokBot && !GrokBotQuotaClient.isConnected)
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
        return [("5H", snapshot?.fiveHour), ("WK", snapshot?.weekly)]
    }

    private func quotaNote(for app: UsageApp) -> String? {
        switch app {
        case .codex, .claude: return nil
        case .grok: return appState.grokPlan
        case .grokBot:
            return GrokBotQuotaClient.isConnected ? appState.grokBotQuota?.planType
                : tr("Not connected yet (Grok Bot app sign-in)", "未接通(需读取 Grok Bot app 的登录)")
        case .gemini: return tr("Pro and Flash share this quota", "Pro 和 Flash 共用")
        case .agy: return tr("Claude and GPT models share this quota", "Claude · GPT 模型共用")
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
        let hottest = rows.count > 1 ? rows.max { $0.totalTokens < $1.totalTokens }?.id : nil
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

    private func modelRow(_ row: ModelRow, isHottest: Bool) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                ServiceLogo(app: row.app, size: 13)
                Text(row.model)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isHottest {
                    HotFlame()
                        .padding(.leading, -2)
                        .help(tr("Most tokens in this range", "这段时间用量最多"))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .font(.system(size: 12))
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
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.system(size: 11, weight: modelSortKey == key ? .semibold : .regular))
            .foregroundStyle(modelSortKey == key ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private var sortedModelRows: [ModelRow] {
        func less(_ a: ModelRow, _ b: ModelRow) -> Bool {
            switch modelSortKey {
            case .model: return a.model.localizedStandardCompare(b.model) == .orderedAscending
            case .input: return a.inputTokens < b.inputTokens
            case .output: return a.outputTokens < b.outputTokens
            case .cacheRead: return a.cacheReadTokens < b.cacheReadTokens
            case .cacheWrite: return a.cacheCreationTokens < b.cacheCreationTokens
            case .cost: return a.costSortValue < b.costSortValue
            }
        }
        return modelRows.sorted { modelSortAscending ? less($0, $1) : less($1, $0) }
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
        return byKey.map { key, entry in
            ModelRow(
                id: key,
                app: entry.app,
                model: entry.model,
                inputTokens: entry.totals.inputTokens,
                outputTokens: entry.totals.outputTokens,
                cacheReadTokens: entry.totals.cacheReadTokens,
                cacheCreationTokens: entry.totals.cacheCreationTokens,
                cost: entry.totals.costUSD,
                isPriced: entry.app == .grok || entry.totals.costUSD > 0 || Pricing.hasPrice(model: entry.model)
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
                    .font(.system(size: 18, weight: .semibold))
                // 只在今天中途才开始记录时提示一句(说明曲线为什么不是从 0 点开始)。
                if let note = timelineRecordingNote {
                    Text(note)
                        .font(.system(size: 11.5))
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
                .font(.system(size: 11, design: .monospaced))
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
            provider: "Claude Code", plan: appState.claudeAccount?.subscriptionType, email: appState.claudeAccount?.email,
            index: nil, tint: .claudeAccent, snapshot: appState.claudeQuota, accountExists: appState.claudeAccount != nil)
        for (idx, account) in appState.extraAccounts(for: .claude).enumerated() {
            add(base: QuotaHistoryAccountKey.extra(id: account.id),
                provider: "Claude Code", plan: account.plan, email: account.email, index: idx + 1,
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
        for b in filteredBuckets {
            let value: Double
            switch metric {
            case .cost:
                guard b.app == .grok || b.costUSD > 0 || Pricing.hasPrice(model: b.model) else { continue }
                value = b.costUSD.doubleValue
            case .tokens:
                value = Double(b.inputTokens + b.outputTokens + b.cacheCreationTokens + (mergeTokens ? b.cacheReadTokens : 0))
            }
            byDay[b.day, default: [:]][b.app, default: 0] += value
        }

        let (rangeFrom, rangeTo) = rangeBounds
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
            .font(.system(size: 12))
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
            if b.app == .grok || b.costUSD > 0 || Pricing.hasPrice(model: b.model) {
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
                        .font(.system(size: 12.5, weight: .semibold))
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
                Text(tr("Token activity", "Token 活动"))
                    .font(.system(size: 13, weight: .semibold))
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
                .font(.system(size: 12.5, weight: mode == value ? .semibold : .regular))
                .foregroundStyle(mode == value ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: Summary

    private var summaryRow: some View {
        let streaks = streaks
        return HStack(spacing: 0) {
            summaryCell(StatsFormatter.compactToken(daily.values.reduce(0, +)), tr("Total tokens", "累计 Token 数"))
            Divider().frame(height: 34)
            summaryCell(StatsFormatter.compactToken(daily.values.max() ?? 0), tr("Peak day", "Token 使用峰值"))
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
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 11.5))
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
        let cal = Self.calendar
        return ZStack(alignment: .topLeading) {
            ForEach(Array(starts.enumerated()), id: \.offset) { index, start in
                let month = cal.component(.month, from: start)
                let previous = index > 0 ? cal.component(.month, from: starts[index - 1]) : -1
                if month != previous && index < starts.count - 2 {
                    Text(tr(start.formatted(.dateTime.month(.abbreviated)), "\(month)月"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(index) * pitch)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func tokens(_ value: Int) -> String {
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
                    .font(.system(size: 11.5, weight: .medium))
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.trailing, accessory == nil ? 0 : 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if let accessory { accessory }
                }
            // 数值单行 + 按宽度缩放,窄窗口下不折行;合并 / 拆分时数字滚动过渡。
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .kerning(-0.5)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(detail ?? " ")
                .font(.system(size: 11))
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
    /// 额度还没接通(Grok Bot):不画额度行。
    var unavailable = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ServiceLogo(app: app, size: 20)
                .padding(.top, 4)
                .help(app.displayName)
            VStack(alignment: .leading, spacing: 0) {
                if !unavailable {
                    ForEach(lanes, id: \.label) { lane in
                        LimitBarRow(label: lane.label, window: lane.window, tint: app.accent, labelWidth: 40)
                    }
                }
                if let note {
                    Text(note)
                        .font(.system(size: 10.5))
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
private struct LimitBarRow: View {
    let label: String
    let window: QuotaWindow?
    let tint: Color
    var labelWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: labelWidth, alignment: .leading)
            ProgressBar(value: (window?.remainingPercent ?? 0) / 100, tint: window == nil ? .secondary : tint, height: 6)
            Text(percentText)
                .font(.system(size: 11.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(percentColor)
                .frame(width: 36, alignment: .trailing)
            ResetTimeText(resetsAt: window?.resetsAt)
                .font(.system(size: 10.5))
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
    /// 显示曲线 / 展开详情 / 5H·WK 切换的动画(与概览的切换动画一致)。
    static let animation = Animation.spring(response: 0.45, dampingFraction: 0.86)

    let sections: [QuotaTimelineSection]
    @Binding var hidden: Set<String>
    @Binding var expanded: Set<String>
    @State private var selectedTime: Date?

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
                    .font(.system(size: 12))
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
                            .font(.system(size: 10))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 20, 50, 80, 100]) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)%")
                                    .font(.system(size: 10))
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
                .font(.system(size: 11, weight: .semibold))
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
                .font(.system(size: 11))
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
                Text(tr("Accounts", "账号"))
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(tr("Show in chart", "显示曲线"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(sections) { section in
                Divider()
                accountRow(section, color: colors[section.accountKey] ?? section.tint)
                if expanded.contains(section.accountKey) {
                    Group {
                        if section.events.isEmpty {
                            Text(tr("No changes today", "今天暂无变动"))
                                .font(.system(size: 11.5))
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
                .font(.system(size: 12.5, weight: .medium))
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
                .font(.system(size: 11.5))
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
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
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
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: alignment)
    }

    private func tableText(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: alignment)
    }
}

// MARK: - Daily / Model row models

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
