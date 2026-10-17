import Foundation

// MARK: - ImportedCodexStore
//
// 持久化"其他 Codex 账号"。
// - 元数据 → Application Support/yybar/imported_codex_accounts.json (原子写,版本号兜底)。
// - Token 三件套 → 只有本用户可读的文件(见 AccountTokenFiles),内容为 JSON {access,refresh,id}。
//   旧版本存在钥匙串(service 见 keychainServices,account = account_id),
//   第一次读取时迁移到文件并删掉钥匙串条目。

struct ImportedCodexTokens: Sendable, Equatable, Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

enum ImportedCodexStore {
    /// 旧版本存 token 的钥匙串 service(改名后 / 改名前 yybar 时期),只用于迁移和清理。
    nonisolated private static let keychainServices = ["com.yybar.codex.imported"]
    nonisolated private static let fileName = "imported_codex_accounts.json"
    nonisolated private static let bundleDirectory = "yybar"

    // MARK: - 元数据 (JSON)

    private struct Payload: Codable, Equatable {
        var version: Int = 1
        var accounts: [ImportedCodexAccount] = []
    }

    nonisolated static func loadAll() -> [ImportedCodexAccount] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == 1
        else { return [] }
        return payload.accounts
    }

    nonisolated static func saveAll(_ accounts: [ImportedCodexAccount]) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Payload(accounts: accounts))
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Token (文件)

    nonisolated static func loadTokens(accountId: String) -> ImportedCodexTokens? {
        let data = AccountTokenFiles.read(kind: .codex, id: accountId)
            ?? AccountTokenFiles.migrateFromKeychain(kind: .codex, id: accountId, services: keychainServices)
        guard let data else { return nil }
        return try? JSONDecoder().decode(ImportedCodexTokens.self, from: data)
    }

    nonisolated static func saveTokens(_ tokens: ImportedCodexTokens, accountId: String) throws {
        try AccountTokenFiles.write(JSONEncoder().encode(tokens), kind: .codex, id: accountId)
    }

    nonisolated static func deleteTokens(accountId: String) {
        AccountTokenFiles.delete(kind: .codex, id: accountId)
        AccountTokenFiles.deleteKeychainItems(id: accountId, services: keychainServices)
    }
}
