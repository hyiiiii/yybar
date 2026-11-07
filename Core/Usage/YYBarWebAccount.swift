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
// 上传(每一天的每个服务只算一份，网站和本机两边都记):
// - 只传今天以前、已经过完的天(本地日期)，按 天 × 服务 × 模型 汇总。
// - 网站对每个（日期, 服务）记一份和它的量(token 总数，Gemini 是回答次数):再传同一天，量更多才整份换掉，否则跳过(usage_uploads)。
//   本机也给传过的打标签(web-uploads-<login>.json),按（日期, 服务）打、记下网站上的量：没标签的传;有标签的，本机这一天的量
//   比记下的多(比如新加了一个 Codex 目录，找到了另一个账号以前的会话)也传。启动、连上、每次上传前用 GET /api/v1/usage/days 补齐标签和量。
// - 传的服务：Codex / Claude / Grok / Grok Bot / Antigravity 按用量桶传;Gemini 没有 token 和花费，按每天每个模型的回答次数传。
// - 自动上传：每天 0:30 先扫一遍本地统计再传没标签的天(前一天刚过完);那时没开 App 或在睡眠，
//   之后第一次扫描完补传，一天只自动传一次。
// - 一键上传：每天只能成功点一次，点完当天变灰;没传成功(断网等)可以再点。
//
// 订阅(网站个人主页 @ 后面那一排):各服务账号的套餐，一个账号一条 { app, account, plan },account 是账号的摘要，
// 不传邮箱。随用量一起上传：每次上传(一键 / 自动)都 PUT /api/v1/accounts,带上这台 Mac 固定的设备 id,
// 网站把这台设备上次传的整份替换(重新连接换了令牌也一样)。

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
    /// 自动上传每天几点传(本地时间 0:30:前一天刚过完)。
    static let autoUploadHour = 0
    static let autoUploadMinute = 30

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
    /// 当前各账号的订阅(AppState.webAccountPlans);AppState 启动时设好，上传时取。
    var accountPlans: (@MainActor () -> [AccountPlan])?
    private static let autoUploadKey = "yybar.settings.webAutoUpload"
    private static let deviceKey = "yybar.settings.webDevice"

    /// 这台 Mac 固定的设备 id(第一次传订阅时生成):网站按它替换这台设备上次传的订阅。
    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    // MARK: 本机标签

    /// 每个 GitHub 账号一份：传过的（日期, 服务）、上次上传时间、一键上传用掉的那天。
    struct Ledger: Codable, Equatable {
        /// 旧版本的标签：只记日期(那时只传 Codex / Claude / Grok)。
        var uploadedDays: Set<String> = []
        /// 「日期|服务」,例如 2026-10-21|agy。旧文件没有这一项。
        var uploaded: Set<String>? = []
        var lastUploadAt: Date?
        var manualUploadDay: String?
        /// 哪天已经自动传过了(每天 0:30 一次)。旧文件没有这一项。
        var autoUploadDay: String?
        /// 「日期|服务」→ 网站上这一天这个服务的量和花费。本机的量比它多就再传一次。
        /// 旧文件、旧网站没有这一项，那些天照旧只传一次。
        var sent: [String: Sent]? = [:]

        struct Sent: Codable, Equatable {
            /// token 总数(Gemini 是回答次数)，和网站 usage_uploads.total 一样算
            var total: Int
            /// 花费(微美元)，只用来估这次能多换多少筹码
            var costMicro: Int
        }

        func contains(day: String, app: UsageApp) -> Bool {
            (uploaded ?? []).contains("\(day)|\(app.rawValue)") || (YYBarWebAccount.legacyApps.contains(app) && uploadedDays.contains(day))
        }

        mutating func insert(day: String, app: String) {
            uploaded = (uploaded ?? []).union(["\(day)|\(app)"])
        }

        mutating func record(day: String, app: String, _ value: Sent) {
            insert(day: day, app: app)
            sent = (sent ?? [:]).merging(["\(day)|\(app)": value]) { $1 }
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
        // 对一下网站上各天的量：bar 页「待上传」能算上本机量变多了的天
        Task { await syncUploadedDays() }
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
        ledger = Ledger()
        phase = .idle
        scheduleNoon()
        setMessage(nil)
    }

    /// 网站上已经传过的（日期, 服务）和它们的量补进本机标签(换了台 Mac、重装过都不会再传一遍;别的电脑传的量更多，这里就不再传)。
    private func syncUploadedDays() async {
        guard let token, let login = profile?.login else { return }
        guard let remote: UploadedDays = try? await get("api/v1/usage/days", token: token) else { return }
        if let uploads = remote.uploads {
            for u in uploads {
                if let total = u.total {
                    ledger.record(day: u.day, app: u.app, .init(total: total, costMicro: u.costMicro ?? 0))
                } else {
                    ledger.insert(day: u.day, app: u.app)
                }
            }
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

    /// 今天以前、要传的（日期, 服务）：还没打标签的，和本机的量比网站上记的多的。
    func pending(_ source: Source, now: Date = Date()) -> Pending {
        let cutoff = UsageDay.startOfDay(for: now)
        var out = Pending()
        let local = Self.localTotals(source, before: cutoff)
        for (pair, mine) in local {
            let parts = pair.split(separator: "|").map(String.init)
            guard parts.count == 2, let app = UsageApp(rawValue: parts[1]) else { continue }
            var extraCost = mine.cost
            if ledger.contains(day: parts[0], app: app) {
                // 传过了：本机的量更多才再传，筹码按多出来的花费估
                guard let before = ledger.sent?[pair], mine.total > before.total else { continue }
                extraCost = max(0, mine.cost - Decimal(before.costMicro) / 1_000_000)
            }
            out.pairs.insert(pair)
            out.costUSD += extraCost
            out.answers += app == .gemini ? mine.total : 0
        }
        out.days = Set(out.pairs.compactMap { $0.split(separator: "|").first.map(String.init) }).sorted()
        return out
    }

    /// 本机每个（日期, 服务）的量(token 总数，Gemini 是回答次数，和网站一样算)和花费。
    private static func localTotals(_ source: Source, before cutoff: Date) -> [String: (total: Int, cost: Decimal)] {
        var out: [String: (total: Int, cost: Decimal)] = [:]
        for b in source.buckets where uploadApps.contains(b.app) && b.day < cutoff {
            let key = "\(dayKey(b.day))|\(b.app.rawValue)"
            out[key, default: (0, 0)].total += b.inputTokens + b.outputTokens + b.cacheReadTokens + b.cacheCreationTokens
            out[key, default: (0, 0)].cost += b.costUSD
        }
        for c in source.answers where c.count > 0 && c.day < cutoff {
            out["\(dayKey(c.day))|\(UsageApp.gemini.rawValue)", default: (0, 0)].total += c.count
        }
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

    /// 本地统计扫描完调用：开着自动上传、过了今天 0:30 还没自动传过，就传。
    func usageDidUpdate(_ source: Source) {
        lastSource = source
        triggerAutoUpload()
    }

    /// 今天的自动上传到点了还没做：过了 0:30，今天还没自动传过。
    private func autoUploadDue(_ now: Date = Date()) -> Bool {
        guard autoUpload, isConnected,
              let noon = Calendar.current.date(bySettingHour: Self.autoUploadHour, minute: Self.autoUploadMinute, second: 0, of: now) else { return false }
        return now >= noon && ledger.autoUploadDay != Self.dayKey(now)
    }

    private func triggerAutoUpload() {
        // 还没扫过本地统计(刚启动)时不算，免得把「没东西可传」记成今天传过了
        guard autoUploadDue(), phase == .idle, !lastSource.buckets.isEmpty || !lastSource.answers.isEmpty else { return }
        let source = lastSource
        Task { await upload(source, manual: false) }
    }

    /// 每天 0:30 叫一次本地统计扫描，扫完 usageDidUpdate 就会传。用连续时钟：Mac 睡眠跨过 0:30，醒来马上补。
    private func scheduleNoon() {
        noonTask?.cancel()
        noonTask = nil
        guard autoUpload, token != nil else { return }
        noonTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard var next = Calendar.current.date(bySettingHour: Self.autoUploadHour, minute: Self.autoUploadMinute, second: 0, of: now) else { return }
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
        phase = .uploading
        defer { phase = .idle }
        // 上一次的结果(比如「上传失败」)不留到这次：不然转圈的时候还挂着旧的报错
        setMessage(nil)
        // 订阅随用量一起传，不管有没有新的天
        await uploadAccountPlans(token: token)
        // 先对一下网站上各天的量(别的电脑传过更多的就不用再传)
        await syncUploadedDays()
        let todo = pending(source)
        guard !todo.days.isEmpty else {
            if manual { setMessage(tr("Nothing new to upload — every finished day is already in.", "没有新的天要传：今天以前的都传过了。")) }
            else {
                ledger.autoUploadDay = Self.dayKey(Date())
                Self.saveLedger(ledger, login: login)
            }
            return
        }
        // 按天整理成网站要的格式：每天只放要传的服务(没传过的、本机量更多的)，一次最多传 100 天
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
        let local = Self.localTotals(source, before: UsageDay.startOfDay(for: Date()))
        var accepted = 0, skipped = 0
        do {
            for chunk in stride(from: 0, to: todo.days.count, by: 100).map({ Array(todo.days[$0..<min($0 + 100, todo.days.count)]) }) {
                let body = UploadBody(days: chunk.map { UploadDay(day: $0, entries: byDay[$0] ?? []) })
                let result: UploadResult = try await post("api/v1/usage", token: token, body: body)
                accepted += result.accepted.count
                skipped += result.skipped.count
                // 这一批传的（日期, 服务）不管是新收下的还是网站上早就有的，都打上标签、记下这次的量，量不再变多就不再传
                for day in chunk {
                    for entry in byDay[day] ?? [] {
                        guard let mine = local["\(day)|\(entry.app)"] else { ledger.insert(day: day, app: entry.app); continue }
                        let micro = NSDecimalNumber(decimal: mine.cost * 1_000_000).int64Value
                        ledger.record(day: day, app: entry.app, .init(total: mine.total, costMicro: Int(micro)))
                    }
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

    /// 订阅随用量一起上传：每次上传(一键 / 自动，不管有没有新的天)都把当前的订阅整份交给网站。
    /// 没传成功不影响用量上传，下次上传再传。
    private func uploadAccountPlans(token: String) async {
        guard let plans = accountPlans?() else { return }
        let _: AccountsResult? = try? await put("api/v1/accounts", token: token, body: AccountsBody(device: Self.deviceID, accounts: plans))
    }

    // MARK: 网络

    private struct WhoAmI: Decodable {
        struct User: Decodable { var login: String; var name: String?; var avatarUrl: String? }
        var user: User
    }
    private struct UploadedDays: Decodable {
        /// total / costMicro:网站记的这一天这个服务的量和花费(旧版网站没有)
        struct Pair: Decodable { var day: String; var app: String; var total: Int?; var costMicro: Int? }
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
    private struct AccountsBody: Encodable { var device: String; var accounts: [AccountPlan] }
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
