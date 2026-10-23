import CommonCrypto
import Foundation

// 此独立回归不读真实登录、不读钥匙串、不联网、不运行 agy;只验证 Gemini / agy 与 Grok Bot 的响应解析和
// Grok Bot 登录文件的解密(用自造的口令和 token)。

@main
struct GoogleQuotaRegression {
    static func main() throws {
        // agy 1.3.5 `agy -p /usage --output-format json` 的真实输出结构(数值改过)。
        let usage = """
        {"conversation_id":"","status":"SUCCESS","response":"…","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
            {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.88,"reset_time":"2026-10-26T13:32:25Z"},
            {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.72,"reset_time":"2026-10-19T18:32:25Z"}]},
          {"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
            {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-26T13:32:25Z"},
            {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","reset_time":"2026-10-19T18:32:25Z"}]}]}}}
        """
        let result = try GoogleQuotaClient.parse(data: Data(usage.utf8))
        let gemini = result.gemini!, agy = result.agy!
        precondition(gemini.app == .gemini && agy.app == .agy)
        precondition(abs(gemini.fiveHour!.remainingPercent - 72) < 0.001)
        precondition(abs(gemini.weekly!.remainingPercent - 88) < 0.001)
        precondition(gemini.fiveHour!.resetsAt == ISO8601DateFormatter().date(from: "2026-10-19T18:32:25Z"))
        precondition(agy.weekly!.remainingPercent == 100)
        // 没有 remaining_fraction 的档位视为未知，不当成用完。
        precondition(agy.fiveHour == nil)

        // Antigravity 格子 = agy 两个池子：逐池列出，单个数字取剩余最少的池。
        let combined = QuotaPool.antigravity(gemini: gemini, thirdParty: agy)!
        precondition(combined.app == .agy && combined.pools?.map(\.label) == ["Gemini", "Claude·GPT"])
        precondition(abs(combined.fiveHour!.remainingPercent - 72) < 0.001)   // 只有 Gemini 池有 5H
        precondition(abs(combined.weekly!.remainingPercent - 88) < 0.001)     // 88 < 100
        precondition(QuotaPool.antigravity(gemini: nil, thirdParty: nil) == nil)

        // 失败状态:限流按 429 处理(走退避),其他为解码错误。
        do {
            _ = try GoogleQuotaClient.parse(data: Data(#"{"status":"ERROR","error":"429 RESOURCE_EXHAUSTED"}"#.utf8))
            preconditionFailure("expected rate limit")
        } catch let error as QuotaError { precondition(error.isRateLimited) }
        do {
            _ = try GoogleQuotaClient.parse(data: Data("not json".utf8))
            preconditionFailure("expected decode error")
        } catch let error as QuotaError { if case .decode = error {} else { preconditionFailure("\(error)") } }

        // 独立目录没登录：先打印提示，最后一行是 ERROR JSON → 视为未登录。
        let unauth = "Error: authentication required. Run 'agy' to log in, then retry.\nerror: authentication failed or timed out\n"
            + #"{"conversation_id":"","status":"ERROR","response":"","error":"authentication failed or timed out"}"#
        do {
            _ = try GoogleQuotaClient.parse(data: Data(unauth.utf8))
            preconditionFailure("expected missing token")
        } catch let error as QuotaError { if case .missingToken = error {} else { preconditionFailure("\(error)") } }

        // Grok Bot:GetSandUsageStatusResponse(Connect JSON)。
        let sand = """
        {"currentPeriodStart":"2026-10-17T00:00:00Z","nextResetTimestampUtc":"2026-10-24T00:00:00Z",
         "usagePercent":39.5,"hasNonZeroIncludedLimit":true,"grokPlanLabel":"SuperGrok"}
        """
        let bot = try GrokBotQuotaClient.parse(data: Data(sand.utf8))
        precondition(bot.app == .grokBot && abs(bot.primary!.remainingPercent - 60.5) < 0.001)
        precondition(bot.primary!.windowSeconds == 7 * 86400 && bot.planType == "SuperGrok")
        // 新周期省略 usagePercent → 0% 已用。
        let fresh = try GrokBotQuotaClient.parse(data: Data("{}".utf8))
        precondition(fresh.primary!.usedPercent == 0)
        do {
            _ = try GrokBotQuotaClient.parse(data: Data(#"{"usesPooledEnterpriseAllowance":true}"#.utf8))
            preconditionFailure("expected pooled allowance error")
        } catch is QuotaError {}

        try grokBotAuth()
        try geminiAppQuota()
        try geminiResponseFailures()
        googlePlan()
        grokBotUsage()
        geminiRecentModels()
        try geminiAnswers()
        precondition(!Pricing.hasDisplayableCost(app: .grokBot, model: "gemini-2.5-flash", cost: 0))
        precondition(Pricing.hasDisplayableCost(app: .grokBot, model: "grok-bot-default", cost: 1))
        precondition(Pricing.hasDisplayableCost(app: .claude, model: "claude-opus-5-5", cost: 0))
        print("GoogleQuotaRegression OK")
    }

    static func geminiRecentModels() {
        var status: [Any] = Array(repeating: NSNull(), count: 16)
        status[15] = [["id-argon", "Argon"], ["id-flash", "Flash"], ["id-unused", "Pro"]]
        let registry = GeminiAppQuotaClient.modelNames(status: status)
        func turn(actual: String?, requested: String) -> [Any] {
            var answer: [Any] = Array(repeating: NSNull(), count: 18)
            if let actual { answer[14] = actual; answer[17] = actual }
            return [["private-chat-id", "private-turn-id"], [], ["private user content", NSNull(), NSNull(), NSNull(), requested], answer]
        }
        let result = GeminiAppQuotaClient.recentModels(turns: [[
            turn(actual: "id-argon", requested: "id-flash"),
            turn(actual: "id-argon", requested: "id-argon"),
            turn(actual: nil, requested: "id-flash"),
            turn(actual: "unknown-id", requested: "id-unused")
        ]], registry: registry)
        precondition(result.names == ["Argon"] && result.sampledTurns == 2)
        precondition(GeminiAppQuotaClient.recentModels(turns: [], registry: registry).names.isEmpty)
        let encoded = String(decoding: try! JSONEncoder().encode(result), as: UTF8.self)
        precondition(!encoded.contains("private") && !encoded.contains("id-argon"))
    }

    /// Gemini 回答次数：从一轮对话里取 回答 ID 摘要 / 时间 / 模型，记进 GeminiAnswerLog 时按回答去重。
    static func geminiAnswers() throws {
        var status: [Any] = Array(repeating: NSNull(), count: 16)
        status[15] = [["id-argon", "Argon"], ["id-flash", "Flash"]]
        let registry = GeminiAppQuotaClient.modelNames(status: status)
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        let fallback = Date(timeIntervalSince1970: 1_792_400_000)
        func turn(_ response: String, model: String?, time: [Any]?, answered: Bool = true) -> [Any] {
            var reply: [Any] = Array(repeating: NSNull(), count: 18)
            if answered { reply[0] = [["rc_private", ["private answer text"]]] }
            if let model { reply[14] = model }
            var result: [Any] = [["c_private", response], [], ["private user content"], reply]
            if let time { result.append(time) }
            return result
        }
        func parse(_ t: [Any]) -> (answer: GeminiAnswerLog.Answer, timeFromTurn: Bool)? {
            GeminiAppQuotaClient.answer(turn: t, registry: registry, fallback: fallback, now: now)
        }
        let a = parse(turn("r_1", model: "id-argon", time: [1_792_450_000, 500_000_000]))!
        precondition(a.timeFromTurn && a.answer.model == "Argon")
        precondition(abs(a.answer.time.timeIntervalSince1970 - 1_792_450_000.5) < 0.001)
        precondition(a.answer.digest.count == 32 && !a.answer.digest.contains("r_1"))
        // 认不出的模型记为 Gemini;没有自己的时间戳就用会话更新时间。
        let b = parse(turn("r_2", model: "unknown-id", time: nil))!
        precondition(!b.timeFromTurn && b.answer.time == fallback && b.answer.model == "Gemini")
        // 小数字对、未来超过一天的时间都不当时间戳。
        precondition(parse(turn("r_3", model: nil, time: [5, 1]))?.timeFromTurn == false)
        precondition(parse(turn("r_4", model: nil, time: [Int(now.timeIntervalSince1970) + 90_000, 0]))?.timeFromTurn == false)
        // 没有回答内容、没有回答 ID 的一轮不算。
        precondition(parse(turn("r_5", model: "id-argon", time: nil, answered: false)) == nil)
        precondition(parse(turn("", model: "id-argon", time: nil)) == nil)

        var log = GeminiAnswerLog(account: "someone@example.com")
        precondition(log.record([a.answer, b.answer, a.answer]) == 2, "Same answer counted twice")
        precondition(log.record([a.answer]) == 0)
        let wide = (Date(timeIntervalSince1970: 1_792_000_000), Date(timeIntervalSince1970: 1_793_000_000))
        precondition(log.total(from: wide.0, to: wide.1) == 2)
        precondition(log.byModel(from: wide.0, to: wide.1) == ["Argon": 1, "Gemini": 1])
        precondition(log.daily.values.reduce(0, +) == 2)
        precondition(log.firstDay(before: wide.1) == UsageDay.startOfDay(for: fallback))
        log.markChats(["chat": 5])
        log.markChats(["chat": 3])
        precondition(log.chats["chat"] == 5)
        // 存盘内容只有摘要、天、模型和次数，不含回答 / 会话 ID 和正文。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = String(decoding: try encoder.encode(log), as: UTF8.self)
        precondition(!encoded.contains("r_1") && !encoded.contains("private") && !encoded.contains("c_"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(GeminiAnswerLog.self, from: Data(encoded.utf8))
        precondition(decoded == log)
    }

    static func geminiAppQuota() throws {
        func response(_ windows: [Any], rpc: String = "jSf9Qc") throws -> Data {
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: [2, windows, 1]), as: UTF8.self)
            let envelope: [[Any]] = [["wrb.fr", "unrelated", "[]"], ["wrb.fr", rpc, payload]]
            return Data(")]}'\n123\n".utf8) + (try JSONSerialization.data(withJSONObject: envelope)) + Data("\n".utf8)
        }
        let quota = try GeminiAppQuotaClient.parse(data: response([
            [999999, 0.43, 2, [[1_800_000_000, 0]]],
            [123456, 0.12, 1, [[1_800_000_100, 0]]]
        ]))
        precondition(quota.app == .gemini)
        precondition(abs(quota.fiveHour!.remainingPercent - 88) < 0.001)
        precondition(abs(quota.weekly!.remainingPercent - 57) < 0.001)
        precondition(quota.weekly!.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        precondition(quota.pools == nil)
        precondition(quota.planType == nil)
        let zero = try GeminiAppQuotaClient.parse(data: response([[0, 0, 1]]))
        precondition(zero.fiveHour!.remainingPercent == 100 && zero.weekly == nil)
        for windows: [Any] in [[], [[0, true, 1]], [[0, -0.1, 1]], [[0, 1.1, 2]], [[0, 0, 5]],
                               [[0, 0, 1], [0, 0.5, 1]]] {
            do {
                _ = try GeminiAppQuotaClient.parse(data: response(windows))
                preconditionFailure("malformed / missing windows must not become 100%")
            } catch is QuotaError {}
        }
        do {
            _ = try GeminiAppQuotaClient.parse(data: response([[0, 0.5, 1]], rpc: "other"))
            preconditionFailure("must match quota RPC")
        } catch is QuotaError {}
        let params = try GeminiAppQuotaClient.pageParameters(Data(#"window.data={"SNlM0e":"test\u002bcsrf","cfb2h":"test-build"}"#.utf8))
        precondition(params.token == "test+csrf" && params.build == "test-build")
        do {
            _ = try GeminiAppQuotaClient.pageParameters(Data("<html>Sign in</html>".utf8))
            preconditionFailure("signed out page must require login")
        } catch let error as QuotaError { if case .missingToken = error {} else { preconditionFailure() } }
    }

    static func geminiResponseFailures() throws {
        func response(_ status: Int, location: String? = nil, type: String = "text/html") -> HTTPURLResponse {
            var headers = ["Content-Type": type]
            headers["Location"] = location
            return HTTPURLResponse(url: URL(string: "https://gemini.google.com/app")!, statusCode: status,
                                   httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        // 实际故障：Google 的异常流量验证跳转不能冒充登录过期。
        for status in [302, 429] {
            do {
                try GeminiAppQuotaClient.validateResponse(response(status, location: "https://www.google.com/sorry/index?continue=private"))
                preconditionFailure("expected browser verification")
            } catch let error as QuotaError {
                precondition(error.requiresBrowserVerification && !error.isAuthFailure)
                precondition(!error.description.contains("private"))
            }
        }
        do {
            try GeminiAppQuotaClient.validateResponse(response(302, location: "https://accounts.google.com/ServiceLogin"))
            preconditionFailure("expected login error")
        } catch let error as QuotaError {
            if case .missingToken = error {} else { preconditionFailure("\(error)") }
        }
        for target in ["https://example.com/sorry/index", "https://accounts.google.com.example.com/ServiceLogin", "/unexpected"] {
            do {
                try GeminiAppQuotaClient.validateResponse(response(302, location: target))
                preconditionFailure("expected unexpected redirect")
            } catch let error as QuotaError {
                if case .transport = error {} else { preconditionFailure("\(error)") }
            }
        }
        do {
            try GeminiAppQuotaClient.validateResponse(response(429))
            preconditionFailure("expected rate limit")
        } catch let error as QuotaError { precondition(error.isRateLimited && !error.requiresBrowserVerification) }
        let challenge = Data(#"<form id="captcha-form" action="https://www.google.com/sorry/index"></form>"#.utf8)
        do {
            try GeminiAppQuotaClient.validateResponse(response(200), data: challenge)
            preconditionFailure("expected verification page")
        } catch let error as QuotaError { precondition(error.requiresBrowserVerification) }
        try GeminiAppQuotaClient.validateResponse(response(200), data: Data(#"<script src="https://www.google.com/recaptcha/api.js"></script>"#.utf8))
        // RPC 会话正文中即使提到验证码表单，也不是 Google 返回的验证页面。
        try GeminiAppQuotaClient.validateResponse(response(200, type: "application/json"), data: challenge)
    }

    /// Electron safeStorage 格式的自造样例:"v10" + AES-128-CBC(PKCS7,IV 16 个空格)。
    static func grokBotAuth() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = GrokBotAuth.deriveKey(password: "test-safe-storage-password")!
        precondition(key.count == 16)
        func jwt(exp: Int) -> String {
            func b64(_ s: String) -> String {
                Data(s.utf8).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            return b64(#"{"alg":"HS256","typ":"JWT"}"#) + "." + b64("{\"sub\":\"user_test\",\"exp\":\(exp)}") + ".c2ln"
        }
        func encryptBytes(_ data: Data, key: Data) -> Data {
            let plain = [UInt8](data), keyBytes = [UInt8](key)
            let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
            var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
            let capacity = out.count
            var moved = 0
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                 keyBytes, keyBytes.count, iv, plain, plain.count, &out, capacity, &moved)
            precondition(Int(status) == kCCSuccess)
            return Data("v10".utf8) + Data(out.prefix(moved))
        }
        func encrypt(_ text: String, key: Data) -> Data { encryptBytes(Data(text.utf8), key: key) }
        let access = jwt(exp: 1_800_003_600), refresh = jwt(exp: 1_900_000_000)

        // 解密往返。
        precondition(GrokBotAuth.decrypt(encrypt("hello", key: key), key: key) == Data("hello".utf8))

        // 1. 整个登录 JSON 加密后以 base64 存:取 accessToken,不取 refreshToken。
        let inner = "{\"refreshToken\":\"\(refresh)\",\"accessToken\":\"\(access)\"}"
        let file1 = "{\"sand.auth\":\"\(encrypt(inner, key: key).base64EncodedString())\"}"
        guard case .success(let t1) = GrokBotAuth.extractToken(fileData: Data(file1.utf8), key: key, now: now) else {
            preconditionFailure("expected token from base64 blob")
        }
        precondition(t1 == access)

        // 2. 每个值单独加密，存成 Node Buffer JSON:按外层键名挑 access。
        func buffer(_ data: Data) -> String { "{\"type\":\"Buffer\",\"data\":[" + data.map { String($0) }.joined(separator: ",") + "]}" }
        let file2 = "{\"cursorRefreshToken\":\(buffer(encrypt(refresh, key: key))),\"cursorAccessToken\":\(buffer(encrypt(access, key: key)))}"
        guard case .success(let t2) = GrokBotAuth.extractToken(fileData: Data(file2.utf8), key: key, now: now) else {
            preconditionFailure("expected token from Buffer blob")
        }
        precondition(t2 == access)

        // 3. hex 字符串，键名不含 access:退回取 JWT。
        let hex = encrypt(access, key: key).map { String(format: "%02x", $0) }.joined()
        guard case .success(let t3) = GrokBotAuth.extractToken(fileData: Data("{\"token\":\"\(hex)\"}".utf8), key: key, now: now) else {
            preconditionFailure("expected token from hex blob")
        }
        precondition(t3 == access)

        // 3b. cursor-accounts 里有两个账号：取过期时间最晚(当前登录)的 access token。
        let older = jwt(exp: 1_800_001_000)
        let accounts = "{\"cursor-accounts\":[{\"cursor-access-token\":\"" + older + "\",\"cursor-refresh-token\":\"" + refresh
            + "\"},{\"cursor-access-token\":\"" + access + "\"}]}"
        let file3b = "{\"secrets\":\"" + encrypt(accounts, key: key).base64EncodedString() + "\"}"
        guard case .success(let t3b) = GrokBotAuth.extractToken(fileData: Data(file3b.utf8), key: key, now: now) else {
            preconditionFailure("expected token from cursor-accounts")
        }
        precondition(t3b == access)

        // 3c. 复合登录串(账号::JWT,分隔符转义成 %3A%3A),键名叫 session:整串原样返回。
        let composite = "user_abc123%3A%3A" + access
        let file3c = "{\"workos\":\"" + encrypt("{\"WorkosCursorSessionToken\":\"" + composite + "\"}", key: key).base64EncodedString() + "\"}"
        guard case .success(let t3c) = GrokBotAuth.extractToken(fileData: Data(file3c.utf8), key: key, now: now) else {
            preconditionFailure("expected composite session token")
        }
        precondition(t3c == composite)
        precondition(GrokBotAuth.embeddedJWT(composite) == access)

        // 4. 过期 token → expired;口令不对 → noToken;没有密文 → noToken。
        let expiredInner = "{\"accessToken\":\"" + jwt(exp: 1_700_000_000) + "\"}"
        let expiredFile = "{\"a\":\"" + encrypt(expiredInner, key: key).base64EncodedString() + "\"}"
        guard case .failure(.expired) = GrokBotAuth.extractToken(fileData: Data(expiredFile.utf8), key: key, now: now) else {
            preconditionFailure("expected expired")
        }
        let wrongKey = GrokBotAuth.deriveKey(password: "other")!
        guard case .failure(.noToken(let d1)) = GrokBotAuth.extractToken(fileData: Data(file1.utf8), key: wrongKey, now: now) else {
            preconditionFailure("expected noToken with wrong key")
        }
        precondition(d1 == GrokBotTokenDiagnostics(fileKind: "JSON", blobCount: 1, blobPaths: ["/sand.auth"], decryptedCount: 0))
        precondition(d1.summary.contains("钥匙串口令解不开") && !d1.summary.contains(access))
        guard case .failure(.noToken(let d2)) = GrokBotAuth.extractToken(fileData: Data(#"{"x":"plain"}"#.utf8), key: key, now: now) else {
            preconditionFailure("expected noToken without blobs")
        }
        precondition(d2.blobCount == 0 && d2.fileKind == "JSON" && d2.summary.contains("没找到加密块"))
        guard case .failure(.noToken(let d3)) = GrokBotAuth.extractToken(fileData: Data("garbage".utf8), key: key, now: now) else {
            preconditionFailure("expected noToken for unknown file")
        }
        precondition(d3.fileKind == "无法识别")

        // 5. 解得开但没有 token:报解开数量和路径;像账号的键名打码，诊断里不出现明文。
        let secret = "not-a-token-but-secret-value"
        let file5 = "{\"accounts\":{\"me@example.com\":{\"profile\":\"" + encrypt("{\"name\":\"" + secret + "\"}", key: key).base64EncodedString()
            + "\"}}}"
        guard case .failure(.noToken(let d5)) = GrokBotAuth.extractToken(fileData: Data(file5.utf8), key: key, now: now) else {
            preconditionFailure("expected noToken when decrypted text has no token")
        }
        precondition(d5.decryptedCount == 1 && d5.blobPaths == ["/accounts/<账号>/profile"])
        precondition(d5.summary.contains("解开了 1/1") && !d5.summary.contains(secret) && !d5.summary.contains("example.com"))
        precondition(d5.innerPaths == ["/accounts/<账号>/profile/name(长串)"] && d5.jwtCount == 0)
        precondition(!d5.details.contains(secret) && !d5.details.contains("example.com"))

        // 6. 明文里的值本身是序列化过的 JSON(字符串套字符串，或 base64):逐层展开后照常取 token。
        let accountsJSON = "{\"cursor-accounts\":[{\"cursor-access-token\":\"" + access + "\"}]}"
        let stringified = String(data: try JSONSerialization.data(withJSONObject: ["state": accountsJSON]), encoding: .utf8)!
        let file6 = "{\"secrets\":\"" + encrypt(stringified, key: key).base64EncodedString() + "\"}"
        guard case .success(let t6) = GrokBotAuth.extractToken(fileData: Data(file6.utf8), key: key, now: now) else {
            preconditionFailure("expected token from stringified JSON")
        }
        precondition(t6 == access)
        let base64Inner = "{\"blob\":\"" + Data(accountsJSON.utf8).base64EncodedString() + "\"}"
        let file6b = "{\"secrets\":\"" + encrypt(base64Inner, key: key).base64EncodedString() + "\"}"
        guard case .success(let t6b) = GrokBotAuth.extractToken(fileData: Data(file6b.utf8), key: key, now: now) else {
            preconditionFailure("expected token from base64 JSON")
        }
        precondition(t6b == access)

        // Chrome v24+ Cookie 明文以 host SHA256 开头，必须核对域名后去掉。
        var hostHash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let host = Array(".google.com".utf8)
        _ = CC_SHA256(host, CC_LONG(host.count), &hostHash)
        let cookie = encryptBytes(Data(hostHash) + Data("test-cookie".utf8), key: key)
        let decodedCookie = try GeminiChromeAuth.decryptCookie(cookie, key: key, host: ".google.com", version: 24)
        precondition(decodedCookie == "test-cookie")
        do {
            _ = try GeminiChromeAuth.decryptCookie(cookie, key: key, host: ".example.com", version: 24)
            preconditionFailure("must reject domain hash mismatch")
        } catch is GeminiChromeAuthError {}

        // 7. Grok Bot 0.71.2 实际结构：外层序列化账号表，内层字段各自加密。
        // 当前账号 token 比另一个账号更早过期，必须按 active 选择。
        func modernFile(active: String, activeToken: String = access) throws -> Data {
            let accounts: [String: Any] = [
                "active": active,
                "accounts": [
                    "current": ["cursor-access-token": encrypt(activeToken, key: key).base64EncodedString(),
                                "cursor-refresh-token": encrypt(refresh, key: key).base64EncodedString(),
                                "cursor-account-profile": encrypt(#"{"email":"me@example.com","name":"Ada"}"#, key: key).base64EncodedString()],
                    "other": ["cursor-access-token": encrypt(refresh, key: key).base64EncodedString(),
                              "cursor-account-profile": encrypt(#"{"email":"other@example.com","name":"Bob"}"#, key: key).base64EncodedString()]
                ]
            ]
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: accounts), as: UTF8.self)
            return try JSONSerialization.data(withJSONObject: [
                "version": 1, "cursor-accounts": serialized,
                "cursor-machine-id": encrypt("device-id", key: key).base64EncodedString(),
                "cursor-access-token": encrypt(refresh, key: key).base64EncodedString()
            ])
        }
        guard case .success(let t7) = GrokBotAuth.extractToken(fileData: try modernFile(active: "current"), key: key, now: now) else {
            preconditionFailure("expected active account from serialized outer JSON")
        }
        precondition(t7 == access)
        let profile = GrokBotAuth.account(fileData: try modernFile(active: "current"), key: key)
        precondition(profile == GrokBotAccount(email: "me@example.com", name: "Ada"))
        let missingProfile = GrokBotAuth.account(fileData: try modernFile(active: "missing"), key: key)
        precondition(missingProfile == nil)
        guard case .failure(.noToken) = GrokBotAuth.extractToken(fileData: try modernFile(active: "missing"), key: key, now: now) else {
            preconditionFailure("must not fall back to another account")
        }
        guard case .failure(.expired) = GrokBotAuth.extractToken(
            fileData: try modernFile(active: "current", activeToken: jwt(exp: 1_700_000_000)), key: key, now: now) else {
            preconditionFailure("expired active account must not use another account")
        }
    }

    static func googlePlan() {
        let html = """
        <h2>当前状态</h2><span class="vKKXxe">Google AI Pro</span>
        <script>AF_initDataCallback({key: 'ds:3', hash: '6', data:[[["5497558138880","5 TB"],null,null,null,"Google AI Pro",null,["升级到 Google AI Ultra"]]]});</script>
        <a href="https://one.google.com/explore-plan/gemini-advanced">Google AI Ultra</a>
        """
        precondition(GoogleOnePlan.parse(html: html) == "Google AI Pro")
        let conflict = """
        <script>AF_initDataCallback({key: 'ds:3', hash: '6', data:[[["1","5 TB"],null,null,null,"Google AI Pro"],[["2","20 TB"],null,null,null,"Google AI Ultra"]]});</script>
        """
        precondition(GoogleOnePlan.parse(html: conflict) == nil)
        precondition(GoogleOnePlan.parse(html: "<p>Google AI Pro</p>") == nil)
        precondition(GrokBotAccount.parse(#"{"email":"not-an-email","name":"A"}"#) == nil)
    }

    static func grokBotUsage() {
        let data = Data(#"""
        {"dailySpend":[
          {"day":"1791244800000","category":"grok-bot-default","totalTokens":"100"},
          {"day":1791244800000,"category":"grok-bot-default","totalTokens":80},
          {"day":1791417600000,"category":"grok-bot-cua","totalTokens":5,"spendCents":20},
          {"day":1,"category":"bad","totalTokens":9},
          {"category":"missing-day","totalTokens":9}
        ]}
        """#.utf8)
        let rows = GrokBotUsageClient.parse(data: data)
        precondition(rows?.count == 2)
        // 按 UTC 日、再按模型名升序。同一天同一模型只留较大的合计。
        precondition(rows?.first?.model == "grok-bot-default" && rows?.first?.totalTokens == 100 && rows?.first?.spendCents == 0)
        precondition(rows?.last?.model == "grok-bot-cua" && rows?.last?.totalTokens == 5 && rows?.last?.spendCents == 20)
        precondition(GrokBotUsageClient.parse(data: Data(#"{"startDate":"1"}"#.utf8)) == nil)
        precondition(GrokBotUsageClient.parse(data: Data(#"{"dailySpend":[]}"#.utf8)) == [])
    }
}
