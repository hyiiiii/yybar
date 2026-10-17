import Foundation
import CryptoKit

// MARK: - ExtraAccount
//
// 用户手动添加的 Claude Code / Grok 额外账号(Codex 额外账号沿用 ImportedCodexAccount)。
// - 元数据 → Application Support/yybar/extra_accounts.json。
// - Claude token → 只有本用户可读的文件(见 AccountTokenFiles;旧版本在钥匙串，第一次读取时迁移),
//   由本 App 自己续期，与本机 Claude Code CLI 的凭据互不影响。
// - Grok 凭据 → 每个账号一个独立的 GROK_HOME(Application Support/yybar/grok-homes/<folder>/auth.json),
//   续期交给官方 grok CLI(`GROK_HOME=<dir> grok models`),与 ~/.grok 互不影响。
// 设计见 docs/技术实现.md「2026-10 统一添加账号」。

nonisolated enum ExtraProvider: String, Sendable, Codable {
    case claude
    case grok
}

nonisolated struct ExtraAccount: Sendable, Equatable, Codable, Identifiable {
    /// `<provider>:<identity>`。Claude 取邮箱(无邮箱时随机),Grok 取 user_id:team_id。
    var id: String
    var provider: ExtraProvider
    var alias: String
    var email: String?
    var plan: String?
    var visibleInPopover: Bool
    var addedAt: Date
    /// 仅 Grok:该账号独立 GROK_HOME 的目录名。
    var homeFolder: String?
    /// 在菜单栏 / 悬浮窗显示这个账号的额度(需同时启用)。旧数据没有这两个字段，视为 false。
    var showInMenuBar: Bool? = nil
    var showInFloating: Bool? = nil
    /// 仅 Claude:订阅开始日(资料接口的 subscription_created_at),用于推算续费日;订阅不是 active 时为 nil。
    var subscriptionStartedAt: Date? = nil

    /// 列表 / Popover 上的显示名：别名 > 邮箱 @ 前缀 > 服务名。
    var displayName: String {
        if !alias.isEmpty { return alias }
        if let email, !email.isEmpty { return email.components(separatedBy: "@").first ?? email }
        return provider == .claude ? "Claude" : "Grok"
    }
}

nonisolated struct ExtraClaudeTokens: Sendable, Equatable, Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    /// 从本机 CLI 切走时保存的完整 `claudeAiOauth`(scopes / subscriptionType 等)和 `~/.claude.json` 的
    /// `oauthAccount`,切回时原样还原。粘贴 / 浏览器添加的账号没有这两项，切换时按资料接口补齐。
    var credentialJSON: String? = nil
    var oauthAccountJSON: String? = nil
}

enum ExtraAccountStore {
    /// 旧版本存 Claude token 的钥匙串 service(改名后 / 改名前),只用于迁移和清理。
    nonisolated private static let claudeKeychainServices = ["com.yybar.claude.extra"]
    nonisolated private static let fileName = "extra_accounts.json"
    nonisolated private static let bundleDirectory = "yybar"

    nonisolated private struct Payload: Codable {
        var version: Int = 1
        var accounts: [ExtraAccount] = []
    }

    // MARK: 元数据

    nonisolated static func loadAll() -> [ExtraAccount] {
        guard let data = try? Data(contentsOf: fileURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data), payload.version == 1 else { return [] }
        return payload.accounts
    }

    nonisolated static func saveAll(_ accounts: [ExtraAccount]) throws {
        let url = fileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Payload(accounts: accounts)).write(to: url, options: [.atomic])
    }

    nonisolated static func supportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent(bundleDirectory, isDirectory: true)
    }

    nonisolated private static func fileURL() -> URL {
        supportDirectory().appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: Grok 独立 home

    nonisolated static func grokHome(folder: String) -> URL {
        supportDirectory()
            .appendingPathComponent("grok-homes", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    /// 新建一个空的、仅本用户可读的 GROK_HOME 目录。
    nonisolated static func makeGrokHome() throws -> (folder: String, url: URL) {
        let folder = UUID().uuidString.lowercased()
        let url = grokHome(folder: folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return (folder, url)
    }

    nonisolated static func removeGrokHome(folder: String) {
        try? FileManager.default.removeItem(at: grokHome(folder: folder))
    }

    // MARK: Claude token(文件，见 AccountTokenFiles;旧版本在钥匙串，第一次读取时迁移)

    nonisolated static func loadClaudeTokens(id: String) -> ExtraClaudeTokens? {
        let data = AccountTokenFiles.read(kind: .claude, id: id)
            ?? AccountTokenFiles.migrateFromKeychain(kind: .claude, id: id, services: claudeKeychainServices)
        guard let data else { return nil }
        return try? JSONDecoder().decode(ExtraClaudeTokens.self, from: data)
    }

    nonisolated static func saveClaudeTokens(_ tokens: ExtraClaudeTokens, id: String) throws {
        try AccountTokenFiles.write(JSONEncoder().encode(tokens), kind: .claude, id: id)
    }

    nonisolated static func deleteClaudeTokens(id: String) {
        AccountTokenFiles.delete(kind: .claude, id: id)
        AccountTokenFiles.deleteKeychainItems(id: id, services: claudeKeychainServices)
    }
}

// MARK: - 粘贴解析

enum ExtraAccountPaste {
    struct ClaudeParsed: Sendable {
        var tokens: ExtraClaudeTokens
        var email: String?
        var plan: String?
    }

    /// 解析 `~/.claude/.credentials.json`(或 Keychain 中同格式的 JSON)。
    nonisolated static func parseClaude(_ text: String) -> Result<ClaudeParsed, PasteError> {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let access = (oauth["accessToken"] ?? oauth["access_token"]) as? String, !access.isEmpty else {
            return .failure(.missing("claudeAiOauth.accessToken"))
        }
        let refresh = (oauth["refreshToken"] ?? oauth["refresh_token"]) as? String
        var expiresAt: Date?
        if let raw = oauth["expiresAt"] as? Double ?? (oauth["expiresAt"] as? String).flatMap(Double.init) {
            expiresAt = Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        return .success(ClaudeParsed(
            tokens: ExtraClaudeTokens(accessToken: access, refreshToken: refresh, expiresAt: expiresAt),
            email: (oauth["emailAddress"] ?? oauth["email"]) as? String,
            plan: oauth["subscriptionType"] as? String
        ))
    }

    /// 校验 `~/.grok/auth.json`:必须含官方账号(auth.x.ai)记录，原样写入独立 GROK_HOME。
    nonisolated static func validateGrokAuth(_ text: String) -> Result<Data, PasteError> {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return .failure(.invalidJSON)
        }
        let firstParty = records.contains { key, value in
            (key.hasPrefix("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in")
                && (value["key"] as? String)?.isEmpty == false
        }
        return firstParty ? .success(data) : .failure(.missing("auth.x.ai"))
    }

    enum PasteError: Error, CustomStringConvertible {
        case invalidJSON
        case missing(String)

        var description: String {
            switch self {
            case .invalidJSON: return "粘贴内容不是合法 JSON（Paste is not valid JSON）"
            case .missing(let field): return "没有找到可用的凭据：\(field)（No usable credentials found）"
            }
        }
    }
}

// MARK: - 添加账号错误

enum AddAccountError: Error, LocalizedError {
    case alreadyOnThisMac
    case message(String)

    var errorDescription: String? {
        switch self {
        case .alreadyOnThisMac:
            return "这个账号已经是本机登录的账号，已显示在上方（This account is already signed in on this Mac）"
        case .message(let text):
            return text
        }
    }
}

// MARK: - Claude 独立目录登录的凭据位置

/// `CLAUDE_CONFIG_DIR=<dir> claude auth login` 之后，凭据可能落在两处:
/// - `<dir>/.credentials.json`(部分环境)
/// - macOS Keychain,service 为 `Claude Code-credentials-<sha256(dir) 前 8 位>`(自定义配置目录时的命名)
enum ClaudeIsolatedLogin {
    nonisolated static func readCredentials(configDir: URL) -> String? {
        let file = configDir.appendingPathComponent(".credentials.json")
        if let text = try? String(contentsOf: file, encoding: .utf8), !text.isEmpty { return text }
        for service in keychainServices(configDir: configDir) {
            if let text = runSecurity(["find-generic-password", "-s", service, "-w"]), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// 导入后删除 CLI 为这个临时目录建的 Keychain 条目(目录本身也会被删)。
    nonisolated static func deleteKeychainItems(configDir: URL) {
        for service in keychainServices(configDir: configDir) {
            _ = runSecurity(["delete-generic-password", "-s", service])
        }
    }

    /// 登录后 CLI 会把账号信息写进 `<dir>/.claude.json` 的 oauthAccount。
    nonisolated static func email(configDir: URL) -> String? {
        guard let data = try? Data(contentsOf: configDir.appendingPathComponent(".claude.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["oauthAccount"] as? [String: Any],
              let email = oauth["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email
    }

    nonisolated private static func keychainServices(configDir: URL) -> [String] {
        let paths = Set([configDir.path, configDir.resolvingSymlinksInPath().path, configDir.standardizedFileURL.path])
        return paths.map { "Claude Code-credentials-" + String(sha256Hex($0).prefix(8)) }
    }

    nonisolated private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func runSecurity(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Claude 账号资料(邮箱 / 订阅)

/// 粘贴的凭据里常常没有邮箱，用 OAuth profile 接口补齐。失败返回 nil,不影响添加。
enum ClaudeProfileClient {
    struct Profile: Sendable {
        var email: String?
        var plan: String?
        /// 订阅开始日;订阅状态不是 active(已取消等)时为 nil。
        var subscriptionStartedAt: Date? = nil
    }

    nonisolated static func fetch(accessToken: String) async -> Profile? {
        guard let root = await profileJSON(accessToken: accessToken) else { return nil }
        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]
        let email = (account?["email_address"] ?? account?["email"]) as? String
        var plan: String?
        if let type = organization?["organization_type"] as? String {
            // claude_max / claude_pro / claude_team / claude_enterprise → max / pro / team / enterprise
            plan = type.hasPrefix("claude_") ? String(type.dropFirst("claude_".count)) : type
        } else if account?["has_claude_max"] as? Bool == true {
            plan = "max"
        } else if account?["has_claude_pro"] as? Bool == true {
            plan = "pro"
        }
        let active = (organization?["subscription_status"] as? String).map { $0 == "active" } ?? true
        return Profile(email: email, plan: plan,
                       subscriptionStartedAt: active ? SubscriptionRenewal.parseDate(organization?["subscription_created_at"]) : nil)
    }

    /// 切换本机 CLI 账号时，为没有保存 `oauthAccount` 的账号(粘贴 / 浏览器添加)补齐
    /// `~/.claude.json` 的 oauthAccount(JSON 字符串)和凭据里的 rateLimitTier。
    struct OAuthAccount: Sendable {
        var json: String
        var rateLimitTier: String?
    }

    nonisolated static func fetchOAuthAccount(accessToken: String) async -> OAuthAccount? {
        guard let root = await profileJSON(accessToken: accessToken) else { return nil }
        let account = root["account"] as? [String: Any] ?? [:]
        let organization = root["organization"] as? [String: Any] ?? [:]
        var oauth: [String: Any] = [:]
        oauth["accountUuid"] = account["uuid"]
        oauth["emailAddress"] = account["email_address"] ?? account["email"]
        oauth["displayName"] = account["display_name"]
        oauth["fullName"] = account["full_name"]
        oauth["organizationUuid"] = organization["uuid"]
        oauth["organizationName"] = organization["name"]
        oauth["organizationType"] = organization["organization_type"]
        oauth["billingType"] = organization["billing_type"]
        oauth["organizationRateLimitTier"] = organization["rate_limit_tier"]
        oauth["subscriptionCreatedAt"] = organization["subscription_created_at"]
        guard oauth["emailAddress"] != nil, let json = CLIAccountSwitch.jsonString(oauth) else { return nil }
        return OAuthAccount(json: json, rateLimitTier: organization["rate_limit_tier"] as? String)
    }

    nonisolated private static func profileJSON(accessToken: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
