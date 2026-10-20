import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    var codexAccount: CodexAccount?
    var claudeAccount: ClaudeAccount?
    var grokAccount: GrokAccount?
    var codexError: String?
    var claudeError: String?

    // MARK: 导入的 Codex 副账号
    //
    // 用户手动粘贴 auth.json 添加的"其他账号"。与默认账号(`~/.codex/auth.json`)解耦,
    // 允许重复出现,token 走 Keychain (见 ImportedCodexStore)。
    // - `importedCodexAccounts` 元数据列表,保持添加顺序。
    // - `importedCodexQuotas / Sources / Errors / RefreshStates` 按 account.id 索引,
    //   只在该账号 `visibleInPopover` 为 true 时才刷新与展示。
    var importedCodexAccounts: [ImportedCodexAccount] = []
    var importedCodexQuotas: [String: QuotaSnapshot] = [:]
    var importedCodexSources: [String: QuotaSnapshotSource] = [:]
    var importedCodexErrors: [String: String] = [:]
    var importedCodexRefreshStates: [String: QuotaRefreshState] = [:]

    // 额外 Claude / Grok 账号(设置 · 服务 →「添加账号」),按 ExtraAccount.id 索引。
    var extraAccounts: [ExtraAccount] = []
    var extraQuotas: [String: QuotaSnapshot] = [:]
    var extraErrors: [String: String] = [:]
    var extraRefreshStates: [String: QuotaRefreshState] = [:]
    @ObservationIgnored private var extraPlanFetchedAt: [String: Date] = [:]

    /// 主窗口当前 tab,允许 ⌘1 / ⌘, 等命令从外部驱动切换
    var mainTab: MainTab = .stats
    /// 定位请求：侧边栏点击 / 菜单栏打开时更新，统计 / 设置大页据此平滑滚动到 mainTab。
    var scrollRequest: UUID?
    /// 主窗口侧边栏是否显示(标题栏按钮 / ⌃⌘S 切换)。
    var sidebarVisible = true

    /// 选中某个部分并请求滚动过去。
    func select(_ tab: MainTab) {
        mainTab = tab
        scrollRequest = UUID()
    }

    /// 首次启动时由 bootstrap 设为 true,触发 Onboarding 窗口
    var shouldShowOnboarding: Bool = false

    var codexQuota: QuotaSnapshot?
    var claudeQuota: QuotaSnapshot?
    var grokQuota: QuotaSnapshot?
    var grokQuotaError: String?
    var grokRefreshState = QuotaRefreshState()
    /// Grok 订阅等级(如 SuperGrok)。随额度刷新顺带获取，最多 6 小时查一次。
    var grokPlan: String?
    private var grokPlanFetchedAt: Date?
    var codexQuotaError: String?
    var claudeQuotaError: String?
    var codexQuotaSource: QuotaSnapshotSource?
    var claudeQuotaSource: QuotaSnapshotSource?
    var codexRefreshState = QuotaRefreshState()
    var claudeRefreshState = QuotaRefreshState()
    var quotaHistory = QuotaHistoryPayload()

    var codexTodayCost: Decimal?
    var claudeTodayCost: Decimal?
    var grokTodayCost: Decimal?

    // MARK: Grok Bot / Gemini / agy
    //
    // Gemini 与 agy 的额度来自同一次 `agy -p /usage`(Google 账号的两个池子):
    // Gemini 池(Pro + Flash 共用)→ geminiQuota,Claude + GPT 池 → agyQuota,共用一个刷新状态。
    // Grok Bot 额度用本机 Grok Bot app 的登录读取(见 GrokBotQuotaClient / GrokBotAuth)。
    var geminiQuota: QuotaSnapshot?
    var agyQuota: QuotaSnapshot?
    var googleQuotaError: String?
    var googleRefreshState = QuotaRefreshState()
    var grokBotQuota: QuotaSnapshot?
    var grokBotQuotaError: String?
    var grokBotRefreshState = QuotaRefreshState()
    /// 从钥匙串「Grok Bot Safe Storage」派生的解密密钥，只留在内存，避免每次刷新都读钥匙串。
    private var grokBotKey: Data?
    /// 钥匙串读取被拒绝后，定时刷新不再自动弹窗，等手动刷新再问。
    private var grokBotKeychainDenied = false
    /// 本机 agy 登录的 Google 邮箱(从 agy 日志读，只用于显示和识别重复账号)。
    var googleEmail: String?
    /// 本机 agy 的套餐名(只取 /usage 输出里自带的，没有就是 nil)。
    var googlePlan: String?
    /// agy 每次查询要起一个 CLI 进程(约 10~15 秒),定时刷新至少间隔 100 秒(默认 2 分钟一次);
    /// 手动刷新不受此限(429 退避仍然生效)。
    private let googleMinPeriodicInterval: TimeInterval = 100

    /// OpenAI / Anthropic statuspage.io 最新快照,失败时保留上一份。
    var codexServiceStatus: ServiceStatus?
    var claudeServiceStatus: ServiceStatus?
    var grokServiceStatus: ServiceStatus?
    /// Google(Gemini / Antigravity)和 Cursor(Grok Bot)的官方状态。
    var googleServiceStatus: ServiceStatus?
    var cursorServiceStatus: ServiceStatus?

    let usageService = UsageService()
    private let scheduler = Scheduler()
    private var didBootstrap = false
    private var quotaCache = QuotaCachePayload()
    private var claudeFallbackBackoffUntil: Date?

    /// `refreshNow()` 的去重锁。同一时刻只允许一个真正在跑的整体刷新;
    /// 期间额外的 `refreshNow()` 调用立即返回(no-op),不再排队。
    /// UI 的"刷新按钮"依然每点必转图标,只是不会真的发起重复请求。
    private var refreshInFlight: Task<Void, Never>?

    /// `ClaudeDelegatedRefresh` 完成成功时的通知订阅。
    /// 保留引用以便释放时取消(目前 AppState 生命周期 = App 生命周期,实际不会释放)。
    private var delegatedRefreshObserver: NSObjectProtocol?

    private let minSuccessInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 10 * 60

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        subscribeToDelegatedRefreshSuccess()
        loadQuotaCache()
        loadQuotaHistory()
        reloadImportedCodexAccounts()
        reloadExtraAccounts()
        await migrateAccountTokensFromKeychain()
        usageService.bootstrap(appState: self)
        await loadCodex()
        maybeShowKeychainPrompt()
        await loadClaude()
        logCredentialSummary()

        if !SettingsStore.shared.didCompleteOnboarding {
            shouldShowOnboarding = true
        }

        let settings = SettingsStore.shared
        scheduler.start(
            appState: self,
            quotaInterval: settings.quotaInterval.seconds,
            usageInterval: settings.usageInterval.seconds
        )
        // 启动后台触发一次 JSONL 扫描，让今日 cost 立刻更新（不阻塞 bootstrap）
        Task { await usageService.scanNow() }
        // 启动后异步拉一次服务状态;后续由 Scheduler 5 分钟刷新一次
        Task { await refreshServiceStatus() }
        Task { await loadGrokQuota(reason: .userInitiated) }
        Task { await loadGoogleQuota(reason: .userInitiated) }
    }

    /// 旧版本把其他账号的 token 存在钥匙串里，启动时先统一搬到文件(见 AccountTokenFiles)。
    /// 放在后台线程、并在任何额度刷新之前做完：迁移时系统可能弹一次钥匙串授权，不卡界面，也不会重复弹。
    private func migrateAccountTokensFromKeychain() async {
        let codexIds = importedCodexAccounts.map(\.id)
        let claudeIds = extraAccounts.filter { $0.provider == .claude }.map(\.id)
        guard !codexIds.isEmpty || !claudeIds.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            for id in codexIds { _ = ImportedCodexStore.loadTokens(accountId: id) }
            for id in claudeIds { _ = ExtraAccountStore.loadClaudeTokens(id: id) }
        }.value
    }

    /// 设置变更后，把刷新间隔同步到 Scheduler
    func applySettingsChange() {
        let settings = SettingsStore.shared
        scheduler.setQuotaInterval(settings.quotaInterval.seconds)
        scheduler.setUsageInterval(settings.usageInterval.seconds)
    }

    func refreshNow() async {
        // 去重:已有刷新在跑就直接返回,避免用户连点导致多份并发请求。
        // UI 端不依赖这里的 await 时长,按钮立刻就响应了。
        if refreshInFlight != nil { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.refreshQuotas(reason: .userInitiated)
            await self.usageService.scanNow()
            await self.refreshServiceStatus()
        }
        refreshInFlight = task
        await task.value
        refreshInFlight = nil
    }

    /// 订阅 `ClaudeDelegatedRefresh` 后台委托刷新成功的通知。
    /// 一旦 claude CLI 在后台帮我们刷新了 token 并写回了 keychain,
    /// 这里会自动触发一次完整刷新,UI 拿到新数据,用户全程无感。
    private func subscribeToDelegatedRefreshSuccess() {
        delegatedRefreshObserver = NotificationCenter.default.addObserver(
            forName: .claudeDelegatedRefreshDidSucceed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证回调线程,再 Task 进 MainActor 做异步刷新。
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 用 .periodic 而不是 .userInitiated,避免被当作"用户操作"
                // 影响速率限制 / 退避策略。
                await self.refreshQuotas(reason: .periodic)
            }
        }
    }

    /// 每次刷新(手动 / Scheduler 定时)都先重读本地凭据,以便用户在外部
    /// (如 cc-switch)切换账号后 yybar 能感知到。loadCodex / loadClaude
    /// 内部会比较 accountId / email,若身份变化则清掉旧的额度缓存,避免
    /// 出现"新账号 + 旧额度"的错配。
    func refreshQuotas(reason: QuotaRefreshReason = .periodic) async {
        async let grokRefresh: Void = loadGrokQuota(reason: reason)
        async let googleRefresh: Void = loadGoogleQuota(reason: reason)
        async let grokBotRefresh: Void = loadGrokBotQuota(reason: reason)
        await loadCodex()
        await loadClaude()
        await loadCodexQuota(reason: reason)
        await loadClaudeQuota(reason: reason)
        await grokRefresh
        await googleRefresh
        await grokBotRefresh
        await loadAllImportedCodexQuotas(reason: reason)
        await loadAllExtraQuotas(reason: reason)
        logQuotaSummary()
    }

    /// 拉取 OpenAI / Anthropic / Cursor statuspage、xAI 状态 RSS 与 Google incidents。失败保留旧快照,不清空。
    /// 三个请求并发,任意一个失败不影响其他。
    func refreshServiceStatus() async {
        async let codex = Self.fetchServiceStatus(url: ServiceStatusClient.openAIStatusURL,
                                                  components: ServiceStatusClient.openAIComponents, tag: "openai")
        async let claude = Self.fetchServiceStatus(url: ServiceStatusClient.anthropicStatusURL,
                                                   components: ServiceStatusClient.anthropicComponents, tag: "anthropic")
        async let grok = Self.fetchXAIStatus()
        async let cursor = Self.fetchServiceStatus(url: ServiceStatusClient.cursorStatusURL,
                                                   components: ServiceStatusClient.cursorComponents, tag: "cursor")
        async let google = Self.fetchGoogleStatus()
        let codexResult = await codex
        let claudeResult = await claude
        let grokResult = await grok
        let cursorResult = await cursor
        let googleResult = await google
        if let codexResult { codexServiceStatus = codexResult }
        if let claudeResult { claudeServiceStatus = claudeResult }
        if let grokResult { grokServiceStatus = grokResult }
        if let cursorResult { cursorServiceStatus = cursorResult }
        if let googleResult { googleServiceStatus = googleResult }
    }

    private static func fetchGoogleStatus() async -> ServiceStatus? {
        do {
            return try await ServiceStatusClient.fetchGoogle()
        } catch {
            print("[service-status] google fetch failed: \(error)")
            return nil
        }
    }

    private static func fetchXAIStatus() async -> ServiceStatus? {
        do {
            return try await ServiceStatusClient.fetchXAI()
        } catch {
            print("[service-status] xai fetch failed: \(error)")
            return nil
        }
    }

    private static func fetchServiceStatus(url: URL, components: [String], tag: String) async -> ServiceStatus? {
        do {
            return try await ServiceStatusClient.fetch(from: url, components: components)
        } catch {
            print("[service-status] \(tag) fetch failed: \(error)")
            return nil
        }
    }

    func quotaStatusLine(for app: QuotaApp) -> String? {
        let snapshot: QuotaSnapshot?
        let source: QuotaSnapshotSource?
        let error: String?
        let state: QuotaRefreshState
        switch app {
        case .codex:
            snapshot = codexQuota
            source = codexQuotaSource
            error = codexQuotaError
            state = codexRefreshState
        case .claude:
            snapshot = claudeQuota
            source = claudeQuotaSource
            error = claudeQuotaError
            state = claudeRefreshState
        case .grok:
            snapshot = grokQuota
            source = grokRefreshState.source
            error = grokQuotaError
            state = grokRefreshState
        case .grokBot:
            snapshot = grokBotQuota
            source = grokBotRefreshState.source
            error = grokBotQuotaError
            state = grokBotRefreshState
        case .gemini, .agy:
            snapshot = app == .gemini ? geminiQuota : agyQuota
            source = googleRefreshState.source
            error = googleQuotaError
            state = googleRefreshState
        }

        var parts: [String] = []
        if let snapshot, !format(snapshot).isEmpty {
            parts.append(format(snapshot))
        }
        if let source {
            parts.append(source.displayName)
        }
        if let lastSuccessAt = state.lastSuccessAt {
            parts.append("更新 \(relativeAge(from: lastSuccessAt))前")
        }
        if let backoffUntil = state.backoffUntil, backoffUntil > Date() {
            parts.append("限流退避 \(relativeAge(until: backoffUntil))")
        }
        if let error, !error.isEmpty {
            parts.append("错误: \(shortError(error))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func loadQuotaCache() {
        quotaCache = QuotaCache.load()
        if let record = quotaCache.codex {
            codexQuota = record.snapshot
            codexQuotaSource = .cache
            codexRefreshState.lastSuccessAt = record.updatedAt
            codexRefreshState.source = .cache
        }
        if let record = quotaCache.claude {
            claudeQuota = record.snapshot
            claudeQuotaSource = .cache
            claudeRefreshState.lastSuccessAt = record.updatedAt
            claudeRefreshState.source = .cache
        }
        // Validate the current identity before displaying a cached Grok account.
        if let account = try? GrokAccount.load() {
            grokAccount = account
            if quotaCache.grokAccountID == account.identity, let record = quotaCache.grok {
                grokQuota = record.snapshot
                grokRefreshState.lastSuccessAt = record.updatedAt
                grokRefreshState.source = .cache
            }
        }
        if let record = quotaCache.gemini { geminiQuota = record.snapshot }
        if let record = quotaCache.agy { agyQuota = record.snapshot }
        if let updated = [quotaCache.gemini?.updatedAt, quotaCache.agy?.updatedAt].compactMap({ $0 }).max() {
            googleRefreshState.lastSuccessAt = updated
            googleRefreshState.source = .cache
        }
        if let record = quotaCache.grokBot {
            grokBotQuota = record.snapshot
            grokBotRefreshState.lastSuccessAt = record.updatedAt
            grokBotRefreshState.source = .cache
        }
        for (id, record) in quotaCache.extra ?? [:] {
            extraQuotas[id] = record.snapshot
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            extraRefreshStates[id] = state
        }
        for (id, record) in quotaCache.importedCodex ?? [:] {
            importedCodexQuotas[id] = record.snapshot
            importedCodexSources[id] = .cache
            var state = QuotaRefreshState()
            state.lastSuccessAt = record.updatedAt
            state.source = .cache
            importedCodexRefreshStates[id] = state
        }
    }

    private func loadQuotaHistory() {
        quotaHistory = QuotaHistoryStore.load()
        saveQuotaHistory()
    }

    // MARK: - Removing on-Mac accounts from yybar

    /// 本机 CLI 当前账号的身份，用来记住「已删除」的是哪个账号。
    func localAccountIdentity(_ provider: AccountProvider) -> String? {
        switch provider {
        case .codex: return codexAccount.flatMap { nonEmpty($0.accountId) ?? nonEmpty($0.email) }
        case .claude: return nonEmpty(claudeAccount?.email)
        case .grok: return grokAccount?.identity
        }
    }

    func isLocalAccountRemoved(_ provider: AccountProvider) -> Bool {
        guard let identity = localAccountIdentity(provider) else { return false }
        return SettingsStore.shared.removedLocalAccounts[provider.rawValue] == identity
    }

    /// 从 yybar 中移除本机账号：关闭该服务的显示和刷新，并记住账号身份。不会退出 CLI 登录。
    func removeLocalAccount(_ provider: AccountProvider) {
        guard let identity = localAccountIdentity(provider) else { return }
        let settings = SettingsStore.shared
        settings.removedLocalAccounts[provider.rawValue] = identity
        setLocalAccountEnabled(provider, false)
    }

    var hasRemovedLocalAccounts: Bool {
        AccountProvider.allCases.contains { isLocalAccountRemoved($0) }
            || Self.quotaOnlyApps.contains { isQuotaOnlyRemoved($0) }
    }

    func restoreRemovedLocalAccounts() {
        for provider in AccountProvider.allCases where isLocalAccountRemoved(provider) {
            SettingsStore.shared.removedLocalAccounts.removeValue(forKey: provider.rawValue)
            setLocalAccountEnabled(provider, true)
        }
        for app in Self.quotaOnlyApps where isQuotaOnlyRemoved(app) {
            SettingsStore.shared.removedLocalAccounts.removeValue(forKey: app.rawValue)
            setQuotaOnlyEnabled(app, true)
        }
    }

    /// 只有本机账号的服务(Grok Bot / Gemini / agy)。删除同样记在 removedLocalAccounts,键为 UsageApp.rawValue。
    static let quotaOnlyApps: [UsageApp] = [.grokBot, .gemini, .agy]

    /// 身份:Gemini / agy 用 Google 邮箱(读不到时 "local"),Grok Bot 用 "local"。换账号后自动重新出现。
    private func quotaOnlyIdentity(_ app: UsageApp) -> String {
        switch app {
        case .gemini, .agy: return nonEmpty(googleEmail) ?? "local"
        default: return "local"
        }
    }

    func isQuotaOnlyRemoved(_ app: UsageApp) -> Bool {
        SettingsStore.shared.removedLocalAccounts[app.rawValue] == quotaOnlyIdentity(app)
    }

    func removeQuotaOnlyAccount(_ app: UsageApp) {
        SettingsStore.shared.removedLocalAccounts[app.rawValue] = quotaOnlyIdentity(app)
        setQuotaOnlyEnabled(app, false)
    }

    private func setQuotaOnlyEnabled(_ app: UsageApp, _ enabled: Bool) {
        let settings = SettingsStore.shared
        switch app {
        case .grokBot: settings.showGrokBot = enabled
        case .gemini: settings.showGemini = enabled
        case .agy: settings.showAgy = enabled
        default: return
        }
        if enabled {
            if app == .grokBot {
                Task { await loadGrokBotQuota(reason: .userInitiated) }
            } else {
                Task { await loadGoogleQuota(reason: .userInitiated) }
            }
        }
        FloatingPanelController.shared.sync()
    }

    private func setLocalAccountEnabled(_ provider: AccountProvider, _ enabled: Bool) {
        let settings = SettingsStore.shared
        switch provider {
        case .codex: settings.showCodex = enabled
        case .claude: settings.showClaude = enabled
        case .grok:
            settings.showGrok = enabled
            if enabled { Task { await loadGrokQuota(reason: .userInitiated) } }
        }
        FloatingPanelController.shared.sync()
    }

    // MARK: - Custom model prices

    /// 自定义价格每改一次 +1,设置页的价格表据此刷新。
    var customPricesVersion = 0
    /// 正在按新价格重算历史费用(设置页显示进度)。
    var isRepricing = false
    @ObservationIgnored private var repriceTask: Task<Void, Never>?
    @ObservationIgnored private var repriceKeys: Set<String> = []

    /// 设置 / 清除某个模型的自定义价格。连续修改时，停 0.8 秒后才按新价格重算一次历史费用
    /// (只重算改过价的模型;日志已删除的历史也保留，见 UsageService.mergePreservingHistory)。
    func setCustomPrice(_ price: ModelPrice?, forKey key: String) {
        CustomModelPrices.shared.set(price, forKey: key)
        customPricesVersion += 1
        repriceKeys.insert(key)
        repriceTask?.cancel()
        repriceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let keys = self.repriceKeys
            self.repriceKeys = []
            self.isRepricing = true
            await self.usageService.rescanAll(repricing: keys)
            self.isRepricing = false
        }
    }

    // MARK: - Switching the CLI account

    /// 设置页账号卡片下方的切换结果提示。
    struct AccountSwitchNotice: Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// 正在把本机 CLI 切换到的账号 id(设置页该行显示转圈，其他行暂不可切换)。
    var switchingAccountId: String?
    var accountSwitchNotice: AccountSwitchNotice?

    /// 把本机 Codex CLI 切换到这个其他账号。原来的本机账号存为其他账号(沿用目标账号的启用 / 菜单栏 / 悬浮窗设置)。
    func switchCLI(toCodex target: ImportedCodexAccount) async {
        await performSwitch(id: target.id, provider: .codex, label: target.email ?? target.id) {
            await self.waitWhileRefreshing { self.codexRefreshState.inFlight || self.importedCodexRefreshStates[target.id]?.inFlight == true }
            // 1. 目标账号的 token,临期先续期，交给 CLI 的是可用的。
            guard let stored = ImportedCodexStore.loadTokens(accountId: target.id) else {
                throw CLIAccountSwitch.SwitchError.message("找不到这个账号保存的凭据，请重新添加（Saved credentials not found）")
            }
            let tokens: ImportedCodexTokens
            switch await CodexTokenRefresher.ensureFreshTokens(currentAccessToken: stored.accessToken, refreshToken: stored.refreshToken,
                                                               idToken: stored.idToken, writeBack: .importedAccount(id: target.id)) {
            case .success(let fresh):
                tokens = ImportedCodexTokens(accessToken: fresh.accessToken,
                                             refreshToken: fresh.refreshToken.isEmpty ? stored.refreshToken : fresh.refreshToken,
                                             idToken: fresh.idToken ?? stored.idToken)
            case .failure(let error):
                throw CLIAccountSwitch.SwitchError.message("这个账号的登录已失效，请重新添加（\(error.description)）")
            }

            // 2. 本机原来的账号存为其他账号。
            let url = CodexAuth.authFileURL()
            let currentData = try? Data(contentsOf: url)
            let currentRoot = CLIAccountSwitch.readJSON(at: url)
            var savedOldId: String?
            if let currentData {
                CLIAccountSwitch.backup(currentData, name: "codex-auth.json")
                if let text = String(data: currentData, encoding: .utf8),
                   case .success(let parsed) = ImportedCodexPaste.parse(text), parsed.id != target.id {
                    try self.upsertImportedCodexAccount(from: parsed, alias: "", visibleInPopover: target.visibleInPopover)
                    self.updateImportedCodexMetadata(id: parsed.id) {
                        $0.showInMenuBar = target.showInMenuBar
                        $0.showInFloating = target.showInFloating
                    }
                    savedOldId = parsed.id
                }
            }

            // 3. 写入 CLI 的 auth.json;目标账号成为本机账号，从其他账号里移除。
            try CLIAccountSwitch.writeCodexAuth(base: currentRoot, tokens: tokens, accountId: target.chatgptAccountId)
            let seed = self.importedCodexQuotas[target.id]
            let oldSnapshot = self.codexQuota
            self.removeImportedCodexAccount(id: target.id)
            await self.loadCodex()

            // 4. 额度先沿用各自最近一次的结果，再立即刷新本机账号。
            if let savedOldId, let oldSnapshot { self.storeImportedCodex(id: savedOldId, snapshot: oldSnapshot, source: .cache) }
            if let seed {
                self.codexQuota = seed
                self.codexQuotaSource = .cache
            }
            await self.loadCodexQuota(reason: .userInitiated)
        }
    }

    /// 把本机 Claude Code / Grok CLI 切换到这个其他账号。
    func switchCLI(toExtra target: ExtraAccount) async {
        let provider: AccountProvider = target.provider == .claude ? .claude : .grok
        await performSwitch(id: target.id, provider: provider, label: target.email ?? target.displayName) {
            switch target.provider {
            case .claude: try await self.switchClaude(to: target)
            case .grok: try await self.switchGrok(to: target)
            case .google:
                throw CLIAccountSwitch.SwitchError.message("Google 账号不支持切换本机 agy 登录")
            }
        }
    }

    private func switchClaude(to target: ExtraAccount) async throws {
        await waitWhileRefreshing { self.claudeRefreshState.inFlight || self.extraRefreshStates[target.id]?.inFlight == true }
        guard var tokens = ExtraAccountStore.loadClaudeTokens(id: target.id) else {
            throw CLIAccountSwitch.SwitchError.message("找不到这个账号保存的凭据，请重新添加（Saved credentials not found）")
        }
        // 1. 临期先续期。
        if let expires = tokens.expiresAt, expires.timeIntervalSinceNow < 600, let refresh = tokens.refreshToken {
            do {
                let renewed = try await ClaudeTokenRefresher.refreshExtraAccount(using: refresh)
                tokens.accessToken = renewed.accessToken
                tokens.refreshToken = renewed.refreshToken
                tokens.expiresAt = renewed.expiresAt
                try ExtraAccountStore.saveClaudeTokens(tokens, id: target.id)
            } catch {
                throw CLIAccountSwitch.SwitchError.message("这个账号的登录已失效，请重新添加（\((error as? QuotaError)?.description ?? error.localizedDescription)）")
            }
        }

        // 2. 本机原来的账号(凭据 + oauthAccount)存为其他账号，切回时原样还原。
        let current = CLIAccountSwitch.readClaudeCredential()
        let currentOAuthAccount = CLIAccountSwitch.readClaudeOAuthAccount()
        var savedOldId: String?
        if let current, let data = CLIAccountSwitch.jsonString(current.root)?.data(using: .utf8) {
            CLIAccountSwitch.backup(data, name: "claude-credentials.json")
        }
        if let oauth = current?.root["claudeAiOauth"] as? [String: Any],
           let access = oauth["accessToken"] as? String, !access.isEmpty {
            let email = claudeAccount?.email ?? currentOAuthAccount?["emailAddress"] as? String
            if email == nil || email?.lowercased() != target.email?.lowercased() {
                var expiresAt: Date?
                if let raw = oauth["expiresAt"] as? Double ?? (oauth["expiresAt"] as? String).flatMap(Double.init) {
                    expiresAt = Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
                }
                let saved = ExtraClaudeTokens(accessToken: access, refreshToken: oauth["refreshToken"] as? String, expiresAt: expiresAt,
                                              credentialJSON: CLIAccountSwitch.jsonString(oauth),
                                              oauthAccountJSON: currentOAuthAccount.flatMap(CLIAccountSwitch.jsonString))
                let id = "claude:" + (email?.lowercased() ?? UUID().uuidString.lowercased())
                try ExtraAccountStore.saveClaudeTokens(saved, id: id)
                try upsertExtraAccount(ExtraAccount(
                    id: id, provider: .claude, alias: "", email: email,
                    plan: oauth["subscriptionType"] as? String ?? claudeAccount?.subscriptionType,
                    visibleInPopover: target.visibleInPopover, addedAt: Date(), homeFolder: nil,
                    showInMenuBar: target.showInMenuBar, showInFloating: target.showInFloating,
                    subscriptionStartedAt: SubscriptionRenewal.parseDate(currentOAuthAccount?["subscriptionCreatedAt"])
                        ?? claudeAccount?.subscriptionCreatedAt
                ))
                savedOldId = id
            }
        }

        // 3. 目标账号的 claudeAiOauth:有切走时保存的完整对象就用它，否则沿用本机的 scopes,订阅等按资料接口补。
        var oauth = CLIAccountSwitch.jsonObject(tokens.credentialJSON) ?? [:]
        if oauth.isEmpty, let scopes = (current?.root["claudeAiOauth"] as? [String: Any])?["scopes"] {
            oauth["scopes"] = scopes
        }
        oauth["accessToken"] = tokens.accessToken
        oauth["refreshToken"] = tokens.refreshToken
        oauth["expiresAt"] = tokens.expiresAt.map { Int($0.timeIntervalSince1970 * 1000) }
        var oauthAccount = CLIAccountSwitch.jsonObject(tokens.oauthAccountJSON)
        if oauthAccount == nil, let profile = await ClaudeProfileClient.fetchOAuthAccount(accessToken: tokens.accessToken) {
            oauthAccount = CLIAccountSwitch.jsonObject(profile.json)
            if oauth["rateLimitTier"] == nil { oauth["rateLimitTier"] = profile.rateLimitTier }
        }
        if oauth["subscriptionType"] == nil { oauth["subscriptionType"] = target.plan }
        var root = current?.root ?? [:]
        root["claudeAiOauth"] = oauth
        try CLIAccountSwitch.writeClaudeCredential(root, source: current?.source ?? .keychain)
        if let oauthAccount {
            try CLIAccountSwitch.writeClaudeOAuthAccount(oauthAccount)
        } else if let email = target.email {
            try CLIAccountSwitch.writeClaudeOAuthAccount(["emailAddress": email])
        }

        // 4. 目标账号成为本机账号;额度先沿用各自最近一次的结果，再立即刷新。
        let seed = extraQuotas[target.id]
        let oldSnapshot = claudeQuota
        removeExtraAccount(id: target.id)
        await loadClaude()
        if let savedOldId, let oldSnapshot { storeExtraQuota(id: savedOldId, snapshot: oldSnapshot) }
        if let seed {
            claudeQuota = seed
            claudeQuotaSource = .cache
        }
        await loadClaudeQuota(reason: .userInitiated)
    }

    private func switchGrok(to target: ExtraAccount) async throws {
        await waitWhileRefreshing { self.grokRefreshState.inFlight || self.extraRefreshStates[target.id]?.inFlight == true }
        guard let folder = target.homeFolder,
              let targetRoot = CLIAccountSwitch.readJSON(at: ExtraAccountStore.grokHome(folder: folder).appendingPathComponent("auth.json")) else {
            throw CLIAccountSwitch.SwitchError.message("找不到这个账号保存的凭据，请重新添加（Saved credentials not found）")
        }
        let targetRecords = targetRoot.filter { CLIAccountSwitch.isGrokFirstParty($0.key) }
        guard !targetRecords.isEmpty else {
            throw CLIAccountSwitch.SwitchError.message("这个账号没有 xAI 官方登录记录，请重新添加（No xAI sign-in found）")
        }

        // 1. 本机原来的官方账号记录存进新的独立 GROK_HOME,作为其他账号。
        let authURL = CLIAccountSwitch.grokAuthFile
        if let data = try? Data(contentsOf: authURL) { CLIAccountSwitch.backup(data, name: "grok-auth.json") }
        let currentRoot = CLIAccountSwitch.readJSON(at: authURL) ?? [:]
        let currentRecords = currentRoot.filter { CLIAccountSwitch.isGrokFirstParty($0.key) }
        var savedOldId: String?
        if !currentRecords.isEmpty, let local = try? GrokAccount.load(), "grok:" + local.identity != target.id {
            let home = try ExtraAccountStore.makeGrokHome()
            do {
                try CLIAccountSwitch.writeSecureJSON(currentRecords, to: home.url.appendingPathComponent("auth.json"))
                try upsertExtraAccount(ExtraAccount(
                    id: "grok:" + local.identity, provider: .grok, alias: "", email: local.email, plan: grokPlan,
                    visibleInPopover: target.visibleInPopover, addedAt: Date(), homeFolder: home.folder,
                    showInMenuBar: target.showInMenuBar, showInFloating: target.showInFloating
                ))
                savedOldId = "grok:" + local.identity
            } catch {
                ExtraAccountStore.removeGrokHome(folder: home.folder)
                throw error
            }
        }

        // 2. ~/.grok/auth.json:换成目标账号的官方记录，自定义 provider 的记录保留。
        var next = currentRoot.filter { !CLIAccountSwitch.isGrokFirstParty($0.key) }
        next.merge(targetRecords) { _, new in new }
        try CLIAccountSwitch.writeSecureJSON(next, to: authURL)

        // 3. 目标账号成为本机账号;重新拉一次额度(身份变化时会清掉旧结果)。
        let seed = extraQuotas[target.id]
        let oldSnapshot = grokQuota
        removeExtraAccount(id: target.id)
        if let savedOldId, let oldSnapshot { storeExtraQuota(id: savedOldId, snapshot: oldSnapshot) }
        await loadGrokQuota(reason: .userInitiated)
        if grokQuota == nil, let seed { grokQuota = seed }
    }

    /// 统一处理：同一时间只做一次切换、本机账号曾被「删除」时恢复显示、结果提示。
    private func performSwitch(id: String, provider: AccountProvider, label: String,
                               _ body: @escaping () async throws -> Void) async {
        guard switchingAccountId == nil else { return }
        switchingAccountId = id
        defer { switchingAccountId = nil }
        let wasRemoved = isLocalAccountRemoved(provider)
        do {
            try await body()
            if wasRemoved {
                SettingsStore.shared.removedLocalAccounts.removeValue(forKey: provider.rawValue)
                setLocalAccountEnabled(provider, true)
            }
            FloatingPanelController.shared.sync()
            accountSwitchNotice = AccountSwitchNotice(
                text: tr("The \(provider.title) CLI now uses \(label). Restart sessions that are already running.",
                         "本机 \(provider.title) CLI 已切换到 \(label)。已在运行的会话需重启后生效。"),
                isError: false
            )
        } catch {
            accountSwitchNotice = AccountSwitchNotice(
                text: tr("Couldn't switch: \(error.localizedDescription)", "切换失败：\(error.localizedDescription)"),
                isError: true
            )
        }
    }

    /// 等本机 / 目标账号正在进行的刷新结束(最多 5 秒),避免刷新写回的旧 token 覆盖刚切换的凭据。
    private func waitWhileRefreshing(_ busy: () -> Bool) async {
        for _ in 0..<50 {
            guard busy() else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Extra Claude / Grok accounts

    func reloadExtraAccounts() {
        extraAccounts = ExtraAccountStore.loadAll()
        // Google 账号的 Antigravity 池存在 id#3p 下，也算在用。
        let alive = Set(extraAccounts.map(\.id) + extraAccounts.filter { $0.provider == .google }.map(\.antigravityQuotaKey))
        extraQuotas = extraQuotas.filter { alive.contains($0.key) }
        extraErrors = extraErrors.filter { alive.contains($0.key) }
        extraRefreshStates = extraRefreshStates.filter { alive.contains($0.key) }
        if let cache = quotaCache.extra {
            let kept = cache.filter { alive.contains($0.key) }
            if kept.count != cache.count {
                quotaCache.extra = kept.isEmpty ? nil : kept
                saveQuotaCache()
            }
        }
    }

    /// 某服务的其他账号。和本机 CLI 正在用的是同一个账号的(切换后旧副本、或手动导入了本机账号)不列出，
    /// 由本机账号那一行代表。
    func extraAccounts(for provider: ExtraProvider) -> [ExtraAccount] {
        extraAccounts.filter { $0.provider == provider && !extraAccountMirrorsLocal($0) }
    }

    /// 其他 Codex 账号(同样去掉和本机账号相同的那个)。
    var otherCodexAccounts: [ImportedCodexAccount] {
        importedCodexAccounts.filter { !importedCodexAccountMirrorsPrimary($0) }
    }

    private func extraAccountMirrorsLocal(_ account: ExtraAccount) -> Bool {
        switch account.provider {
        case .claude:
            guard let local = claudeAccount?.email, let email = account.email else { return false }
            return local.caseInsensitiveCompare(email) == .orderedSame
        case .grok:
            guard let local = grokAccount?.identity else { return false }
            return account.id == "grok:" + local
        case .google:
            guard let local = googleEmail, let email = account.email else { return false }
            return local.caseInsensitiveCompare(email) == .orderedSame
        }
    }

    // MARK: - Other accounts in the menu bar / floating window

    /// 菜单栏 / 悬浮窗里显示的一个其他账号。
    struct OtherAccountQuota: Identifiable {
        let id: String
        let app: UsageApp
        /// 邮箱 @ 前的部分(或别名),悬浮窗多账号时用来区分。
        let name: String
        let snapshot: QuotaSnapshot?
    }

    /// 某服务里勾选了「菜单栏」(menuBar = true)或「悬浮窗」(false)且已启用的其他账号，按设置页顺序。
    func otherAccountsShown(for app: UsageApp, inMenuBar: Bool) -> [OtherAccountQuota] {
        func shortName(alias: String, email: String?, fallback: String) -> String {
            if !alias.isEmpty { return alias }
            if let email, !email.isEmpty { return email.components(separatedBy: "@").first ?? email }
            return fallback
        }
        switch app {
        case .codex:
            return otherCodexAccounts
                .filter { $0.visibleInPopover && ((inMenuBar ? $0.showInMenuBar : $0.showInFloating) ?? false) }
                .map { OtherAccountQuota(id: $0.id, app: .codex,
                                         name: shortName(alias: $0.alias, email: $0.email, fallback: "Codex"),
                                         snapshot: importedCodexQuotas[$0.id]) }
        case .claude, .grok:
            return extraAccounts(for: app == .claude ? .claude : .grok)
                .filter { $0.visibleInPopover && ((inMenuBar ? $0.showInMenuBar : $0.showInFloating) ?? false) }
                .map { OtherAccountQuota(id: $0.id, app: app,
                                         name: shortName(alias: $0.alias, email: $0.email, fallback: app == .claude ? "Claude" : "Grok"),
                                         snapshot: extraQuotas[$0.id]) }
        case .gemini:
            // 其他 Google 账号的 Gemini 池也只算在 Antigravity 里。
            return []
        case .agy:
            return extraAccounts(for: .google)
                .filter { $0.visibleInPopover && ((inMenuBar ? $0.showInMenuBar : $0.showInFloating) ?? false) }
                .map { OtherAccountQuota(id: $0.antigravityQuotaKey, app: app,
                                         name: shortName(alias: $0.alias, email: $0.email, fallback: "Google"),
                                         snapshot: antigravityQuota(for: $0)) }
        case .grokBot:
            // Grok Bot 只能读本机 app 的登录。
            return []
        }
    }

    /// 其他 Google 账号的 Antigravity 额度(两个池子合在一起)。
    func antigravityQuota(for account: ExtraAccount) -> QuotaSnapshot? {
        QuotaPool.antigravity(gemini: extraQuotas[account.id], thirdParty: extraQuotas[account.antigravityQuotaKey])
    }

    /// 本机账号的额度快照(按服务)。
    func localQuota(for app: UsageApp) -> QuotaSnapshot? {
        switch app {
        case .codex: return codexQuota
        case .claude: return claudeQuota
        case .grok: return grokQuota
        case .grokBot: return grokBotQuota
        // Gemini.app 的额度未接通(geminiQuota 是 agy 的 Gemini 池，只用于 Antigravity)。
        case .gemini: return GoogleQuotaClient.isGeminiAppConnected ? geminiQuota : nil
        // Antigravity 显示 agy 的两个池子(Gemini 池 + Claude·GPT 池)。
        case .agy: return QuotaPool.antigravity(gemini: geminiQuota, thirdParty: agyQuota)
        }
    }

    func updateExtraAccount(id: String, mutate: (inout ExtraAccount) -> Void) {
        var list = ExtraAccountStore.loadAll()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[idx])
        do { try ExtraAccountStore.saveAll(list) } catch {
            print("[extra-account] save metadata failed: \(error)")
        }
        reloadExtraAccounts()
    }

    func removeExtraAccount(id: String) {
        let list = ExtraAccountStore.loadAll()
        if let account = list.first(where: { $0.id == id }) {
            switch account.provider {
            case .claude: ExtraAccountStore.deleteClaudeTokens(id: id)
            case .grok: if let folder = account.homeFolder { ExtraAccountStore.removeGrokHome(folder: folder) }
            case .google: if let folder = account.homeFolder { ExtraAccountStore.removeAgyHome(folder: folder) }
            }
        }
        do { try ExtraAccountStore.saveAll(list.filter { $0.id != id }) } catch {
            print("[extra-account] delete failed: \(error)")
        }
        var cache = quotaCache.extra ?? [:]
        cache.removeValue(forKey: id)
        cache.removeValue(forKey: id + "#3p")
        quotaCache.extra = cache.isEmpty ? nil : cache
        saveQuotaCache()
        reloadExtraAccounts()
    }

    /// 新增或覆盖(同 id 覆盖凭据与元数据，保留别名和显示开关)。
    private func upsertExtraAccount(_ account: ExtraAccount) throws {
        var list = ExtraAccountStore.loadAll()
        if let idx = list.firstIndex(where: { $0.id == account.id }) {
            let old = list[idx]
            if old.provider == .grok, let oldFolder = old.homeFolder, oldFolder != account.homeFolder {
                ExtraAccountStore.removeGrokHome(folder: oldFolder)
            }
            if old.provider == .google, let oldFolder = old.homeFolder, oldFolder != account.homeFolder {
                ExtraAccountStore.removeAgyHome(folder: oldFolder)
            }
            var merged = account
            merged.alias = old.alias
            merged.visibleInPopover = old.visibleInPopover
            merged.addedAt = old.addedAt
            list[idx] = merged
        } else {
            list.append(account)
        }
        try ExtraAccountStore.saveAll(list)
        reloadExtraAccounts()
    }

    // MARK: Add: Claude

    /// 粘贴 `.credentials.json` 添加 Claude 账号。返回显示名。
    @discardableResult
    func addExtraClaude(pasted text: String) async throws -> String {
        let parsed = try ExtraAccountPaste.parseClaude(text).get()
        return try await addExtraClaude(parsed: parsed, emailHint: nil)
    }

    private func addExtraClaude(parsed: ExtraAccountPaste.ClaudeParsed, emailHint: String?) async throws -> String {
        var email = emailHint ?? parsed.email
        var plan = parsed.plan
        // 资料接口补齐邮箱 / 订阅，并取订阅开始日(推算续费日)。
        let profile = await ClaudeProfileClient.fetch(accessToken: parsed.tokens.accessToken)
        email = email ?? profile?.email
        plan = plan ?? profile?.plan
        if let email, let primary = claudeAccount?.email, email.caseInsensitiveCompare(primary) == .orderedSame {
            throw AddAccountError.alreadyOnThisMac
        }
        let id = "claude:" + (email?.lowercased() ?? UUID().uuidString.lowercased())
        try ExtraAccountStore.saveClaudeTokens(parsed.tokens, id: id)
        let account = ExtraAccount(id: id, provider: .claude, alias: "", email: email, plan: plan,
                                   visibleInPopover: true, addedAt: Date(), homeFolder: nil,
                                   subscriptionStartedAt: profile?.subscriptionStartedAt)
        try upsertExtraAccount(account)
        if profile != nil { extraPlanFetchedAt[id] = Date() }
        Task { await loadExtraQuota(account: account, reason: .userInitiated) }
        return account.displayName
    }

    // MARK: Add: Grok

    /// 粘贴 `auth.json` 添加 Grok 账号:写入新的独立 GROK_HOME。返回显示名。
    @discardableResult
    func addExtraGrok(pasted text: String) async throws -> String {
        let data = try ExtraAccountPaste.validateGrokAuth(text).get()
        let home = try ExtraAccountStore.makeGrokHome()
        let file = home.url.appendingPathComponent("auth.json")
        do {
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return try await addExtraGrok(folder: home.folder)
        } catch {
            ExtraAccountStore.removeGrokHome(folder: home.folder)
            throw error
        }
    }

    private func addExtraGrok(folder: String) async throws -> String {
        let home = ExtraAccountStore.grokHome(folder: folder)
        let account = try GrokAccount.load(home: home)
        if let primary = grokAccount, primary.identity == account.identity {
            throw AddAccountError.alreadyOnThisMac
        }
        let plan = await GrokQuotaClient.fetchPlan(account: account)
        let extra = ExtraAccount(id: "grok:" + account.identity, provider: .grok, alias: "", email: account.email,
                                 plan: plan, visibleInPopover: true, addedAt: Date(), homeFolder: folder)
        try upsertExtraAccount(extra)
        if plan != nil { extraPlanFetchedAt[extra.id] = Date() }
        Task { await loadExtraQuota(account: extra, reason: .userInitiated) }
        return extra.displayName
    }

    // MARK: Add: from browser login

    /// 官方 CLI 在独立目录登录成功后，从该目录导入凭据。返回显示名。
    @discardableResult
    func importLoggedIn(session: CLILoginSession) async throws -> String {
        switch session.provider {
        case .codex:
            defer { session.cleanup() }
            let text = try String(contentsOf: session.home.appendingPathComponent("auth.json"), encoding: .utf8)
            let parsed: [ImportedCodexPaste.Parsed]
            switch ImportedCodexPaste.parseAny(text) {
            case .success(let list): parsed = list
            case .failure(let failure): throw AddAccountError.message(failure.description)
            }
            for p in parsed {
                try upsertImportedCodexAccount(from: p, alias: "", visibleInPopover: true)
            }
            Task { await loadAllImportedCodexQuotas(reason: .userInitiated) }
            return parsed.first?.email.map { $0.components(separatedBy: "@").first ?? $0 } ?? "Codex"
        case .claude:
            defer { session.cleanup() }
            guard let credentials = ClaudeIsolatedLogin.readCredentials(configDir: session.home) else {
                throw AddAccountError.message("已登录，但读不到新的 Claude 凭据，请改用粘贴凭据（Signed in, but couldn't read the new Claude credentials）")
            }
            defer { ClaudeIsolatedLogin.deleteKeychainItems(configDir: session.home) }
            let parsed = try ExtraAccountPaste.parseClaude(credentials).get()
            return try await addExtraClaude(parsed: parsed, emailHint: ClaudeIsolatedLogin.email(configDir: session.home))
        case .grok:
            guard let folder = session.grokFolder else { throw AddAccountError.message("missing grok home") }
            do {
                let name = try await addExtraGrok(folder: folder)
                session.cleanup(keepGrokHome: true)
                return name
            } catch {
                session.cleanup()
                throw error
            }
        }
    }

    // MARK: Quota refresh

    private func loadAllExtraQuotas(reason: QuotaRefreshReason) async {
        let visible = extraAccounts.filter(\.visibleInPopover)
        guard !visible.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in visible {
                group.addTask { [weak self] in
                    await self?.loadExtraQuota(account: account, reason: reason)
                }
            }
        }
    }

    private func loadExtraQuota(account: ExtraAccount, reason: QuotaRefreshReason) async {
        let now = Date()
        var state = extraRefreshStates[account.id] ?? QuotaRefreshState()
        guard !state.inFlight else { return }
        if let until = state.backoffUntil, until > now { return }
        if reason == .periodic, let last = state.lastSuccessAt, now.timeIntervalSince(last) < minSuccessInterval { return }
        if account.provider == .google, reason == .periodic, let last = state.lastAttemptAt,
           now.timeIntervalSince(last) < googleMinPeriodicInterval { return }
        state.inFlight = true
        state.lastAttemptAt = now
        extraRefreshStates[account.id] = state
        defer { extraRefreshStates[account.id]?.inFlight = false }

        do {
            let snapshot: QuotaSnapshot
            switch account.provider {
            case .claude: snapshot = try await fetchExtraClaudeQuota(id: account.id)
            case .grok: snapshot = try await fetchExtraGrokQuota(account: account)
            case .google:
                try await loadExtraGoogleQuota(account: account)
                return
            }
            storeExtraQuota(id: account.id, snapshot: snapshot)
            recordExtraQuotaHistory(account: account, snapshot: snapshot, sampledAt: Date())
        } catch {
            let message = (error as? QuotaError)?.description ?? error.localizedDescription
            extraErrors[account.id] = message
            var failed = extraRefreshStates[account.id] ?? QuotaRefreshState()
            failed.lastError = message
            if (error as? QuotaError)?.isRateLimited == true {
                failed.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
            }
            extraRefreshStates[account.id] = failed
        }
    }

    private func fetchExtraClaudeQuota(id: String) async throws -> QuotaSnapshot {
        guard var tokens = ExtraAccountStore.loadClaudeTokens(id: id) else {
            throw QuotaError.missingToken
        }
        func renew() async throws {
            guard let refresh = tokens.refreshToken else { throw QuotaError.tokenRevoked }
            let renewed = try await ClaudeTokenRefresher.refreshExtraAccount(using: refresh)
            // 只换 token,保留切换账号时存下的 credentialJSON / oauthAccountJSON。
            tokens.accessToken = renewed.accessToken
            tokens.refreshToken = renewed.refreshToken
            tokens.expiresAt = renewed.expiresAt
            try ExtraAccountStore.saveClaudeTokens(tokens, id: id)
        }
        if let expires = tokens.expiresAt, expires.timeIntervalSinceNow < 300 { try await renew() }
        var result = await ClaudeQuotaClient.fetch(accessToken: tokens.accessToken)
        if case .failure(let error) = result, error.httpStatusCode == 401 {
            try await renew()
            result = await ClaudeQuotaClient.fetch(accessToken: tokens.accessToken)
        }
        let snapshot = try result.get()
        // 每 6 小时顺带更新一次订阅等级和订阅开始日(续费日)。
        if extraPlanFetchedAt[id].map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true,
           let profile = await ClaudeProfileClient.fetch(accessToken: tokens.accessToken) {
            extraPlanFetchedAt[id] = Date()
            if let current = extraAccounts.first(where: { $0.id == id }),
               current.plan != (profile.plan ?? current.plan) || current.subscriptionStartedAt != profile.subscriptionStartedAt {
                updateExtraAccount(id: id) {
                    $0.plan = profile.plan ?? $0.plan
                    $0.subscriptionStartedAt = profile.subscriptionStartedAt
                }
            }
        }
        return snapshot
    }

    private func fetchExtraGrokQuota(account extra: ExtraAccount) async throws -> QuotaSnapshot {
        guard let folder = extra.homeFolder else { throw QuotaError.missingToken }
        let home = ExtraAccountStore.grokHome(folder: folder)
        var account = try GrokAccount.load(home: home)
        if let expires = account.expiresAt, expires.timeIntervalSinceNow < 300 {
            guard await GrokQuotaClient.refreshCredentials(grokHome: home) else {
                throw QuotaError.tokenRefreshFailed("Grok token renewal failed")
            }
            account = try GrokAccount.load(home: home)
        }
        var result = await GrokQuotaClient.fetch(account: account)
        if case .failure(let error) = result, error.httpStatusCode == 401,
           await GrokQuotaClient.refreshCredentials(grokHome: home) {
            account = try GrokAccount.load(home: home)
            result = await GrokQuotaClient.fetch(account: account)
        }
        let snapshot = try result.get()
        if extraPlanFetchedAt[extra.id].map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true,
           let plan = await GrokQuotaClient.fetchPlan(account: account) {
            extraPlanFetchedAt[extra.id] = Date()
            if plan != extra.plan { updateExtraAccount(id: extra.id) { $0.plan = plan } }
        }
        return snapshot
    }

    /// 其他 Google 账号：用它自己的 agy 目录跑一次 `/usage`,Gemini 池存在 id 下，Antigravity 池存在 id#3p 下。
    private func loadExtraGoogleQuota(account: ExtraAccount) async throws {
        guard let folder = account.homeFolder else { throw QuotaError.missingToken }
        let result = try await GoogleQuotaClient.fetch(home: ExtraAccountStore.agyHome(folder: folder)).get()
        if let gemini = result.gemini { storeExtraQuota(id: account.id, snapshot: gemini) }
        recordAgyQuotaHistory(gemini: result.gemini, thirdParty: result.agy,
                              geminiKey: QuotaHistoryAccountKey.extra(id: account.id),
                              thirdPartyKey: QuotaHistoryAccountKey.extra(id: account.antigravityQuotaKey), kind: .agyExtra)
        if let agy = result.agy {
            storeExtraQuota(id: account.antigravityQuotaKey, snapshot: agy)
            // 刷新状态统一记在账号 id 上。
            if result.gemini == nil { extraRefreshStates[account.id] = extraRefreshStates[account.antigravityQuotaKey] }
        }
    }

    /// 在终端登录完独立 agy 目录后添加 Google 账号。登录没完成时抛出可读的错误，目录保留以便重试。
    func addExtraGoogle(folder: String) async throws -> String {
        let home = ExtraAccountStore.agyHome(folder: folder)
        let result: GoogleQuotaClient.Result
        switch await GoogleQuotaClient.fetch(home: home) {
        case .success(let value): result = value
        case .failure(let error):
            if case .missingToken = error {
                throw AddAccountError.message(tr("Not signed in yet. Finish signing in in Terminal, then try again.",
                                                 "还没有登录成功：请在终端里完成登录后再点「完成添加」。"))
            }
            throw AddAccountError.message(error.description)
        }
        let email = GoogleQuotaClient.signedInEmail(home: home)
        if let email, let local = googleEmail, email.caseInsensitiveCompare(local) == .orderedSame {
            throw AddAccountError.message(tr("This is the Google account agy on this Mac already uses.",
                                             "这就是本机 agy 正在使用的 Google 账号，不需要重复添加。"))
        }
        let id = "google:" + (email?.lowercased() ?? folder)
        let extra = ExtraAccount(id: id, provider: .google, alias: "", email: email, plan: result.plan,
                                 visibleInPopover: true, addedAt: Date(), homeFolder: folder)
        try upsertExtraAccount(extra)
        if let gemini = result.gemini { storeExtraQuota(id: id, snapshot: gemini) }
        if let agy = result.agy { storeExtraQuota(id: extra.antigravityQuotaKey, snapshot: agy) }
        try? FileManager.default.removeItem(at: home.appendingPathComponent("yybar-agy-login.command"))
        return extra.displayName
    }

    private func storeExtraQuota(id: String, snapshot: QuotaSnapshot) {
        let now = Date()
        extraQuotas[id] = snapshot
        extraErrors[id] = nil
        var state = extraRefreshStates[id] ?? QuotaRefreshState()
        state.lastSuccessAt = now
        state.lastError = nil
        state.backoffUntil = nil
        state.source = .api
        extraRefreshStates[id] = state
        var cache = quotaCache.extra ?? [:]
        cache[id] = QuotaCacheRecord(snapshot: snapshot, source: .api, updatedAt: now)
        quotaCache.extra = cache
        saveQuotaCache()
    }

    // MARK: - Imported Codex accounts

    /// 从磁盘读取元数据列表,移除内存中已经不存在的账号的运行时状态。
    /// 设置页增删账号后由调用方触发。
    func reloadImportedCodexAccounts() {
        importedCodexAccounts = ImportedCodexStore.loadAll()
        let alive = Set(importedCodexAccounts.map(\.id))
        importedCodexQuotas = importedCodexQuotas.filter { alive.contains($0.key) }
        importedCodexSources = importedCodexSources.filter { alive.contains($0.key) }
        importedCodexErrors = importedCodexErrors.filter { alive.contains($0.key) }
        importedCodexRefreshStates = importedCodexRefreshStates.filter { alive.contains($0.key) }
        var importedCache = quotaCache.importedCodex ?? [:]
        importedCache = importedCache.filter { alive.contains($0.key) }
        quotaCache.importedCodex = importedCache.isEmpty ? nil : importedCache
        saveQuotaCache()
    }

    /// 增 / 改:同 account_id 静默覆盖 token,元数据按入参更新;新增时落到列表末尾。
    func upsertImportedCodexAccount(
        from parsed: ImportedCodexPaste.Parsed,
        alias: String,
        visibleInPopover: Bool
    ) throws {
        let tokens = ImportedCodexTokens(
            accessToken: parsed.accessToken,
            refreshToken: parsed.refreshToken,
            idToken: parsed.idToken
        )
        try ImportedCodexStore.saveTokens(tokens, accountId: parsed.id)

        var list = ImportedCodexStore.loadAll()
        if let idx = list.firstIndex(where: { $0.id == parsed.id }) {
            var existing = list[idx]
            existing.alias = alias
            existing.email = parsed.email ?? existing.email
            existing.planType = parsed.planType ?? existing.planType
            existing.subscriptionActiveUntil = parsed.subscriptionActiveUntil ?? existing.subscriptionActiveUntil
            existing.visibleInPopover = visibleInPopover
            list[idx] = existing
        } else {
            list.append(ImportedCodexAccount(
                id: parsed.id,
                alias: alias,
                email: parsed.email,
                planType: parsed.planType,
                visibleInPopover: visibleInPopover,
                addedAt: Date(),
                subscriptionActiveUntil: parsed.subscriptionActiveUntil
            ))
        }
        try ImportedCodexStore.saveAll(list)
        reloadImportedCodexAccounts()
    }

    /// 仅更新元数据(别名、颜色、显示开关),不动 token。
    func updateImportedCodexMetadata(id: String, mutate: (inout ImportedCodexAccount) -> Void) {
        var list = ImportedCodexStore.loadAll()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        mutate(&list[idx])
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] save metadata failed: \(error)")
            return
        }
        reloadImportedCodexAccounts()
    }

    /// 按给定 id 顺序重排导入账号(忽略不存在的 id,缺失的追加到末尾)。
    func reorderImportedCodexAccounts(orderedIds: [String]) {
        let list = ImportedCodexStore.loadAll()
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        var seen = Set<String>()
        var reordered: [ImportedCodexAccount] = []
        for id in orderedIds {
            guard let acc = byId[id], !seen.contains(id) else { continue }
            reordered.append(acc)
            seen.insert(id)
        }
        for acc in list where !seen.contains(acc.id) {
            reordered.append(acc)
        }
        guard reordered.map(\.id) != list.map(\.id) else { return }
        do { try ImportedCodexStore.saveAll(reordered) } catch {
            print("[imported-codex] reorder failed: \(error)")
            return
        }
        reloadImportedCodexAccounts()
    }

    /// 删除:同步清 Keychain、元数据、运行时状态与缓存。
    func removeImportedCodexAccount(id: String) {
        ImportedCodexStore.deleteTokens(accountId: id)
        let list = ImportedCodexStore.loadAll().filter { $0.id != id }
        do { try ImportedCodexStore.saveAll(list) } catch {
            print("[imported-codex] delete failed: \(error)")
        }
        reloadImportedCodexAccounts()
    }

    func importedCodexQuota(for account: ImportedCodexAccount) -> QuotaSnapshot? {
        if importedCodexAccountMirrorsPrimary(account) { return codexQuota }
        return importedCodexQuotas[account.id]
    }

    func importedCodexError(for account: ImportedCodexAccount) -> String? {
        if importedCodexAccountMirrorsPrimary(account) { return codexQuotaError }
        return importedCodexErrors[account.id]
    }

    func importedCodexRefreshState(for account: ImportedCodexAccount) -> QuotaRefreshState {
        if importedCodexAccountMirrorsPrimary(account) { return codexRefreshState }
        return importedCodexRefreshStates[account.id] ?? QuotaRefreshState()
    }

    /// 对所有 `visibleInPopover` 为 true 的导入账号并发拉一遍配额,并发上限 3。
    private func loadAllImportedCodexQuotas(reason: QuotaRefreshReason) async {
        let visible = importedCodexAccounts.filter(\.visibleInPopover)
        guard !visible.isEmpty else { return }
        let maxConcurrent = 3
        var index = 0
        while index < visible.count {
            let batch = Array(visible[index..<min(index + maxConcurrent, visible.count)])
            await withTaskGroup(of: Void.self) { group in
                for account in batch {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.loadImportedCodexQuota(account: account, reason: reason)
                    }
                }
            }
            index += maxConcurrent
        }
    }

    private func loadImportedCodexQuota(account: ImportedCodexAccount, reason: QuotaRefreshReason) async {
        if importedCodexAccountMirrorsPrimary(account) {
            mirrorPrimaryCodexQuota(toImportedId: account.id)
            syncPrimaryCodexTokensToImported(id: account.id)
            return
        }

        guard beginImportedCodexRefresh(id: account.id, reason: reason) else { return }
        defer { importedCodexRefreshStates[account.id]?.inFlight = false }

        guard let tokens = ImportedCodexStore.loadTokens(accountId: account.id) else {
            markImportedCodexFailure(id: account.id, message: "missing saved tokens")
            return
        }
        // id_token 续期后付费周期结束日可能更新，同步到元数据(用于显示续费日)。
        if let until = ImportedCodexPaste.subscriptionActiveUntil(idToken: tokens.idToken), until != account.subscriptionActiveUntil {
            updateImportedCodexMetadata(id: account.id) { $0.subscriptionActiveUntil = until }
        }
        let refreshed = await CodexTokenRefresher.ensureFreshAccessToken(
            currentAccessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            writeBack: .importedAccount(id: account.id)
        )
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
        case .failure(let err):
            markImportedCodexFailure(id: account.id, message: err.description, error: err)
            return
        }
        let result = await CodexQuotaClient.fetch(accessToken: activeToken, accountId: account.chatgptAccountId)
        switch result {
        case .success(let snapshot):
            storeImportedCodex(id: account.id, snapshot: snapshot, source: .api)
        case .failure(let err):
            markImportedCodexFailure(id: account.id, message: err.description, error: err)
        }
    }

    private func importedCodexAccountMirrorsPrimary(_ account: ImportedCodexAccount) -> Bool {
        guard let primary = codexAccount,
              let primaryAccountId = nonEmpty(primary.accountId),
              let importedAccountId = nonEmpty(account.chatgptAccountId),
              primaryAccountId == importedAccountId
        else { return false }

        let primaryUserId = nonEmpty(primary.chatgptUserId)
        let importedUserId = importedCodexUserId(from: account)
        if let primaryUserId, let importedUserId {
            return primaryUserId == importedUserId
        }
        return true
    }

    private func importedCodexUserId(from account: ImportedCodexAccount) -> String? {
        guard let colon = account.id.firstIndex(of: ":") else { return nil }
        let tail = String(account.id[account.id.index(after: colon)...])
        return nonEmpty(tail)
    }

    private func mirrorPrimaryCodexQuota(toImportedId id: String) {
        importedCodexQuotas[id] = codexQuota
        importedCodexSources[id] = codexQuotaSource
        importedCodexErrors[id] = codexQuotaError
        importedCodexRefreshStates[id] = codexRefreshState

        if let snapshot = codexQuota, codexQuotaSource == .api {
            recordImportedCodexQuotaHistory(
                id: id,
                snapshot: snapshot,
                sampledAt: codexRefreshState.lastSuccessAt ?? Date()
            )
        }

        var cache = quotaCache.importedCodex ?? [:]
        if cache.removeValue(forKey: id) != nil {
            quotaCache.importedCodex = cache.isEmpty ? nil : cache
            saveQuotaCache()
        }
    }

    private func syncPrimaryCodexTokensToImported(id: String) {
        guard let account = codexAccount,
              let accessToken = nonEmpty(account.accessToken)
        else { return }
        let tokens = ImportedCodexTokens(
            accessToken: accessToken,
            refreshToken: nonEmpty(account.refreshToken),
            idToken: nonEmpty(account.idToken)
        )
        do {
            try ImportedCodexStore.saveTokens(tokens, accountId: id)
        } catch {
            print("[imported-codex] sync primary tokens failed: \(error)")
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func beginImportedCodexRefresh(id: String, reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        guard !state.inFlight else { return false }
        if let backoffUntil = state.backoffUntil, backoffUntil > now {
            state.lastError = backoffMessage(until: backoffUntil)
            importedCodexRefreshStates[id] = state
            importedCodexErrors[id] = state.lastError
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = state.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        state.inFlight = true
        state.lastAttemptAt = now
        importedCodexRefreshStates[id] = state
        return true
    }

    private func storeImportedCodex(id: String, snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        importedCodexQuotas[id] = snapshot
        importedCodexSources[id] = source
        importedCodexErrors[id] = nil
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastSuccessAt = updatedAt
        state.lastError = nil
        state.backoffUntil = nil
        state.source = source
        importedCodexRefreshStates[id] = state

        var cache = quotaCache.importedCodex ?? [:]
        cache[id] = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        quotaCache.importedCodex = cache
        saveQuotaCache()
        recordImportedCodexQuotaHistory(id: id, snapshot: snapshot, sampledAt: updatedAt)
    }

    private func markImportedCodexFailure(id: String, message: String, error: QuotaError? = nil) {
        importedCodexErrors[id] = message
        var state = importedCodexRefreshStates[id] ?? QuotaRefreshState()
        state.lastError = message
        if error?.isRateLimited == true {
            state.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
        importedCodexRefreshStates[id] = state
    }

    private func saveQuotaCache() {
        do {
            try QuotaCache.save(quotaCache)
        } catch {
            print("[QuotaCache 额度缓存] 写盘失败 save failed: \(error)")
        }
    }

    private func recordCodexQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexPrimary(accountId: codexAccount?.accountId),
            app: .codex,
            kind: .codexPrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordClaudeQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.claudePrimary(),
            app: .claude,
            kind: .claudePrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordGrokQuotaHistory(snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.grokPrimary(),
            app: .grok,
            kind: .grokPrimary,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordExtraQuotaHistory(account: ExtraAccount, snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.extra(id: account.id),
            app: account.provider == .claude ? .claude : .grok,
            kind: account.provider == .claude ? .claudeExtra : .grokExtra,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    /// Antigravity 的两个池子各记一条(都算在 Antigravity 下)。
    private func recordAgyQuotaHistory(gemini: QuotaSnapshot?, thirdParty: QuotaSnapshot?,
                                       geminiKey: String, thirdPartyKey: String, kind: QuotaHistoryAccountKind) {
        let now = Date()
        if let gemini { recordQuotaHistory(accountKey: geminiKey, app: .agy, kind: kind, snapshot: gemini, sampledAt: now) }
        if let thirdParty { recordQuotaHistory(accountKey: thirdPartyKey, app: .agy, kind: kind, snapshot: thirdParty, sampledAt: now) }
    }

    private func recordImportedCodexQuotaHistory(id: String, snapshot: QuotaSnapshot, sampledAt: Date) {
        recordQuotaHistory(
            accountKey: QuotaHistoryAccountKey.codexImported(id: id),
            app: .codex,
            kind: .codexImported,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
    }

    private func recordQuotaHistory(
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date
    ) {
        // 5H 与周窗口各记一份(周窗口 key 带 #wk);快照里没有的窗口自动跳过。
        var next = QuotaHistoryStore.record(
            payload: quotaHistory,
            accountKey: accountKey,
            app: app,
            kind: kind,
            snapshot: snapshot,
            sampledAt: sampledAt
        )
        next = QuotaHistoryStore.record(
            payload: next,
            accountKey: QuotaHistoryAccountKey.weekly(accountKey),
            app: app,
            kind: kind,
            snapshot: snapshot,
            sampledAt: sampledAt,
            window: .weekly
        )
        guard next != quotaHistory else { return }
        quotaHistory = next
        saveQuotaHistory()
    }

    private func saveQuotaHistory() {
        do {
            try QuotaHistoryStore.save(quotaHistory)
        } catch {
            print("[QuotaHistory 额度历史] 写盘失败 save failed: \(error)")
        }
    }

    private func loadCodex() async {
        do {
            let next = try await Task.detached(priority: .utility) {
                try CodexAuth.load()
            }.value
            if codexIdentityChanged(previous: codexAccount, next: next) {
                resetCodexQuotaState()
            }
            self.codexAccount = next
            self.codexError = nil
        } catch {
            self.codexAccount = nil
            self.codexError = "\(error)"
        }
    }

    /// 比较 accountId 优先,缺失时回退到 email。仅当能确认"前后是不同账号"
    /// 时返回 true;previous 为 nil(首次加载)不算变化,避免误清启动缓存。
    private func codexIdentityChanged(previous: CodexAccount?, next: CodexAccount) -> Bool {
        guard let previous else { return false }
        if let a = previous.accountId, let b = next.accountId, !a.isEmpty, !b.isEmpty {
            return a != b
        }
        return previous.email != next.email
    }

    private func resetCodexQuotaState() {
        codexQuota = nil
        codexQuotaSource = nil
        codexQuotaError = nil
        codexRefreshState = QuotaRefreshState()
        quotaCache.codex = nil
        saveQuotaCache()
    }

    /// 没有本地凭据文件、且尚未提示过时,先用一个模态 alert 告诉用户
    /// 接下来会弹出系统 Keychain 授权窗口,避免一上来就被系统弹窗吓到。
    private func maybeShowKeychainPrompt() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        let hasFile = FileManager.default.fileExists(atPath: url.path)
        let settings = SettingsStore.shared
        guard !hasFile, !settings.didShowKeychainPrompt else { return }

        let alert = NSAlert()
        alert.messageText = tr("Allow Keychain Access", "允许访问 Keychain")
        alert.informativeText = tr(
            "yybar reads the Claude credential stored in your macOS Keychain to query your quota. After you continue, macOS will ask for permission — choose \"Always Allow\".",
            "yybar 需要读取 macOS 钥匙串里的 Claude 凭据来查询额度。点击「继续」后会弹出系统授权窗口,请选择「始终允许」。"
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: tr("Continue", "继续"))
        alert.runModal()
        settings.didShowKeychainPrompt = true
    }

    private func loadClaude() async {
        do {
            let next = try await Task.detached(priority: .utility) {
                try ClaudeAuth.load()
            }.value
            if claudeIdentityChanged(previous: claudeAccount, next: next) {
                resetClaudeQuotaState()
            }
            self.claudeAccount = next
            self.claudeError = nil
        } catch {
            self.claudeAccount = nil
            self.claudeError = "\(error)"
        }
    }

    private func claudeIdentityChanged(previous: ClaudeAccount?, next: ClaudeAccount) -> Bool {
        guard let previous else { return false }
        return previous.email != next.email
    }

    private func resetClaudeQuotaState() {
        claudeQuota = nil
        claudeQuotaSource = nil
        claudeQuotaError = nil
        claudeRefreshState = QuotaRefreshState()
        quotaCache.claude = nil
        saveQuotaCache()
    }

    private func loadCodexQuota(reason: QuotaRefreshReason) async {
        guard beginCodexRefresh(reason: reason) else { return }
        defer { codexRefreshState.inFlight = false }

        guard var account = codexAccount else {
            markCodexFailure("no codex account")
            return
        }
        guard let token = account.accessToken else {
            markCodexFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await CodexTokenRefresher.ensureFreshTokens(
            currentAccessToken: token,
            refreshToken: account.refreshToken,
            idToken: account.idToken
        )
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t.accessToken
            account.accessToken = t.accessToken
            account.refreshToken = nonEmpty(t.refreshToken)
            account.idToken = t.idToken
            codexAccount = account
        case .failure(let err):
            markCodexFailure(err.description)
            return
        }
        let result = await CodexQuotaClient.fetch(
            accessToken: activeToken,
            accountId: account.accountId
        )
        switch result {
        case .success(let snapshot):
            storeCodex(snapshot: snapshot, source: .api)
        case .failure(let err):
            markCodexFailure(err.description, error: err)
        }
    }

    func loadGrokQuota(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showGrok, !grokRefreshState.inFlight else { return }
        let now = Date()
        // Honor the same backoff even for manual refresh.
        if let until = grokRefreshState.backoffUntil, until > now { return }
        if reason == .periodic, let last = grokRefreshState.lastSuccessAt,
           now.timeIntervalSince(last) < minSuccessInterval { return }
        grokRefreshState.inFlight = true
        grokRefreshState.lastAttemptAt = now
        defer { grokRefreshState.inFlight = false }
        do {
            var account = try GrokAccount.load()
            if grokAccount?.identity != account.identity {
                grokPlan = nil
                grokPlanFetchedAt = nil
                grokQuota = nil
                grokRefreshState.lastSuccessAt = nil
                grokRefreshState.source = nil
                quotaCache.grok = nil
                quotaCache.grokAccountID = account.identity
                saveQuotaCache()
            }
            grokAccount = account
            if let expires = account.expiresAt, expires.timeIntervalSinceNow < 300 {
                guard await GrokQuotaClient.refreshCredentials() else {
                    throw QuotaError.tokenRefreshFailed("Grok token renewal failed; run grok login")
                }
                account = try GrokAccount.load()
            }
            var result = await GrokQuotaClient.fetch(account: account)
            if case .failure(let error) = result, error.httpStatusCode == 401 {
                if await GrokQuotaClient.refreshCredentials() {
                    account = try GrokAccount.load()
                    result = await GrokQuotaClient.fetch(account: account)
                }
            }
            let snapshot = try result.get()
            // A CLI sign-in may change while a network request is in flight.
            guard try GrokAccount.load().identity == account.identity else {
                grokQuota = nil
                throw QuotaError.transport("Grok account changed; refresh again")
            }
            grokAccount = account
            grokQuota = snapshot
            grokQuotaError = nil
            grokRefreshState.lastError = nil
            grokRefreshState.backoffUntil = nil
            grokRefreshState.lastSuccessAt = snapshot.fetchedAt
            grokRefreshState.source = .api
            recordGrokQuotaHistory(snapshot: snapshot, sampledAt: snapshot.fetchedAt)
            quotaCache.grok = QuotaCacheRecord(snapshot: snapshot, source: .api, updatedAt: snapshot.fetchedAt)
            quotaCache.grokAccountID = account.identity
            saveQuotaCache()
            if grokPlan == nil || (grokPlanFetchedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true) {
                if let plan = await GrokQuotaClient.fetchPlan(account: account) {
                    grokPlan = plan
                    grokPlanFetchedAt = Date()
                }
            }
        } catch {
            let message: String
            if let error = error as? QuotaError {
                if error.isRateLimited {
                    grokRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
                }
                if case .missingToken = error {
                    grokAccount = nil
                    grokQuota = nil
                    quotaCache.grok = nil
                    quotaCache.grokAccountID = nil
                    saveQuotaCache()
                    message = "Grok 未登录，请运行 grok login"
                } else { message = error.description }
            } else { message = error.localizedDescription }
            grokQuotaError = message
            grokRefreshState.lastError = message
        }
    }

    /// Gemini / agy 额度：一次 `agy -p /usage` 同时得到两个池子。失败保留已有快照;429 退避 10 分钟。
    func loadGoogleQuota(reason: QuotaRefreshReason) async {
        let settings = SettingsStore.shared
        guard settings.showGemini || settings.showAgy, !googleRefreshState.inFlight else { return }
        let now = Date()
        if let until = googleRefreshState.backoffUntil, until > now { return }
        if reason == .periodic, let last = googleRefreshState.lastAttemptAt,
           now.timeIntervalSince(last) < googleMinPeriodicInterval { return }
        googleRefreshState.inFlight = true
        googleRefreshState.lastAttemptAt = now
        defer { googleRefreshState.inFlight = false }
        switch await GoogleQuotaClient.fetch() {
        case .success(let result):
            markActivityIfConsumed(.agy, old: agyQuota, new: result.agy)
            // Antigravity 包含 Gemini 池：任一池下降都呼吸。
            markActivityIfConsumed(.agy, old: geminiQuota, new: result.gemini)
            googleEmail = GoogleQuotaClient.signedInEmail(home: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini"))
            googlePlan = result.plan
            if let gemini = result.gemini {
                geminiQuota = gemini
                quotaCache.gemini = QuotaCacheRecord(snapshot: gemini, source: .api, updatedAt: gemini.fetchedAt)
            }
            if let agy = result.agy {
                agyQuota = agy
                quotaCache.agy = QuotaCacheRecord(snapshot: agy, source: .api, updatedAt: agy.fetchedAt)
            }
            saveQuotaCache()
            recordAgyQuotaHistory(gemini: result.gemini, thirdParty: result.agy,
                                  geminiKey: QuotaHistoryAccountKey.agyPrimary(pool: "gemini"),
                                  thirdPartyKey: QuotaHistoryAccountKey.agyPrimary(pool: "3p"), kind: .agyPrimary)
            googleQuotaError = nil
            googleRefreshState.lastError = nil
            googleRefreshState.backoffUntil = nil
            googleRefreshState.lastSuccessAt = Date()
            googleRefreshState.source = .agyCLI
        case .failure(let error):
            if error.isRateLimited {
                googleRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
            }
            let message: String
            if case .missingToken = error {
                message = GoogleQuotaClient.isAgyInstalled
                    ? "agy 未登录，请在终端运行 agy 用 Google 账号登录"
                    : "没有找到 agy CLI(Gemini / Antigravity 额度通过它读取)"
            } else {
                message = error.description
            }
            googleQuotaError = message
            googleRefreshState.lastError = message
        }
    }

    /// Grok Bot:解密本机 Grok Bot app 存的 Cursor token(只读),再查每周额度。失败保留旧快照。
    func loadGrokBotQuota(reason: QuotaRefreshReason) async {
        guard SettingsStore.shared.showGrokBot, GrokBotQuotaClient.isInstalled,
              !grokBotRefreshState.inFlight else { return }
        let now = Date()
        if let until = grokBotRefreshState.backoffUntil, until > now { return }
        if reason == .periodic {
            if grokBotKeychainDenied { return }
            if let last = grokBotRefreshState.lastSuccessAt, now.timeIntervalSince(last) < minSuccessInterval { return }
        }
        grokBotRefreshState.inFlight = true
        grokBotRefreshState.lastAttemptAt = now
        defer { grokBotRefreshState.inFlight = false }

        let key: Data
        if let cached = grokBotKey {
            key = cached
        } else {
            switch await Task.detached(operation: { GrokBotAuth.loadKey() }).value {
            case .success(let loaded):
                key = loaded
                grokBotKey = loaded
                grokBotKeychainDenied = false
            case .failure(.notSignedIn):
                markGrokBotFailure("Grok Bot 未登录，请打开 Grok Bot app 登录")
                return
            case .failure(let error):
                grokBotKeychainDenied = true
                var reason = ""
                if case .keychainDenied(let message) = error { reason = "(\(message))" }
                markGrokBotFailure("读取钥匙串「Grok Bot Safe Storage」被拒绝或取消\(reason)。点刷新会再询问，选「始终允许」后不再弹出")
                return
            }
        }
        let token: String
        switch await Task.detached(operation: { GrokBotAuth.loadToken(key: key) }).value {
        case .success(let value):
            token = value
        case .failure(let error):
            switch error {
            case .notSignedIn:
                markGrokBotFailure("Grok Bot 未登录，请打开 Grok Bot app 登录")
            case .expired:
                markGrokBotFailure("Grok Bot 登录已过期，打开 Grok Bot app 让它续期后再刷新")
            case .noToken(let diagnostics):
                // 钥匙串口令可能变了(重装 / 重新登录),下次重新读。
                grokBotKey = nil
                markGrokBotFailure("没能从 Grok Bot app 的登录里解出 token:\(diagnostics.summary)")
            case .keychainDenied(let message):
                grokBotKey = nil
                markGrokBotFailure("读取钥匙串「Grok Bot Safe Storage」被拒绝或取消(\(message))")
            }
            return
        }
        switch await GrokBotQuotaClient.fetch(accessToken: token) {
        case .success(let snapshot):
            markActivityIfConsumed(.grokBot, old: grokBotQuota, new: snapshot)
            grokBotQuota = snapshot
            quotaCache.grokBot = QuotaCacheRecord(snapshot: snapshot, source: .api, updatedAt: snapshot.fetchedAt)
            saveQuotaCache()
            recordQuotaHistory(accountKey: QuotaHistoryAccountKey.grokBotPrimary(), app: .grokBot,
                               kind: .grokBotPrimary, snapshot: snapshot, sampledAt: snapshot.fetchedAt)
            grokBotQuotaError = nil
            grokBotRefreshState.lastError = nil
            grokBotRefreshState.backoffUntil = nil
            grokBotRefreshState.lastSuccessAt = Date()
            grokBotRefreshState.source = .api
        case .failure(let error):
            if error.isRateLimited {
                grokBotRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
            }
            if error.httpStatusCode == 401 {
                markGrokBotFailure("Grok Bot 登录已过期，打开 Grok Bot app 让它续期后再刷新")
            } else {
                markGrokBotFailure(error.description)
            }
        }
    }

    private func markGrokBotFailure(_ message: String) {
        grokBotQuotaError = message
        grokBotRefreshState.lastError = message
    }

    /// 没有本地会话日志的服务：两次刷新之间剩余减少了(5H 或 WK),就让菜单栏图标呼吸到下次刷新之后。
    private func markActivityIfConsumed(_ app: UsageApp, old: QuotaSnapshot?, new: QuotaSnapshot?) {
        guard let old, let new else { return }
        func dropped(_ a: QuotaWindow?, _ b: QuotaWindow?) -> Bool {
            guard let a, let b else { return false }
            // 新窗口(重置后)不算消耗。
            if let ra = a.resetsAt, let rb = b.resetsAt, rb.timeIntervalSince(ra) > 60 { return false }
            return b.usedPercent - a.usedPercent > 0.05
        }
        guard dropped(old.fiveHour, new.fiveHour) || dropped(old.weekly, new.weekly) else { return }
        let hold = max(180, (SettingsStore.shared.quotaInterval.seconds ?? 120) * 1.5)
        UsageActivityMonitor.shared.markQuotaActivity(app, until: Date().addingTimeInterval(hold))
    }

    private func loadClaudeQuota(reason: QuotaRefreshReason) async {
        guard beginClaudeRefresh(reason: reason) else { return }
        defer { claudeRefreshState.inFlight = false }

        guard var account = claudeAccount else {
            markClaudeFailure("no claude account")
            return
        }
        guard account.accessToken != nil else {
            markClaudeFailure(QuotaError.missingToken.description)
            return
        }
        let refreshed = await ClaudeTokenRefresher.ensureFreshAccessToken(account: &account)
        let activeToken: String
        switch refreshed {
        case .success(let t):
            activeToken = t
            if t != claudeAccount?.accessToken {
                claudeAccount = account
            }
        case .failure(let err):
            markClaudeFailure(err.description, error: err)
            return
        }
        let result = await ClaudeQuotaClient.fetch(accessToken: activeToken)
        switch result {
        case .success(let snapshot):
            storeClaude(snapshot: snapshot, source: .api)
        case .failure(let err):
            markClaudeFailure(err.description, error: err)
            if reason == .userInitiated, claudeQuota == nil {
                await loadClaudeCLIFallback(apiError: err)
            }
        }
    }

    private func loadClaudeCLIFallback(apiError: QuotaError) async {
        let now = Date()
        if let claudeFallbackBackoffUntil, claudeFallbackBackoffUntil > now {
            markClaudeFailure("\(apiError.description); cli fallback cooling down until \(claudeFallbackBackoffUntil)")
            return
        }

        claudeFallbackBackoffUntil = now.addingTimeInterval(rateLimitBackoff)
        let result = await ClaudeCLIFallbackQuotaClient.fetch()
        switch result {
        case .success(let snapshot):
            storeClaude(snapshot: snapshot, source: .cliFallback)
        case .failure(let err):
            markClaudeFailure("\(apiError.description); cli fallback failed: \(err.description)", error: err)
        }
    }

    private func beginCodexRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !codexRefreshState.inFlight else { return false }
        if let backoffUntil = codexRefreshState.backoffUntil, backoffUntil > now {
            markCodexFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = codexRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        codexRefreshState.inFlight = true
        codexRefreshState.lastAttemptAt = now
        return true
    }

    private func beginClaudeRefresh(reason: QuotaRefreshReason) -> Bool {
        let now = Date()
        guard !claudeRefreshState.inFlight else { return false }
        if let backoffUntil = claudeRefreshState.backoffUntil, backoffUntil > now {
            markClaudeFailure(backoffMessage(until: backoffUntil))
            return false
        }
        if reason == .periodic,
           let lastSuccessAt = claudeRefreshState.lastSuccessAt,
           now.timeIntervalSince(lastSuccessAt) < minSuccessInterval
        {
            return false
        }
        claudeRefreshState.inFlight = true
        claudeRefreshState.lastAttemptAt = now
        return true
    }

    private func storeCodex(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        codexQuota = snapshot
        codexQuotaSource = source
        codexQuotaError = nil
        codexRefreshState.lastSuccessAt = updatedAt
        codexRefreshState.lastError = nil
        codexRefreshState.backoffUntil = nil
        codexRefreshState.source = source
        quotaCache.codex = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordCodexQuotaHistory(snapshot: snapshot, sampledAt: updatedAt)
    }

    private func storeClaude(snapshot: QuotaSnapshot, source: QuotaSnapshotSource) {
        let updatedAt = Date()
        claudeQuota = snapshot
        claudeQuotaSource = source
        claudeQuotaError = nil
        claudeRefreshState.lastSuccessAt = updatedAt
        claudeRefreshState.lastError = nil
        if source == .api {
            claudeRefreshState.backoffUntil = nil
        }
        claudeRefreshState.source = source
        quotaCache.claude = QuotaCacheRecord(snapshot: snapshot, source: source, updatedAt: updatedAt)
        saveQuotaCache()
        recordClaudeQuotaHistory(snapshot: snapshot, sampledAt: updatedAt)
    }

    private func markCodexFailure(_ message: String, error: QuotaError? = nil) {
        codexQuotaError = message
        codexRefreshState.lastError = message
        if error?.isRateLimited == true {
            codexRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func markClaudeFailure(_ message: String, error: QuotaError? = nil) {
        claudeQuotaError = message
        claudeRefreshState.lastError = message
        if error?.isRateLimited == true {
            claudeRefreshState.backoffUntil = Date().addingTimeInterval(rateLimitBackoff)
        }
    }

    private func backoffMessage(until: Date) -> String {
        "rate limited; retry in \(relativeAge(until: until))"
    }

    private func logCredentialSummary() {
        if let c = codexAccount {
            print("[Credentials 凭据] Codex: email=\(c.email ?? "—") plan=\(c.planType ?? "—") account_id=\(c.accountId ?? "—") expiredGuess=\(c.expiredGuess) hasAccessToken=\(c.accessToken != nil) hasRefreshToken=\(c.refreshToken != nil)")
        } else {
            print("[Credentials 凭据] Codex 未加载: error=\(codexError ?? "unknown")")
        }
        if let c = claudeAccount {
            print("[Credentials 凭据] Claude: source=\(c.source.rawValue) email=\(c.email ?? "—") plan=\(c.subscriptionType ?? "—") expiresAt=\(c.expiresAt.map { "\($0)" } ?? "—") expiredGuess=\(c.expiredGuess) hasAccessToken=\(c.accessToken != nil)")
        } else {
            print("[Credentials 凭据] Claude 未加载: error=\(claudeError ?? "unknown")")
        }
        if let g = grokAccount {
            print("[Credentials 凭据] Grok: email=\(g.email ?? "—") identity=\(g.identity) expiresAt=\(g.expiresAt.map { "\($0)" } ?? "—")")
        } else if SettingsStore.shared.showGrok {
            print("[Credentials 凭据] Grok 未加载")
        }
    }

    private func logQuotaSummary() {
        if let q = codexQuota {
            print("[Quota 额度] Codex: source=\(codexQuotaSource?.rawValue ?? "—") plan=\(q.planType ?? "—") \(format(q))")
        } else {
            print("[Quota 额度] Codex 拉取失败: error=\(codexQuotaError ?? "unknown")")
        }
        if let q = claudeQuota {
            print("[Quota 额度] Claude: source=\(claudeQuotaSource?.rawValue ?? "—") \(format(q))")
            if let opus = q.weeklyOpus { print("       └─ weeklyOpus=\(format(window: opus))") }
            if let sonnet = q.weeklySonnet { print("       └─ weeklySonnet=\(format(window: sonnet))") }
        } else {
            print("[Quota 额度] Claude 拉取失败: error=\(claudeQuotaError ?? "unknown")")
        }
        if SettingsStore.shared.showGrok {
            if let q = grokQuota {
                print("[Quota 额度] Grok: source=\(grokRefreshState.source?.rawValue ?? "—") \(format(q))")
            } else {
                print("[Quota 额度] Grok 拉取失败: error=\(grokQuotaError ?? "unknown")")
            }
        }
        if SettingsStore.shared.showGemini || SettingsStore.shared.showAgy {
            if geminiQuota != nil || agyQuota != nil {
                if let q = geminiQuota { print("[Quota 额度] Gemini: \(format(q))") }
                if let q = agyQuota { print("[Quota 额度] agy (Claude + GPT): \(format(q))") }
            } else {
                print("[Quota 额度] Gemini / agy 拉取失败: error=\(googleQuotaError ?? "unknown")")
            }
        }
    }

    private func format(_ q: QuotaSnapshot) -> String {
        let parts = [
            q.primary.map { "period=\(format(window: $0))" },
            q.fiveHour.map { "5h=\(format(window: $0))" },
            q.weekly.map { "1w=\(format(window: $0))" }
        ].compactMap { $0 }
        return parts.joined(separator: " ")
    }

    private func format(window w: QuotaWindow) -> String {
        let pct = String(format: "%.1f%% left", w.remainingPercent)
        let reset: String
        if let r = w.resetsAt {
            let mins = Int(r.timeIntervalSinceNow / 60)
            reset = mins > 0 ? "resets in ~\(mins)m" : "resets now"
        } else {
            reset = "resets ?"
        }
        return "\(pct) (\(reset))"
    }

    private func relativeAge(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private func relativeAge(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(Date())))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    private func shortError(_ error: String) -> String {
        let oneLine = error.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if oneLine.count <= 120 { return oneLine }
        return String(oneLine.prefix(117)) + "..."
    }
}
