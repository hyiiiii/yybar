import CommonCrypto
import Foundation
import SQLite3

/// 近期会话样本里实际回答的模型；不是可选模型列表，也不是完整调用统计。
struct GeminiRecentModels: Codable, Equatable, Sendable {
    var names: [String]
    var sampledTurns: Int
    var fetchedAt: Date
}

/// 一次读取近期会话的结果：新读到的回答、读过的会话(摘要 → 更新时间)、近期模型样本(没读到回答时为 nil)。
nonisolated struct GeminiActivity: Sendable {
    var answers: [GeminiAnswerLog.Answer] = []
    var chats: [String: Double] = [:]
    var recent: GeminiRecentModels?
    /// 诊断：多少条回答用了自己的时间戳、多少条用会话更新时间代替。
    var timedByTurn = 0
    var timedByChat = 0
}

/// Gemini Apps 的网页额度，与 agy / Gemini CLI 的额度池独立。
/// 只读额度与近期会话模型元数据；不保存对话正文、不发送推理、不刷新 Google 登录。
/// 协议参考 diegoparras/tokenyou/src/adapters/gemini.js、HanaokaYuzu/Gemini-API。
enum GeminiAppQuotaClient {
    /// 每次最多读几个有更新的会话、每个会话最多取最近几轮。
    nonisolated static let activityChatsPerRun = 6
    nonisolated static let activityTurnsPerChat = 30
    /// 最近 30 轮全是新回答时补读的轮数。
    nonisolated static let activityTurnsBackfill = 200

    /// 读取近期会话里的回答：列出最近 20 个会话(普通 + 置顶)，只读更新时间比上次读取时新的会话(新的优先，
    /// 每次最多 activityChatsPerRun 个，其余下次再读)，每个取最近 activityTurnsPerChat 轮。
    /// 每条回答只取 回答 ID 摘要、时间(取不到就用会话更新时间)、模型名;响应里虽有正文，但不提取、不保存，
    /// 也不保存会话标题或会话 ID。最近 6 条回答的模型作为「近期模型」样本。目录中的可选模型只用于 ID → 名称映射。
    nonisolated static func fetchActivity(session login: GeminiChromeSession, log: GeminiAnswerLog) async -> Result<GeminiActivity, QuotaError> {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: GeminiQuotaRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var page = URLComponents(string: "https://gemini.google.com/app")!
            page.queryItems = [URLQueryItem(name: "authuser", value: login.email)]
            var pageRequest = URLRequest(url: page.url!, timeoutInterval: 25)
            pageRequest.setValue(login.cookieHeader, forHTTPHeaderField: "Cookie")
            browserHeaders(&pageRequest, rpc: false)
            let parameters = try pageParameters(await response(pageRequest, session: session))
            func rpc(_ id: String, _ arguments: [Any]) async throws -> [Any] {
                let args = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
                let envelope = String(decoding: try JSONSerialization.data(withJSONObject: [[[id, args, NSNull(), "generic"]]]), as: UTF8.self)
                var url = URLComponents(string: "https://gemini.google.com/_/BardChatUi/data/batchexecute")!
                url.queryItems = [URLQueryItem(name: "rpcids", value: id), URLQueryItem(name: "bl", value: parameters.build),
                                  URLQueryItem(name: "authuser", value: login.email), URLQueryItem(name: "rt", value: "c")]
                var request = URLRequest(url: url.url!, timeoutInterval: 25)
                request.httpMethod = "POST"
                request.setValue(login.cookieHeader, forHTTPHeaderField: "Cookie")
                request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
                browserHeaders(&request, rpc: true)
                request.httpBody = Data(("f.req=" + formEncode(envelope) + "&at=" + formEncode(parameters.token)).utf8)
                let data = try await response(request, session: session)
                guard let payload = rpcPayload(data: data, id: id) else { throw QuotaError.decode("Gemini 会话元数据不可读") }
                return payload
            }
            func turnsOf(_ id: String, limit: Int) async throws -> [[Any]] {
                try await rpc("hNvQHb", [id, limit, NSNull(), 1, [1], [4], NSNull(), 1]).first as? [[Any]] ?? []
            }
            let registry = modelNames(status: try await rpc("otAQ7b", []))
            guard !registry.isEmpty else { throw QuotaError.decode("Gemini 模型目录不可读") }
            var chats: [String: Double] = [:]
            for pinned in [0, 1] {
                let payload = try await rpc("MaZiqc", [20, NSNull(), [pinned, NSNull(), 1]])
                guard payload.count > 2, let rows = payload[2] as? [[Any]] else { continue }
                for row in rows {
                    guard let id = row.first as? String, id.hasPrefix("c_") else { continue }
                    let timestamp = row.count > 5 ? (row[5] as? [Any])?.first.flatMap(number) ?? 0 : 0
                    chats[id] = max(chats[id] ?? 0, timestamp)
                }
            }
            let changed = chats
                .filter { id, updated in log.chats[GeminiAnswerLog.digest(id)].map { $0 < updated } ?? true }
                .sorted { $0.value > $1.value }
                .prefix(activityChatsPerRun)
            var activity = GeminiActivity()
            let counted = Set(log.counted)
            for (id, updated) in changed {
                // 会话没给更新时间(0)时：没有时间戳的回答记在今天，也不记下这个会话(下次照样读，回答按 ID 去重)。
                let fallback = updated > 0 ? Date(timeIntervalSince1970: updated) : Date()
                var turns = try await turnsOf(id, limit: activityTurnsPerChat)
                // 取满了而最旧的一轮还没记过：上次读完后新增的回答可能不止这些，再多取一次，免得漏算。
                if turns.count >= activityTurnsPerChat,
                   let oldest = turns.last.flatMap({ answer(turn: $0, registry: registry, fallback: fallback) }),
                   !counted.contains(oldest.answer.digest) {
                    turns = try await turnsOf(id, limit: activityTurnsBackfill)
                }
                for turn in turns {
                    guard let parsed = answer(turn: turn, registry: registry, fallback: fallback) else { continue }
                    activity.answers.append(parsed.answer)
                    if parsed.timeFromTurn { activity.timedByTurn += 1 } else { activity.timedByChat += 1 }
                }
                if updated > 0 { activity.chats[GeminiAnswerLog.digest(id)] = updated }
            }
            let latest = activity.answers.sorted { $0.time > $1.time }.prefix(6)
            if !latest.isEmpty {
                activity.recent = GeminiRecentModels(names: Set(latest.map(\.model)).sorted(), sampledTurns: latest.count, fetchedAt: Date())
            }
            return .success(activity)
        } catch let error as QuotaError { return .failure(error) }
        catch { return .failure(.transport("Gemini 会话读取失败")) }
    }

    /// 一轮对话里的回答：要有回答 ID(`turn[0][1]`)和回答内容(`turn[3][0]` 候选)。
    /// 模型取回答元数据 [14] / [17] 的模型 ID(用户消息里的只是请求的模型)，认不出就记为「Gemini」。
    /// 时间优先取这一轮自己的时间戳，取不到用会话更新时间(fallback)。
    nonisolated static func answer(turn: [Any], registry: [String: String], fallback: Date,
                                   now: Date = Date()) -> (answer: GeminiAnswerLog.Answer, timeFromTurn: Bool)? {
        guard turn.count > 3, let ids = turn.first as? [Any], ids.count > 1,
              let responseID = ids[1] as? String, !responseID.isEmpty,
              let reply = turn[3] as? [Any], let candidates = reply.first as? [Any], !candidates.isEmpty else { return nil }
        let model = [14, 17].lazy.compactMap { index -> String? in
            guard reply.count > index, let id = reply[index] as? String else { return nil }
            return registry[id]
        }.first ?? "Gemini"
        let time = turnTime(turn, now: now)
        return (GeminiAnswerLog.Answer(digest: GeminiAnswerLog.digest(responseID), time: time ?? fallback, model: model), time != nil)
    }

    /// 这一轮的时间戳 `[秒, 纳秒]`:先看 turn[4],再看除用户消息 [2]、回答 [3] 以外的顶层字段。
    /// 秒数要落在 2020-09 之后、现在 + 1 天之内，免得把别的数字对当成时间。
    nonisolated static func turnTime(_ turn: [Any], now: Date = Date()) -> Date? {
        func pair(_ value: Any) -> Date? {
            guard let array = value as? [Any], let first = array.first, let seconds = number(first),
                  seconds > 1_600_000_000, seconds < now.timeIntervalSince1970 + 86_400 else { return nil }
            let nanos = array.count > 1 ? (number(array[1]) ?? 0) : 0
            guard nanos >= 0, nanos < 1_000_000_000 else { return nil }
            return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
        }
        if turn.count > 4, let time = pair(turn[4]) { return time }
        for (index, value) in turn.enumerated() where index != 2 && index != 3 {
            if let time = pair(value) { return time }
        }
        return nil
    }

    nonisolated static func rpcPayload(data: Data, id: String) -> [Any]? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let rows = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[Any]] else { continue }
            for row in rows where row.count > 2 && row[0] as? String == "wrb.fr" && row[1] as? String == id {
                if let text = row[2] as? String,
                   let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] { return payload }
            }
        }
        return nil
    }

    nonisolated static func modelNames(status: [Any]) -> [String: String] {
        guard status.count > 15, let rows = status[15] as? [[Any]] else { return [:] }
        var result: [String: String] = [:]
        for row in rows where row.count > 1 {
            guard let id = row[0] as? String, let name = row[1] as? String,
                  !id.isEmpty, !name.isEmpty, name.count <= 80, !name.contains("\n") else { continue }
            result[id] = name
        }
        return result
    }

    nonisolated static func recentModels(turns: [Any], registry: [String: String], now: Date = Date()) -> GeminiRecentModels {
        var names = Set<String>()
        var count = 0
        for turn in turns.first as? [[Any]] ?? [] {
            guard turn.count > 3, let answer = turn[3] as? [Any] else { continue }
            // 回答元数据 [14] / [17] 是模型 ID；用户消息 [2][4] 只是请求的模型，不作为执行证据。
            let model = [14, 17].lazy.compactMap { index -> String? in
                guard answer.count > index, let id = answer[index] as? String else { return nil }
                return registry[id]
            }.first
            if let model { names.insert(model); count += 1 }
        }
        return GeminiRecentModels(names: names.sorted(), sampledTurns: count, fetchedAt: now)
    }

    nonisolated static func fetch(session login: GeminiChromeSession) async -> Result<QuotaSnapshot, QuotaError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: GeminiQuotaRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var page = URLComponents(string: "https://gemini.google.com/app")!
            page.queryItems = [URLQueryItem(name: "authuser", value: login.email)]
            var request = URLRequest(url: page.url!, timeoutInterval: 25)
            request.setValue(login.cookieHeader, forHTTPHeaderField: "Cookie")
            browserHeaders(&request, rpc: false)
            let html = try await response(request, session: session)
            let parameters = try pageParameters(html)
            var endpoint = URLComponents(string: "https://gemini.google.com/_/BardChatUi/data/batchexecute")!
            endpoint.queryItems = [
                URLQueryItem(name: "rpcids", value: "jSf9Qc"),
                URLQueryItem(name: "source-path", value: "/usage"),
                URLQueryItem(name: "bl", value: parameters.build),
                URLQueryItem(name: "authuser", value: login.email),
                URLQueryItem(name: "hl", value: "en"), URLQueryItem(name: "rt", value: "c")
            ]
            request = URLRequest(url: endpoint.url!, timeoutInterval: 25)
            request.httpMethod = "POST"
            request.setValue(login.cookieHeader, forHTTPHeaderField: "Cookie")
            request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            browserHeaders(&request, rpc: true)
            request.httpBody = Data(("f.req=" + formEncode(#"[[["jSf9Qc","[]",null,"generic"]]]"#)
                                    + "&at=" + formEncode(parameters.token)).utf8)
            return .success(try parse(data: await response(request, session: session)))
        } catch let error as QuotaError { return .failure(error) }
        catch { return .failure(.transport("Gemini Apps 额度请求失败")) }
    }

    /// 和 Gemini 网页自己发的请求一样带上浏览器 UA / 语言;数据请求(batchexecute)再带 Origin、Referer、X-Same-Domain。
    /// 不带这些、用 CFNetwork 默认 UA 的请求更容易被 Google 当成自动程序转到 /sorry 验证页。Cookie 本来就取自 Chrome,UA 也用 Chrome 的。
    nonisolated static func browserHeaders(_ request: inout URLRequest, rpc: Bool) {
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        guard rpc else { return }
        request.setValue("https://gemini.google.com", forHTTPHeaderField: "Origin")
        request.setValue("https://gemini.google.com/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "X-Same-Domain")
    }

    nonisolated private static func response(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.transport("non-http") }
        try validateResponse(http, data: data)
        return data
    }

    /// 不跟随 Google 验证跳转，也不把它误当成 Cookie 失效。错误中不包含跳转查询参数。
    nonisolated static func validateResponse(_ http: HTTPURLResponse, data: Data = Data()) throws {
        let location = http.value(forHTTPHeaderField: "Location")
            .flatMap { URL(string: $0, relativeTo: http.url)?.absoluteURL }
        func isVerificationURL(_ url: URL?) -> Bool {
            guard let url, ["google.com", "www.google.com"].contains(url.host?.lowercased() ?? "") else { return false }
            return url.path == "/sorry" || url.path.hasPrefix("/sorry/")
        }
        let html = http.mimeType == "text/html" ? String(decoding: data, as: UTF8.self) : ""
        let hasVerificationForm = (html.contains("id=\"captcha-form\"") || html.contains("id='captcha-form'"))
            && (html.contains("/sorry/") || html.contains("google.com/recaptcha"))
        if isVerificationURL(location) || isVerificationURL(http.url) || hasVerificationForm {
            throw QuotaError.webVerificationRequired
        }
        if (300..<400).contains(http.statusCode) {
            if location?.host?.lowercased() == "accounts.google.com" { throw QuotaError.missingToken }
            throw QuotaError.transport("Gemini 页面跳转异常，请稍后重试")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.http(http.statusCode, "Gemini Apps quota request failed")
        }
    }

    nonisolated static func pageParameters(_ data: Data) throws -> (token: String, build: String) {
        let html = String(decoding: data, as: UTF8.self)
        func value(_ key: String) -> String? {
            let pattern = "\"\(key)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html),
                  let value = try? JSONSerialization.jsonObject(with: Data(html[range].utf8), options: .fragmentsAllowed) as? String,
                  !value.isEmpty else { return nil }
            return value
        }
        guard let token = value("SNlM0e"), let build = value("cfb2h") else { throw QuotaError.missingToken }
        return (token, build)
    }

    /// batchexecute: 防 XSSI 前缀、字节长度行、JSON envelope；窗口顺序不固定。
    /// w[0] 是服务内部额度单位，不是 token；只取 w[1] 使用比例和 w[3] 重置时间。
    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        var payload: [Any]?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let rows = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[Any]] else { continue }
            for row in rows where row.count >= 3 {
                guard row[0] as? String == "wrb.fr", row[1] as? String == "jSf9Qc",
                      let encoded = row[2] as? String,
                      let decoded = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [Any] else { continue }
                payload = decoded
            }
        }
        guard let payload, payload.count >= 2, let windows = payload[1] as? [[Any]] else {
            throw QuotaError.decode("Gemini Apps 未返回额度窗口")
        }
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        for item in windows {
            guard item.count >= 3, let kind = number(item[2]), kind == 1 || kind == 2 else { continue }
            guard let fraction = number(item[1]), (0...1).contains(fraction) else {
                throw QuotaError.decode("Gemini Apps 额度比例无效")
            }
            var reset: Date?
            if item.count > 3, let timestamps = item[3] as? [[Any]], let timestamp = timestamps.first,
               let seconds = timestamp.first.flatMap(number), seconds > 0 {
                let nanos = timestamp.count > 1 ? (number(timestamp[1]) ?? 0) : 0
                reset = Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
            }
            let window = QuotaWindow(usedPercent: fraction * 100, resetsAt: reset,
                                     windowSeconds: kind == 1 ? 5 * 3600 : 7 * 86400)
            if kind == 1 {
                guard fiveHour == nil else { throw QuotaError.decode("Gemini Apps 重复的当前窗口") }
                fiveHour = window
            } else {
                guard weekly == nil else { throw QuotaError.decode("Gemini Apps 重复的每周窗口") }
                weekly = window
            }
        }
        guard fiveHour != nil || weekly != nil else { throw QuotaError.decode("Gemini Apps 没有可读额度") }
        return QuotaSnapshot(app: .gemini, fiveHour: fiveHour, weekly: weekly, weeklyOpus: nil,
                             weeklySonnet: nil, planType: nil, fetchedAt: now)
    }

    /// Google AI 订阅（Gemini App 和同一 Google 账号的 Antigravity 共用）。额度 RPC 不带套餐名。
    nonisolated static func fetchPlan(session login: GeminiChromeSession) async -> String? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: GoogleOneRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://one.google.com/settings")!, timeoutInterval: 25)
        request.setValue(login.cookieHeader, forHTTPHeaderField: "Cookie")
        browserHeaders(&request, rpc: false)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return GoogleOnePlan.parse(html: String(decoding: data, as: UTF8.self))
        } catch { return nil }
    }

    nonisolated private static func number(_ value: Any) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    nonisolated private static func formEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }
}

/// 当前 Google AI 套餐。只认设置页会员数据里的名字，页面上的升级文案不算。
enum GoogleOnePlan {
    nonisolated static let names: Set<String> = [
        "Google AI Ultra 20x", "Google AI Ultra 5x", "Google AI Ultra",
        "Google AI Pro", "Google AI Plus", "Gemini Advanced",
    ]

    nonisolated static func parse(html: String) -> String? {
        var found: [String] = []
        var search = html.startIndex
        while let call = html.range(of: "AF_initDataCallback(", range: search..<html.endIndex) {
            search = call.upperBound
            guard let dataKey = html.range(of: "data:", range: call.upperBound..<html.endIndex),
                  html.distance(from: call.upperBound, to: dataKey.lowerBound) < 160 else { continue }
            var index = dataKey.upperBound
            while index < html.endIndex, html[index].isWhitespace { index = html.index(after: index) }
            guard index < html.endIndex, html[index] == "[" || html[index] == "{" else { continue }
            guard let end = jsonValueEnd(html, from: index),
                  let value = try? JSONSerialization.jsonObject(with: Data(html[index..<end].utf8)) else { continue }
            collectMembership(value, into: &found)
        }
        let plans = Set(found)
        return plans.count == 1 ? plans.first : nil
    }

    /// 会员行是 `[ [配额字节, 容量文案], null, null, null, 套餐名, ... ]`。
    nonisolated private static func collectMembership(_ value: Any, into found: inout [String]) {
        guard let rows = value as? [Any] else { return }
        for row in rows {
            if let row = row as? [Any], row.count > 4,
               let storage = row[0] as? [Any], storage.count >= 2,
               storage[0] is String, storage[1] is String,
               let plan = row[4] as? String, names.contains(plan) {
                found.append(plan)
            }
            collectMembership(row, into: &found)
        }
    }

    nonisolated private static func jsonValueEnd(_ html: String, from start: String.Index) -> String.Index? {
        var index = start
        var stack: [Character] = []
        var inString = false
        var escape = false
        while index < html.endIndex {
            let character = html[index]
            if inString {
                if escape { escape = false }
                else if character == "\\" { escape = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "[", "{": stack.append(character)
                case "]":
                    guard stack.last == "[" else { return nil }
                    stack.removeLast()
                    if stack.isEmpty { return html.index(after: index) }
                case "}":
                    guard stack.last == "{" else { return nil }
                    stack.removeLast()
                    if stack.isEmpty { return html.index(after: index) }
                default: break
                }
            }
            index = html.index(after: index)
            if html.distance(from: start, to: index) > 1_500_000 { return nil }
        }
        return nil
    }
}

/// Cookie 只能发往 Gemini 的 HTTPS 主机；登录跳转交给用户在 Chrome 中完成。
private final class GeminiQuotaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "gemini.google.com" ? request : nil)
    }
}

/// 套餐页只留在 one.google.com，登录跳转不跟着走。
private final class GoogleOneRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "one.google.com" ? request : nil)
    }
}

struct GeminiChromeSession: Sendable {
    var email: String
    var cookieHeader: String
    /// 这份 Chrome 登录的指纹(__Secure-1PSID + 异常流量豁免 Cookie 的 SHA-256 前 16 位，不含原文)。
    /// Google 拒绝过这份登录后，定时刷新就不再拿它去请求，等 Chrome 重新登录 / 通过验证(指纹变了)再继续。
    var loginID: String
}

struct GeminiProfileError: Error {
    var message: String
}

enum GeminiChromeAuthError: Error {
    case notSignedIn
    case keychainDenied(String)
    case unreadableCookies
}

/// 仅读取 Chrome 当前个人资料的 Google 会话 Cookie。钥匙串密钥仅驻留 yybar 内存。
enum GeminiChromeAuth {
    nonisolated static var chromeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
    }

    nonisolated static func profile() -> (directory: URL, email: String)? {
        if case .success(let value) = loadProfile() { return value }
        return nil
    }

    /// 失败原因只含错误码和阶段，不含邮箱或文件内容。
    nonisolated static func loadProfile() -> Result<(directory: URL, email: String), GeminiProfileError> {
        let url = chromeRoot.appendingPathComponent("Local State")
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let ns = error as NSError
            return .failure(GeminiProfileError(message: "read Local State \(ns.domain) \(ns.code)"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profile"] as? [String: Any] else {
            return .failure(GeminiProfileError(message: "Local State has no profile object"))
        }
        guard let info = profiles["info_cache"] as? [String: [String: Any]] else {
            return .failure(GeminiProfileError(message: "Chrome profile info_cache is not readable"))
        }
        let name = profiles["last_used"] as? String ?? "Default"
        guard !name.contains("/"), name != "..", name != "." else {
            return .failure(GeminiProfileError(message: "Chrome profile name is unsafe"))
        }
        guard let email = info[name]?["user_name"] as? String, email.contains("@") else {
            return .failure(GeminiProfileError(message: "Chrome profile has no Google account"))
        }
        return .success((chromeRoot.appendingPathComponent(name), email))
    }

    /// 菜单栏进程里 `SecItemCopyMatching` 可能一直等一个出不来的钥匙串弹窗，把整次刷新卡死。
    /// Chrome 这一项本来就能被本用户的 `security` 读到，这里限时调用，失败就把原因留在错误里。
    nonisolated static func loadKey() -> Result<Data, GeminiChromeAuthError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Chrome Safe Storage", "-a", "Chrome", "-w"]
        let output = Pipe()
        let error = Pipe()
        proc.standardOutput = output
        proc.standardError = error
        do { try proc.run() } catch {
            return .failure(.keychainDenied("security launch failed"))
        }
        let deadline = Date().addingTimeInterval(8)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            return .failure(.keychainDenied("timed out"))
        }
        let errText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0 else {
            if errText.localizedCaseInsensitiveContains("could not be found") { return .failure(.notSignedIn) }
            let message = errText.isEmpty ? "exit \(proc.terminationStatus)" : String(errText.prefix(180))
            return .failure(.keychainDenied(message))
        }
        let password = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let key = GrokBotAuth.deriveKey(password: password) else { return .failure(.unreadableCookies) }
        return .success(key)
    }

    nonisolated static func loadSession(key: Data, now: Date = Date()) throws -> GeminiChromeSession {
        guard let profile = profile() else { throw GeminiChromeAuthError.notSignedIn }
        let candidates = ["Network/Cookies", "Cookies"].map { profile.directory.appendingPathComponent($0) }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw GeminiChromeAuthError.notSignedIn
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw GeminiChromeAuthError.unreadableCookies
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var meta: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &meta, nil) == SQLITE_OK,
           sqlite3_step(meta) == SQLITE_ROW { version = Int(sqlite3_column_int(meta, 0)) }
        sqlite3_finalize(meta)
        guard version > 0 else { throw GeminiChromeAuthError.unreadableCookies }
        // 不读取其他网站、其他 Cookie 或浏览记录。GOOGLE_ABUSE_EXEMPTION 是在 Chrome 里通过 Google「异常流量」验证后
        // 发的豁免 Cookie(有效期约 1 小时);不带它，Chrome 里验证过了 yybar 的请求仍会被转到 /sorry。
        let sql = """
        SELECT name, value, encrypted_value, expires_utc FROM cookies
        WHERE host_key='.google.com' AND name IN ('__Secure-1PSID','__Secure-1PSIDTS','GOOGLE_ABUSE_EXEMPTION')
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw GeminiChromeAuthError.unreadableCookies
        }
        defer { sqlite3_finalize(statement) }
        var cookies: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let nameBytes = sqlite3_column_text(statement, 0) else { continue }
            let name = String(cString: nameBytes)
            let expires = Double(sqlite3_column_int64(statement, 3)) / 1_000_000 - 11_644_473_600
            guard expires <= -11_644_473_600 || expires > now.timeIntervalSince1970 else { continue }
            var value = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            if value.isEmpty, let bytes = sqlite3_column_blob(statement, 2) {
                let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
                value = try decryptCookie(encrypted, key: key, host: ".google.com", version: version)
            }
            guard !value.isEmpty, !value.contains(";"), !value.contains("\r"), !value.contains("\n") else { continue }
            cookies[name] = value
        }
        guard let psid = cookies["__Secure-1PSID"] else { throw GeminiChromeAuthError.notSignedIn }
        let fingerprint = Array((psid + "|" + (cookies["GOOGLE_ABUSE_EXEMPTION"] ?? "")).utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256(fingerprint, CC_LONG(fingerprint.count), &hash)
        return GeminiChromeSession(email: profile.email,
                                   cookieHeader: cookies.keys.sorted().map { "\($0)=\(cookies[$0]!)" }.joined(separator: "; "),
                                   loginID: hash.prefix(8).map { String(format: "%02x", $0) }.joined())
    }

    nonisolated static func decryptCookie(_ data: Data, key: Data, host: String, version: Int) throws -> String {
        guard var plain = GrokBotAuth.decrypt(data, key: key) else { throw GeminiChromeAuthError.unreadableCookies }
        if version >= 24 {
            let bytes = Array(host.utf8)
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = CC_SHA256(bytes, CC_LONG(bytes.count), &hash)
            guard plain.count > hash.count, plain.prefix(hash.count) == Data(hash) else {
                throw GeminiChromeAuthError.unreadableCookies
            }
            plain = Data(plain.dropFirst(hash.count))
        }
        guard let value = String(data: plain, encoding: .utf8) else { throw GeminiChromeAuthError.unreadableCookies }
        return value
    }
}
