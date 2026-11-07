import Foundation

/// 扫 `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`,以及 Codex 压缩后的旧会话 `*.jsonl.zst`。
/// 压缩文件内容和原 `.jsonl` 逐字节相同：原文件扫过的话沿用它的进度(字节偏移是解压后的偏移),不会重复计数;
/// 本机没有 zstd 命令时跳过压缩文件但保留进度，装上后从断点继续。
/// 关键事件：
///   - `type=turn_context`，`payload.model` 提供当前模型（剥前缀 / 日期后缀）。
///   - `type=event_msg`，`payload.type=token_count`，`payload.info.last_token_usage` 是本次调用的真实 token；
///     使用 total_token_usage 增量去除重复通知；累计值重置时回退到 last_token_usage。
/// Codex `input_tokens` 含 cache_read，需在 billable 时扣掉。
enum CodexJSONLScanner {
    struct Result: Sendable {
        var entries: [UsageEntry]
        var newState: [String: ScanFileState]
        var filesScanned: Int
        var linesParsed: Int
    }

    nonisolated static func scan(previous: [String: ScanFileState], roots suppliedRoots: [URL]? = nil) -> Result {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = suppliedRoots ?? [
            home.appendingPathComponent(".codex/sessions", isDirectory: true),
            home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        ]
        var files: [URL] = []
        // 同一个会话文件(文件名里有时间和会话 ID)在几个 Codex 目录里都有时(备份、复制过去的)只算排在前面的那个
        var seenNames = Set<String>()
        for r in roots {
            for file in JSONLDirectoryEnumerator.files(at: r, includeZstd: true) {
                var name = file.lastPathComponent.lowercased()
                if name.hasSuffix(".zst") { name.removeLast(4) }
                if seenNames.insert(name).inserted { files.append(file) }
            }
        }

        var newState: [String: ScanFileState] = previous
        var entries: [UsageEntry] = []
        var linesParsed = 0
        // 只有这两类行有用，其余(对话正文、工具输出)不解析。
        let keywords = ["turn_context", "token_count"]

        for url in files {
            let path = url.path
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

            let isZstd = path.lowercased().hasSuffix(".jsonl.zst")
            // 同名文件(移到 archived_sessions、或被压缩成 .zst)沿用原来的进度。
            func baseName(_ p: String) -> String {
                let name = URL(fileURLWithPath: p).lastPathComponent
                return name.lowercased().hasSuffix(".zst") ? String(name.dropLast(4)) : name
            }
            let own = previous[path]
            var state = own
                ?? (isZstd ? previous[String(path.dropLast(4))] : nil)
                ?? previous.first(where: { baseName($0.key) == baseName(path) })?.value
                ?? ScanFileState(mtime: 0, offset: 0)

            if isZstd {
                // 压缩文件不再变化：这个 .zst 自己的进度在且 mtime 没变，就是已经扫完了。
                if own != nil, state.mtime == mtime {
                    newState[path] = state
                    continue
                }
            } else {
                if state.mtime == mtime, state.offset == size {
                    newState[path] = state
                    continue
                }
                if state.offset > size {
                    state.offset = 0
                    state.lastModel = nil
                    state.lastTotalUsage = nil
                }
            }

            // 本文件这次的结果先放在局部，读完整才并入；中途读失败(如解压出错)丢弃，下次从原进度重来，不会重复计数。
            var fileEntries: [UsageEntry] = []
            var fileLines = 0
            var currentModel = state.lastModel
            var lastTotalUsage = state.lastTotalUsage
            func handle(_ data: Data) {
                fileLines += 1
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let type = root["type"] as? String

                if type == "turn_context" {
                    if let payload = root["payload"] as? [String: Any],
                       let m = payload["model"] as? String {
                        currentModel = m
                    }
                    return
                }
                guard type == "event_msg",
                      let payload = root["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count" else {
                    return
                }
                guard let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any] else {
                    return
                }
                var usage = last.compactMapValues { $0 as? Int }
                if let total = info["total_token_usage"] as? [String: Int] {
                    if let prior = lastTotalUsage {
                        if total == prior { return }
                        let keys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"]
                        if keys.allSatisfy({ total[$0, default: 0] >= prior[$0, default: 0] }) {
                            usage = Dictionary(uniqueKeysWithValues: keys.map {
                                ($0, total[$0, default: 0] - prior[$0, default: 0])
                            })
                        }
                    }
                    lastTotalUsage = total
                }
                let inputTotal = max(0, usage["input_tokens"] ?? 0)
                let cachedInput = min(inputTotal, max(0, usage["cached_input_tokens"] ?? 0))
                let output = max(0, usage["output_tokens"] ?? 0)
                let cacheWrite = min(inputTotal - cachedInput, max(0, usage["cache_write_input_tokens"] ?? 0))
                let billableInput = max(0, inputTotal - cachedInput - cacheWrite)
                if output == 0 && billableInput == 0 && cachedInput == 0 && cacheWrite == 0 { return }

                guard let s = root["timestamp"] as? String, let ts = JSONLTimestamp.parse(s) else { return }
                let model = currentModel ?? "unknown"
                let cost = Pricing.cost(
                    model: model,
                    input: billableInput,
                    output: output,
                    cacheRead: cachedInput,
                    cacheCreation: cacheWrite,
                    requestInputTokens: last["input_tokens"] as? Int
                )
                fileEntries.append(UsageEntry(
                    app: .codex,
                    model: Pricing.normalize(model: model),
                    day: UsageDay.startOfDay(for: ts),
                    timestamp: ts,
                    inputTokens: billableInput,
                    outputTokens: output,
                    cacheReadTokens: cachedInput,
                    cacheCreationTokens: cacheWrite,
                    costUSD: cost
                ))
            }

            let newOffset: UInt64
            if isZstd {
                guard var result = JSONLLineReader.scanZstd(url: url, fromOffset: state.offset, keywords: keywords, handle) else {
                    // 没有 zstd 命令或解压失败：保留(可能从原 .jsonl 继承的)进度，mtime 记 0 以便下次重试。
                    state.mtime = 0
                    newState[path] = state
                    continue
                }
                if result.total < state.offset {
                    // 继承来的偏移超出解压后的长度(内容对不上):从头重扫。
                    state.lastModel = nil
                    state.lastTotalUsage = nil
                    fileEntries = []
                    fileLines = 0
                    currentModel = nil
                    lastTotalUsage = nil
                    guard let again = JSONLLineReader.scanZstd(url: url, fromOffset: 0, keywords: keywords, handle) else {
                        state.mtime = 0
                        newState[path] = state
                        continue
                    }
                    result = again
                }
                newOffset = result.newOffset
            } else {
                guard let offset = JSONLLineReader.scan(url: url, fromOffset: state.offset, keywords: keywords, handle) else {
                    newState[path] = state
                    continue
                }
                newOffset = offset
            }

            entries.append(contentsOf: fileEntries)
            linesParsed += fileLines
            state.mtime = mtime
            state.offset = newOffset
            state.lastModel = currentModel
            state.lastTotalUsage = lastTotalUsage
            newState[path] = state
        }

        let alive = Set(files.map { $0.path })
        for key in newState.keys where !alive.contains(key) {
            newState.removeValue(forKey: key)
        }

        return Result(entries: entries, newState: newState, filesScanned: files.count, linesParsed: linesParsed)
    }
}
