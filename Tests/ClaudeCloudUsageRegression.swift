import Foundation

// 此独立回归不读真实登录、不联网；与应用同用解析/账本/扫描实现。
struct ClaudeAccount {}
enum ClaudeAuth { static func load() throws -> ClaudeAccount { throw ClaudeCloudError.identity } }
enum ClaudeTokenRefresher {
    static func ensureFreshAccessToken(account: inout ClaudeAccount) async -> Result<String, ClaudeCloudError> { .failure(.identity) }
}

@main
struct ClaudeCloudUsageRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let since = JSONLTimestamp.parse("2026-10-17T16:00:00Z")!
        func result(_ seq: Int, _ time: String, _ input: Int, _ output: Int, _ cost: Double, index: Int = 0) -> [String: Any] {
            ["sequence_num": String(seq), "created_at": time, "payload": ["type": "result", "result_index": index,
             "modelUsage": ["claude-opus-5-5[1m]": ["inputTokens": input, "outputTokens": output,
             "cacheReadInputTokens": 100, "cacheCreationInputTokens": 20, "costUSD": cost]]]]
        }
        let baseline = result(1, "2026-10-17T15:59:00Z", 10, 5, 0.1, index: 7)
        let next = result(2, "2026-10-17T16:01:00Z", 20, 15, 0.2) // result_index 归零不重计
        let duplicate = result(3, "2026-10-17T16:02:00Z", 20, 15, 0.2)
        var session = ClaudeCloudSession()
        try session.consume(["data": [baseline, next, duplicate]], since: since)
        precondition(session.records.count == 1 && session.records[0].usage.total == 20)
        precondition(session.records[0].usage.cost == Decimal(string: "0.1")!)
        precondition(session.records[0].model == "claude-opus-5-5")
        try session.consume(["data": [baseline, next, duplicate]], since: since)
        precondition(session.records.count == 1 && session.cursor == 3)
        let inputOnly = result(4, "2026-10-18T16:01:00Z", 30, 15, 0.21)
        try session.consume(["data": [inputOnly]], since: since)
        precondition(session.records.last?.usage.input == 10 && session.records.last?.usage.output == 0)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        precondition(calendar.component(.day, from: session.records.last!.timestamp) == 19)
        let bad = result(6, "not a timestamp", 40, 20, 0.3)
        do {
            try session.consume(["data": [result(5, "2026-10-19T01:00:00Z", 40, 20, 0.3), bad]], since: since)
            preconditionFailure("Invalid page should fail atomically")
        } catch {}
        precondition(session.cursor == 4 && session.records.count == 2)
        do {
            try session.consume(["data": [result(5, "2026-10-19T01:00:00Z", 1, 1, 0.01)]], since: since)
            preconditionFailure("Counter rollback must not invent usage")
        } catch {}
        precondition(session.cursor == 4)
        let assistant: [String: Any] = ["sequence_num": "5", "created_at": "2026-10-19T01:00:00Z",
           "payload": ["type": "assistant", "message": ["id": "covered-message", "usage": ["output_tokens": 2]]]]
        try session.consume(["data": [assistant]], since: since)
        precondition(session.messageIDs.isEmpty && session.pendingMessageIDs == ["covered-message"])
        try session.consume(["data": [result(6, "2026-10-19T01:01:00Z", 31, 15, 0.22)]], since: since)
        precondition(session.messageIDs == ["covered-message"] && session.records.count == 3)
        var ledger = ClaudeCloudLedger(); ledger.sessions["account/session"] = session
        let file = root.appendingPathComponent("ledger/state.json")
        try ledger.save(to: file)
        let loaded = try ClaudeCloudLedger.load(from: file)
        precondition(loaded.entries == ledger.entries && loaded.sessions["account/session"]?.cursor == 6)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        // 同一消息存在本机日志时，云端叠加层扣回其本地贡献；重复核对幂等。
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let line = #"{"type":"assistant","timestamp":"2026-10-19T01:00:00Z","message":{"id":"covered-message","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":20}}}"#
        try Data((line + "\n").utf8).write(to: logs.appendingPathComponent("session.jsonl"))
        let local = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], includingMessageIDs: loaded.messageIDs, roots: [logs])
        precondition(local.entries.count == 1 && local.messageEntries.count == 1)
        ledger.reconcile(local: local.messageEntries)
        let once = ledger.entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }
        ledger.reconcile(local: local.messageEntries)
        precondition(ledger.localDeductions.count == 1)
        precondition(once == ledger.entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens })
        precondition(once == 1) // 云端增量 31 - 本机 30
        try ledger.save(to: file)
        let reconciled = try ClaudeCloudLedger.load(from: file)
        precondition(reconciled.localDeductions.count == 1)
        precondition(ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], roots: [logs]).entries.count == 1)
        if CommandLine.arguments.count == 2 {
            // 本机脱敏实录：每个会话整页回放，与服务端累计总量核对。
            let replay = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String: Any]]
            var daily: [String: Int] = [:]
            let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.timeZone = calendar.timeZone
            for fixture in replay {
                var actual = ClaudeCloudSession()
                for page in fixture["pages"] as! [[String: Any]] { try actual.consume(page, since: since) }
                precondition(actual.total == fixture["expected"] as! Int, "Cloud cumulative totals mismatch")
                for record in actual.records { daily[format.string(from: record.timestamp), default: 0] += record.usage.total }
            }
            print("Recovered cloud tokens by completion date:", daily.sorted { $0.key < $1.key })
        }
        print("Claude cloud usage regression passed")
    }
}
