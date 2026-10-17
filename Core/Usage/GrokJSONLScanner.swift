import Foundation

/// Grok's update stream reports per-prompt usage, including completed subagents.
/// Read only turn_completed (not intermediate notifications or chat text).
enum GrokJSONLScanner {
    nonisolated static func scan(previous: [String: ScanFileState], root suppliedRoot: URL? = nil) -> CodexJSONLScanner.Result {
        let root = suppliedRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/sessions", isDirectory: true)
        let files = JSONLDirectoryEnumerator.files(at: root).filter { $0.lastPathComponent == "updates.jsonl" }
        var states: [String: ScanFileState] = [:]
        var entries: [UsageEntry] = []
        var linesParsed = 0
        var allSeen = Set(previous.values.flatMap { $0.seenTurnIds ?? [] })
        for url in files {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
            var state = previous[url.path] ?? ScanFileState(mtime: 0, offset: 0)
            if state.mtime == mtime && state.offset == size {
                states[url.path] = state
                continue
            }
            // Retain prompt IDs on truncation so replayed turns cannot be counted twice.
            if state.offset > size { state.offset = 0 }
            var seen = Set(state.seenTurnIds ?? [])
            var fileEntries: [UsageEntry] = []
            var fileSeen = Set<String>()
            var fileLines = 0
            // 只读 turn_completed,其余行不解析。
            let newOffset = JSONLLineReader.scan(url: url, fromOffset: state.offset, keywords: ["turn_completed"]) { data in
                fileLines += 1
                guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["method"] as? String == "_x.ai/session/update",
                      let params = event["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      update["sessionUpdate"] as? String == "turn_completed",
                      let usage = update["usage"] as? [String: Any],
                      let timestamp = event["timestamp"] as? Double,
                      let prompt = update["prompt_id"] as? String,
                      !allSeen.contains(prompt), !fileSeen.contains(prompt) else { return }
                let models = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
                // Preserve totals even when older streams omit the model breakdown.
                let breakdown = models.isEmpty ? ["grok-unknown": usage] : models
                let date = Date(timeIntervalSince1970: timestamp)
                for (model, value) in breakdown {
                    let input = max(0, value["inputTokens"] as? Int ?? 0)
                    let cached = min(input, max(0, value["cachedReadTokens"] as? Int ?? 0))
                    let creation = min(input - cached, max(0, value["cacheCreationTokens"] as? Int ?? 0))
                    let output = max(0, value["outputTokens"] as? Int ?? 0)
                    guard input + output > 0 else { continue }
                    // Local Grok docs: 126890500 ticks = $0.01268905 (10^10 ticks/USD).
                    let ticks = value["costUsdTicks"] as? Int64 ?? 0
                    fileEntries.append(UsageEntry(
                        app: .grok, model: model, day: UsageDay.startOfDay(for: date),
                        timestamp: date, inputTokens: input - cached - creation,
                        outputTokens: output, cacheReadTokens: cached,
                        cacheCreationTokens: creation, costUSD: Decimal(ticks) / 10_000_000_000
                    ))
                }
                fileSeen.insert(prompt)
            }
            guard let newOffset else {
                states[url.path] = state
                continue
            }
            entries.append(contentsOf: fileEntries)
            linesParsed += fileLines
            seen.formUnion(fileSeen)
            allSeen.formUnion(fileSeen)
            state.mtime = mtime
            state.offset = newOffset
            state.seenTurnIds = seen.sorted()
            states[url.path] = state
        }
        return .init(entries: entries, newState: states, filesScanned: files.count, linesParsed: linesParsed)
    }
}
