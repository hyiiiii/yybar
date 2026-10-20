import SwiftUI

// MARK: - SettingsRootView
//
// 见 docs/界面布局.md §4。
// 设置分 4 页(服务 / 显示 / 刷新 / 通用),由主窗口侧边栏切换。
// 每页沿用 PrefsGroup + PrefsRow 卡片结构，内容限宽，避免控件离标签太远。

struct SettingsRootView: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLoginError: String?
    /// 待确认删除的本机账号。
    @State private var localDeleteTarget: AccountProvider?
    @State private var quotaOnlyDeleteTarget: UsageApp?
    /// hook 安装 / 卸载结果(已挂上的 CLI、失败原因)。
    @State private var hookStatus: String?
    @State private var hookError: String?
    @State private var hookWorking = false

    var body: some View {
        @Bindable var settings = SettingsStore.shared

        SectionedScrollPage(sections: MainTab.settingsPages) {
            settingsSection(.services) {
                servicesGroup(settings: settings)
                switchNotice
            }
            settingsSection(.display) {
                menuBarGroup(settings: settings)
                statsDisplayGroup(settings: settings)
                floatingGroup(settings: settings)
            }
            settingsSection(.refresh) {
                refreshGroup(settings: settings)
            }
            settingsSection(.general) {
                generalGroup(settings: settings)
                PrefsGroup(
                    title: "Model prices",
                    chinese: "模型价格",
                    desc: appState.isRepricing ? "Recalculating costs with the new prices…" : "USD per million tokens. Models come from Models in Statistics; Grok costs come from its own logs. Press Return or leave a field to save; past costs are recalculated.",
                    chineseDesc: appState.isRepricing ? "正在按新价格重算历史费用…" : "美元 / 百万 Token。模型取自统计 · 模型明细(Grok 的费用直接取自其日志，不在此列)。回车或离开输入框即保存，历史费用会按新价格重算"
                ) {
                    ModelPriceRows()
                }
                footer
            }
        }
    }

    /// 设置大页里的一个部分：标题 + 内容，内容限宽 640pt。
    private func settingsSection<Content: View>(_ tab: MainTab, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: tab.title)
            content()
        }
        .frame(maxWidth: 640, alignment: .topLeading)
        .sectionAnchor(tab)
    }

    // MARK: Services

    /// 切换本机 CLI 账号的结果，显示在账号卡片下方，8 秒后淡出。
    @ViewBuilder
    private var switchNotice: some View {
        if let notice = appState.accountSwitchNotice {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(notice.isError ? Color.orange : Color.green)
                Text(notice.text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.top, -8)
            .transition(.opacity)
            .task(id: notice.id) {
                try? await Task.sleep(for: .seconds(8))
                if appState.accountSwitchNotice?.id == notice.id {
                    withAnimation(.easeInOut(duration: 0.3)) { appState.accountSwitchNotice = nil }
                }
            }
        }
    }

    /// 按服务分组：本机 CLI 正在使用的账号(绿点，带 启用 / 菜单栏 / 悬浮窗 三列)在前，
    /// 该服务的其他账号紧随其后，卡片底部是「添加账号…」。
    private func servicesGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Accounts",
            chinese: "账号",
            desc: "The green dot marks the account each CLI on this Mac is using. Click the circle next to another account to switch the CLI to it.",
            chineseDesc: "绿点表示本机 CLI 正在使用的账号；点其他账号左侧的圆圈，即可把本机 CLI 切换到该账号"
        ) {
            ServiceMatrixHeader()
            ForEach(AccountProvider.allCases) { provider in
                let showLocal = !appState.isLocalAccountRemoved(provider)
                if showLocal || hasOtherAccounts(provider) {
                    Divider()
                    if showLocal { localRow(provider, settings: settings) }
                    OtherAccountRows(provider: provider, leadingDivider: showLocal)
                }
                // Grok Bot 紧跟 Grok;Gemini / agy 排在最后(和菜单栏顺序一致)。
                if provider == .grok, !appState.isQuotaOnlyRemoved(.grokBot) {
                    Divider()
                    quotaOnlyRow(.grokBot, settings: settings)
                }
            }
            ForEach([UsageApp.gemini, .agy], id: \.self) { app in
                if !appState.isQuotaOnlyRemoved(app) {
                    Divider()
                    quotaOnlyRow(app, settings: settings)
                }
            }
            // 其他 Google 账号(Gemini · Antigravity 两个池子一起)。
            OtherAccountRows(provider: .claude, extraProvider: .google)
            Divider()
            AddAccountButton()
            if appState.hasRemovedLocalAccounts {
                Divider()
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                        appState.restoreRemovedLocalAccounts()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text(tr("Restore removed on-Mac accounts", "恢复已删除的本机账号"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog(
            tr("Remove this account from yybar?", "从 yybar 中删除这个账号？"),
            isPresented: Binding(get: { localDeleteTarget != nil }, set: { if !$0 { localDeleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = localDeleteTarget {
                Button(tr("Remove", "删除"), role: .destructive) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                        appState.removeLocalAccount(target)
                    }
                    localDeleteTarget = nil
                }
                Button(tr("Cancel", "取消"), role: .cancel) { localDeleteTarget = nil }
            }
        } message: {
            Text(tr("yybar stops showing and refreshing it. The \(localDeleteTarget?.title ?? "") CLI stays signed in. It comes back if the CLI signs in to another account, or use \u{201C}Restore\u{201D} below.",
                    "yybar 将不再显示和刷新它，本机 \(localDeleteTarget?.title ?? "") CLI 的登录不受影响。CLI 换成其他账号后会重新出现，也可以在下方「恢复」。"))
        }
        .confirmationDialog(
            tr("Remove this account from yybar?", "从 yybar 中删除这个账号？"),
            isPresented: Binding(get: { quotaOnlyDeleteTarget != nil }, set: { if !$0 { quotaOnlyDeleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = quotaOnlyDeleteTarget {
                Button(tr("Remove", "删除"), role: .destructive) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
                        appState.removeQuotaOnlyAccount(target)
                    }
                    quotaOnlyDeleteTarget = nil
                }
                Button(tr("Cancel", "取消"), role: .cancel) { quotaOnlyDeleteTarget = nil }
            }
        } message: {
            Text(tr("yybar stops showing and refreshing it. \(quotaOnlyDeleteTarget?.displayName ?? "") on this Mac stays signed in. Use \u{201C}Restore\u{201D} below to bring it back.",
                    "yybar 将不再显示和刷新它，本机 \(quotaOnlyDeleteTarget?.displayName ?? "") 的登录不受影响。可以在下方「恢复」。"))
        }
    }

    private func hasOtherAccounts(_ provider: AccountProvider) -> Bool {
        switch provider {
        case .codex: return !appState.otherCodexAccounts.isEmpty
        case .claude: return !appState.extraAccounts(for: .claude).isEmpty
        case .grok: return !appState.extraAccounts(for: .grok).isEmpty
        }
    }

    @ViewBuilder
    private func localRow(_ provider: AccountProvider, settings: SettingsStore) -> some View {
        switch provider {
        case .codex:
            ServiceMatrixRow(
                title: "Codex", logoName: "codex", fallback: "C", tint: .codexAccent,
                email: appState.codexAccount?.email,
                plan: appState.codexAccount?.planType,
                renewal: .codex(activeUntil: appState.codexAccount?.subscriptionActiveUntil),
                switchState: appState.codexAccount?.email != nil ? .inUse : .none,
                detected: appState.codexAccount?.email != nil,
                enabled: Binding(get: { settings.showCodex }, set: { settings.showCodex = $0 }),
                menuBar: Binding(get: { settings.menuBarShowCodex }, set: { settings.menuBarShowCodex = $0 }),
                floating: floatingBinding(get: { settings.floatingShowCodex }, set: { settings.floatingShowCodex = $0 }),
                floatingAvailable: settings.floatingEnabled,
                quotaCard: AnyView(LocalQuotaCard(provider: .codex).environment(appState)),
                onDelete: { localDeleteTarget = .codex }
            )
        case .claude:
            ServiceMatrixRow(
                title: "Claude Code", logoName: "claude", fallback: "K", tint: .claudeAccent,
                email: appState.claudeAccount?.email,
                plan: appState.claudeAccount?.subscriptionType,
                renewal: .monthly(from: appState.claudeAccount?.subscriptionCreatedAt),
                switchState: appState.claudeAccount?.email != nil ? .inUse : .none,
                detected: appState.claudeAccount?.email != nil,
                enabled: Binding(get: { settings.showClaude }, set: { settings.showClaude = $0 }),
                menuBar: Binding(get: { settings.menuBarShowClaude }, set: { settings.menuBarShowClaude = $0 }),
                floating: floatingBinding(get: { settings.floatingShowClaude }, set: { settings.floatingShowClaude = $0 }),
                floatingAvailable: settings.floatingEnabled,
                quotaCard: AnyView(LocalQuotaCard(provider: .claude).environment(appState)),
                onDelete: { localDeleteTarget = .claude }
            )
        case .grok:
            ServiceMatrixRow(
                title: "Grok", logoName: "grok", fallback: "G", tint: .grokAccent,
                email: appState.grokAccount?.email,
                plan: appState.grokPlan,
                switchState: appState.grokAccount != nil ? .inUse : .none,
                detected: appState.grokAccount != nil,
                enabled: Binding(
                    get: { settings.showGrok },
                    set: {
                        settings.showGrok = $0
                        if $0 { Task { await appState.loadGrokQuota(reason: .userInitiated) } }
                    }
                ),
                menuBar: Binding(get: { settings.menuBarShowGrok }, set: { settings.menuBarShowGrok = $0 }),
                floating: floatingBinding(get: { settings.floatingShowGrok }, set: { settings.floatingShowGrok = $0 }),
                floatingAvailable: settings.floatingEnabled,
                quotaCard: AnyView(LocalQuotaCard(provider: .grok).environment(appState)),
                onDelete: { localDeleteTarget = .grok }
            )
        }
    }

    /// Grok Bot / Gemini / agy:只有本机账号(读本机 App / CLI 的登录),没有其他账号和切换。
    /// 和 Codex / Claude 本机行同一组件、同样字段:服务名 + 套餐标签 + 邮箱 + 开关 + 查看额度 + 删除。
    /// 本机没装对应 App / CLI 时整行禁用(显示「未识别」)。
    private func quotaOnlyRow(_ app: UsageApp, settings: SettingsStore) -> some View {
        let detected: Bool
        let email: String?
        let plan: String?
        let enabled: Binding<Bool>
        let menuBar: Binding<Bool>
        let floating: Binding<Bool>
        switch app {
        case .grokBot:
            detected = GrokBotQuotaClient.isInstalled
            // Grok Bot 的 token 里没有邮箱，只显示额度接口返回的套餐。
            email = nil
            plan = appState.grokBotQuota?.planType
            enabled = Binding(get: { settings.showGrokBot }, set: { settings.showGrokBot = $0 })
            menuBar = Binding(get: { settings.menuBarShowGrokBot }, set: { settings.menuBarShowGrokBot = $0 })
            floating = floatingBinding(get: { settings.floatingShowGrokBot }, set: { settings.floatingShowGrokBot = $0 })
        case .gemini:
            detected = GoogleQuotaClient.isGeminiInstalled
            email = appState.googleEmail
            plan = appState.googlePlan
            enabled = Binding(get: { settings.showGemini }, set: {
                settings.showGemini = $0
                if $0 { Task { await appState.loadGoogleQuota(reason: .userInitiated) } }
            })
            menuBar = Binding(get: { settings.menuBarShowGemini }, set: { settings.menuBarShowGemini = $0 })
            floating = floatingBinding(get: { settings.floatingShowGemini }, set: { settings.floatingShowGemini = $0 })
        default:
            detected = GoogleQuotaClient.isAgyInstalled
            email = appState.googleEmail
            plan = appState.googlePlan
            enabled = Binding(get: { settings.showAgy }, set: {
                settings.showAgy = $0
                if $0 { Task { await appState.loadGoogleQuota(reason: .userInitiated) } }
            })
            menuBar = Binding(get: { settings.menuBarShowAgy }, set: { settings.menuBarShowAgy = $0 })
            floating = floatingBinding(get: { settings.floatingShowAgy }, set: { settings.floatingShowAgy = $0 })
        }
        return ServiceMatrixRow(
            title: app.displayName, logoName: app.rawValue, fallback: app.fallbackLetter, tint: app.accent,
            email: email,
            plan: plan,
            switchState: detected ? .inUse : .none,
            detected: detected,
            enabled: enabled,
            menuBar: menuBar,
            floating: floating,
            floatingAvailable: settings.floatingEnabled,
            quotaCard: AnyView(QuotaOnlyServiceCard(app: app).environment(appState)),
            onDelete: { quotaOnlyDeleteTarget = app }
        )
    }

    private func floatingBinding(get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: get, set: { newValue in
            set(newValue)
            FloatingPanelController.shared.sync()
        })
    }

    // MARK: Display

    private func menuBarGroup(settings: SettingsStore) -> some View {
        PrefsGroup(
            title: "Menu Bar",
            chinese: "菜单栏",
            desc: "Which services appear is set on the Services page.",
            chineseDesc: "显示哪些服务在「服务」页勾选"
        ) {
            PrefsRow(label: "Quota period", chinese: "额度周期") {
                Picker("", selection: Binding(get: { settings.menuBarWindow }, set: { settings.menuBarWindow = $0 })) {
                    Text("5H").tag(MenuBarWindowChoice.fiveHour)
                    Text("WK").tag(MenuBarWindowChoice.weekly)
                    Text(tr("Both", "都显示")).tag(MenuBarWindowChoice.both)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            Divider()
            PrefsRow(
                label: "Breathe while in use",
                chinese: "使用中图标呼吸",
                desc: "A service's icon pulses in its own colour while it's being used.",
                chineseDesc: "服务正在消耗额度时，图标以自身颜色呼吸闪烁"
            ) {
                Toggle("", isOn: Binding(get: { settings.menuBarBreatheWhenActive }, set: { settings.menuBarBreatheWhenActive = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider()
            PrefsRow(
                label: "Hold colour while waiting for approval",
                chinese: "等待审批保持颜色",
                desc: "When a CLI is waiting for you to approve a tool call, its icon stays in its own colour.",
                chineseDesc: "CLI 等待你批准工具调用时，图标保持自身颜色不闪烁"
            ) {
                Toggle("", isOn: Binding(get: { settings.menuBarHoldColorWhileWaiting }, set: { settings.menuBarHoldColorWhileWaiting = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            Divider()
            PrefsRow(
                label: "Drive breathing with CLI hooks",
                chinese: "用 hook 驱动呼吸",
                desc: "Adds yybar's own hooks to Codex, Claude Code, Grok and agy so the icon reacts the moment a prompt, tool call, approval or reply happens. Your existing hooks are left alone; turning this off removes only yybar's.",
                chineseDesc: "给 Codex、Claude Code、Grok、agy 挂上 yybar 自己的 hook:提问、调用工具、请求审批、回答结束时图标立刻响应。不动你已有的 hook,关掉只删 yybar 的"
            ) {
                HStack(spacing: 6) {
                    if hookWorking { ProgressView().controlSize(.small) }
                    Toggle("", isOn: Binding(
                        get: { settings.activityHooksEnabled },
                        set: { setActivityHooks($0, settings: settings) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(hookWorking)
                }
            }
            if let hookStatus {
                Text(hookStatus)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            if let hookError {
                Text(hookError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { refreshHookStatus(settings: settings) }
    }

    private func setActivityHooks(_ enabled: Bool, settings: SettingsStore) {
        hookWorking = true
        hookError = nil
        Task {
            let report = await Task.detached {
                enabled ? ActivityHooks.install() : ActivityHooks.uninstall()
            }.value
            UsageActivityMonitor.shared.reloadHookStates()
            if enabled, report.changed.isEmpty {
                // 一个都没装上：开关退回关闭。
                settings.activityHooksEnabled = false
            } else {
                settings.activityHooksEnabled = enabled
            }
            if !report.failed.isEmpty {
                hookError = report.failed.map { "\($0.app.displayName):\($0.message)" }.joined(separator: "\n")
            } else if enabled, report.changed.isEmpty {
                hookError = tr("No supported CLI found on this Mac.", "本机没有找到支持的 CLI")
            }
            refreshHookStatus(settings: settings)
            hookWorking = false
        }
    }

    private func refreshHookStatus(settings: SettingsStore) {
        let installed = ActivityHooks.installedApps()
        guard settings.activityHooksEnabled || !installed.isEmpty else {
            hookStatus = nil
            return
        }
        if installed.isEmpty {
            hookStatus = tr("No hooks installed.", "还没有挂上任何 hook")
            return
        }
        let names = installed.map(\.displayName).joined(separator: "、")
        var text = tr("Installed for: ", "已挂上：") + names
        if installed.contains(.codex) {
            text += tr(". Codex runs new hooks only after you trust them in its /hooks.",
                       "。Codex 要在它的 /hooks 里信任新 hook 后才会执行")
        }
        hookStatus = text
    }

    /// 原「弹出窗口」分组：弹出窗口已取消，这两项现在作用于统计页。
    private func statsDisplayGroup(settings: SettingsStore) -> some View {
        PrefsGroup(title: "Statistics", chinese: "统计") {
            PrefsRow(
                label: "Reset time",
                chinese: "重置时间显示为",
                desc: "Used in Current limits and the floating window.",
                chineseDesc: "用于「当前额度」和悬浮窗"
            ) {
                Picker("", selection: Binding(
                    get: { settings.resetTimeDisplay },
                    set: { settings.resetTimeDisplay = $0 }
                )) {
                    Text(tr("Remaining", "剩余时长")).tag(ResetTimeDisplay.relative)
                    Text(tr("Exact time", "具体时间")).tag(ResetTimeDisplay.absolute)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Divider()
            PrefsRow(
                label: "Service status dot",
                chinese: "服务状态圆点",
                desc: "Show OpenAI / Anthropic / xAI / Cursor / Google status on the service filter buttons in Statistics.",
                chineseDesc: "在统计页的服务筛选按钮上显示 OpenAI / Anthropic / xAI / Cursor / Google 官方状态"
            ) {
                Toggle("", isOn: Binding(get: { settings.showServiceStatus }, set: { settings.showServiceStatus = $0 }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    private func floatingGroup(settings: SettingsStore) -> some View {
        PrefsGroup(title: "Floating HUD", chinese: "悬浮窗") {
            PrefsRow(
                label: "Show floating window",
                chinese: "显示悬浮窗",
                desc: "A small always-on-top window. Pick its services on the Services page.",
                chineseDesc: "固定在桌面上的小窗口，显示哪些服务在「服务」页勾选"
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.floatingEnabled },
                    set: { newValue in
                        settings.floatingEnabled = newValue
                        FloatingPanelController.shared.sync()
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: Refresh

    private func refreshGroup(settings: SettingsStore) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            PrefsGroup(
                title: "",
                chinese: "",
                desc: "How often the app polls in the background. Rate limits back off automatically.",
                chineseDesc: "后台轮询频率，遇到限流时会自动退避"
            ) {
                PrefsRow(
                    label: "Quota refresh",
                    chinese: "额度刷新",
                    desc: "Fetches remaining quota from each service.",
                    chineseDesc: "请求官方接口获取剩余额度"
                ) {
                    Picker("", selection: Binding(
                        get: { settings.quotaInterval },
                        set: { newValue in
                            settings.quotaInterval = newValue
                            appState.applySettingsChange()
                        }
                    )) {
                        ForEach(QuotaIntervalChoice.allCases) { choice in
                            Text(choice.bilingualDisplayName).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider()
                PrefsRow(
                    label: "Log scan",
                    chinese: "日志扫描",
                    desc: "Reads local CLI logs to count tokens and cost.",
                    chineseDesc: "读取本地 CLI 记录计算 Token 和费用"
                ) {
                    Picker("", selection: Binding(
                        get: { settings.usageInterval },
                        set: { newValue in
                            settings.usageInterval = newValue
                            appState.applySettingsChange()
                        }
                    )) {
                        ForEach(UsageIntervalChoice.allCases) { choice in
                            Text(choice.bilingualDisplayName).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            PrefsGroup(title: "Claude Projects", chinese: "Claude 云端项目") {
                PrefsRow(
                    label: "Sync cloud usage", chinese: "同步云端用量",
                    desc: "Uses the local Claude Code account. First sync starts yesterday; checks at least 5 minutes apart.",
                    chineseDesc: "使用本机 Claude Code 账号。首次回补昨天起的记录，至少间隔 5 分钟同步"
                ) {
                    Toggle("", isOn: Binding(
                        get: { settings.claudeCloudUsageEnabled },
                        set: { enabled in
                            settings.claudeCloudUsageEnabled = enabled
                            if enabled { Task { await appState.usageService.scanNow() } }
                        }
                    )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                Text(tr("Usage is assigned to each turn's completion date. Disabling sync keeps recovered history.",
                        "按每轮结束日期统计，跨午夜任务计入结束当天；关闭同步会保留已恢复的历史。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if settings.claudeCloudUsageEnabled {
                    Text(appState.usageService.cloudStatus)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            PrefsGroup(title: "Status", chinese: "状态") {
                PrefsRow(label: "Last refresh", chinese: "上次刷新") {
                    HStack(spacing: 10) {
                        Text(lastRefreshText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button {
                            Task { await appState.refreshNow() }
                        } label: {
                            Label(tr("Refresh now", "立即刷新"), systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: General

    private func generalGroup(settings: SettingsStore) -> some View {
        PrefsGroup(title: "", chinese: "") {
            PrefsRow(label: "Language", chinese: "语言") {
                Picker("", selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.appLanguage = $0 }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Divider()
            PrefsRow(label: "Launch at login", chinese: "开机自动启动") {
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        do {
                            try settings.setLaunchAtLogin(newValue)
                            launchAtLoginError = nil
                        } catch {
                            launchAtLoginError = error.localizedDescription
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if let launchAtLoginError {
                Divider()
                PrefsRow(label: "Error", chinese: "错误") {
                    Text(launchAtLoginError)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            Divider()
            PrefsRow(label: "Version", chinese: "版本") {
                Text(appVersion)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var footer: some View {
        Text(tr("yybar \(appVersion) · quota and usage for Codex, Claude Code and Grok",
                "yybar \(appVersion) · Codex、Claude Code 和 Grok 的额度与本地用量"))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
    }

    // MARK: Helpers

    private var lastRefreshText: String {
        let latest = [
            appState.codexRefreshState.lastSuccessAt,
            appState.claudeRefreshState.lastSuccessAt,
            appState.grokRefreshState.lastSuccessAt
        ].compactMap { $0 }.max()
        guard let latest else { return "—" }
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(timeFormatter.string(from: latest)) · \(RelativeTime.short(from: latest)) \(tr("ago", "前"))"
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "0.0"
    }
}

// MARK: - PrefsGroup

private struct PrefsGroup<Content: View>: View {
    let title: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题为空(和所在部分的标题重复时)不显示标题行，只留说明;两者都没有就直接是卡片。
            if !title.isEmpty || desc != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if !title.isEmpty {
                        Text(tr(title, chinese))
                            .font(.system(size: 12, weight: .semibold))
                            .kerning(-0.05)
                    }
                    if let desc, let chineseDesc {
                        Text(tr(desc, chineseDesc))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }

            VStack(spacing: 0) {
                content()
            }
            .ccPanel(cornerRadius: 10)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

// MARK: - PrefsRow

private struct PrefsRow<Trailing: View>: View {
    let label: String
    let chinese: String
    var desc: String? = nil
    var chineseDesc: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tr(label, chinese))
                    .font(.system(size: 12.5))
                if let desc, let chineseDesc {
                    Text(tr(desc, chineseDesc))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}

// MARK: - Service matrix

enum ServiceMatrixColumn {
    /// 最左侧「本机 CLI 使用中 / 切换」单选列。
    static let radio: CGFloat = 24
    /// 行内分隔线的起点(和服务名文字左对齐):行左边距 14 + 单选列 + tile 26 + 间距 10。
    static let textInset: CGFloat = 14 + radio + 26 + 10
    static let enabled: CGFloat = 56
    static let menuBar: CGFloat = 64
    static let floating: CGFloat = 56
    /// 「查看额度」按钮列。
    static let quota: CGFloat = 40
    /// 删除按钮列。
    static let action: CGFloat = 28
}

private struct ServiceMatrixHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: ServiceMatrixColumn.radio, height: 1)
            Text(tr("Account", "账号"))
            Spacer()
            Text(tr("On", "启用")).frame(width: ServiceMatrixColumn.enabled)
            Text(tr("Menu bar", "菜单栏")).frame(width: ServiceMatrixColumn.menuBar)
            Text(tr("HUD", "悬浮窗")).frame(width: ServiceMatrixColumn.floating)
            Text(tr("Quota", "额度")).frame(width: ServiceMatrixColumn.quota)
            Color.clear.frame(width: ServiceMatrixColumn.action, height: 1)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// 账号行最左侧的单选标记。
enum AccountSwitchIndicator {
    /// 本机 CLI 正在使用(绿点)。
    case inUse
    /// 其他账号：点一下把本机 CLI 切换到它。busy = 正在切换到它;disabled = 正在切换别的账号。
    case switchable(busy: Bool, disabled: Bool, action: () -> Void)
    /// 本机未登录等，不显示。
    case none
}

/// 账号卡片里的一行。本机账号和其他账号共用同一布局，保证完全对齐:
/// 单选(绿点 = 本机 CLI 使用中，空心圆 = 点击切换)| tile + 服务名 + 订阅标签 / 邮箱 | 启用 | 菜单栏 | 悬浮窗 | 额度 | 删除。
struct ServiceMatrixRow: View {
    let title: String
    let logoName: String
    let fallback: String
    let tint: Color
    let email: String?
    let plan: String?
    /// 下次续费日(邮箱后显示;Grok 等拿不到时为 nil)。
    var renewal: SubscriptionRenewal? = nil
    var switchState: AccountSwitchIndicator = .none
    /// 是否已识别到账号(本机账号未登录时为 false,整行禁用)。
    var detected: Bool = true
    @Binding var enabled: Bool
    var menuBar: Binding<Bool>? = nil
    var floating: Binding<Bool>? = nil
    /// 悬浮窗总开关(「显示」页)关闭时，悬浮窗列不可勾选。
    var floatingAvailable: Bool = true
    /// 「查看额度」浮层内容(取代原来点菜单栏图标弹出的额度窗口)。
    var quotaCard: AnyView? = nil
    var onDelete: (() -> Void)? = nil

    @State private var showingQuota = false

    var body: some View {
        HStack(spacing: 0) {
            AccountSwitchRadio(state: switchState)
                .frame(width: ServiceMatrixColumn.radio, alignment: .leading)

            HStack(spacing: 10) {
                ServiceTile(logoName: logoName, fallback: fallback, tint: tint, size: 26, logoSize: 15, cornerRadius: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                        if let plan, !plan.isEmpty, detected {
                            PlanTag(plan: plan, service: logoName)
                        }
                        if detected, let renewal {
                            RenewalTag(renewal: renewal)
                        }
                    }
                    Text(detected ? (email ?? "—") : tr("Not detected", "未识别"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(detected ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .opacity(enabled || !detected ? 1 : 0.5)

            Spacer(minLength: 8)

            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!detected)
                .help(tr("Show and refresh this account's quota", "显示并刷新这个账号的额度"))
                .frame(width: ServiceMatrixColumn.enabled)

            Group {
                if let menuBar {
                    Toggle("", isOn: menuBar)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(!enabled || !detected)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: ServiceMatrixColumn.menuBar)

            Group {
                if let floating {
                    Toggle("", isOn: floating)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .disabled(!enabled || !detected || !floatingAvailable)
                        .help(floatingAvailable ? "" : tr("Turn on the floating window on the Display page first.",
                                                          "先在「显示」页开启悬浮窗"))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: ServiceMatrixColumn.floating)

            Group {
                if let quotaCard, detected {
                    Button {
                        showingQuota.toggle()
                    } label: {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 13))
                            .foregroundStyle(showingQuota ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("View quota", "查看额度"))
                    .popover(isPresented: $showingQuota, arrowEdge: .bottom) {
                        quotaCard
                    }
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: ServiceMatrixColumn.quota)

            Group {
                if let onDelete, detected {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("Remove", "删除"))
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: ServiceMatrixColumn.action)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        // 启用 / 停用时整行变淡、勾选框禁用状态平滑过渡。
        .animation(.easeInOut(duration: 0.2), value: enabled)
    }
}

/// 订阅等级标签：按档次着色(免费灰、标准档蓝、高档紫、团队 / 企业青)。
private struct PlanTag: View {
    let plan: String
    /// 服务(logoName):codex / claude / grok,同名档次在不同服务里含义不同(ChatGPT Pro 是最高档，Claude Pro 是标准档)。
    let service: String

    private enum Tier { case free, standard, premium, team }

    private var tier: Tier {
        let p = plan.lowercased()
        if p.contains("free") || p == "guest" { return .free }
        if ["team", "business", "enterprise", "edu"].contains(where: { p.contains($0) }) { return .team }
        switch service {
        case "codex": return p.contains("pro") ? .premium : .standard
        case "claude": return p.contains("max") ? .premium : .standard
        default: return p.contains("heavy") ? .premium : .standard
        }
    }

    var body: some View {
        let color: Color
        switch tier {
        case .free: color = .secondary
        case .standard: color = .blue
        case .premium: color = .purple
        case .team: color = .teal
        }
        return Text(plan.prefix(1).uppercased() + plan.dropFirst())
            .font(.system(size: 10, weight: tier == .free ? .regular : .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(tier == .free ? Color.primary.opacity(0.07) : color.opacity(0.13)))
    }
}

/// 订阅等级后的续费标签「10月20日续费」,样式同订阅标签;3 天内续费变橙色。悬停说明来源(准确 / 按订阅开始日推算)。
private struct RenewalTag: View {
    let renewal: SubscriptionRenewal

    var body: some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: renewal.date)).day ?? 0
        let month = calendar.component(.month, from: renewal.date)
        let day = calendar.component(.day, from: renewal.date)
        let english = renewal.date.formatted(.dateTime.month(.abbreviated).day())
        let soon = days <= 3
        let basis = renewal.basis.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        Text(tr("Renews \(english)", "\(month)月\(day)日续费"))
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(soon ? Color.orange : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(soon ? Color.orange.opacity(0.13) : Color.primary.opacity(0.07)))
            .fixedSize()
            .help(renewal.estimated
                  ? tr("Estimated from the subscription start (\(basis)), assuming monthly billing. Annual plans or plan changes may differ.",
                       "按订阅开始日(\(basis))每月续费推算，年付或中途改过套餐时可能不准")
                  : tr("From the ChatGPT sign-in: the current paid period ends \(basis). \(days) days left.",
                       "来自 ChatGPT 登录信息：当前付费周期到 \(basis),还有 \(days) 天"))
    }
}

/// 账号行最左侧的单选标记：绿点 = 本机 CLI 使用中；空心圆 = 点击切换(悬停时变强调色并预览实心点)。
/// 三种状态占同样的 14pt,圆心对齐;按钮命中区域向外扩 4pt,不影响布局。
private struct AccountSwitchRadio: View {
    let state: AccountSwitchIndicator
    @State private var hovering = false

    var body: some View {
        switch state {
        case .inUse:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.green.opacity(0.16)))
                .help(tr("In use by the CLI on this Mac", "本机 CLI 正在使用的账号"))
        case .switchable(let busy, let disabled, let action):
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                let active = hovering && !disabled
                Button(action: action) {
                    ZStack {
                        Circle()
                            .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: 1.2)
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .opacity(active ? 1 : 0)
                            .scaleEffect(active ? 1 : 0.4)
                    }
                    .frame(width: 14, height: 14)
                    .padding(4)
                    .contentShape(Rectangle())
                    .padding(-4)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.15), value: active)
                .help(tr("Switch the CLI on this Mac to this account", "切换本机 CLI 使用这个账号"))
            }
        case .none:
            Color.clear.frame(width: 14, height: 14)
        }
    }
}

// MARK: - Bilingual display names for existing enums

extension QuotaIntervalChoice {
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}

extension UsageIntervalChoice {
    var bilingualDisplayName: String {
        switch self {
        case .m1: return tr("1 minute", "1 分钟")
        case .m2: return tr("2 minutes", "2 分钟")
        case .m3: return tr("3 minutes", "3 分钟")
        case .m5: return tr("5 minutes", "5 分钟")
        case .m10: return tr("10 minutes", "10 分钟")
        }
    }
}
