import Foundation
import Security

// MARK: - AccountTokenFiles
//
// 「其他账号」的 token(导入的 Codex 账号、额外的 Claude 账号)存成只有本用户可读的文件：
// Application Support/yybar/account-tokens/(目录 0700)下每个账号一个 JSON(文件 0600),原子替换写入。
// Grok Bot 登录的解密密钥(从钥匙串「Grok Bot Safe Storage」派生)也缓存在这里，见 GrokBotAuth.loadKey。
// 保护级别与 Codex CLI 自己的 ~/.codex/auth.json、yybar 的 Grok 账号(grok-homes/)相同。
//
// 为什么不用钥匙串：本机自签名的 App 没有 Apple 团队 ID,钥匙串条目的访问分区(partition list)只能按
// 每次构建的 cdhash 记录，每次重新构建 / 更新后第一次读取都会弹窗要登录密码。
//
// 旧版本存在钥匙串里的 token:读不到文件时从钥匙串读一次(这一次系统可能弹窗)，写成文件后删掉钥匙串条目;
// 文件写失败就保留钥匙串条目，下次再试。

enum AccountTokenFiles {
    enum Kind: String {
        case codex
        case claude
        case grokBot = "grokbot"
        /// yybar 网站的上传令牌和头像信息(见 YYBarWebAccount)
        case yybarWeb = "yybarweb"
    }

    /// 与 ExtraAccountStore.supportDirectory() 同一目录;这里自己拼，免得独立回归测试也要编进账号存储。
    nonisolated static func directory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("yybar/account-tokens", isDirectory: true)
    }

    /// 文件名：`<kind>-<账号 id 百分号编码>.json`(Claude 的 id 含邮箱，编码后只剩字母数字和 -._%)。
    nonisolated static func url(kind: Kind, id: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        let safe = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? UUID().uuidString
        return directory().appendingPathComponent("\(kind.rawValue)-\(safe).json", isDirectory: false)
    }

    nonisolated static func read(kind: Kind, id: String) -> Data? {
        try? Data(contentsOf: url(kind: kind, id: id))
    }

    nonisolated static func write(_ data: Data, kind: Kind, id: String) throws {
        let fm = FileManager.default
        let dir = directory()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let target = url(kind: kind, id: id)
        // 先写同目录下的临时文件(创建时即为 0600),再 rename 原子替换。
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    nonisolated static func delete(kind: Kind, id: String) {
        try? FileManager.default.removeItem(at: url(kind: kind, id: id))
    }

    // MARK: 钥匙串迁移

    /// 本次运行里用户拒绝过(或取消了)钥匙串授权的账号：不再去读，免得每次刷新额度都弹窗。下次启动再试。
    nonisolated(unsafe) private static var declined: Set<String> = []
    nonisolated private static let declinedLock = NSLock()

    /// 按顺序在这些 service 里找该账号的旧条目，找到就写成文件并删掉所有 service 下的条目。返回 token 数据。
    nonisolated static func migrateFromKeychain(kind: Kind, id: String, services: [String]) -> Data? {
        let key = "\(kind.rawValue):\(id)"
        guard !declinedLock.withLock({ declined.contains(key) }) else { return nil }
        for service in services {
            var query = keychainQuery(service: service, account: id)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
                declinedLock.withLock { _ = declined.insert(key) }
                return nil
            }
            guard status == errSecSuccess, let data = item as? Data else { continue }
            if (try? write(data, kind: kind, id: id)) != nil {
                deleteKeychainItems(id: id, services: services)
            }
            return data
        }
        return nil
    }

    /// 删除旧版本留在钥匙串里的条目(没有时什么也不做)。
    nonisolated static func deleteKeychainItems(id: String, services: [String]) {
        for service in services {
            SecItemDelete(keychainQuery(service: service, account: id) as CFDictionary)
        }
    }

    nonisolated private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
