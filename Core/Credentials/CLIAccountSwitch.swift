import Foundation

// MARK: - CLIAccountSwitch
//
// 「切换本机 CLI 账号」用到的凭据读写。流程编排在 AppState.switchCLI(…)。
// - Codex:`~/.codex/auth.json` 的 tokens(保留其余字段)。
// - Claude:登录钥匙串 `Claude Code-credentials`(或 `~/.claude/.credentials.json`)的 `claudeAiOauth`
//   (保留 mcpOAuth 等其余字段),以及 `~/.claude.json` 的 `oauthAccount`(CLI 和 yybar 都从这里取邮箱)。
// - Grok:`~/.grok/auth.json` 里的官方账号记录(auth.x.ai),自定义 provider 的记录原样保留。
// 写文件都是原子写入；切换前把原凭据另存到 Application Support/yybar/switch-backups/(每个服务只留最近一份,0600)。

enum CLIAccountSwitch {
    enum SwitchError: Error, LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }

    // MARK: Files

    nonisolated static func readJSON(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 原子写入并设为仅本用户可读写(0600)。
    nonisolated static func writeSecureJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 切换前另存原凭据，出问题时可手动恢复。
    nonisolated static func backup(_ data: Data, name: String) {
        let dir = ExtraAccountStore.supportDirectory().appendingPathComponent("switch-backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(name)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Codex

    /// 写入 `~/.codex/auth.json`:换掉 tokens,其余字段(OPENAI_API_KEY 等)沿用原文件。
    /// 写 Codex 的 auth.json;默认本机主目录，切进其他 Codex 目录时传那个目录的。
    nonisolated static func writeCodexAuth(base: [String: Any]?, tokens: ImportedCodexTokens, accountId: String,
                                           to url: URL = CodexAuth.authFileURL()) throws {
        var root = base ?? ["OPENAI_API_KEY": NSNull()]
        root["auth_mode"] = "chatgpt"
        var entry: [String: Any] = ["access_token": tokens.accessToken, "account_id": accountId]
        if let refresh = tokens.refreshToken, !refresh.isEmpty { entry["refresh_token"] = refresh }
        if let id = tokens.idToken, !id.isEmpty { entry["id_token"] = id }
        root["tokens"] = entry
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = iso.string(from: Date())
        try writeSecureJSON(root, to: url)
    }

    // MARK: Claude

    nonisolated static let claudeKeychainService = "Claude Code-credentials"

    nonisolated static var claudeCredentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    nonisolated static var claudeConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// 本机 Claude Code 的凭据根对象：有 `.credentials.json` 用文件，否则读钥匙串(和 ClaudeAuth 的顺序一致)。
    nonisolated static func readClaudeCredential() -> (root: [String: Any], source: CredentialSource)? {
        if let root = readJSON(at: claudeCredentialsFile) { return (root, .file) }
        if let text = runSecurity(["find-generic-password", "-s", claudeKeychainService, "-w"]),
           let root = jsonObject(text) {
            return (root, .keychain)
        }
        return nil
    }

    nonisolated static func writeClaudeCredential(_ root: [String: Any], source: CredentialSource) throws {
        switch source {
        case .file:
            try writeSecureJSON(root, to: claudeCredentialsFile)
        case .keychain:
            guard let text = jsonString(root) else { throw SwitchError.message("凭据编码失败（Couldn't encode credentials）") }
            // 和 Claude Code 写入时同一个 service + account(当前用户名),-U 覆盖原条目。
            guard runSecurity(["add-generic-password", "-U", "-s", claudeKeychainService, "-a", NSUserName(), "-w", text]) != nil else {
                throw SwitchError.message("写入钥匙串失败（Couldn't write to the Keychain）")
            }
        }
    }

    nonisolated static func readClaudeOAuthAccount() -> [String: Any]? {
        readJSON(at: claudeConfigFile)?["oauthAccount"] as? [String: Any]
    }

    /// 只替换 `~/.claude.json` 的 `oauthAccount`,其余内容保留;文件解析失败时不写，避免覆盖用户配置。
    nonisolated static func writeClaudeOAuthAccount(_ account: [String: Any]) throws {
        let url = claudeConfigFile
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SwitchError.message("~/.claude.json 无法解析，未修改（Couldn't parse ~/.claude.json）")
            }
            root = parsed
        }
        root["oauthAccount"] = account
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: [.atomic])
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
    }

    // MARK: Grok

    nonisolated static var grokAuthFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")
    }

    /// xAI 官方账号的记录(和 GrokAccount.load 的筛选一致)。
    nonisolated static func isGrokFirstParty(_ key: String) -> Bool {
        key.hasPrefix("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in"
    }

    // MARK: security

    nonisolated private static func runSecurity(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
