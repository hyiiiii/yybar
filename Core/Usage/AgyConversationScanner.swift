import Foundation
import SQLite3

/// agy(Antigravity CLI)本机会话库的用量扫描。
///
/// 每个会话一个 SQLite 库:`~/.gemini/antigravity-cli/conversations/<uuid>.db`(旧版目录 `~/.gemini/antigravity/conversations`)。
/// 只读两张表里的 protobuf 数字字段和模型名，不解析对话内容:
/// - `steps.metadata`(每次模型调用一条，step_type 15):
///   field 1 = 创建时间(Timestamp,1 = 秒)、field 9 = 用量(2 = 输入 token,3 = 输出 token(含思考),
///   5 = 缓存读取、9 = 其中思考、10 = 其中回复)、field 11 = 模型枚举。
///   缓存读取字段号按 CodexBar 的解析(本机库里暂未出现过);按 Gemini API 口径视为包含在输入里，记账时从输入扣掉。
/// - `gen_metadata.data`:field 1 → 3 = 模型枚举、19 = 模型名(如 `gemini-3.8-flash-n`、`claude-opus-4-6-thinking`)。
/// 归属与额度池一致:Gemini 模型记到 Gemini,其余(Claude / GPT-OSS)记到 Antigravity。
///
/// agy 运行中会持有库并写 WAL,所以先把 `.db` / `-wal` 复制到临时目录再打开副本，不锁原库。
/// 增量：库和 WAL 的修改时间、大小都没变就跳过;变了则重读该库，已记过的 step(按 idx,存在 seenTurnIds)不重复计。
enum AgyConversationScanner {
    nonisolated static func defaultRoots() -> [URL] {
        let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        return ["antigravity-cli/conversations", "antigravity/conversations"].map {
            gemini.appendingPathComponent($0, isDirectory: true)
        }
    }

    nonisolated static func scan(previous: [String: ScanFileState], roots suppliedRoots: [URL]? = nil) -> CodexJSONLScanner.Result {
        let fm = FileManager.default
        let files = (suppliedRoots ?? defaultRoots()).flatMap { root in
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "db" }
        }
        var states: [String: ScanFileState] = [:]
        var entries: [UsageEntry] = []
        var stepsParsed = 0
        for url in files {
            let (mtime, size) = signature(of: url)
            var state = previous[url.path] ?? ScanFileState(mtime: 0, offset: 0)
            if state.mtime == mtime && state.offset == size {
                states[url.path] = state
                continue
            }
            guard let calls = readCalls(url: url) else {
                // 读失败(正在被重写等):保留旧进度，下次再试。
                if previous[url.path] != nil { states[url.path] = state }
                continue
            }
            var seen = Set(state.seenTurnIds ?? [])
            for call in calls where !seen.contains(call.id) {
                seen.insert(call.id)
                guard call.input + call.output + call.cacheRead > 0 else { continue }
                let date = call.timestamp
                entries.append(UsageEntry(
                    app: app(forModel: call.model), model: call.model,
                    day: UsageDay.startOfDay(for: date), timestamp: date,
                    inputTokens: call.input, outputTokens: call.output,
                    cacheReadTokens: call.cacheRead, cacheCreationTokens: 0,
                    costUSD: Pricing.cost(model: call.model, input: call.input, output: call.output,
                                          cacheRead: call.cacheRead, cacheCreation: 0)
                ))
            }
            stepsParsed += calls.count
            state.mtime = mtime
            state.offset = size
            state.seenTurnIds = seen.sorted()
            states[url.path] = state
        }
        return .init(entries: entries, newState: states, filesScanned: files.count, linesParsed: stepsParsed)
    }

    /// Gemini 模型 → Gemini 池，其余 → Antigravity 池。
    nonisolated static func app(forModel model: String) -> UsageApp {
        model.lowercased().hasPrefix("gemini") ? .gemini : .agy
    }

    /// agy 的模型名带变体后缀(`-thinking`、`-n` 等),去掉后才能对上价格表。
    nonisolated static func canonicalModel(_ raw: String) -> String {
        var name = raw.lowercased()
        for suffix in ["-thinking", "-n", "-high", "-low", "-medium"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    struct Call: Sendable, Equatable {
        var id: String
        var timestamp: Date
        var model: String
        /// 已扣掉缓存读取。
        var input: Int
        var output: Int
        var cacheRead: Int = 0
    }

    // MARK: - SQLite

    /// 库 + WAL 的合并签名(修改时间取较新者，大小相加)。
    nonisolated private static func signature(of url: URL) -> (Double, UInt64) {
        var mtime = 0.0
        var size: UInt64 = 0
        for path in [url.path, url.path + "-wal"] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            mtime = max(mtime, (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            size += (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        }
        return (mtime, size)
    }

    nonisolated static func readCalls(url: URL) -> [Call]? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("yybar-agy-scan-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        defer { try? fm.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("conversation.db")
        do { try fm.copyItem(at: url, to: copy) } catch { return nil }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }
        return readCalls(databaseAt: copy)
    }

    /// 直接读一个(已复制出来的)会话库。回归测试也用它。
    nonisolated static func readCalls(databaseAt url: URL) -> [Call]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var names: [UInt64: String] = [:]
        forEachBlob(db, "SELECT data FROM gen_metadata") { _, blob in
            guard let info = ProtoReader.message(blob, field: 1),
                  let model = ProtoReader.string(info, field: 19), !model.isEmpty else { return }
            if let enumValue = ProtoReader.varint(info, field: 3) { names[enumValue] = model }
        }

        var calls: [Call] = []
        forEachBlob(db, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL") { idx, blob in
            guard let usage = ProtoReader.message(blob, field: 9),
                  let created = ProtoReader.message(blob, field: 1),
                  let seconds = ProtoReader.varint(created, field: 1) else { return }
            let prompt = Int(ProtoReader.varint(usage, field: 2) ?? 0)
            let cached = min(prompt, Int(ProtoReader.varint(usage, field: 5) ?? 0))
            let output = Int(ProtoReader.varint(usage, field: 3) ?? 0)
            let enumValue = ProtoReader.varint(blob, field: 11) ?? ProtoReader.varint(usage, field: 1)
            let raw = enumValue.flatMap { names[$0] } ?? "agy-model-\(enumValue.map(String.init) ?? "unknown")"
            calls.append(Call(id: String(idx), timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
                              model: canonicalModel(raw), input: prompt - cached, output: output,
                              cacheRead: cached))
        }
        return calls
    }

    nonisolated private static func forEachBlob(_ db: OpaquePointer, _ sql: String, _ body: (Int64, [UInt8]) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let blobColumn: Int32 = sqlite3_column_count(stmt) - 1
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idx = blobColumn > 0 ? sqlite3_column_int64(stmt, 0) : 0
            let count = Int(sqlite3_column_bytes(stmt, blobColumn))
            guard count > 0, let pointer = sqlite3_column_blob(stmt, blobColumn) else { continue }
            body(idx, Array(UnsafeRawBufferPointer(start: pointer, count: count)))
        }
    }
}

/// 极简 protobuf 读取：只按字段号取第一个 varint / 子消息 / 字符串。
nonisolated enum ProtoReader {
    private static func fields(_ bytes: [UInt8], _ visit: (Int, Int, UInt64, ArraySlice<UInt8>) -> Bool) {
        var i = 0
        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let byte = bytes[i]
                i += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let key = readVarint() else { return }
            let field = Int(key >> 3)
            let wire = Int(key & 7)
            switch wire {
            case 0:
                guard let value = readVarint() else { return }
                if !visit(field, wire, value, []) { return }
            case 1:
                i += 8
            case 2:
                guard let length = readVarint(), length <= UInt64(bytes.count - i) else { return }
                let slice = bytes[i..<(i + Int(length))]
                i += Int(length)
                if !visit(field, wire, 0, slice) { return }
            case 5:
                i += 4
            default:
                return
            }
        }
    }

    static func varint(_ bytes: [UInt8], field: Int) -> UInt64? {
        var found: UInt64?
        fields(bytes) { f, wire, value, _ in
            if f == field, wire == 0 { found = value; return false }
            return true
        }
        return found
    }

    static func message(_ bytes: [UInt8], field: Int) -> [UInt8]? {
        var found: [UInt8]?
        fields(bytes) { f, wire, _, slice in
            if f == field, wire == 2 { found = Array(slice); return false }
            return true
        }
        return found
    }

    static func string(_ bytes: [UInt8], field: Int) -> String? {
        message(bytes, field: field).flatMap { String(bytes: $0, encoding: .utf8) }
    }
}
