import Foundation

enum CodexAuth {
    /// 读一份 Codex 的 auth.json;默认本机主目录(`CODEX_HOME` 或 `~/.codex`),其他 Codex 目录传各自的。
    nonisolated static func load(url: URL = authFileURL()) throws -> CodexAccount {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.invalidJSON(url.path)
        }
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let idToken = tokens["id_token"] as? String
        let accessToken = tokens["access_token"] as? String
        let refreshToken = tokens["refresh_token"] as? String
        let lastRefresh = parseDate(root["last_refresh"])
        let idClaims = idToken.flatMap { JWT.decodePayload($0) }
        let accessClaims = accessToken.flatMap { JWT.decodePayload($0) }

        var email: String?
        var planType: String?
        var claimKeys: [String] = []
        if let claims = idClaims {
            claimKeys = Array(claims.keys).sorted()
            email = claims["email"] as? String
            if let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
                planType = auth["chatgpt_plan_type"] as? String
            }
            if planType == nil {
                planType = claims["chatgpt_plan_type"] as? String
            }
        }
        if planType == nil, let claims = accessClaims,
           let auth = claims["https://api.openai.com/auth"] as? [String: Any] {
            planType = auth["chatgpt_plan_type"] as? String
        }
        let accountId = nonEmpty(tokens["account_id"] as? String)
            ?? authClaim("chatgpt_account_id", from: accessClaims)
            ?? authClaim("chatgpt_account_id", from: idClaims)
        let chatgptUserId = authClaim("chatgpt_user_id", from: accessClaims)
            ?? authClaim("chatgpt_user_id", from: idClaims)
        let activeUntil = SubscriptionRenewal.parseDate(
            (idClaims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_subscription_active_until"]
        )

        let expiredGuess: Bool = {
            guard let lastRefresh else { return true }
            return Date().timeIntervalSince(lastRefresh) > 8 * 24 * 3600
        }()

        return CodexAccount(
            email: email,
            planType: planType,
            accountId: accountId,
            chatgptUserId: chatgptUserId,
            lastRefresh: lastRefresh,
            expiredGuess: expiredGuess,
            rawClaimKeys: claimKeys,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            subscriptionActiveUntil: activeUntil
        )
    }

    /// 本机主目录之外的其他 Codex 目录(第二个 Codex 用 CODEX_HOME 放在别处、和主目录同时在用时)。按路径去重，不含主目录:
    /// - 自动找到的：家目录下以 `.codex` 开头、里面有 `sessions` 的目录(`.codex-pro`、`.codex2`…);
    ///   菜单栏 App 读不到终端里设的 CODEX_HOME,别的位置要手动添加;
    /// - 设置里手动添加的(选的是 Codex 目录或它的 `sessions` 都行)。
    /// 用户移除过的自动目录(ignored)不要；手动添加的不受影响。返回(目录, 是不是自动找到的)。
    nonisolated static func extraHomes(manual: [String], ignored: [String]) -> [(url: URL, auto: Bool)] {
        let fm = FileManager.default
        let key = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
        var seen: Set<String> = [key(authFileURL().deletingLastPathComponent())]
        let ignoredKeys = Set(ignored.map { key(URL(fileURLWithPath: $0)) })
        var found: [(url: URL, auto: Bool)] = []
        for raw in manual.map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            var url = URL(fileURLWithPath: raw, isDirectory: true)
            if url.lastPathComponent.lowercased() == "sessions" { url.deleteLastPathComponent() }
            if seen.insert(key(url)).inserted { found.append((url, false)) }
        }
        let home = fm.homeDirectoryForCurrentUser
        let names = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.lowercased().hasPrefix(".codex") }.sorted()
        for name in names {
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.appendingPathComponent("sessions").path, isDirectory: &isDir), isDir.boolValue,
                  !ignoredKeys.contains(key(url)), seen.insert(key(url)).inserted else { continue }
            found.append((url, true))
        }
        return found.sorted { $0.url.path < $1.url.path }
    }

    nonisolated static func authFileURL() -> URL {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
    }

    nonisolated private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        if let n = any as? Double { return Date(timeIntervalSince1970: n) }
        return nil
    }

    nonisolated private static func authClaim(_ key: String, from claims: [String: Any]?) -> String? {
        guard let auth = claims?["https://api.openai.com/auth"] as? [String: Any] else { return nil }
        return nonEmpty(auth[key] as? String)
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
