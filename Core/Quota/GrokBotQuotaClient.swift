import CommonCrypto
import Foundation
import Security

// MARK: - Grok Bot
//
// Grok Bot 桌面 App(/Applications/Grok Bot.app,bundle id com.anysphere.sand,Electron)用 Cursor 账号登录，
// 「设置 → 用量与账单」里的每周额度来自 Cursor 后端(App 包内 app.asar 0.71.2 的代码):
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus  (Connect 协议，请求体 {},Bearer token)
//   响应 GetSandUsageStatusResponse:usagePercent(已用 %)、nextResetTimestampUtc(下次重置)、currentPeriodStart、
//   usesPooledEnterpriseAllowance、grokPlanLabel / cursorPlanName 等。
//
// token:App 把 Cursor access token 用 Electron safeStorage 加密后存在
// ~/Library/Application Support/Grok Bot/sand-secrets.json,解密密钥在钥匙串「Grok Bot Safe Storage」(见 GrokBotAuth)。
// yybar 只读：不刷新 token、不写回，token 过期时提示打开 Grok Bot app 让它自己续期。

enum GrokBotQuotaClient {
    nonisolated static let appPath = "/Applications/Grok Bot.app"
    nonisolated static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    /// 本机装了 Grok Bot(默认启用的依据)。
    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
    }

    nonisolated static func fetch(accessToken: String) async -> Result<QuotaSnapshot, QuotaError> {
        // 复合登录串(`账号::JWT`)多数端点要整串当 Bearer;万一端点只认里面那段 JWT,401 时再用 JWT 试一次。
        let jwtOnly = GrokBotAuth.embeddedJWT(accessToken)
        let result = await request(bearer: accessToken)
        if case .failure(let error) = result, error.httpStatusCode == 401,
           let jwtOnly, jwtOnly != accessToken {
            return await request(bearer: jwtOnly)
        }
        return result
    }

    nonisolated private static func request(bearer: String) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, "Grok Bot usage request failed"))
            }
            return .success(try parse(data: data))
        } catch let error as QuotaError { return .failure(error) }
        catch { return .failure(.transport(error.localizedDescription)) }
    }

    /// 解析 GetSandUsageStatusResponse(Connect JSON:字段 lowerCamelCase,Timestamp 为 RFC 3339 字符串)。
    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("Grok Bot usage response is not JSON")
        }
        // 企业共享额度没有个人百分比,App 自己也不显示周额度条。
        if root["usesPooledEnterpriseAllowance"] as? Bool == true {
            throw QuotaError.decode("Grok Bot uses a pooled enterprise allowance")
        }
        // proto3 JSON 省略零值：没有 usagePercent 视为 0(新周期)。
        let used: Double
        if let raw = root["usagePercent"] {
            guard let value = GrokQuotaClient.double(raw), value.isFinite else {
                throw QuotaError.decode("Grok Bot usage percent is invalid")
            }
            used = max(0, value)
        } else {
            used = 0
        }
        let reset = GrokQuotaClient.parseDate(root["nextResetTimestampUtc"])
        let start = GrokQuotaClient.parseDate(root["currentPeriodStart"])
        var seconds = 7 * 86400
        if let reset, let start, reset > start { seconds = Int(reset.timeIntervalSince(start)) }
        let window = QuotaWindow(usedPercent: min(100, used), resetsAt: reset, windowSeconds: seconds)
        let plan = [root["grokPlanLabel"], root["cursorPlanName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return QuotaSnapshot(app: .grokBot, fiveHour: nil, weekly: window, weeklyOpus: nil, weeklySonnet: nil,
                             planType: plan, fetchedAt: now, primary: window, primaryLabel: "WEEK · 本周")
    }
}

// MARK: - Grok Bot 登录(只读)
//
// Electron safeStorage 在 macOS 上的格式(Chromium os_crypt):
//   密文 = "v10" + AES-128-CBC(PKCS7),IV 为 16 个空格(0x20);
//   密钥 = PBKDF2-HMAC-SHA1(钥匙串「Grok Bot Safe Storage」里的口令，盐 "saltysalt",1003 次,16 字节)。
// sand-secrets.json 的字段名没有公开，这里不假设结构：遍历整个 JSON,把能解出 "v10" 密文的值逐个解密，
// 再从明文里挑 access token(优先键名含 access 的，排除 refresh;实际在 cursor-accounts 里当前账号的
// cursor-access-token)。token 只留在内存，不写日志。

enum GrokBotAuthError: Error {
    /// 没有 sand-secrets.json 或钥匙串条目(Grok Bot 没登录过)。
    case notSignedIn
    /// 钥匙串读取被拒绝或取消。
    case keychainDenied(String)
    /// 文件里找不到能解开的 token(格式变了，或钥匙串口令不对)。附带只含路径和数量的诊断。
    case noToken(GrokBotTokenDiagnostics)
    /// token 已过期(Grok Bot app 打开时会自己续期)。
    case expired
}

/// 解不出 token 时的诊断：只有数量和键路径(账号样子的段落打码),不含任何密文、明文、token 或口令。
struct GrokBotTokenDiagnostics: Equatable, Sendable {
    /// 文件整体是什么："JSON"、"v10 密文" 或 "无法识别"。
    var fileKind: String
    /// 找到的加密块数量和所在键路径(最多列 6 个)。
    var blobCount: Int
    var blobPaths: [String]
    /// 用钥匙串口令解开的加密块数量。
    var decryptedCount: Int
    /// 解开后的明文里有哪些键路径，每条后面注明值的样子(JWT / 含 JWT / 长串 / 短串)，最多列 12 个。不含值本身。
    var innerPaths: [String] = []
    /// 明文里含 JWT 的值有几个。
    var jwtCount: Int = 0

    /// 给界面看的一句话。
    var summary: String {
        let paths = blobPaths.isEmpty ? "" : ",路径 " + blobPaths.joined(separator: "、") + (blobCount > blobPaths.count ? " 等" : "")
        if blobCount == 0 {
            return "登录文件里没找到加密块(文件格式：\(fileKind))"
        }
        if decryptedCount == 0 {
            return "钥匙串口令解不开登录文件里的 \(blobCount) 个加密块\(paths)"
        }
        return "解开了 \(decryptedCount)/\(blobCount) 个加密块，但里面没有 access token\(paths)"
    }

    /// 写进诊断文件的完整版(多行)。同样不含任何值。
    var details: String {
        var lines = [summary, "文件格式：\(fileKind)", "加密块：\(blobCount) 个，解开 \(decryptedCount) 个"]
        lines.append("加密块路径：" + (blobPaths.isEmpty ? "无" : blobPaths.joined(separator: "、")))
        lines.append("明文里的 JWT:\(jwtCount) 个")
        lines.append("明文键路径(值的样子):")
        lines += innerPaths.isEmpty ? ["  无"] : innerPaths.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    /// 路径里像账号(含 @)或很长的段落打码，避免把邮箱、id 带进界面。
    nonisolated static func maskedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            if part.contains("@") { return "<账号>" }
            if part.count > 32 { return String(part.prefix(12)) + "…" }
            return String(part)
        }.joined(separator: "/")
    }
}

enum GrokBotAuth {
    nonisolated static let keychainService = "Grok Bot Safe Storage"

    nonisolated static var secretsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }

    /// 读钥匙串口令并派生 AES 密钥。用 Security 框架在 yybar 进程内读，macOS 弹窗问的是 yybar 本身，
    /// 「始终允许」只把 yybar 加进这一项的访问列表(不用 /usr/bin/security,免得任何脚本都能静默读取)。
    /// 自签名构建每次重新构建后可能再问一次。会阻塞到用户回应弹窗，调用方放到后台执行。
    nonisolated static func loadKey() -> Result<Data, GrokBotAuthError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .failure(.notSignedIn) }
        guard status == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !password.isEmpty else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return .failure(.keychainDenied(message))
        }
        guard let key = deriveKey(password: password) else { return .failure(.keychainDenied("key derivation failed")) }
        return .success(key)
    }

    /// 从 sand-secrets.json 解出 access token,并检查是否过期。
    nonisolated static func loadToken(key: Data, now: Date = Date()) -> Result<String, GrokBotAuthError> {
        guard let data = try? Data(contentsOf: secretsURL), !data.isEmpty else { return .failure(.notSignedIn) }
        return extractToken(fileData: data, key: key, now: now)
    }

    nonisolated static func extractToken(fileData: Data, key: Data, now: Date = Date()) -> Result<String, GrokBotAuthError> {
        var blobs: [(path: String, blob: Data)] = []
        let fileKind: String
        if fileData.starts(with: versionPrefix) {
            fileKind = "v10 密文"
            blobs.append(("", fileData))
        } else if let root = try? JSONSerialization.jsonObject(with: fileData, options: [.fragmentsAllowed]) {
            fileKind = "JSON"
            collectBlobs(root, path: "", into: &blobs)
        } else {
            fileKind = "无法识别"
        }
        var strings: [(path: String, value: String)] = []
        var decrypted = 0
        for item in blobs {
            // 口令不对时偶尔也能过 PKCS7 填充检查，解出乱码;能按 UTF-8 读出来才算解开。
            guard let plain = decrypt(item.blob, key: key),
                  let decoded = String(data: plain, encoding: .utf8) else { continue }
            decrypted += 1
            let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                collectStrings(inner, path: item.path, into: &strings)
            } else {
                strings.append((item.path, text))
            }
        }
        guard let token = pickAccessToken(strings) else {
            var paths: [String] = []
            for item in blobs {
                let masked = GrokBotTokenDiagnostics.maskedPath(item.path)
                if !paths.contains(masked) { paths.append(masked) }
            }
            var inner: [String] = []
            for item in strings {
                let kind = isJWT(item.value) ? "JWT" : embeddedJWT(item.value) != nil ? "含 JWT" : (item.value.count >= 20 ? "长串" : "短串")
                let line = GrokBotTokenDiagnostics.maskedPath(item.path) + "(\(kind))"
                if !inner.contains(line) { inner.append(line) }
            }
            return .failure(.noToken(GrokBotTokenDiagnostics(
                fileKind: fileKind, blobCount: blobs.count, blobPaths: Array(paths.prefix(6)), decryptedCount: decrypted,
                innerPaths: Array(inner.prefix(12)), jwtCount: strings.filter { embeddedJWT($0.value) != nil }.count)))
        }
        if let exp = expiry(of: token), exp <= now { return .failure(.expired) }
        return .success(token)
    }

    // MARK: 解密

    nonisolated private static let versionPrefix = Data("v10".utf8)

    nonisolated static func deriveKey(password: String) -> Data? {
        let salt = Array("saltysalt".utf8)
        let passwordLength = password.utf8.count
        guard passwordLength > 0 else { return nil }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let keyLength = key.count
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passwordLength,
                                          salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                          &key, keyLength)
        return Int(status) == kCCSuccess ? Data(key) : nil
    }

    nonisolated static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard blob.starts(with: versionPrefix) else { return nil }
        let cipher = [UInt8](blob.dropFirst(versionPrefix.count))
        guard !cipher.isEmpty, cipher.count % kCCBlockSizeAES128 == 0 else { return nil }
        let keyBytes = [UInt8](key)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             keyBytes, keyBytes.count, iv,
                             cipher, cipher.count,
                             &out, outCapacity, &moved)
        guard Int(status) == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    // MARK: 找密文 / 挑 token

    /// 密文可能存成 base64 / hex 字符串、Node Buffer 的 JSON({"type":"Buffer","data":[…]})或字节数组。
    nonisolated private static func collectBlobs(_ value: Any, path: String, into blobs: inout [(path: String, blob: Data)]) {
        switch value {
        case let string as String:
            if let data = Data(base64Encoded: string), data.starts(with: versionPrefix) {
                blobs.append((path, data))
            } else if let data = hexData(string), data.starts(with: versionPrefix) {
                blobs.append((path, data))
            } else if let data = string.data(using: .isoLatin1), data.starts(with: versionPrefix) {
                blobs.append((path, data))
            }
        case let dict as [String: Any]:
            if dict["type"] as? String == "Buffer", let bytes = byteArray(dict["data"]) {
                if bytes.starts(with: versionPrefix) { blobs.append((path, bytes)) }
                return
            }
            for (key, child) in dict { collectBlobs(child, path: path + "/" + key, into: &blobs) }
        case let array as [Any]:
            if let bytes = byteArray(array) {
                if bytes.starts(with: versionPrefix) { blobs.append((path, bytes)) }
                return
            }
            for (index, child) in array.enumerated() { collectBlobs(child, path: path + "/\(index)", into: &blobs) }
        default:
            break
        }
    }

    /// 明文里的值本身也可能是序列化过的 JSON(或它的 base64),逐层展开(最多 4 层)。
    nonisolated private static func collectStrings(_ value: Any, path: String, depth: Int = 0,
                                                   into strings: inout [(path: String, value: String)]) {
        switch value {
        case let string as String:
            if depth < 4, let nested = nestedJSON(string) {
                collectStrings(nested, path: path, depth: depth + 1, into: &strings)
            } else {
                strings.append((path, string))
            }
        case let dict as [String: Any]:
            for (key, child) in dict { collectStrings(child, path: path + "/" + key, depth: depth, into: &strings) }
        case let array as [Any]:
            for (index, child) in array.enumerated() { collectStrings(child, path: path + "/\(index)", depth: depth, into: &strings) }
        default:
            break
        }
    }

    nonisolated private static func nestedJSON(_ string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [Data] = []
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\"") {
            candidates.append(Data(trimmed.utf8))
        } else if trimmed.count >= 8, !isJWT(trimmed), let decoded = Data(base64Encoded: trimmed),
                  let first = decoded.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            candidates.append(decoded)
        }
        for data in candidates {
            if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               object is [String: Any] || object is [Any] || object is String {
                return object
            }
        }
        return nil
    }

    /// 挑登录串。Grok Bot 用 Cursor 账号,登录串常是复合形式(`账号::一串 JWT`,`::` 可能被转义成
    /// `%3A%3A`),整串就是请求要带的 Bearer,不是纯 JWT;也可能直接是一串 JWT。所以只要值里含有一段
    /// 合法 JWT(本身是，或按 `::` / `%3A%3A` 拆开后某段是)就算候选,整串原样返回。
    /// 优先级:键名含 access / token / session / auth 的 > 其他含 JWT 的。键名含 refresh 的一律不用。
    /// 同一档里有多个(多个 Cursor 账号)时取内嵌 JWT 过期时间最晚的,当前登录的账号最新。
    nonisolated static func pickAccessToken(_ strings: [(path: String, value: String)]) -> String? {
        let usable = strings
            .map { (path: $0.path.lowercased(), value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.path.contains("refresh") && !$0.value.contains(" ") && embeddedJWT($0.value) != nil }
        func named(_ path: String) -> Bool {
            ["access", "token", "session", "auth"].contains { path.contains($0) }
        }
        func latest(_ values: [String]) -> String? {
            values.max { (expiry(of: $0) ?? .distantPast) < (expiry(of: $1) ?? .distantPast) }
        }
        let tiers: [[String]] = [
            usable.filter { named($0.path) }.map { $0.value },
            usable.map { $0.value },
        ]
        return tiers.lazy.compactMap(latest).first
    }

    /// 三段都只含 base64url 字符(签名段可空)且载荷能解开。不查字符集的话，`账号%3A%3A<JWT>` 这种复合串
    /// 整体也能按点拆成三段、解开载荷，被误当成纯 JWT。
    nonisolated static func isJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        let base64URL = parts.allSatisfy { part in
            part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
        }
        return base64URL && JWT.decodePayload(value) != nil
    }

    /// 值本身是 JWT,或复合登录串(`账号::JWT`,分隔符可能是 `::` 或转义的 `%3A%3A`)里的某一段是 JWT。
    nonisolated static func embeddedJWT(_ value: String) -> String? {
        if isJWT(value) { return value }
        let normalized = value.replacingOccurrences(of: "%3A%3A", with: "::")
            .replacingOccurrences(of: "%3a%3a", with: "::")
        guard normalized.contains("::") else { return nil }
        return normalized.components(separatedBy: "::").first(where: isJWT)
    }

    nonisolated static func expiry(of token: String) -> Date? {
        guard let jwt = embeddedJWT(token), let payload = JWT.decodePayload(jwt) else { return nil }
        if let exp = payload["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = payload["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        return nil
    }

    nonisolated private static func byteArray(_ value: Any?) -> Data? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(array.count)
        for item in array {
            guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let int = number.intValue
            guard (0...255).contains(int), Double(int) == number.doubleValue else { return nil }
            bytes.append(UInt8(int))
        }
        return Data(bytes)
    }

    nonisolated private static func hexData(_ string: String) -> Data? {
        let chars = Array(string.utf8)
        guard chars.count >= 2, chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let hi = hexValue(chars[index]), let lo = hexValue(chars[index + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            index += 2
        }
        return Data(bytes)
    }

    nonisolated private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }
}
