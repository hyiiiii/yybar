import CryptoKit
import Foundation

// MARK: - GeminiAnswerLog
//
// Gemini App 每天每个模型回答了几次。Gemini App 不给 token 数，本机也没有它的对话记录，
// 统计里 Gemini 只能按回答次数算(只看 Gemini 时统计页换成回答次数，见 StatsView.answersOnly)。
//
// 数据来自 Gemini Apps 网页的会话元数据(GeminiAppQuotaClient.fetchActivity):只记 天 + 模型 + 次数，
// 不存正文、标题和会话 ID;去重用回答 ID / 会话 ID 的 SHA-256 摘要。
// 按 Google 账号分文件存在 Application Support/yybar/gemini-answers-<账号摘要>.json,换账号不混在一起。
// 从开始记录起才有数据：第一次读到某个会话时只算它最近 30 轮，更早的回答不补。

nonisolated struct GeminiAnswerLog: Codable, Equatable, Sendable {
    nonisolated struct Count: Codable, Equatable, Sendable {
        /// 本地 0 点。
        var day: Date
        var model: String
        var count: Int
    }

    /// 抓取时得到的一条回答，记进 counts 后不再保留。
    nonisolated struct Answer: Equatable, Sendable {
        var digest: String
        var time: Date
        var model: String
    }

    /// 这份记录属于哪个 Google 账号(邮箱)。
    var account: String?
    var counts: [Count] = []
    /// 已计数回答 ID 的摘要(先进先出，最多 maxCounted 个)。
    var counted: [String] = []
    /// 会话 ID 摘要 → 上次读取时会话的更新时间(秒)。更新时间没变的会话不再读。
    var chats: [String: Double] = [:]

    nonisolated static let maxCounted = 20_000
    nonisolated static let maxChats = 1_000

    nonisolated init(account: String? = nil) {
        self.account = account
    }

    nonisolated static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 记入新回答(已计数的跳过)。返回新记入的条数。
    @discardableResult
    nonisolated mutating func record(_ answers: [Answer]) -> Int {
        var seen = Set(counted)
        var added = 0
        var index = Dictionary(counts.enumerated().map { (CountKey(day: $0.element.day, model: $0.element.model), $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        for answer in answers where !seen.contains(answer.digest) {
            seen.insert(answer.digest)
            counted.append(answer.digest)
            added += 1
            let key = CountKey(day: UsageDay.startOfDay(for: answer.time), model: answer.model)
            if let at = index[key] {
                counts[at].count += 1
            } else {
                index[key] = counts.count
                counts.append(Count(day: key.day, model: key.model, count: 1))
            }
        }
        if counted.count > Self.maxCounted { counted.removeFirst(counted.count - Self.maxCounted) }
        return added
    }

    /// 记下这次读过的会话(只留最近更新的 maxChats 个)。
    nonisolated mutating func markChats(_ marks: [String: Double]) {
        chats.merge(marks) { max($0, $1) }
        if chats.count > Self.maxChats {
            let keep = chats.sorted { $0.value > $1.value }.prefix(Self.maxChats)
            chats = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    private nonisolated struct CountKey: Hashable {
        let day: Date
        let model: String
    }

    // MARK: 查询

    /// [from, to) 内的回答次数。
    nonisolated func total(from: Date, to: Date) -> Int {
        counts.reduce(0) { $1.day >= from && $1.day < to ? $0 + $1.count : $0 }
    }

    /// [from, to) 内每个模型的回答次数。
    nonisolated func byModel(from: Date, to: Date) -> [String: Int] {
        var result: [String: Int] = [:]
        for c in counts where c.day >= from && c.day < to { result[c.model, default: 0] += c.count }
        return result
    }

    /// 每天的回答次数。
    nonisolated var daily: [Date: Int] {
        var result: [Date: Int] = [:]
        for c in counts { result[c.day, default: 0] += c.count }
        return result
    }

    /// day 之前最早有回答的那天。
    nonisolated func firstDay(before day: Date) -> Date? {
        counts.lazy.filter { $0.day < day && $0.count > 0 }.map(\.day).min()
    }

    // MARK: 存储

    nonisolated static func fileURL(account: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("yybar/gemini-answers-\(digest(account.lowercased())).json", isDirectory: false)
    }

    nonisolated static func load(account: String) -> GeminiAnswerLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: fileURL(account: account)),
              var log = try? decoder.decode(GeminiAnswerLog.self, from: data) else { return GeminiAnswerLog(account: account) }
        log.account = account
        return log
    }

    /// 存盘排在同一个串行队列里，先拿到的快照先写，不会被旧快照盖住。
    private nonisolated static let saveQueue = DispatchQueue(label: "yybar.gemini-answers.save", qos: .utility)

    nonisolated func saveInBackground() {
        let snapshot = self
        Self.saveQueue.async { try? snapshot.save() }
    }

    nonisolated func save() throws {
        guard let account else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let url = Self.fileURL(account: account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
