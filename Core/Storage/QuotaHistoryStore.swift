import Foundation

enum QuotaHistoryAccountKind: String, Sendable, Codable {
    case codexPrimary
    case codexImported
    case claudePrimary
    case claudeExtra
    case grokPrimary
    case grokExtra
}

/// 记录哪个额度窗口。周窗口的记录用 `QuotaHistoryAccountKey.weekly(_:)` 派生的 key 存，
/// 与 5H 记录互不干扰，旧文件(只有 5H)照常读取。
enum QuotaHistoryWindow: Sendable {
    case fiveHour
    case weekly

    /// 从快照里取该窗口。Grok 没有 5H,周期额度在 `primary`(周计费时也写在 weekly)。
    nonisolated func window(in snapshot: QuotaSnapshot) -> QuotaWindow? {
        switch self {
        case .fiveHour: return snapshot.fiveHour
        case .weekly: return snapshot.weekly ?? snapshot.primary
        }
    }
}

struct QuotaHistorySample: Sendable, Equatable, Codable {
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var remainingPercent: Int
    var resetsAt: Date?
}

struct QuotaChangeEvent: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var accountKey: String
    var app: QuotaApp
    var kind: QuotaHistoryAccountKind
    var sampledAt: Date
    var beforeRemainingPercent: Int
    var afterRemainingPercent: Int
    var deltaPercent: Int
    var resetsAt: Date?
}

struct QuotaHistoryPayload: Sendable, Equatable, Codable {
    static let currentVersion = 1

    var version: Int = Self.currentVersion
    var dayStart: Date = QuotaHistoryStore.todayStart()
    var lastSamples: [String: QuotaHistorySample] = [:]
    var events: [QuotaChangeEvent] = []
    /// 每个 key 今天第一次采样的时间。曲线从这里开始画，早于它的时段没有数据。
    /// 旧文件没有该字段，解码为 nil。
    var firstSampledAt: [String: Date]? = nil
}

enum QuotaHistoryAccountKey {
    nonisolated static func codexPrimary(accountId: String?) -> String {
        if let id = nonEmpty(accountId) {
            return "codex:primary:\(id)"
        }
        return "codex:primary"
    }

    nonisolated static func codexImported(id: String) -> String {
        "codex:imported:\(id)"
    }

    nonisolated static func claudePrimary() -> String {
        "claude:primary"
    }

    nonisolated static func grokPrimary() -> String {
        "grok:primary"
    }

    /// 额外 Claude / Grok 账号,id 为 ExtraAccount.id(已带 provider 前缀)。
    nonisolated static func extra(id: String) -> String {
        "extra:\(id)"
    }

    /// 同一账号周窗口的 key。
    nonisolated static func weekly(_ key: String) -> String {
        key + "#wk"
    }

    nonisolated private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

enum QuotaHistoryStore {
    nonisolated private static let fileName = "quota-history-today.json"
    nonisolated private static let bundleDirectory = "yybar"

    nonisolated static func load(now: Date = Date()) -> QuotaHistoryPayload {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(QuotaHistoryPayload.self, from: data),
              payload.version == QuotaHistoryPayload.currentVersion
        else {
            return QuotaHistoryPayload(dayStart: todayStart(now: now))
        }
        return prune(payload, now: now)
    }

    nonisolated static func save(_ payload: QuotaHistoryPayload) throws {
        let url = fileURL()
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated static func record(
        payload: QuotaHistoryPayload,
        accountKey: String,
        app: QuotaApp,
        kind: QuotaHistoryAccountKind,
        snapshot: QuotaSnapshot,
        sampledAt: Date,
        window: QuotaHistoryWindow = .fiveHour
    ) -> QuotaHistoryPayload {
        guard let fiveHour = window.window(in: snapshot) else {
            return prune(payload, now: sampledAt)
        }

        var next = prune(payload, now: sampledAt)
        if next.firstSampledAt?[accountKey] == nil {
            var first = next.firstSampledAt ?? [:]
            first[accountKey] = sampledAt
            next.firstSampledAt = first
        }
        let remaining = roundedPercent(fiveHour.remainingPercent)
        let previous = next.lastSamples[accountKey]

        next.lastSamples[accountKey] = QuotaHistorySample(
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            remainingPercent: remaining,
            resetsAt: fiveHour.resetsAt
        )

        guard let previous, previous.remainingPercent != remaining else {
            return next
        }

        let delta = remaining - previous.remainingPercent
        next.events.append(QuotaChangeEvent(
            id: eventId(accountKey: accountKey, sampledAt: sampledAt, before: previous.remainingPercent, after: remaining),
            accountKey: accountKey,
            app: app,
            kind: kind,
            sampledAt: sampledAt,
            beforeRemainingPercent: previous.remainingPercent,
            afterRemainingPercent: remaining,
            deltaPercent: delta,
            resetsAt: fiveHour.resetsAt
        ))
        return next
    }

    nonisolated static func todayStart(now: Date = Date()) -> Date {
        Calendar.current.startOfDay(for: now)
    }

    nonisolated static func fileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent(bundleDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    nonisolated private static func prune(_ payload: QuotaHistoryPayload, now: Date) -> QuotaHistoryPayload {
        let start = todayStart(now: now)
        guard Calendar.current.isDate(payload.dayStart, inSameDayAs: start) else {
            return QuotaHistoryPayload(dayStart: start)
        }

        var next = payload
        next.dayStart = start
        next.events = next.events.filter { Calendar.current.isDate($0.sampledAt, inSameDayAs: start) }
        next.lastSamples = next.lastSamples.filter { Calendar.current.isDate($0.value.sampledAt, inSameDayAs: start) }
        next.firstSampledAt = next.firstSampledAt?.filter { Calendar.current.isDate($0.value, inSameDayAs: start) }
        return next
    }

    nonisolated private static func roundedPercent(_ value: Double) -> Int {
        max(0, min(100, Int(value.rounded())))
    }

    nonisolated private static func eventId(
        accountKey: String,
        sampledAt: Date,
        before: Int,
        after: Int
    ) -> String {
        "\(accountKey)|\(Int(sampledAt.timeIntervalSince1970))|\(before)|\(after)"
    }
}
