import Foundation
import Observation

/// 按 (day, app, model) 聚合的内存表。
///
/// 标记为 `@Observable`：`snapshot()` / `todayCost(...)` / `totals(...)` 在 SwiftUI
/// body 内访问 `buckets` 时会自动登记依赖，扫描完成后 `ingest` 写回 `buckets`
/// 触发的变更会驱动所有读这个聚合器的视图自动刷新。视图侧无需任何额外订阅。
@MainActor
@Observable
final class UsageAggregator {
    private var buckets: [BucketKey: UsageBucket] = [:]
    /// 每次数据变化 +1。统计页据此判断是否需要重建按天汇总的索引。
    private(set) var version = 0

    struct BucketKey: Hashable {
        let day: Date
        let app: UsageApp
        let model: String
    }

    func load(from snapshot: [UsageBucket]) {
        version += 1
        buckets.removeAll(keepingCapacity: true)
        for b in snapshot {
            let key = BucketKey(day: b.day, app: b.app, model: b.model)
            buckets[key] = b
        }
    }

    /// 用接口返回的当天合计覆盖这一格。再刷到同一数字不会累加。
    func setDailyTotals(app: UsageApp, rows: [APIUsageTotal]) {
        guard !rows.isEmpty else { return }
        version += 1
        for row in rows {
            let key = BucketKey(day: row.day, app: app, model: row.model)
            buckets[key] = UsageBucket(app: app, model: row.model, day: row.day,
                                       inputTokens: row.inputTokens, outputTokens: 0,
                                       cacheReadTokens: 0, cacheCreationTokens: 0, costUSD: row.costUSD)
        }
    }

    func ingest(_ entries: [UsageEntry]) {
        if !entries.isEmpty { version += 1 }
        for e in entries {
            let key = BucketKey(day: e.day, app: e.app, model: e.model)
            if var b = buckets[key] {
                b.inputTokens += e.inputTokens
                b.outputTokens += e.outputTokens
                b.cacheReadTokens += e.cacheReadTokens
                b.cacheCreationTokens += e.cacheCreationTokens
                b.costUSD += e.costUSD
                buckets[key] = b
            } else {
                buckets[key] = UsageBucket(
                    app: e.app,
                    model: e.model,
                    day: e.day,
                    inputTokens: e.inputTokens,
                    outputTokens: e.outputTokens,
                    cacheReadTokens: e.cacheReadTokens,
                    cacheCreationTokens: e.cacheCreationTokens,
                    costUSD: e.costUSD
                )
            }
        }
    }

    func snapshot() -> [UsageBucket] {
        Array(buckets.values)
    }

    func todayCost(for app: UsageApp, now: Date = Date()) -> Decimal {
        let today = UsageDay.startOfDay(for: now)
        var sum: Decimal = 0
        for b in buckets.values where b.app == app && b.day == today {
            sum += b.costUSD
        }
        return sum
    }

    /// 给 M6 复用：按时间范围 / 应用聚合。
    func totals(app: UsageApp, from: Date, to: Date) -> UsageTotals {
        var totals = UsageTotals.zero
        for b in buckets.values where b.app == app && b.day >= from && b.day < to {
            totals.add(b)
        }
        return totals
    }
}
