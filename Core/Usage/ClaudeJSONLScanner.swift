import Foundation

/// 扫 `~/.claude/projects/**/*.jsonl` 和 Claude 桌面 App Cowork 会话的日志(见 `logRoots`)，把 assistant 行解析成 UsageEntry。
/// 增量逻辑：file mtime + byte offset；同一条 message.id 跨调用只计一次（持久化到 ScanFileState.seenMessageIds）。
enum ClaudeJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var messageEntries: [String: UsageEntry]
        var newState: [String: ScanFileState]
        var newSeenIds: [String]
        var filesScanned: Int
        var linesParsed: Int
    }

    /// 日志根目录：CLI 的 `~/.claude/projects`,加上 Claude 桌面 App Cowork(本地代理模式)每个会话自己的
    /// `~/Library/Application Support/Claude/local-agent-mode-sessions/<账号>/<组织>/local_<id>/.claude/projects`。
    /// `.claude` 是隐藏目录，目录枚举会跳过它，所以逐层列出会话目录再拼路径。
    nonisolated static func logRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots = [home.appendingPathComponent(".claude/projects", isDirectory: true)]
        let cowork = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
        for account in subdirectories(of: cowork) {
            for org in subdirectories(of: account) {
                for session in subdirectories(of: org) where session.lastPathComponent.hasPrefix("local_") {
                    roots.append(session.appendingPathComponent(".claude/projects", isDirectory: true))
                }
            }
        }
        return roots
    }

    private nonisolated static func subdirectories(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    nonisolated static func scan(previous: [String: ScanFileState], seenMessageIds: [String], includingMessageIDs: Set<String>? = nil, roots: [URL] = logRoots()) -> Result {
        let files = roots.flatMap { JSONLDirectoryEnumerator.files(at: $0) }

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var messageEntries: [String: UsageEntry] = [:]
        var linesParsed = 0
        // 跨文件全局去重：同一 message.id 在 sidechain / subagent 文件中会反复出现。
        var seen = Set(seenMessageIds)

        for url in files {
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

            var state = previous[path] ?? ScanFileState(mtime: 0, offset: 0)
            // mtime 没变 & size 没变 → 跳过
            if state.mtime == mtime, state.offset == size {
                newState[path] = state
                continue
            }
            // 文件被截断：offset 回到 0 重扫（此时仍由全局 seen 兜底防重复计费）
            if state.offset > size {
                state.offset = 0
            }

            // 本批次内按 id 收集 candidate，最后挑 stop_reason != nil 的；最终再与全局 seen 比对。
            // 只有带 usage 的 assistant 行有用，按 "output_tokens" 粗筛，其余行不解析。
            var candidates: [String: ParsedAssistant] = [:]
            var fileLines = 0
            let newOffset = JSONLLineReader.scan(url: url, fromOffset: state.offset, keywords: ["output_tokens"]) { line in
                fileLines += 1
                guard let parsed = parseAssistantLine(line) else { return }
                if seen.contains(parsed.messageId) { return }
                if let includingMessageIDs, !includingMessageIDs.contains(parsed.messageId) { return }
                if let existing = candidates[parsed.messageId] {
                    let prefer = (parsed.stopReason != nil && existing.stopReason == nil)
                        || (parsed.outputTokens > existing.outputTokens && existing.stopReason == nil)
                    if prefer { candidates[parsed.messageId] = parsed }
                } else {
                    candidates[parsed.messageId] = parsed
                }
            }
            guard let newOffset else {
                newState[path] = state
                continue
            }
            linesParsed += fileLines

            for (id, p) in candidates {
                seen.insert(id)
                let day = UsageDay.startOfDay(for: p.timestamp)
                let cost = Pricing.cost(
                    model: p.model,
                    input: p.inputTokens,
                    output: p.outputTokens,
                    cacheRead: p.cacheReadTokens,
                    cacheCreation: p.cacheCreationTokens
                )
                let entry = UsageEntry(
                    app: .claude,
                    model: Pricing.normalize(model: p.model),
                    day: day,
                    timestamp: p.timestamp,
                    inputTokens: p.inputTokens,
                    outputTokens: p.outputTokens,
                    cacheReadTokens: p.cacheReadTokens,
                    cacheCreationTokens: p.cacheCreationTokens,
                    costUSD: cost
                )
                entries.append(entry)
                messageEntries[id] = entry
            }

            state.mtime = mtime
            state.offset = newOffset
            newState[path] = state
        }

        // 删除已不存在的文件 watermark
        let alive = Set(files.map { $0.path })
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        // 控制全局 seen 集合大小：保留最近 20000 条
        let seenArr = Array(seen)
        let cappedSeen = seenArr.count > 20000 ? Array(seenArr.suffix(20000)) : seenArr

        return Result(entries: entries, messageEntries: messageEntries, newState: newState, newSeenIds: cappedSeen, filesScanned: files.count, linesParsed: linesParsed)
    }

    private struct ParsedAssistant {
        var messageId: String
        var model: String
        var timestamp: Date
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var stopReason: String?
    }

    private nonisolated static func parseAssistantLine(_ data: Data) -> ParsedAssistant? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (root["type"] as? String) == "assistant" else { return nil }
        guard let message = root["message"] as? [String: Any] else { return nil }
        guard let messageId = message["id"] as? String else { return nil }
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        let outputTokens = (usage["output_tokens"] as? Int) ?? 0
        if outputTokens == 0 { return nil }
        let inputTokens = (usage["input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let model = (message["model"] as? String) ?? "unknown"
        let stopReason = message["stop_reason"] as? String

        let ts: Date
        if let s = root["timestamp"] as? String, let parsed = JSONLTimestamp.parse(s) {
            ts = parsed
        } else {
            ts = Date()
        }

        return ParsedAssistant(
            messageId: messageId,
            model: model,
            timestamp: ts,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            stopReason: stopReason
        )
    }
}
