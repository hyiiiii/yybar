import Foundation

@main
struct UsageScannerRegression {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        let grok = root.appendingPathComponent("grok")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: grok, withIntermediateDirectories: true)
        let file = codex.appendingPathComponent("rollout-test.jsonl")
        let model = #"{"type":"turn_context","payload":{"model":"gpt-6-astra"}}"#
        func tokens(_ input: Int, _ output: Int, _ cached: Int) -> String {
            """
            {"timestamp":"2026-09-07T23:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output)},"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}}}
            """
        }
        func write(_ text: String, to url: URL, append: Bool = false) throws {
            if append {
                let h = try FileHandle(forWritingTo: url)
                try h.seekToEnd()
                try h.write(contentsOf: Data(text.utf8))
                try h.close()
            } else { try Data(text.utf8).write(to: url) }
        }
        try write(model + "\n" + tokens(100, 10, 40) + "\n" + tokens(100, 10, 40) + "\n", to: file)
        let first = CodexJSONLScanner.scan(previous: [:], roots: [codex])
        precondition(first.entries.count == 1, "Repeated token notification counted twice")
        precondition(first.entries[0].inputTokens == 60 && first.entries[0].cacheReadTokens == 40)
        precondition(first.entries[0].model == "gpt-6-astra")
        precondition(CodexJSONLScanner.scan(previous: first.newState, roots: [codex]).entries.isEmpty)
        // The next usage event is incomplete until its newline arrives.
        try write(tokens(200, 20, 80), to: file, append: true)
        let partial = CodexJSONLScanner.scan(previous: first.newState, roots: [codex])
        precondition(partial.entries.isEmpty)
        try write("\n", to: file, append: true)
        let next = CodexJSONLScanner.scan(previous: partial.newState, roots: [codex])
        precondition(next.entries.count == 1 && next.entries[0].inputTokens == 60)
        try write(tokens(100, 10, 40) + "\n", to: file, append: true)
        let reset = CodexJSONLScanner.scan(previous: next.newState, roots: [codex])
        precondition(reset.entries.count == 1 && reset.entries[0].outputTokens == 10)
        let archive = root.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        precondition(CodexJSONLScanner.scan(previous: reset.newState, roots: [codex, archive]).entries.isEmpty)
        let event = #"{"timestamp":1788746493,"method":"_x.ai/session/update","params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"prompt-1","usage":{"modelUsage":{"grok-4.6-build":{"inputTokens":100,"cachedReadTokens":40,"cacheCreationTokens":10,"outputTokens":20,"costUsdTicks":126890500}}}}}}"#
        let gfile = grok.appendingPathComponent("updates.jsonl")
        try write(event + "\n" + event + "\n", to: gfile)
        let clone = grok.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try write(event + "\n", to: clone.appendingPathComponent("updates.jsonl"))
        let gfirst = GrokJSONLScanner.scan(previous: [:], root: grok)
        precondition(gfirst.entries.count == 1, "Cloned Grok prompt counted twice")
        precondition(gfirst.entries[0].inputTokens == 50)
        precondition(gfirst.entries[0].costUSD == Decimal(string: "0.01268905")!)
        precondition(GrokJSONLScanner.scan(previous: gfirst.newState, root: grok).entries.isEmpty)
        precondition(Pricing.hasPrice(model: "gpt-6-astra"))
        precondition(Pricing.hasPrice(model: "gpt-5.6-sol"))
        // Streaming reader: lines longer than the 1 MB read buffer, and keyword-filtered lines in between.
        let long = root.appendingPathComponent("long")
        try FileManager.default.createDirectory(at: long, withIntermediateDirectories: true)
        let longFile = long.appendingPathComponent("rollout-long.jsonl")
        let filler = #"{"type":"response_item","payload":{"output":""# + String(repeating: "x", count: 3_000_000) + #""}}"#
        try write(model + "\n" + filler + "\n" + tokens(100, 10, 40) + "\n" + filler + "\n" + tokens(200, 20, 80) + "\n", to: longFile)
        let longScan = CodexJSONLScanner.scan(previous: [:], roots: [long])
        precondition(longScan.entries.count == 2, "Lines around a long line were lost")
        let longSize = try FileManager.default.attributesOfItem(atPath: longFile.path)[.size] as! NSNumber
        precondition(longScan.newState.count == 1 && longScan.newState.values.first?.offset == longSize.uint64Value)
        // Compressed sessions stream through zstd and keep the uncompressed file's progress.
        if let zstd = JSONLLineReader.zstdBinary {
            let compress = Process()
            compress.executableURL = zstd
            compress.arguments = ["-q", "--rm", longFile.path]
            try compress.run()
            compress.waitUntilExit()
            precondition(compress.terminationStatus == 0)
            precondition(CodexJSONLScanner.scan(previous: longScan.newState, roots: [long]).entries.isEmpty,
                         "Compressed session counted again")
            let fresh = CodexJSONLScanner.scan(previous: [:], roots: [long])
            precondition(fresh.entries.count == 2 && fresh.entries[1].inputTokens == 60)
            precondition(fresh.newState.count == 1 && fresh.newState.values.first?.offset == longSize.uint64Value)
        }
        precondition(Pricing.hasPrice(model: "gpt-5.6-luna"))
        precondition(Pricing.hasPrice(model: "claude-opus-5-5-20260922"))
        precondition(Pricing.hasPrice(model: "gpt-6-sol"))
        precondition(Pricing.hasPrice(model: "gpt-6-luna"))
        precondition(Pricing.hasPrice(model: "gpt-6.1-sol"))
        precondition(Pricing.hasPrice(model: "gpt-6.2-astra"))
        precondition(Pricing.hasPrice(model: "gpt-6.2-sol"))
        precondition(Pricing.hasPrice(model: "gpt-6.1-terra"))
        precondition(Pricing.cost(model: "gpt-6.2-astra", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheCreation: 0, requestInputTokens: 300_000) == 76)
        precondition(Pricing.cost(model: "claude-opus-5-5", input: 1_000_000, output: 0, cacheRead: 1_000_000, cacheCreation: 0) == Decimal(string: "4.2")!)
        precondition(Pricing.cost(model: "gpt-6-sol", input: 1_000_000, output: 0, cacheRead: 0, cacheCreation: 0, requestInputTokens: 1) == 2)
        precondition(Pricing.cost(model: "gpt-6-sol", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheCreation: 0, requestInputTokens: 300_000) == 19)
        precondition(Pricing.cost(model: "gpt-6-luna", input: 1_000_000, output: 1_000_000, cacheRead: 0, cacheCreation: 0, requestInputTokens: 1) == Decimal(string: "0.6")!)
        precondition(!Pricing.hasPrice(model: "not-a-real-model"))
        let billing = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-05T19:08:50.096538+00:00","end":"2026-09-12T19:08:50.096538+00:00"},"creditUsagePercent":2}}"#.utf8)
        let snap = try GrokQuotaClient.parse(data: billing)
        precondition(snap.app == .grok)
        precondition(snap.primary?.usedPercent == 2)
        precondition(abs((snap.primary?.remainingPercent ?? 0) - 98) < 0.01)
        precondition(snap.primaryLabel == "WEEK · 本周")
        // Regression: billing omits creditUsagePercent after the weekly reset.
        var rootBilling = try JSONSerialization.jsonObject(with: billing) as! [String: Any]
        var config = rootBilling["config"] as! [String: Any]
        config.removeValue(forKey: "creditUsagePercent")
        rootBilling["config"] = config
        let zeroSnapshot = try GrokQuotaClient.parse(data: JSONSerialization.data(withJSONObject: rootBilling))
        precondition(zeroSnapshot.primary?.remainingPercent == 100)
        precondition(zeroSnapshot.weekly?.remainingPercent == 100)
        precondition(zeroSnapshot.primary?.resetsAt == snap.primary?.resetsAt)
        for value in [0, 100, 120] {
            config["creditUsagePercent"] = value
            rootBilling["config"] = config
            let result = try GrokQuotaClient.parse(data: JSONSerialization.data(withJSONObject: rootBilling))
            precondition(result.primary?.remainingPercent == Double(max(0, 100 - value)))
        }
        for value: Any in [NSNull(), true, "invalid", -1] {
            config["creditUsagePercent"] = value
            rootBilling["config"] = config
            do {
                _ = try GrokQuotaClient.parse(data: JSONSerialization.data(withJSONObject: rootBilling))
                preconditionFailure("Malformed percentage accepted")
            } catch {}
        }
        for broken in [#"{}"#, #"{"config":{}}"#,
                       #"{"config":{"currentPeriod":{"start":"bad","end":"bad"}}}"#] {
            do {
                _ = try GrokQuotaClient.parse(data: Data(broken.utf8))
                preconditionFailure("Missing/invalid period accepted as full quota")
            } catch {}
        }
        // Claude:CLI 日志和 Cowork 会话(隐藏的 .claude 目录)都要扫到;不是 local_ 开头的目录不算;同一 message.id 只计一次。
        let home = root.appendingPathComponent("home")
        let sessions = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        let cliProject = home.appendingPathComponent(".claude/projects/-Users-test")
        let coworkProject = sessions.appendingPathComponent("acct/org/local_abc/.claude/projects/-sessions-outputs")
        let pluginProject = sessions.appendingPathComponent("skills-plugin/org/acct/.claude/projects/p")
        for dir in [cliProject, coworkProject, pluginProject] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        func assistant(_ id: String) -> String {
            #"{"type":"assistant","timestamp":"2026-06-11T08:00:00Z","message":{"id":""# + id
                + #"","model":"claude-opus-4-8","stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":20}}}"#
        }
        try write(assistant("msg_cli") + "\n", to: cliProject.appendingPathComponent("s1.jsonl"))
        try write(assistant("msg_cowork") + "\n" + assistant("msg_cli") + "\n", to: coworkProject.appendingPathComponent("s2.jsonl"))
        try write(assistant("msg_plugin") + "\n", to: pluginProject.appendingPathComponent("s3.jsonl"))
        let claudeRoots = ClaudeJSONLScanner.logRoots(home: home)
        precondition(claudeRoots.count == 2, "Cowork session log folder not found")
        let claude = ClaudeJSONLScanner.scan(previous: [:], seenMessageIds: [], roots: claudeRoots)
        precondition(claude.entries.count == 2 && claude.newState.count == 2, "Cowork logs missed or counted twice")
        precondition(ClaudeJSONLScanner.scan(previous: claude.newState, seenMessageIds: claude.newSeenIds, roots: claudeRoots).entries.isEmpty)
        let live = GrokJSONLScanner.scan(previous: [:])
        print("PASS: repeated notifications, cache arithmetic, incremental resume, partial lines, counter reset, archive move, long lines, zstd streaming, Grok clone deduplication, Claude Cowork logs, cost units, cloud billing parse, current model prices.")
        print("Local Grok: \(live.entries.count) model entries, \(live.entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }) tokens, $\(live.entries.reduce(Decimal.zero) { $0 + $1.costUSD })")
    }
}
