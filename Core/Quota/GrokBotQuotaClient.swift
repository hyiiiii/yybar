import CommonCrypto
import Foundation

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
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
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
    /// 文件里找不到能解开的 token(格式变了，或钥匙串口令不对)。
    case noToken
    /// token 已过期(Grok Bot app 打开时会自己续期)。
    case expired
}

enum GrokBotAuth {
    nonisolated static let keychainService = "Grok Bot Safe Storage"

    nonisolated static var secretsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
    }

    /// 读钥匙串口令并派生 AES 密钥。首次读取 macOS 会弹窗，点「始终允许」后不再询问。
    /// 会阻塞到 `security` 退出，调用方放到后台执行。
    nonisolated static func loadKey() -> Result<Data, GrokBotAuthError> {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { return .failure(.keychainDenied(error.localizedDescription)) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let password = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 44 = errSecItemNotFound:Grok Bot 还没在这台 Mac 上存过登录。
        if proc.terminationStatus == 44 { return .failure(.notSignedIn) }
        guard proc.terminationStatus == 0, !password.isEmpty else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(.keychainDenied(msg.isEmpty ? "exit \(proc.terminationStatus)" : msg))
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
        if fileData.starts(with: versionPrefix) {
            blobs.append(("", fileData))
        } else if let root = try? JSONSerialization.jsonObject(with: fileData, options: [.fragmentsAllowed]) {
            collectBlobs(root, path: "", into: &blobs)
        }
        var strings: [(path: String, value: String)] = []
        for item in blobs {
            guard let plain = decrypt(item.blob, key: key),
                  let text = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            if let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                collectStrings(inner, path: item.path, into: &strings)
            } else {
                strings.append((item.path, text))
            }
        }
        guard let token = pickAccessToken(strings) else { return .failure(.noToken) }
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

    nonisolated private static func collectStrings(_ value: Any, path: String, into strings: inout [(path: String, value: String)]) {
        switch value {
        case let string as String:
            strings.append((path, string))
        case let dict as [String: Any]:
            for (key, child) in dict { collectStrings(child, path: path + "/" + key, into: &strings) }
        case let array as [Any]:
            for (index, child) in array.enumerated() { collectStrings(child, path: path + "/\(index)", into: &strings) }
        default:
            break
        }
    }

    /// 优先级：键名含 access 的 JWT > 键名含 access 的长字符串 > 任意 JWT。键名含 refresh 的一律不用。
    /// 同一档里有多个(多个 Cursor 账号)时取过期时间最晚的，Grok Bot 当前登录的账号 token 最新。
    nonisolated static func pickAccessToken(_ strings: [(path: String, value: String)]) -> String? {
        let usable = strings
            .map { (path: $0.path.lowercased(), value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.path.contains("refresh") && !$0.value.contains(" ") }
        func isAccess(_ path: String) -> Bool { path.contains("access") }
        func latest(_ values: [String]) -> String? {
            values.max { (expiry(of: $0) ?? .distantPast) < (expiry(of: $1) ?? .distantPast) }
        }
        let tiers: [[String]] = [
            usable.filter { isAccess($0.path) && isJWT($0.value) }.map { $0.value },
            usable.filter { isAccess($0.path) && $0.value.count >= 20 }.map { $0.value },
            usable.filter { isJWT($0.value) }.map { $0.value },
        ]
        return tiers.lazy.compactMap(latest).first
    }

    nonisolated static func isJWT(_ value: String) -> Bool {
        value.split(separator: ".").count == 3 && JWT.decodePayload(value) != nil
    }

    nonisolated static func expiry(of token: String) -> Date? {
        guard let payload = JWT.decodePayload(token) else { return nil }
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
