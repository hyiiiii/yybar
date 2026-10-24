import Foundation
import CryptoKit

/// Projects 的 result.modelUsage 是会话累计值，assistant.usage 是流式中间值，不能直接相加。
/// 独立账本只存用量和去重标识；与本地 rollup 分开，重扫/重启不会再次叠加。
nonisolated struct ClaudeCloudCounters: Codable, Sendable, Equatable {
    var input = 0
    var output = 0
    var read = 0
    var write = 0
    var cost: Decimal = 0
    var total: Int { input + output + read + write }

    init() {}
    init(json: [String: Any]) throws {
        func count(_ key: String) throws -> Int {
            guard let n = json[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue < Double(Int.max),
                  n.doubleValue.rounded() == n.doubleValue else { throw ClaudeCloudError.invalidData }
            return n.intValue
        }
        input = try count("inputTokens")
        output = try count("outputTokens")
        read = try count("cacheReadInputTokens")
        write = try count("cacheCreationInputTokens")
        guard let n = json["costUSD"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0 else { throw ClaudeCloudError.invalidData }
        cost = n.decimalValue
    }

    func delta(from old: Self) throws -> Self {
        // result_index / process_turn_index 重启会归零，计数器不会。下降时保留旧账并报告不兼容。
        guard input >= old.input, output >= old.output, read >= old.read, write >= old.write,
              cost + Decimal(string: "0.000000001")! >= old.cost else { throw ClaudeCloudError.counterReset }
        var result = Self()
        result.input = input - old.input; result.output = output - old.output
        result.read = read - old.read; result.write = write - old.write
        result.cost = max(0, cost - old.cost)
        return result
    }
}

nonisolated struct ClaudeCloudRecord: Codable, Sendable {
    var model: String
    var timestamp: Date
    var usage: ClaudeCloudCounters

    func entry() -> UsageEntry {
        let cost = CustomModelPrices.shared.price(forKey: model) == nil ? usage.cost : Pricing.cost(
            model: model, input: usage.input, output: usage.output, cacheRead: usage.read,
            cacheCreation: usage.write, requestInputTokens: 0)
        return UsageEntry(app: .claude, model: model, day: UsageDay.startOfDay(for: timestamp), timestamp: timestamp,
                          inputTokens: usage.input, outputTokens: usage.output, cacheReadTokens: usage.read,
                          cacheCreationTokens: usage.write, costUSD: cost)
    }
}

nonisolated struct ClaudeCloudSession: Codable, Sendable {
    var cursor = 0
    var counters: [String: ClaudeCloudCounters] = [:]
    var records: [ClaudeCloudRecord] = []
    var messageIDs: Set<String> = []
    var pendingMessageIDs: Set<String> = []
    var total: Int { counters.values.reduce(0) { $0 + $1.total } }

    mutating func consume(_ page: [String: Any], since: Date) throws {
        guard let events = page["data"] as? [[String: Any]] else { throw ClaudeCloudError.invalidData }
        var next = self // 页面全部验证通过后才前移游标，失败重试不会丢行。
        for event in events {
            guard let sequence = Self.integer(event["sequence_num"]), sequence > 0 else { throw ClaudeCloudError.invalidData }
            if sequence <= cursor { continue } // 重放页面幂等。
            guard sequence > next.cursor, let payload = event["payload"] as? [String: Any],
                  let text = event["created_at"] as? String, let time = JSONLTimestamp.parse(text)
            else { throw ClaudeCloudError.invalidData }
            if payload["type"] as? String == "assistant",
               let message = payload["message"] as? [String: Any], let id = message["id"] as? String {
                next.pendingMessageIDs.insert(id)
            }
            if payload["type"] as? String == "result", (payload["parent_tool_use_id"] == nil || payload["parent_tool_use_id"] is NSNull) {
                guard let models = payload["modelUsage"] as? [String: [String: Any]] else { throw ClaudeCloudError.invalidData }
                var settled = false
                for (rawModel, values) in models {
                    let canonical = values["canonicalModel"] as? String ?? String(rawModel.prefix { $0 != "[" })
                    let model = Pricing.normalize(model: canonical)
                    let current = try ClaudeCloudCounters(json: values)
                    let delta = try current.delta(from: next.counters[rawModel] ?? ClaudeCloudCounters())
                    if delta.total > 0 { settled = true }
                    next.counters[rawModel] = current
                    if time >= since, delta.total > 0 || delta.cost > 0 {
                        next.records.append(ClaudeCloudRecord(model: model, timestamp: time, usage: delta))
                    }
                }
                if time < since {
                    next.pendingMessageIDs.removeAll()
                } else if settled {
                    next.messageIDs.formUnion(next.pendingMessageIDs)
                    next.pendingMessageIDs.removeAll()
                }
            }
            next.cursor = sequence
        }
        self = next
    }

    static func integer(_ value: Any?) -> Int? {
        if let s = value as? String { return Int(s) }
        return value as? Int
    }
}

nonisolated struct ClaudeCloudLedger: Codable, Sendable {
    var version = 1
    var since: Date
    var sessions: [String: ClaudeCloudSession] = [:] // account hash / remote session ID
    var localDeductions: [String: ClaudeCloudRecord] = [:]
    var lastSuccess: Date?
    var nextAttempt: Date?
    var lastError: String?

    init(now: Date = Date()) {
        since = Calendar.current.date(byAdding: .day, value: -1, to: UsageDay.startOfDay(for: now))!
    }
    var entries: [UsageEntry] {
        var result = sessions.values.flatMap { $0.records.map { $0.entry() } }
        // 本机 rollup 保持原样；相同 message.id 的本地贡献从云端叠加层扣回。
        // 保存扣回记录，即使原日志被清理，也与保留的本地历史一致。
        for record in localDeductions.values {
            var entry = record.entry()
            entry.costUSD = -Pricing.cost(model: record.model, input: record.usage.input, output: record.usage.output,
                cacheRead: record.usage.read, cacheCreation: record.usage.write)
            entry.inputTokens *= -1; entry.outputTokens *= -1
            entry.cacheReadTokens *= -1; entry.cacheCreationTokens *= -1
            result.append(entry)
        }
        return result
    }

    mutating func reconcile(local: [String: UsageEntry]) {
        let covered = messageIDs
        for (id, entry) in local where covered.contains(id) {
            var counters = ClaudeCloudCounters()
            counters.input = entry.inputTokens; counters.output = entry.outputTokens
            counters.read = entry.cacheReadTokens; counters.write = entry.cacheCreationTokens
            counters.cost = entry.costUSD
            localDeductions[id] = ClaudeCloudRecord(model: entry.model, timestamp: entry.timestamp, usage: counters)
        }
    }
    var messageIDs: Set<String> { sessions.values.reduce(into: Set<String>()) { $0.formUnion($1.messageIDs) } }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("yybar/claude-cloud-usage/state.json")
    }
    static func load(from url: URL = fileURL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw ClaudeCloudError.invalidData }
        return state
    }
    func save(to url: URL = Self.fileURL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

nonisolated enum ClaudeCloudError: Error, LocalizedError {
    case invalidData, counterReset, identity, truncated, http(Int, TimeInterval)
    var errorDescription: String? {
        switch self {
        case .invalidData: return "云端记录格式不完整，保留已同步数据 / Incomplete cloud data"
        case .counterReset: return "云端累计用量回退，保留旧数据 / Cloud counters decreased"
        case .identity: return "请先登录本机 Claude Code / Sign in to Claude Code first"
        case .truncated: return "项目列表或历史不完整，稍后继续同步 / Incomplete project history"
        case .http(let status, _): return "云端同步失败 HTTP \(status)，保留已同步数据 / Cloud sync failed"
        }
    }
}

nonisolated enum ClaudeCloudUsageClient {
    /// 复用本机 Claude Code 登录，只读 Projects。接口属于 Projects beta；变更时显式报错，不清空账本。
    static func sync(_ original: ClaudeCloudLedger, now: Date = Date()) async -> ClaudeCloudLedger {
        if let next = original.nextAttempt, now < next { return original }
        var ledger = original
        ledger.nextAttempt = now.addingTimeInterval(300)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let network = URLSession(configuration: config)
        defer { network.invalidateAndCancel() }
        do {
            let identityURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: identityURL)) as? [String: Any],
                  let oauth = root["oauthAccount"] as? [String: Any],
                  let org = oauth["organizationUuid"] as? String, UUID(uuidString: org) != nil,
                  let accountID = oauth["accountUuid"] as? String else { throw ClaudeCloudError.identity }
            var account = try ClaudeAuth.load()
            let token = try await ClaudeTokenRefresher.ensureFreshAccessToken(account: &account).get()
            let accountKey = SHA256.hash(data: Data("\(accountID)/\(org)".utf8)).map { String(format: "%02x", $0) }.joined()
            func get(_ path: String) async throws -> [String: Any] {
                var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/code/" + path)!)
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue("ccr-byoc-2025-07-29", forHTTPHeaderField: "anthropic-beta")
                request.setValue(org, forHTTPHeaderField: "x-organization-uuid")
                let (data, response) = try await network.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClaudeCloudError.invalidData }
                guard http.statusCode == 200 else {
                    let retry = http.value(forHTTPHeaderField: "Retry-After") ?? ""
                    let dateFormat = DateFormatter()
                    dateFormat.locale = Locale(identifier: "en_US_POSIX")
                    dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
                    dateFormat.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                    let delay = max(600, Double(retry) ?? dateFormat.date(from: retry)?.timeIntervalSince(now) ?? 600)
                    throw ClaudeCloudError.http(http.statusCode, delay)
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeCloudError.invalidData }
                return json
            }
            func safeID(_ value: Any?) throws -> String {
                guard let id = value as? String, !id.isEmpty,
                      id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 })
                else { throw ClaudeCloudError.invalidData }
                return id
            }
            let channels = try await get("channels?scope=all")
            guard let projects = channels["data"] as? [[String: Any]],
                  channels["has_more"] as? Bool != true, channels["next_cursor"] == nil || channels["next_cursor"] is NSNull
            else { throw ClaudeCloudError.truncated }
            for project in projects {
                // 早于回补起点且无后续活动的项目无需下载会话正文。
                if let last = project["last_message_at"] as? String, let time = JSONLTimestamp.parse(last), time < ledger.since { continue }
                let id = try safeID(project["id"])
                let usage = try await get("channels/\(id)/usage")
                guard usage["truncated"] as? Bool == false,
                      let threads = usage["top_sessions"] as? [[String: Any]] else { throw ClaudeCloudError.truncated }
                var sessions = threads
                if let coordinator = usage["channel_session"] as? [String: Any] { sessions.append(coordinator) }
                for info in sessions {
                    let sessionID = try safeID(info["session_id"])
                    let key = "\(accountKey)/\(sessionID)"
                    var session = ledger.sessions[key] ?? ClaudeCloudSession()
                    if session.cursor == 0 {
                        let detail = try await get("sessions/\(sessionID)")
                        guard let shape = detail["response_shape"] as? [String: Any],
                              let environment = shape["environment_kind"] as? String else { throw ClaudeCloudError.invalidData }
                        if environment != "anthropic_cloud" { continue } // bridge / Remote Control 已由本机日志统计。
                    }
                    let expected = (info["usage"] as? [String: Any]).flatMap { ClaudeCloudSession.integer($0["total_tokens"]) }
                    if session.cursor > 0, expected == session.total { continue }
                    var complete = false
                    for _ in 0..<100 {
                        let page = try await get("sessions/\(sessionID)/events?limit=500&sort_order=asc&cursor=\(session.cursor)")
                        let oldCursor = session.cursor
                        try session.consume(page, since: ledger.since)
                        let next = ClaudeCloudSession.integer(page["next_cursor"])
                        if next == nil { complete = true; break }
                        guard next == session.cursor, session.cursor > oldCursor else { throw ClaudeCloudError.invalidData }
                    }
                    guard complete else { throw ClaudeCloudError.truncated }
                    ledger.sessions[key] = session
                }
            }
            ledger.lastSuccess = now
            ledger.lastError = nil
        } catch {
            // 错误文字不包含响应体、会话内容、邮箱或凭据。
            if let failure = error as? ClaudeCloudError {
                ledger.lastError = failure.localizedDescription
                if case .http(429, let delay) = failure { ledger.nextAttempt = now.addingTimeInterval(delay) }
            } else {
                ledger.lastError = "云端连接或登录暂不可用，保留已同步数据 / Cloud connection or sign-in unavailable"
            }
        }
        return ledger
    }
}
