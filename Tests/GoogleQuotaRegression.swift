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
        print("GoogleQuotaRegression OK")
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
        func encrypt(_ text: String, key: Data) -> Data {
            let plain = [UInt8](text.utf8), keyBytes = [UInt8](key)
            let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
            var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
            let capacity = out.count
            var moved = 0
            let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                 keyBytes, keyBytes.count, iv, plain, plain.count, &out, capacity, &moved)
            precondition(Int(status) == kCCSuccess)
            return Data("v10".utf8) + Data(out.prefix(moved))
        }
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

        // 4. 过期 token → expired;口令不对 → noToken;没有密文 → noToken。
        let expiredInner = "{\"accessToken\":\"" + jwt(exp: 1_700_000_000) + "\"}"
        let expiredFile = "{\"a\":\"" + encrypt(expiredInner, key: key).base64EncodedString() + "\"}"
        guard case .failure(.expired) = GrokBotAuth.extractToken(fileData: Data(expiredFile.utf8), key: key, now: now) else {
            preconditionFailure("expected expired")
        }
        let wrongKey = GrokBotAuth.deriveKey(password: "other")!
        guard case .failure(.noToken) = GrokBotAuth.extractToken(fileData: Data(file1.utf8), key: wrongKey, now: now) else {
            preconditionFailure("expected noToken with wrong key")
        }
        guard case .failure(.noToken) = GrokBotAuth.extractToken(fileData: Data(#"{"x":"plain"}"#.utf8), key: key, now: now) else {
            preconditionFailure("expected noToken without blobs")
        }
    }
}
