import Foundation

/// 单个 JSONL 文件的扫描 watermark。
struct ScanFileState: Sendable, Equatable, Codable {
    var mtime: Double          // file modification time, epoch seconds
    var offset: UInt64         // 已扫到的字节数
    /// Codex 用：当前会话最近一次 `turn_context` 里的模型，用于给后续 token_count 打标签。
    var lastModel: String?
    var lastTotalUsage: [String: Int]?
    var seenTurnIds: [String]?
}

struct ScanState: Sendable, Equatable, Codable {
    /// version 管「结构变更」（字段增减导致解码不兼容时 bump）；价格变更由 pricingFingerprint 接管。
    /// v5: Codex 累计去重及 Grok 扫描；重建历史聚合。
    /// v6: 新增 agy 会话库扫描(Gemini / Antigravity)。
    /// v7: agy 用量改为全部记到 Antigravity(重建时旧的 Gemini 桶并入 Antigravity,见 UsageService.mergePreservingHistory)。
    static let currentVersion: Int = 7
    var version: Int = ScanState.currentVersion
    /// 写盘时记录的价格表指纹；load 时与当前 `Pricing.fingerprint` 不一致即视为缓存失效、全量重扫重算。
    var pricingFingerprint: String = ""
    var claude: [String: ScanFileState] = [:]
    var codex: [String: ScanFileState] = [:]
    var grok: [String: ScanFileState] = [:]
    /// agy 会话库(键为 .db 路径;offset 存库 + WAL 大小，seenTurnIds 存已记过的 step idx)。
    var agy: [String: ScanFileState] = [:]
    /// 跨文件的 Claude message.id 去重集合（同一条 assistant 消息可能被 sidechain / subagent 在多个 jsonl 里重复引用）。
    var claudeSeenMessageIds: [String] = []
}

enum ScanCache {
    nonisolated private static let fileName = "scan-state.json"
    nonisolated private static let bundleDirectory = "yybar"

    nonisolated static func load() -> ScanState {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ScanState.self, from: data),
              state.version == ScanState.currentVersion,
              state.pricingFingerprint == Pricing.fingerprint
        else {
            return ScanState()
        }
        return state
    }

    nonisolated static func save(_ state: ScanState) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}

/// 聚合结果磁盘缓存，启动后立刻 UI 有数。
struct UsageRollupPayload: Sendable, Codable {
    /// version 管「结构变更」；价格变更由 pricingFingerprint 接管。
    /// v5: 配合扫描语义更新，丢弃旧桶重新统计。
    static let currentVersion: Int = 5
    var version: Int = UsageRollupPayload.currentVersion
    /// 写盘时记录的价格表指纹。load 时不一致也照常载入(旧日志可能已被删除，丢掉汇总就找不回来了),
    /// 由 UsageService 在第一次扫描时全量重建并按新价格重算(见 mergePreservingHistory)。
    var pricingFingerprint: String = ""
    var buckets: [UsageBucket] = []
    var updatedAt: Date = Date()
}

enum UsageRollupCache {
    nonisolated private static let fileName = "usage-rollup.json"
    nonisolated private static let bundleDirectory = "yybar"

    nonisolated static func load() -> UsageRollupPayload {
        let url = cacheFileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(UsageRollupPayload.self, from: data),
              payload.version == UsageRollupPayload.currentVersion
        else {
            return UsageRollupPayload()
        }
        return payload
    }

    nonisolated static func save(_ payload: UsageRollupPayload) throws {
        let url = cacheFileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func cacheFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
