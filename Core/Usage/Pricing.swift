import Foundation
import CryptoKit

/// 模型价格（USD / 百万 token）。命中不到的模型 cost 计 0，token 仍记录。
nonisolated struct ModelPrice: Sendable, Equatable, Codable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheCreation: Decimal
}

/// 用户在「设置 · 通用 · 模型价格」里填写或覆盖的价格，键为归一化模型名(`Pricing.normalize`),
/// 优先于内置价格表。扫描在后台线程读，设置页在主线程写，所以加锁;持久化在 UserDefaults。
nonisolated final class CustomModelPrices: @unchecked Sendable {
    static let shared = CustomModelPrices()
    private static let defaultsKey = "yybar.settings.customModelPrices"

    private let lock = NSLock()
    private var prices: [String: ModelPrice]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: ModelPrice].self, from: data) {
            prices = decoded
        } else {
            prices = [:]
        }
    }

    var all: [String: ModelPrice] {
        lock.withLock { prices }
    }

    func price(forKey key: String) -> ModelPrice? {
        lock.withLock { prices[key] }
    }

    /// 设置或清除(nil)某个模型的自定义价格。
    func set(_ price: ModelPrice?, forKey key: String) {
        let snapshot: [String: ModelPrice] = lock.withLock {
            prices[key] = price
            return prices
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum Pricing {
    /// Grok Bot 只返回合计 token，不能按 API 单价推导模型费用。
    /// 旧汇总把接口未返回的金额存为 0；这类行应显示未知，不能因模型恰有公开价格而显示 $0。
    nonisolated static func hasDisplayableCost(app: UsageApp, model: String, cost: Decimal) -> Bool {
        if app == .grokBot { return cost > 0 }
        return app == .grok || cost > 0 || hasPrice(model: model)
    }

    /// 价格表与 cc-switch `seed_model_pricing` / CodexBar `CostUsagePricing` 对齐（2026 上半年价位）。
    /// 命中不到时返回 nil。键为归一化后的模型名（剥 `openai/` 前缀和末尾 `-YYYYMMDD` / `-YYYY-MM-DD` 日期段）。
    nonisolated static let table: [String: ModelPrice] = [
        // —— Claude（input 已不含 cache_read）。cacheCreation 用 5 分钟缓存写入价。
        // 2026-10-08 官方 prompt caching 价目：platform.claude.com/docs/en/build-with-claude/prompt-caching
        // Sonnet 5.5 缓存读取按模型页为输入价的 5%（$0.10），Fable 5.1 / 5.2 为 2.5%（$0.25 / $0.20）。
        // Fable 5.2（2026-11 官方价）：$8 / $40，缓存读取 $0.20，5 分钟缓存写入按输入价 1.25 倍。
        "claude-fable-5-2":  .init(input: 8,   output: 40,  cacheRead: 0.20, cacheCreation: 10),
        "claude-fable-5-1":  .init(input: 10,  output: 50,  cacheRead: 0.25, cacheCreation: 12.50),
        "claude-fable-5":    .init(input: 10,  output: 50,  cacheRead: 1.00, cacheCreation: 12.50),
        "claude-opus-5-5":   .init(input: 4,   output: 20,  cacheRead: 0.20, cacheCreation: 5),
        "claude-opus-5":     .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-8":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-7":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-6":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-5":   .init(input: 5,   output: 25,  cacheRead: 0.50, cacheCreation: 6.25),
        "claude-opus-4-1":   .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        "claude-opus-4":     .init(input: 15,  output: 75,  cacheRead: 1.50, cacheCreation: 18.75),
        "claude-sonnet-5-5": .init(input: 2,   output: 10,  cacheRead: 0.10, cacheCreation: 2.50),
        "claude-sonnet-5":   .init(input: 2,   output: 10,  cacheRead: 0.20, cacheCreation: 2.50),
        "claude-sonnet-4-7": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-6": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4-5": .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-sonnet-4":   .init(input: 3,   output: 15,  cacheRead: 0.30, cacheCreation: 3.75),
        "claude-haiku-4-5":  .init(input: 1,   output: 5,   cacheRead: 0.10, cacheCreation: 1.25),
        "claude-haiku-4":    .init(input: 0.8, output: 4,   cacheRead: 0.08, cacheCreation: 1.0),

        // —— Codex / GPT-5 系（input 含 cache_read，调用侧已扣 billable）。
        // 注：实际 5.5 在 >272k context 有阶梯价；本表采用 cc-switch 一致的「单档」价。
        "gpt-5":             .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5-mini":        .init(input: 0.25, output: 2,   cacheRead: 0.025, cacheCreation: 0),
        "gpt-5-nano":        .init(input: 0.05, output: 0.40, cacheRead: 0.005, cacheCreation: 0),
        "gpt-5-codex":       .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.1-codex":     .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.2":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.3":           .init(input: 1.25, output: 10,  cacheRead: 0.125, cacheCreation: 0),
        "gpt-5.4":           .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.4-codex":     .init(input: 2.50, output: 15,  cacheRead: 0.25,  cacheCreation: 0),
        "gpt-5.5":           .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-codex":     .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        "gpt-5.5-pro":       .init(input: 5,    output: 30,  cacheRead: 0.50,  cacheCreation: 0),
        // Official model pages, checked 2026-09-08. USD per million tokens.
        "gpt-5.6":           .init(input: 4,    output: 20,  cacheRead: 0.40, cacheCreation: 5),
        "gpt-5.6-sol":       .init(input: 4,    output: 20,  cacheRead: 0.40, cacheCreation: 5),
        "gpt-5.6-terra":     .init(input: 2,    output: 12,  cacheRead: 0.20, cacheCreation: 2.5),
        "gpt-5.6-luna":      .init(input: 0.2,  output: 1.2, cacheRead: 0.02, cacheCreation: 0.25),
        // OpenAI standard tier, platform.openai.com/docs/pricing, checked 2026-10-08.
        // >272K input：输入与缓存 2 倍、输出 1.5 倍，由 supportsLongContext 处理。
        "gpt-6-astra":       .init(input: 10,   output: 50,  cacheRead: 1,    cacheCreation: 12.5),
        "gpt-6.1-sol":       .init(input: 2,    output: 10,  cacheRead: 0.10, cacheCreation: 2.5),
        "gpt-6-sol":         .init(input: 2,    output: 10,  cacheRead: 0.20, cacheCreation: 2.5),
        "gpt-6-luna":        .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheCreation: 0.125),
        // OpenAI standard tier, developers.openai.com/api/docs/pricing, checked 2026-11-19.
        // cacheCreation 用 30 分钟缓存写入价；>272K input 同样走长上下文倍率。
        "gpt-6.2-astra":     .init(input: 8,    output: 40,  cacheRead: 0.40, cacheCreation: 10),
        "gpt-6.2-sol":       .init(input: 2,    output: 10,  cacheRead: 0.10, cacheCreation: 2.5),
        "gpt-6.1-terra":     .init(input: 1,    output: 5,   cacheRead: 0.05, cacheCreation: 1.25),
        // —— Gemini(agy 会话库;Gemini Developer API 标准档，ai.google.dev/gemini-api/docs/pricing,2026-10-19 查)。
        // agy 库里没有缓存 token,cacheRead 只是照抄官方缓存价;cacheCreation 无此计费项记 0。
        // 3.8 / 3.6 Flash 为 2026 年内价格(2027-01-01 起翻倍,届时需更新)。
        // Gemini 4 Neon / Hydrogen / Carbon:2026-11-19 查 Google 发布公告(blog.google)。Gemini 4 只有隐式缓存，缓存读取为输入价的 5%。
        // Hydrogen 全 1M 上下文同价。Carbon、Argon 为推广价，2026-12-01 起 $4 / $20、缓存 $0.20,届时需更新。
        "gemini-4-neon":          .init(input: 3,    output: 15,   cacheRead: 0.15,  cacheCreation: 0),
        "gemini-4-hydrogen":      .init(input: 1.50, output: 7.50, cacheRead: 0.075, cacheCreation: 0),
        "gemini-4-carbon":        .init(input: 2,    output: 10,   cacheRead: 0.10,  cacheCreation: 0),
        "gemini-4-argon":         .init(input: 2,    output: 10,   cacheRead: 0.10,  cacheCreation: 0),
        "gemini-3.8-flash":       .init(input: 0.75, output: 3.75, cacheRead: 0.075, cacheCreation: 0),
        "gemini-3.6-flash":       .init(input: 0.75, output: 3.75, cacheRead: 0.075, cacheCreation: 0),
        "gemini-3.5-flash-lite":  .init(input: 0.30, output: 2.50, cacheRead: 0.03,  cacheCreation: 0),
        "gemini-3.1-pro-preview": .init(input: 2,    output: 12,   cacheRead: 0.20,  cacheCreation: 0),
        "gemini-3.1-pro":         .init(input: 2,    output: 12,   cacheRead: 0.20,  cacheCreation: 0),
        "gemini-3.1-flash-lite":  .init(input: 0.25, output: 1.50, cacheRead: 0.025, cacheCreation: 0),
        "gemini-3-flash-preview": .init(input: 0.50, output: 3,    cacheRead: 0.05,  cacheCreation: 0),
        "gemini-3-flash":         .init(input: 0.50, output: 3,    cacheRead: 0.05,  cacheCreation: 0),
        "gemini-2.5-pro":         .init(input: 1.25, output: 10,   cacheRead: 0.125, cacheCreation: 0),
        "gemini-2.5-flash":       .init(input: 0.30, output: 2.50, cacheRead: 0.03,  cacheCreation: 0),
        // GPT-OSS(agy 的 Claude + GPT 池):Google / OpenAI 都没有公开按 token 的官方价，不入表 → 费用 0,token 照记。
        "codex-mini-latest": .init(input: 1.50, output: 6,   cacheRead: 0.375, cacheCreation: 0)
        // codex-auto-review 内部 review，官方未公开计费；不入表 → cost=0，token 仍记录
    ]

    /// 归一化模型名：去 `openai/` 前缀；剥末尾 `-YYYY-MM-DD` 或 `-YYYYMMDD` 日期后缀；
    /// 兼容 Vertex AI 的 `@日期` 写法。
    nonisolated static func normalize(model: String) -> String {
        var m = model
        if m.hasPrefix("openai/") {
            m.removeFirst("openai/".count)
        }
        // Vertex 风格：`name@YYYYMMDD`
        if let at = m.firstIndex(of: "@") {
            m = String(m[m.startIndex..<at])
        }
        // Anthropic 风格：`-YYYYMMDD` 或 `-YYYY-MM-DD`
        let patterns = [#"-\d{4}-\d{2}-\d{2}$"#, #"-\d{8}$"#]
        for pat in patterns {
            if let range = m.range(of: pat, options: .regularExpression) {
                m.removeSubrange(range)
                break
            }
        }
        return m.lowercased()
    }

    private static let perMillion: Decimal = 1_000_000

    /// 计算单次调用花费。
    /// - Parameters:
    ///   - app: 用于隐含的 cache_read 语义；Codex 含、Claude 不含（调用方传 input 时已自处理）。
    ///   - input/output/cacheRead/cacheCreation: 直接乘价。
    nonisolated static func cost(
        model: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheCreation: Int,
        requestInputTokens: Int? = nil
    ) -> Decimal {
        let key = normalize(model: model)
        guard let p = price(forKey: key) else { return 0 }
        let i = Decimal(input)     * p.input        / perMillion
        let o = Decimal(output)    * p.output       / perMillion
        let cr = Decimal(cacheRead) * p.cacheRead   / perMillion
        let cc = Decimal(cacheCreation) * p.cacheCreation / perMillion
        let supportsLongContext = [
            "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna",
            "gpt-6.2-astra", "gpt-6.2-sol", "gpt-6.1-terra"
        ].contains(key)
        let longContext = supportsLongContext && (requestInputTokens ?? (input + cacheRead + cacheCreation)) > 272_000
        return longContext ? (i + cr + cc) * 2 + o * Decimal(string: "1.5")! : i + o + cr + cc
    }

    nonisolated static func hasPrice(model: String) -> Bool {
        price(forKey: normalize(model: model)) != nil
    }

    /// 实际使用的价格：用户自定义优先，其次内置表。
    nonisolated static func price(forKey key: String) -> ModelPrice? {
        CustomModelPrices.shared.price(forKey: key) ?? table[key]
    }

    /// 价格表内容指纹（SHA-256，确定性，跨进程稳定）。内置表 + 用户自定义价格一起算。
    /// 扫描状态 / 汇总缓存持久化它；表一变（新增模型、改价、修正数值、用户改了自定义价格）→ 指纹变 →
    /// 缓存自动失效并全量重扫重算历史桶，无需手动 bump 版本号，避免「改了价却忘了重算」。
    nonisolated static var fingerprint: String {
        func describe(_ prices: [String: ModelPrice]) -> String {
            prices.keys.sorted().map { key -> String in
                let p = prices[key]!
                return "\(key):\(p.input)/\(p.output)/\(p.cacheRead)/\(p.cacheCreation)"
            }.joined(separator: ";")
        }
        let custom = CustomModelPrices.shared.all
        let body = describe(table) + (custom.isEmpty ? "" : "|custom|" + describe(custom))
        let digest = SHA256.hash(data: Data(body.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
