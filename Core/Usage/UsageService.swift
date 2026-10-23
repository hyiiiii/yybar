import Foundation
import Observation

/// 协调 JSONL 扫描 → 聚合 → 持久化 → 通知 AppState 的入口。
@MainActor
@Observable
final class UsageService {
    let aggregator = UsageAggregator()
    private let localAggregator = UsageAggregator()
    private var cloudLedger = ClaudeCloudLedger()
    private var cloudLoadFailed = false
    private(set) var cloudStatus = "尚未同步 / Not synced"

    private(set) var isScanning = false
    private(set) var lastScanAt: Date?
    private(set) var lastError: String?

    private weak var appState: AppState?
    /// 扫描进行中送来的 Grok Bot 合计，等这次扫描落盘前覆盖进去，避免被旧快照写回去。
    private var pendingGrokBotTotals: [APIUsageTotal] = []

    func bootstrap(appState: AppState) {
        self.appState = appState
        // 启动同步：先把 rollup 灌进内存
        let payload = UsageRollupCache.load()
        localAggregator.load(from: payload.buckets)
        do {
            cloudLedger = try ClaudeCloudLedger.load()
            updateCloudStatus()
        } catch {
            cloudLoadFailed = true
            cloudStatus = "云端账本读取失败，保留文件 / Cloud ledger unreadable"
        }
        refreshCombinedTotals()
        // 价格表(内置或自定义)在上次退出后变了：第一次扫描全量重建，保留的历史按新价格重算。
        if !payload.buckets.isEmpty, payload.pricingFingerprint != Pricing.fingerprint {
            pendingRebuild = .all
        }
        publishTotals()
    }

    /// 全量重建时，日志已不在磁盘上、只剩在汇总里的历史桶要不要按新价格重算费用。
    enum Reprice: Sendable {
        case none
        case keys(Set<String>)
        case all

        func merged(with other: Reprice) -> Reprice {
            switch (self, other) {
            case (.all, _), (_, .all): return .all
            case (.keys(let a), .keys(let b)): return .keys(a.union(b))
            case (.none, let x), (let x, .none): return x
            }
        }
    }

    /// 待做的全量重建(启动时发现价格变了，或扫描进行中又改了价格)。
    private var pendingRebuild: Reprice?

    /// 由 Scheduler / 手动触发；防重入。
    func scanNow() async {
        await scan(rebuild: nil)
    }

    /// 用户改了某些模型的自定义价格后按新价格重算：重扫所有还在磁盘上的日志到一个新的聚合里，
    /// 日志已被删除的历史保留并按新价格重算(见 mergePreservingHistory),完成后整体替换，期间界面继续显示旧数字。
    func rescanAll(repricing keys: Set<String>) async {
        await scan(rebuild: .keys(keys))
    }

    private func scan(rebuild: Reprice?) async {
        guard !isScanning else {
            if let rebuild { pendingRebuild = pendingRebuild?.merged(with: rebuild) ?? rebuild }
            return
        }
        isScanning = true
        var request = rebuild
        if let pending = pendingRebuild {
            request = request?.merged(with: pending) ?? pending
            pendingRebuild = nil
        }
        await performScan(rebuild: request)
        isScanning = false
        // 扫描结束前刚入队的合计，这里落盘。扫描自己的保存已经把更早入队的合计写进去了。
        await drainGrokBotTotals()
        if let next = pendingRebuild {
            pendingRebuild = nil
            await scan(rebuild: next)
        }
    }

    private func performScan(rebuild requested: Reprice?) async {
        let started = Date()
        let prev = requested != nil ? ScanState() : await Task.detached(priority: .utility) {
            ScanCache.load()
        }.value
        // 扫描进度丢了(缓存目录被清理、结构版本变了)但汇总还在：不能在旧汇总上增量叠加(会重复计数),改为全量重建。
        var rebuild = requested
        if rebuild == nil, prev.claude.isEmpty, prev.codex.isEmpty, prev.grok.isEmpty, prev.agy.isEmpty, !localAggregator.snapshot().isEmpty {
            rebuild = Reprice.none
        }

        let prevSeen = prev.claudeSeenMessageIds
        var pendingCloud = cloudLedger
        if SettingsStore.shared.claudeCloudUsageEnabled, !cloudLoadFailed {
            cloudStatus = "同步中… / Syncing…"
            let prior = cloudLedger
            pendingCloud = await Task.detached(priority: .utility) {
                await ClaudeCloudUsageClient.sync(prior)
            }.value
        }
        let coveredIDs = pendingCloud.messageIDs
        async let overlapTask = Task.detached(priority: .utility) {
            coveredIDs.isEmpty ? [:] : ClaudeJSONLScanner.scan(
                previous: [:], seenMessageIds: [], includingMessageIDs: coveredIDs).messageEntries
        }.value
        async let claudeTask = Task.detached(priority: .utility) {
            ClaudeJSONLScanner.scan(previous: prev.claude, seenMessageIds: prevSeen)
        }.value
        async let codexTask = Task.detached(priority: .utility) {
            CodexJSONLScanner.scan(previous: prev.codex)
        }.value

        async let grokTask = Task.detached(priority: .utility) {
            GrokJSONLScanner.scan(previous: prev.grok)
        }.value

        async let agyTask = Task.detached(priority: .utility) {
            AgyConversationScanner.scan(previous: prev.agy)
        }.value

        let grok = await grokTask
        let agy = await agyTask
        let claude = await claudeTask
        let codex = await codexTask
        let overlapping = await overlapTask
        pendingCloud.reconcile(local: overlapping)
        if !cloudLoadFailed, !coveredIDs.isEmpty || SettingsStore.shared.claudeCloudUsageEnabled {
            let ready = pendingCloud
            do {
                try await Task.detached(priority: .utility) { try ready.save() }.value
                cloudLedger = ready
                updateCloudStatus()
            } catch {
                cloudStatus = "云端账本保存失败，保留上次统计 / Cloud save failed"
            }
        }

        if let rebuild {
            let fresh = UsageAggregator()
            fresh.ingest(claude.entries)
            fresh.ingest(codex.entries)
            fresh.ingest(grok.entries)
            fresh.ingest(agy.entries)
            localAggregator.load(from: Self.mergePreservingHistory(old: localAggregator.snapshot(), fresh: fresh.snapshot(), reprice: rebuild))
        } else {
            localAggregator.ingest(claude.entries)
            localAggregator.ingest(codex.entries)
            localAggregator.ingest(grok.entries)
            localAggregator.ingest(agy.entries)
        }

        applyPendingGrokBotTotals()
        // 持久化
        let buckets = localAggregator.snapshot()
        let newScanState = ScanState(
            pricingFingerprint: Pricing.fingerprint,
            claude: claude.newState,
            codex: codex.newState,
            grok: grok.newState,
            agy: agy.newState,
            claudeSeenMessageIds: claude.newSeenIds
        )
        let rollup = UsageRollupPayload(
            pricingFingerprint: Pricing.fingerprint,
            buckets: buckets,
            updatedAt: Date()
        )
        await Task.detached(priority: .utility) {
            do {
                try ScanCache.save(newScanState)
            } catch {
                print("[UsageScan 用量扫描] 扫描状态写盘失败 scan-state save failed: \(error)")
            }
            do {
                try UsageRollupCache.save(rollup)
            } catch {
                print("[UsageScan 用量扫描] 汇总写盘失败 usage-rollup save failed: \(error)")
            }
        }.value

        while !pendingGrokBotTotals.isEmpty {
            applyPendingGrokBotTotals()
            let late = UsageRollupPayload(pricingFingerprint: Pricing.fingerprint,
                                          buckets: localAggregator.snapshot(), updatedAt: Date())
            await Task.detached(priority: .utility) { try? UsageRollupCache.save(late) }.value
        }
        lastScanAt = Date()
        lastError = nil
        refreshCombinedTotals()
        publishTotals()
        // 开着自动上传时，把今天以前、还没传过的天传到 yybar 网站
        if let appState {
            appState.webAccount.usageDidUpdate(.init(buckets: aggregator.snapshot(), answers: appState.geminiAnswerLog.counts))
        }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("[UsageScan 用量扫描] claude files=\(claude.filesScanned) lines=\(claude.linesParsed) new=\(claude.entries.count); codex files=\(codex.filesScanned) lines=\(codex.linesParsed) new=\(codex.entries.count); grok files=\(grok.filesScanned) lines=\(grok.linesParsed) new=\(grok.entries.count); agy dbs=\(agy.filesScanned) calls=\(agy.linesParsed) new=\(agy.entries.count); elapsed=\(elapsed)")
    }

    /// 全量重建时合并新旧数据。CLI 或清理工具会删掉旧日志，那部分用量只剩在旧汇总里，重扫找不回来:
    /// 按「天 + 服务」比较 token 合计，旧的更多(说明那天有日志被删)就保留旧桶，否则用重扫结果。
    /// 保留的旧桶按需用新价格重算费用：按 token 合计平价计算(没有单次请求的长上下文加价);Grok 费用来自日志，不重算。
    private static func mergePreservingHistory(old: [UsageBucket], fresh: [UsageBucket], reprice: Reprice) -> [UsageBucket] {
        struct DayApp: Hashable {
            let day: Date
            let app: UsageApp
        }
        func tokens(_ buckets: [UsageBucket]) -> Int {
            buckets.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens }
        }
        // Gemini 的用量只来自过 agy 会话库，v7 起改记 Antigravity:旧桶先并过去，免得按天比较时被当成「日志已删的历史」留下。
        let old = old.map { bucket -> UsageBucket in
            var moved = bucket
            if moved.app == .gemini { moved.app = .agy }
            return moved
        }
        let oldByDay = Dictionary(grouping: old) { DayApp(day: $0.day, app: $0.app) }
        let freshByDay = Dictionary(grouping: fresh) { DayApp(day: $0.day, app: $0.app) }
        var result: [UsageBucket] = []
        for key in Set(oldByDay.keys).union(freshByDay.keys) {
            let kept = oldByDay[key] ?? []
            let rescanned = freshByDay[key] ?? []
            if tokens(kept) > tokens(rescanned) {
                result += kept.map { repriced($0, reprice) }
            } else {
                result += rescanned
            }
        }
        return result
    }

    private static func repriced(_ bucket: UsageBucket, _ reprice: Reprice) -> UsageBucket {
        // Grok 的费用来自日志。Grok Bot 只有合计 token 和账单里的美分，不能按输入价重算。
        guard bucket.app != .grok, bucket.app != .grokBot else { return bucket }
        switch reprice {
        case .none:
            return bucket
        case .keys(let keys):
            guard keys.contains(Pricing.normalize(model: bucket.model)) else { return bucket }
        case .all:
            break
        }
        var updated = bucket
        updated.costUSD = Pricing.cost(model: bucket.model, input: bucket.inputTokens, output: bucket.outputTokens,
                                       cacheRead: bucket.cacheReadTokens, cacheCreation: bucket.cacheCreationTokens,
                                       requestInputTokens: 0)
        return updated
    }

    /// Grok Bot 每天每模型的 token 合计。同一天再报同一个数只是覆盖，不会加第二次。
    /// 扫描进行中先入队，由扫描落盘前写入。若扫描用旧快照盖住了刚写入的合计，再写一次。
    func recordGrokBotTotals(_ rows: [APIUsageTotal]) async {
        guard !rows.isEmpty else { return }
        pendingGrokBotTotals = mergeTotals(pendingGrokBotTotals, rows)
        await drainGrokBotTotals()
    }

    private func drainGrokBotTotals() async {
        if isScanning || pendingGrokBotTotals.isEmpty { return }
        let rows = pendingGrokBotTotals
        pendingGrokBotTotals = []
        localAggregator.setDailyTotals(app: .grokBot, rows: rows)
        refreshCombinedTotals()
        let version = localAggregator.version
        await saveRollup()
        guard isScanning || localAggregator.version != version else { return }
        pendingGrokBotTotals = mergeTotals(pendingGrokBotTotals, rows)
        if !isScanning { await drainGrokBotTotals() }
    }

    private func saveRollup() async {
        let rollup = UsageRollupPayload(pricingFingerprint: Pricing.fingerprint,
                                        buckets: localAggregator.snapshot(), updatedAt: Date())
        await Task.detached(priority: .utility) {
            do { try UsageRollupCache.save(rollup) }
            catch { print("[UsageScan 用量扫描] Grok Bot 汇总写盘失败: \(error)") }
        }.value
    }

    private func applyPendingGrokBotTotals() {
        guard !pendingGrokBotTotals.isEmpty else { return }
        let rows = pendingGrokBotTotals
        pendingGrokBotTotals = []
        localAggregator.setDailyTotals(app: .grokBot, rows: rows)
    }

    private func mergeTotals(_ existing: [APIUsageTotal], _ rows: [APIUsageTotal]) -> [APIUsageTotal] {
        var merged: [String: APIUsageTotal] = [:]
        for row in existing + rows {
            merged["\(row.day.timeIntervalSince1970)\t\(row.model)"] = row
        }
        return Array(merged.values)
    }

    private func updateCloudStatus() {
        if let error = cloudLedger.lastError {
            cloudStatus = error
        } else if let time = cloudLedger.lastSuccess {
            cloudStatus = "已同步 / Synced " + time.formatted(date: .omitted, time: .standard)
        } else {
            cloudStatus = "尚未同步 / Not synced"
        }
    }

    private func refreshCombinedTotals() {
        aggregator.load(from: localAggregator.snapshot())
        aggregator.ingest(cloudLedger.entries)
    }

    private func publishTotals() {
        guard let appState else { return }
        let today = UsageDay.startOfDay(for: Date())
        let unpricedCodex = aggregator.snapshot().contains { $0.app == .codex && $0.day == today && !Pricing.hasPrice(model: $0.model) }
        appState.codexTodayCost = unpricedCodex ? nil : aggregator.todayCost(for: .codex)
        appState.claudeTodayCost = aggregator.todayCost(for: .claude)
        appState.grokTodayCost = aggregator.todayCost(for: .grok)
    }
}
