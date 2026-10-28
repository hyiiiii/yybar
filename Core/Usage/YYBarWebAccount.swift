import AppKit
import CryptoKit
import Foundation
import Observation
import Security

// MARK: - YYBarWebAccount
//
// yybar 网站账号：连接(GitHub 授权拿上传令牌)、显示头像、把本地用量传上去换筹码(花费 $1 = 1 筹码)。
//
// 连接：浏览器打开 <网站>/connect?state=随机串 → 用户用 GitHub 登录、点「授权」→ 网站跳回
// yybar://connect?token=…&state=… → AppDelegate 交给 handle(url:),核对 state 后保存令牌，再拉头像和已上传的日期。
// 令牌和头像信息存成本用户私有文件(AccountTokenFiles,kind yybarweb),不进钥匙串。
//
// 上传(每一天的每个服务只算一次，网站和本机两边都记):
// - 只传今天以前、已经过完的天(本地日期)，按 天 × 服务 × 模型 汇总。
// - 网站对每个（日期, 服务）只收第一次，之后再传就跳过(usage_uploads)。本机也给传过的打标签
//   (web-uploads-<login>.json),标签按（日期, 服务）打，每次只传没标签的;连上时用 GET /api/v1/usage/days 补齐标签。
// - 传的服务：Codex / Claude / Grok / Grok Bot / Antigravity 按用量桶传;Gemini 没有 token 和花费，按每天每个模型的回答次数传。
// - 自动上传：每天中午 12:00 先扫一遍本地统计再传没标签的天(前一天早就过完、日志也落盘了);那时没开 App 或在睡眠，
//   之后第一次扫描完补传，一天只自动传一次。
// - 一键上传：每天只能成功点一次，点完当天变灰;没传成功(断网等)可以再点。
//
// 订阅(网站个人主页 @ 后面那一排):各服务账号的套餐，一个账号一条 { app, account, plan },account 是账号的摘要，
// 不传邮箱。AppState 每次刷新完额度交过来，变了就 PUT /api/v1/accounts(网站按设备整份替换),没变每天补传一次。

@MainActor
@Observable
final class YYBarWebAccount {
    struct Profile: Codable, Equatable {
        var login: String
        var name: String?
        var avatarUrl: String?
    }

    enum Phase: Equatable {
        case idle
        /// 已打开浏览器，等网站跳回来
        case waitingForBrowser
        case uploading
    }

    /// 按用量桶上传的服务;Gemini 没有 token 和花费，另按回答次数传(GeminiAnswerLog)。和网站 usage.ts 的 APPS 一致。
    static let uploadApps: [UsageApp] = [.codex, .claude, .grok, .grokBot, .agy]
    /// 旧版本的标签只记日期，那时只传这三家。
    static let legacyApps: Set<UsageApp> = [.codex, .claude, .grok]
    /// 自动上传每天几点传(本地时间)。
    static let autoUploadHour = 12

    private(set) var profile: Profile?
    private(set) var phase: Phase = .idle
    /// 上一次连接 / 上传的结果，显示在 bar 页上传卡片底部。
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var ledger = Ledger()

    var isConnected: Bool { token != nil && profile != nil }

    var autoUpload: Bool {
        get { access(keyPath: \.autoUpload); return UserDefaults.standard.bool(forKey: Self.autoUploadKey) }
        set {
            withMutation(keyPath: \.autoUpload) { UserDefaults.standard.set(newValue, forKey: Self.autoUploadKey) }
            scheduleNoon()
            if newValue { triggerAutoUpload() }
        }
    }

    /// 扫一遍本地统计(扫完 UsageService 会调 usageDidUpdate);AppState 启动时设好。
    var scanUsage: (@MainActor () async -> Void)?
    private var noonTask: Task<Void, Never>?

    private var token: String?
    private var pendingState: String?
    private var lastSource = Source()
    /// 订阅：AppState 最近交过来的、上次传成功的(和时间)、上次没传成功的时间。
    private var accountPlans: [AccountPlan]?
    private var sentAccountPlans: [AccountPlan]?
    private var accountPlansSentAt: Date?
    private var accountPlansFailedAt: Date?
    private var accountPlansInFlight = false
    private static let autoUploadKey = "yybar.settings.webAutoUpload"

    // MARK: 本机标签

    /// 每个 GitHub 账号一份：传过的（日期, 服务）、上次上传时间、一键上传用掉的那天。
    struct Ledger: Codable, Equatable {
        /// 旧版本的标签：只记日期(那时只传 Codex / Claude / Grok)。
        var uploadedDays: Set<String> = []
        /// 「日期|服务」,例如 2026-10-21|agy。旧文件没有这一项。
        var uploaded: Set<String>? = []
        var lastUploadAt: Date?
        var manualUploadDay: String?
        /// 哪天已经自动传过了(每天 12:00 一次)。旧文件没有这一项。
        var autoUploadDay: String?

        func contains(day: String, app: UsageApp) -> Bool {
            (uploaded ?? []).contains("\(day)|\(app.rawValue)") || (YYBarWebAccount.legacyApps.contains(app) && uploadedDays.contains(day))
        }

        mutating func insert(day: String, app: String) {
            uploaded = (uploaded ?? []).union(["\(day)|\(app)"])
        }

        /// 传过东西的天数(去重)。
        var dayCount: Int {
            Set((uploaded ?? []).compactMap { $0.split(separator: "|").first.map(String.init) }).union(uploadedDays).count
        }
    }

    /// 能上传的本地数据：用量桶，和 Gemini 每天每个模型的回答次数。
    struct Source {
        var buckets: [UsageBucket] = []
        var answers: [GeminiAnswerLog.Count] = []
    }

    // MARK: 启动

    func bootstrap() {
        guard let data = AccountTokenFiles.read(kind: .yybarWeb, id: "account"),
              let stored = try? JSONDecoder().decode(StoredAccount.self, from: data) else { return }
        token = stored.token
        profile = stored.profile
        ledger = Self.loadLedger(login: stored.profile.login)
        scheduleNoon()
    }

    private struct StoredAccount: Codable {
        var token: String
        var profile: Profile
    }

    // MARK: 连接

    /// 打开网站的授权页，等它跳回 yybar://connect。
    func connect() {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let state = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        pendingState = state
        phase = .waitingForBrowser
        setMessage(nil)
        var components = URLComponents(url: YYBarWeb.url.appendingPathComponent("connect"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "state", value: state)]
        NSWorkspace.shared.open(components.url!)
    }

    func cancelConnect() {
        pendingState = nil
        if phase == .waitingForBrowser { phase = .idle }
    }

    /// AppDelegate 收到 yybar:// 链接时调用。返回是不是连接回调(是的话打开 bar 页)。
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "yybar", url.host == "connect" else { return false }
        // 已经连着、这边也没在等授权：多点了一次授权页之类的旧链接，直接忽略
        if pendingState == nil, isConnected { return true }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let newToken = items.first { $0.name == "token" }?.value
        let state = items.first { $0.name == "state" }?.value
        guard let newToken, !newToken.isEmpty, let state, let pendingState, state == pendingState else {
            setMessage(tr("This link didn't come from the connect button here. Click \"Connect GitHub\" again.",
                          "这个链接不是从这里点「连接 GitHub」发起的，请重新连接。"), error: true)
            return true
        }
        self.pendingState = nil
        Task { await finishConnect(token: newToken) }
        return true
    }

    private func finishConnect(token newToken: String) async {
        do {
            let who: WhoAmI = try await get("api/v1/whoami", token: newToken)
            let profile = Profile(login: who.user.login, name: who.user.name, avatarUrl: who.user.avatarUrl)
            try AccountTokenFiles.write(JSONEncoder().encode(StoredAccount(token: newToken, profile: profile)), kind: .yybarWeb, id: "account")
            token = newToken
            self.profile = profile
            ledger = Self.loadLedger(login: profile.login)
            phase = .idle
            setMessage(tr("Connected as @\(profile.login).", "已连接 @\(profile.login)。"))
            await syncUploadedDays()
            scheduleNoon()
            triggerAutoUpload()
            syncAccountPlans()
        } catch {
            phase = .idle
            setMessage(tr("Couldn't connect: \(error.localizedDescription)", "连接失败：\(error.localizedDescription)"), error: true)
        }
    }

    /// 断开：删掉本机的令牌(网站上的令牌可在「我的」页撤销)。本机的上传标签留着，下次连同一个账号还能用。
    func disconnect() {
        AccountTokenFiles.delete(kind: .yybarWeb, id: "account")
        token = nil
        profile = nil
        sentAccountPlans = nil
        accountPlansSentAt = nil
        accountPlansFailedAt = nil
        ledger = Ledger()
        phase = .idle
        scheduleNoon()
        setMessage(nil)
    }

    /// 网站上已经传过的（日期, 服务）补进本机标签(换了台 Mac、重装过都不会再传一遍)。
    private func syncUploadedDays() async {
        guard let token, let login = profile?.login else { return }
        guard let remote: UploadedDays = try? await get("api/v1/usage/days", token: token) else { return }
        if let uploads = remote.uploads {
            for u in uploads { ledger.insert(day: u.day, app: u.app) }
        } else {
            ledger.uploadedDays.formUnion(remote.days)
        }
        Self.saveLedger(ledger, login: login)
    }

    // MARK: 待上传

    struct Pending: Equatable {
        /// 有东西要传的天(升序)
        var days: [String] = []
        /// 要传的「日期|服务」
        var pairs: Set<String> = []
        var costUSD: Decimal = 0
        var answers = 0
        var chips: Int { YYBarWebAccount.chips(costUSD) }
    }

    /// 还没打标签、今天以前的（日期, 服务）。
    func pending(_ source: Source, now: Date = Date()) -> Pending {
        let cutoff = UsageDay.startOfDay(for: now)
        var out = Pending()
        var days = Set<String>()
        for b in source.buckets where Self.uploadApps.contains(b.app) && b.day < cutoff {
            let key = Self.dayKey(b.day)
            guard !ledger.contains(day: key, app: b.app) else { continue }
            days.insert(key)
            out.pairs.insert("\(key)|\(b.app.rawValue)")
            out.costUSD += b.costUSD
        }
        for c in source.answers where c.count > 0 && c.day < cutoff {
            let key = Self.dayKey(c.day)
            guard !ledger.contains(day: key, app: .gemini) else { continue }
            days.insert(key)
            out.pairs.insert("\(key)|\(UsageApp.gemini.rawValue)")
            out.answers += c.count
        }
        out.days = days.sorted()
        return out
    }

    /// 花费写成网站认的十进制字符串：保留 6 位小数(网站按微美元存)，不会出现科学计数法。
    static func costString(_ usd: Decimal) -> String {
        var value = max(0, usd), rounded = Decimal()
        NSDecimalRound(&rounded, &value, 6, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    /// 网站的换算：花费 $1 = 1 筹码，向下取整。先取整再转 Int(NSDecimalNumber 直接对带小数的大数取 intValue 会出错)。
    static func chips(_ usd: Decimal) -> Int {
        var value = usd, whole = Decimal()
        NSDecimalRound(&whole, &value, 0, .down)
        return NSDecimalNumber(decimal: whole).intValue
    }

    var usedManualUploadToday: Bool { ledger.manualUploadDay == Self.dayKey(Date()) }

    // MARK: 上传

    /// 一键上传：每天只能成功点一次。
    func uploadNow(_ source: Source) {
        guard isConnected, phase == .idle, !usedManualUploadToday else { return }
        Task { await upload(source, manual: true) }
    }

    /// 本地统计扫描完调用：开着自动上传、过了今天 12:00 还没自动传过，就传。
    func usageDidUpdate(_ source: Source) {
        lastSource = source
        triggerAutoUpload()
    }

    /// 今天的自动上传到点了还没做：过了 12:00，今天还没自动传过。
    private func autoUploadDue(_ now: Date = Date()) -> Bool {
        guard autoUpload, isConnected,
              let noon = Calendar.current.date(bySettingHour: Self.autoUploadHour, minute: 0, second: 0, of: now) else { return false }
        return now >= noon && ledger.autoUploadDay != Self.dayKey(now)
    }

    private func triggerAutoUpload() {
        // 还没扫过本地统计(刚启动)时不算，免得把「没东西可传」记成今天传过了
        guard autoUploadDue(), phase == .idle, !lastSource.buckets.isEmpty || !lastSource.answers.isEmpty else { return }
        let source = lastSource
        Task { await upload(source, manual: false) }
    }

    /// 每天 12:00 叫一次本地统计扫描，扫完 usageDidUpdate 就会传。用连续时钟：Mac 睡眠跨过 12:00，醒来马上补。
    private func scheduleNoon() {
        noonTask?.cancel()
        noonTask = nil
        guard autoUpload, token != nil else { return }
        noonTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard var next = Calendar.current.date(bySettingHour: Self.autoUploadHour, minute: 0, second: 0, of: now) else { return }
                if next <= now, let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: next) { next = tomorrow }
                do {
                    try await Task.sleep(until: .now + .seconds(next.timeIntervalSince(now)), clock: .continuous)
                } catch { return }
                guard let self else { return }
                await self.scanUsage?()
            }
        }
    }

    private func upload(_ source: Source, manual: Bool) async {
        guard let token, let login = profile?.login, phase == .idle else { return }
        let todo = pending(source)
        guard !todo.days.isEmpty else {
            if manual { setMessage(tr("Nothing new to upload — every finished day is already in.", "没有新的天要传：今天以前的都传过了。")) }
            else {
                ledger.autoUploadDay = Self.dayKey(Date())
                Self.saveLedger(ledger, login: login)
            }
            return
        }
        phase = .uploading
        defer { phase = .idle }
        // 按天整理成网站要的格式：每天只放还没传过的服务，一次最多传 100 天
        var byDay: [String: [Entry]] = [:]
        for b in source.buckets where Self.uploadApps.contains(b.app) {
            let key = Self.dayKey(b.day)
            guard todo.pairs.contains("\(key)|\(b.app.rawValue)") else { continue }
            byDay[key, default: []].append(Entry(
                app: b.app.rawValue, model: String(b.model.prefix(120)),
                inputTokens: b.inputTokens, outputTokens: b.outputTokens,
                cacheReadTokens: b.cacheReadTokens, cacheCreationTokens: b.cacheCreationTokens,
                costUSD: Self.costString(b.costUSD), answers: nil))
        }
        for c in source.answers where c.count > 0 {
            let key = Self.dayKey(c.day)
            guard todo.pairs.contains("\(key)|\(UsageApp.gemini.rawValue)") else { continue }
            byDay[key, default: []].append(Entry(
                app: UsageApp.gemini.rawValue, model: String(c.model.prefix(120)),
                inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                costUSD: "0", answers: c.count))
        }
        var accepted = 0, skipped = 0
        do {
            for chunk in stride(from: 0, to: todo.days.count, by: 100).map({ Array(todo.days[$0..<min($0 + 100, todo.days.count)]) }) {
                let body = UploadBody(days: chunk.map { UploadDay(day: $0, entries: byDay[$0] ?? []) })
                let result: UploadResult = try await post("api/v1/usage", token: token, body: body)
                accepted += result.accepted.count
                skipped += result.skipped.count
                // 这一批传的（日期, 服务）不管是新收下的还是网站上早就有的，都打上标签，以后不再传
                for day in chunk {
                    for entry in byDay[day] ?? [] { ledger.insert(day: day, app: entry.app) }
                }
                ledger.lastUploadAt = Date()
                Self.saveLedger(ledger, login: login)
            }
            // 一键上传每天只能成功点一次;自动上传每天传一次，没传成功(断网等)下次扫描完再试
            if manual { ledger.manualUploadDay = Self.dayKey(Date()) } else { ledger.autoUploadDay = Self.dayKey(Date()) }
            Self.saveLedger(ledger, login: login)
            let chips = Self.chips(todo.costUSD)
            setMessage(skipped == 0
                ? tr("Uploaded \(accepted) days · about \(chips.formatted()) chips.", "已上传 \(accepted) 天，约 \(chips.formatted()) 筹码。")
                : tr("Uploaded \(accepted) days; \(skipped) were already on the website and didn't count again.",
                     "已上传 \(accepted) 天；另有 \(skipped) 天网站上已经有了，不再重复计入。"))
        } catch WebError.unauthorized {
            disconnect()
            setMessage(tr("The website no longer accepts this Mac's token. Connect GitHub again.", "网站不再认这台 Mac 的授权了，请重新连接 GitHub。"), error: true)
        } catch {
            setMessage(tr("Upload failed: \(error.localizedDescription)", "上传失败：\(error.localizedDescription)"), error: true)
        }
    }

    // MARK: 订阅

    /// 一个账号的订阅。account 是「服务:账号」的 SHA-256 前 16 位，网站只用它在几台设备之间认出同一个账号。
    struct AccountPlan: Encodable, Equatable {
        var app: String
        var account: String
        var plan: String

        init(app: UsageApp, identity: String, plan: String) {
            self.app = app.rawValue
            let digest = SHA256.hash(data: Data("yybar:\(app.rawValue):\(identity.lowercased())".utf8))
            account = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
            self.plan = String(plan.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        }

        /// Claude 的套餐：Max 按 rateLimitTier(default_claude_max_20x)写成 max_20x / max_5x,其他照 subscriptionType。
        static func claudePlan(_ subscriptionType: String?, _ rateLimitTier: String?) -> String? {
            guard subscriptionType == nil || subscriptionType?.lowercased().contains("max") == true,
                  let tier = rateLimitTier?.lowercased(),
                  let range = tier.range(of: #"max_\d+x"#, options: .regularExpression) else { return subscriptionType }
            return String(tier[range])
        }
    }

    /// AppState 刷新完额度交过来的订阅：和上次传成功的不一样就传，一样的每天补传一次(网站 30 天没收到就不显示这台设备的)。
    func accountsDidUpdate(_ plans: [AccountPlan]) {
        accountPlans = plans
        syncAccountPlans()
    }

    private func syncAccountPlans() {
        guard let token, let plans = accountPlans, !accountPlansInFlight else { return }
        let now = Date()
        // 上次没传成功(断网、网站还没更新)：一小时后再试;传成功过且没变：一天补传一次;变了：马上传
        if let failed = accountPlansFailedAt, now.timeIntervalSince(failed) < 3600 { return }
        if plans == sentAccountPlans, let sent = accountPlansSentAt, now.timeIntervalSince(sent) < 86400 { return }
        accountPlansInFlight = true
        Task {
            defer { accountPlansInFlight = false }
            do {
                let _: AccountsResult = try await put("api/v1/accounts", token: token, body: AccountsBody(accounts: plans))
                sentAccountPlans = plans
                accountPlansSentAt = now
                accountPlansFailedAt = nil
            } catch {
                // 令牌失效由上传那边断开、提示;这里一小时后再试
                accountPlansFailedAt = now
            }
        }
    }

    // MARK: 网络

    private struct WhoAmI: Decodable {
        struct User: Decodable { var login: String; var name: String?; var avatarUrl: String? }
        var user: User
    }
    private struct UploadedDays: Decodable {
        struct Pair: Decodable { var day: String; var app: String }
        var days: [String]
        /// 新版网站按（日期, 服务）记;旧版只有 days
        var uploads: [Pair]?
    }
    private struct Entry: Encodable {
        var app: String
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var costUSD: String
        /// Gemini 的回答次数;别的服务不带
        var answers: Int?
    }
    private struct UploadDay: Encodable { var day: String; var entries: [Entry] }
    private struct UploadBody: Encodable { var days: [UploadDay] }
    private struct UploadResult: Decodable { var accepted: [String]; var skipped: [String] }
    private struct AccountsBody: Encodable { var accounts: [AccountPlan] }
    private struct AccountsResult: Decodable { var ok: Bool }
    private struct ErrorBody: Decodable { var error: String }

    enum WebError: LocalizedError {
        case unauthorized
        case server(String)

        var errorDescription: String? {
            switch self {
            // 总是在 upload 里单独接住、换成双语提示，这里不用 tr(errorDescription 不在主线程上下文)
            case .unauthorized: return "Unauthorized"
            case .server(let text): return text
            }
        }
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        try await send(makeRequest(path, token: token))
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, token: String, body: B) async throws -> T {
        var req = makeRequest(path, token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req)
    }

    private func put<T: Decodable, B: Encodable>(_ path: String, token: String, body: B) async throws -> T {
        var req = makeRequest(path, token: token)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return try await send(req)
    }

    private func makeRequest(_ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: YYBarWeb.url.appendingPathComponent(path))
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw WebError.unauthorized }
        guard (200..<300).contains(status) else {
            let text = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(status)"
            throw WebError.server(text)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: 存储

    private func setMessage(_ text: String?, error: Bool = false) {
        message = text
        messageIsError = error
    }

    /// 本地日期 yyyy-MM-dd(和统计里的「天」一致，按本机时区)。
    nonisolated static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func ledgerURL(login: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let safe = login.addingPercentEncoding(withAllowedCharacters: allowed) ?? "account"
        return AccountTokenFiles.directory().deletingLastPathComponent()
            .appendingPathComponent("web-uploads-\(safe).json", isDirectory: false)
    }

    private static func loadLedger(login: String) -> Ledger {
        guard let data = try? Data(contentsOf: ledgerURL(login: login)),
              let ledger = try? JSONDecoder().decode(Ledger.self, from: data) else { return Ledger() }
        return ledger
    }

    private static func saveLedger(_ ledger: Ledger, login: String) {
        let url = ledgerURL(login: login)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(ledger).write(to: url, options: .atomic)
    }
}
