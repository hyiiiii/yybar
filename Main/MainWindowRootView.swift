import SwiftUI

/// 主窗口页面。统计与设置共用一个侧边栏(见 docs/界面布局.md §3)。
enum MainTab: Hashable, CaseIterable {
    // 统计
    case overview
    case activity
    case quota
    case models
    // 设置
    case services
    case display
    case refresh
    case general

    /// 兼容旧调用:`.stats` 打开统计概览,`.settings` 打开设置首页。
    static var stats: MainTab { .overview }
    static var settings: MainTab { .services }

    var isStats: Bool {
        switch self {
        case .overview, .activity, .quota, .models: return true
        case .services, .display, .refresh, .general: return false
        }
    }

    var title: String {
        switch self {
        case .overview: return tr("Overview", "概览")
        case .activity: return tr("Token activity", "Token 活动")
        case .quota: return tr("Quota changes", "额度变化")
        case .models: return tr("Models", "模型明细")
        case .services: return tr("Services", "服务")
        case .display: return tr("Display", "显示")
        case .refresh: return tr("Refresh", "刷新")
        case .general: return tr("General", "通用")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "chart.pie"
        case .activity: return "square.grid.3x3"
        case .quota: return "chart.line.uptrend.xyaxis"
        case .models: return "cpu"
        case .services: return "powerplug"
        case .display: return "menubar.rectangle"
        case .refresh: return "arrow.clockwise"
        case .general: return "gearshape"
        }
    }

    static let statsPages: [MainTab] = [.overview, .quota, .models, .activity]
    static let settingsPages: [MainTab] = [.services, .display, .refresh, .general]
}

struct MainWindowRootView: View {
    @Environment(AppState.self) private var appState
    /// 侧边栏选中背景在项目之间滑动。
    @Namespace private var sidebarSelection
    @State private var refreshRotation: Double = 0

    var body: some View {
        HStack(spacing: 0) {
            // 侧边栏可由标题栏左侧按钮 / ⌃⌘S 隐藏。
            if appState.sidebarVisible {
                sidebar
                    .frame(width: 150)
                    .transition(.move(edge: .leading))

                Divider()
            }

            Group {
                if appState.mainTab.isStats {
                    StatsView()
                } else {
                    SettingsRootView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            sidebarGroup(title: tr("Statistics", "统计"), pages: MainTab.statsPages)
            sidebarGroup(title: tr("Settings", "设置"), pages: MainTab.settingsPages)
            Spacer()
            refreshFooter
        }
        // 点击或滚动改变选中项时，高亮背景平滑滑过去。
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.mainTab)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    /// 原 Popover 顶部的刷新按钮和「x 前已刷新」挪到这里。
    private var refreshFooter: some View {
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(refreshedText(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                // 每次点击图标转一圈;重复点击由 refreshNow 内部去重。
                withAnimation(.easeInOut(duration: 0.7)) { refreshRotation += 360 }
                Task { await appState.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(refreshRotation))
            }
            .buttonStyle(.plain)
            .help(tr("Refresh now", "立即刷新"))
        }
        .padding(.horizontal, 8)
    }

    private func refreshedText(now: Date) -> String {
        let latest = [appState.codexRefreshState.lastSuccessAt, appState.claudeRefreshState.lastSuccessAt,
                      appState.grokRefreshState.lastSuccessAt].compactMap { $0 }.max()
        guard let latest else { return tr("Waiting for data", "等待数据") }
        let age = RelativeTime.short(from: latest, now: now)
        return tr("Refreshed \(age) ago", "\(age) 前已刷新")
    }

    private func sidebarGroup(title: String, pages: [MainTab]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            ForEach(pages, id: \.self) { page in
                sidebarItem(page)
            }
        }
    }

    private func sidebarItem(_ page: MainTab) -> some View {
        let active = appState.mainTab == page
        return Button {
            appState.select(page)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundStyle(active ? Color.white : Color.secondary)
                Text(page.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(active ? Color.white : Color.primary)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "selection", in: sidebarSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

// MARK: - SidebarToggleButton

/// 标题栏左侧(红绿灯旁)的显示 / 隐藏侧边栏按钮，由 WindowCoordinator 作为 titlebar accessory 挂上。
struct SidebarToggleButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { appState.sidebarVisible.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(appState.sidebarVisible ? tr("Hide sidebar (⌃⌘S)", "隐藏侧边栏(⌃⌘S)") : tr("Show sidebar (⌃⌘S)", "显示侧边栏(⌃⌘S)"))
        .padding(.leading, 4)
        .frame(height: 28)
    }
}

// MARK: - SectionedScrollPage
//
// 统计 / 设置各是一个大页：所有部分纵向排列在同一个 ScrollView 里。
// - 侧边栏点击(appState.select)→ 平滑滚动到对应部分。
// - 手动滚动时，滚到顶部区域的部分成为侧边栏选中项。
// - 顶部按钮改变内容高度前调用 ScrollAnchorKeeper.preserveReadingPosition(),
//   排版完成后用 scrollTo(部分, 计算出的锚点) 把「正在看的部分」放回原来的位置，页面不会跳。
//   补偿必须走 SwiftUI 的 scrollTo:直接改底层 NSScrollView 会和 SwiftUI 自己记录的滚动位置打架，来回抖动。
// 每个部分用 `.sectionAnchor(tab)` 标记。

struct SectionedScrollPage<Content: View>: View {
    @Environment(AppState.self) private var appState
    let sections: [MainTab]
    let keeper: ScrollAnchorKeeper
    @ViewBuilder var content: () -> Content

    @State private var viewportHeight: CGFloat = 0
    /// 程序滚动期间不根据滚动位置改选中项，避免侧边栏高亮在途中闪动。
    @State private var trackingSuppressedUntil = Date.distantPast
    /// 页面出现后先定位到点击的部分，再开始跟随滚动位置。否则从另一页点进来时，
    /// 首次排版的位置回报会先把选中项改成最上面的部分(概览 / 服务),定位就落空了。
    @State private var initialScrollDone = false

    init(sections: [MainTab], keeper: ScrollAnchorKeeper = ScrollAnchorKeeper(), @ViewBuilder content: @escaping () -> Content) {
        self.sections = sections
        self.keeper = keeper
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 44 - SectionLayout.landingGap) {
                    content()
                }
                .padding(.horizontal, 24)
                .padding(.top, 20 - SectionLayout.landingGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 底部留白，让最后一个部分也能滚到顶部。
                Color.clear.frame(height: max(0, viewportHeight - 320))
            }
            .coordinateSpace(name: SectionLayout.space)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                viewportHeight = height
                keeper.viewportHeight = height
            }
            // 位置不存 @State,滚动时不会让整页重绘。
            .onPreferenceChange(SectionOffsetKey.self) { geometry in
                if let fix = keeper.correction(for: geometry) {
                    proxy.scrollTo(fix.tab, anchor: fix.anchor)
                }
                updateActiveSection(offsets: geometry.mapValues(\.minY))
            }
            .onChange(of: appState.scrollRequest) { _, _ in scroll(proxy, to: appState.mainTab, animated: true) }
            .onAppear {
                let target = appState.mainTab
                DispatchQueue.main.async {
                    scroll(proxy, to: target, animated: false)
                    // 首帧后图表 / 数据还可能改变上方部分的高度，稍后再对齐一次。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        scroll(proxy, to: target, animated: false)
                        initialScrollDone = true
                    }
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: MainTab, animated: Bool) {
        guard sections.contains(target) else { return }
        trackingSuppressedUntil = Date().addingTimeInterval(animated ? 0.8 : 0.2)
        if animated {
            withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(target, anchor: .top) }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private func updateActiveSection(offsets: [MainTab: CGFloat]) {
        guard initialScrollDone, Date() >= trackingSuppressedUntil, sections.contains(appState.mainTab) else { return }
        let reached = sections.filter { (offsets[$0] ?? .greatestFiniteMagnitude) <= 120 }
        let active = reached.last ?? sections.first
        if let active, active != appState.mainTab {
            appState.mainTab = active
        }
    }
}

// MARK: - ScrollAnchorKeeper

/// 改变内容(切换时间范围 / 服务筛选)前记下「正在看的部分」在窗口里的位置，
/// 排版后算出一个 scrollTo 锚点，让它回到原位。
final class ScrollAnchorKeeper {
    fileprivate var offsets: [MainTab: CGFloat] = [:]
    fileprivate var heights: [MainTab: CGFloat] = [:]
    fileprivate var viewportHeight: CGFloat = 0
    private var pending: (tab: MainTab, offset: CGFloat, until: Date)?

    /// 在改变内容之前调用。正在看的部分 = 覆盖「阅读线」(窗口上方 1/4 处)的那个部分，
    /// 即顶部不低于阅读线的部分里最靠下的一个。不能取「标题在上部 40% 内」的部分：
    /// 模型明细占满上半屏、Token 活动标题刚露出时，那样会误把 Token 活动当成正在看的，
    /// 模型明细变高后就被往上推。
    /// 返回正在看的是不是页面最上面的部分：是的话它上方没有会变高的内容，可以放心用整页动画;
    /// 否则应瞬时切换，由这里精确补回滚动位置(整页动画中途补偿会先跳一下再滑回来)。
    @discardableResult
    func preserveReadingPosition() -> Bool {
        guard let reading = readingSection, let offset = offsets[reading] else { return true }
        pending = (reading, offset, Date().addingTimeInterval(0.5))
        return reading == offsets.min { $0.value < $1.value }?.key
    }

    /// 正在看的部分(规则见 preserveReadingPosition)。
    var readingSection: MainTab? {
        let readingLine = viewportHeight * 0.25
        return (offsets.filter { $0.value <= readingLine }.max { $0.value < $1.value }
            ?? offsets.min { $0.value < $1.value })?.key
    }

    /// 部分当前的自然高度(含标题上方留白)。
    func height(of tab: MainTab) -> CGFloat? {
        heights[tab]
    }

    /// 新的排版位置到来时：正在看的部分若被挤动，返回让它回到原位的 scrollTo 锚点。
    /// scrollTo 让部分里 y = a 处对齐视口里 y = a 处，部分顶部就落在 a × (视口高 − 部分高);
    /// 要让顶部回到原来的位置 o,取 a = o / (视口高 − 部分高)。
    fileprivate func correction(for geometry: [MainTab: SectionGeometry]) -> (tab: MainTab, anchor: UnitPoint)? {
        offsets = geometry.mapValues(\.minY)
        heights = geometry.mapValues(\.height)
        guard let pending else { return nil }
        guard Date() < pending.until else {
            self.pending = nil
            return nil
        }
        guard let section = geometry[pending.tab], abs(section.minY - pending.offset) > 0.5 else { return nil }
        let room = viewportHeight - section.height
        if abs(room) < 1 {
            // 部分和视口一样高时锚点无法表达位置，只能对齐顶部(原位置接近顶部时才用)。
            return abs(pending.offset) < 1 ? (pending.tab, .top) : nil
        }
        return (pending.tab, UnitPoint(x: 0, y: pending.offset / room))
    }
}

struct SectionGeometry: Equatable {
    var minY: CGFloat
    var height: CGFloat
}

struct SectionOffsetKey: PreferenceKey {
    static let defaultValue: [MainTab: SectionGeometry] = [:]
    static func reduce(value: inout [MainTab: SectionGeometry], nextValue: () -> [MainTab: SectionGeometry]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 冻结时按边框裁切;不冻结时返回极大的矩形，等于不裁(浮层、提示不会被切掉)。
private struct FreezeClip: Shape {
    var active: Bool

    func path(in rect: CGRect) -> Path {
        Path(active ? rect : rect.insetBy(dx: -10_000, dy: -10_000))
    }
}

enum SectionLayout {
    static let space = "sectionScroll"
    /// 点侧边栏定位后，部分标题上方留出的空隙。
    static let landingGap: CGFloat = 20
}

extension View {
    /// 冻结部分高度：nil 时不限制;有值时固定为该高度，多出的内容裁掉、不足留空(都在顶部对齐)。
    /// 始终挂同样的修饰符(不用 if/else),冻结 / 解冻时部分内部的 @State 不会被重置。
    func frozenHeight(_ height: CGFloat?) -> some View {
        self
            .frame(height: height, alignment: .top)
            .clipShape(FreezeClip(active: height != nil))
    }

    /// 标记大页里的一个部分：可被滚动定位，并上报自己相对滚动区顶部的位置和高度。
    /// 定位目标包含标题上方 `landingGap` 的留白，滚过去后标题不会贴着顶部。
    func sectionAnchor(_ tab: MainTab) -> some View {
        self
            .padding(.top, SectionLayout.landingGap)
            .id(tab)
            .background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(SectionLayout.space))
                    Color.clear.preference(
                        key: SectionOffsetKey.self,
                        value: [tab: SectionGeometry(minY: frame.minY, height: frame.height)]
                    )
                }
            )
    }
}

/// 大页里每个部分的标题。
struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
