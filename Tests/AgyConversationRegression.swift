import Foundation
import SQLite3

// agy 会话库用量解析回归。样例库由本测试现场合成(字段号与 agy 实际库相同，数值是编的),
// 不读真实会话、不含任何对话内容。

@main
struct AgyConversationRegression {
    static func varint(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0
        return out
    }
    static func field(_ n: Int, _ value: UInt64) -> [UInt8] { varint(UInt64(n << 3)) + varint(value) }
    static func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(UInt64(n << 3 | 2)) + varint(UInt64(bytes.count)) + bytes }

    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("yybar-agy-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sample.db")
        var db: OpaquePointer?
        precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, metadata blob, step_payload blob);
            CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);
            """, nil, nil, nil)
        func insert(_ sql: String, _ idx: Int, _ blob: [UInt8]) {
            var stmt: OpaquePointer?
            precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK)
            sqlite3_bind_int64(stmt, 1, Int64(idx))
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            precondition(sqlite3_step(stmt) == SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        // gen_metadata:模型枚举 → 模型名(field 1 → 3 / 19)。
        insert("INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", 0, field(1, field(3, 1319) + field(19, Array("gemini-3.8-flash-n".utf8))))
        insert("INSERT INTO gen_metadata (idx, data) VALUES (?, ?)", 1, field(1, field(3, 1026) + field(19, Array("claude-opus-4-6-thinking".utf8))))
        let t: UInt64 = 1_792_419_052
        // 用户输入步骤(无用量)→ 忽略。
        insert("INSERT INTO steps (idx, metadata) VALUES (?, ?)", 0, field(1, field(1, t)))
        // 模型调用：field 1 时间、9 用量(2 输入 / 3 输出 / 9 思考 / 10 回复)、11 模型枚举。
        insert("INSERT INTO steps (idx, metadata) VALUES (?, ?)", 1,
               field(1, field(1, t + 3)) + field(9, field(1, 1319) + field(2, 13_610) + field(3, 39) + field(9, 38) + field(10, 1)) + field(11, 1319))
        insert("INSERT INTO steps (idx, metadata) VALUES (?, ?)", 2,
               field(1, field(1, t + 60)) + field(9, field(1, 1026) + field(2, 15_975) + field(3, 60)) + field(11, 1026))
        // 枚举在 gen_metadata 里找不到 → agy-model-<n>,归 Antigravity。
        insert("INSERT INTO steps (idx, metadata) VALUES (?, ?)", 3,
               field(1, field(1, t + 90)) + field(9, field(2, 100) + field(3, 5) + field(5, 40)) + field(11, 77))
        sqlite3_close(db)

        let calls = AgyConversationScanner.readCalls(databaseAt: url)!
        precondition(calls.count == 3, "\(calls)")
        precondition(calls[0] == .init(id: "1", timestamp: Date(timeIntervalSince1970: TimeInterval(t + 3)),
                                       model: "gemini-3.8-flash", input: 13_610, output: 39))
        precondition(calls[1].model == "claude-opus-4-6" && calls[1].input == 15_975 && calls[1].output == 60)
        precondition(calls[2].model == "agy-model-77" && calls[2].input == 60 && calls[2].cacheRead == 40)
        precondition(calls[1].cacheRead == 0)
        precondition(AgyConversationScanner.app(forModel: calls[0].model) == .agy)   // 按工具归属
        precondition(AgyConversationScanner.app(forModel: calls[1].model) == .agy)
        precondition(AgyConversationScanner.app(forModel: calls[2].model) == .agy)
        precondition(AgyConversationScanner.canonicalModel("gpt-oss-120b-medium") == "gpt-oss-120b")

        // 增量：同一个库第二次扫描不重复计。
        let roots = [dir]
        let first = AgyConversationScanner.scan(previous: [:], roots: roots)
        precondition(first.entries.count == 3 && first.entries.allSatisfy { $0.app == .agy })
        precondition(first.entries[0].costUSD > 0)   // gemini-3.8-flash 有价
        let second = AgyConversationScanner.scan(previous: first.newState, roots: roots)
        precondition(second.entries.isEmpty)
        var touched = first.newState
        touched[url.path]?.mtime = 0                 // 模拟库被改写：重读但已记过的 step 不再计
        precondition(AgyConversationScanner.scan(previous: touched, roots: roots).entries.isEmpty)
        print("AgyConversationRegression OK")
    }
}
