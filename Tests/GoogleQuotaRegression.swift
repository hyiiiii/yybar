import Foundation

// 此独立回归不读真实登录、不联网、不运行 agy;只验证 Gemini / agy 与 Grok Bot 的响应解析。

@main
struct GoogleQuotaRegression {
    static func main() throws {
        // agy 1.3.5 `agy -p /usage --output-format json` 的真实输出结构(数值改过)。
        let usage = """
        {"conversation_id":"","status":"SUCCESS","response":"…","command":{"name":"usage","data":{"groups":[
          {"name":"Gemini Models","description":"Models within this group: Gemini Flash, Gemini Pro","buckets":[
            {"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":0.88,"reset_time":"2026-10-26T13:32:25Z"},
            {"id":"gemini-5h","name":"Five Hour Limit Remaining","window":"5h","remaining_fraction":0.72,"reset_time":"2026-10-19T18:32:25Z"}]},
          {"name":"Claude and GPT models","description":"Models within this group: Claude Opus, Claude Sonnet, GPT-OSS","buckets":[
            {"id":"3p-weekly","name":"Weekly Limit Remaining","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-26T13:32:25Z"},
            {"id":"3p-5h","name":"Five Hour Limit Remaining","window":"5h","reset_time":"2026-10-19T18:32:25Z"}]}]}}}
        """
        let result = try GoogleQuotaClient.parse(data: Data(usage.utf8))
        let gemini = result.gemini!, agy = result.agy!
        precondition(gemini.app == .gemini && agy.app == .agy)
        precondition(abs(gemini.fiveHour!.remainingPercent - 72) < 0.001)
        precondition(abs(gemini.weekly!.remainingPercent - 88) < 0.001)
        precondition(gemini.fiveHour!.resetsAt == ISO8601DateFormatter().date(from: "2026-10-19T18:32:25Z"))
        precondition(agy.weekly!.remainingPercent == 100)
        // 没有 remaining_fraction 的档位视为未知，不当成用完。
        precondition(agy.fiveHour == nil)

        // 失败状态:限流按 429 处理(走退避),其他为解码错误。
        do {
            _ = try GoogleQuotaClient.parse(data: Data(#"{"status":"ERROR","error":"429 RESOURCE_EXHAUSTED"}"#.utf8))
            preconditionFailure("expected rate limit")
        } catch let error as QuotaError { precondition(error.isRateLimited) }
        do {
            _ = try GoogleQuotaClient.parse(data: Data("not json".utf8))
            preconditionFailure("expected decode error")
        } catch let error as QuotaError { if case .decode = error {} else { preconditionFailure("\(error)") } }

        // Grok Bot:GetSandUsageStatusResponse(Connect JSON)。
        let sand = """
        {"currentPeriodStart":"2026-10-17T00:00:00Z","nextResetTimestampUtc":"2026-10-24T00:00:00Z",
         "usagePercent":39.5,"hasNonZeroIncludedLimit":true,"grokPlanLabel":"SuperGrok"}
        """
        let bot = try GrokBotQuotaClient.parse(data: Data(sand.utf8))
        precondition(bot.app == .grokBot && abs(bot.primary!.remainingPercent - 60.5) < 0.001)
        precondition(bot.primary!.windowSeconds == 7 * 86400 && bot.planType == "SuperGrok")
        // 新周期省略 usagePercent → 0% 已用。
        let fresh = try GrokBotQuotaClient.parse(data: Data("{}".utf8))
        precondition(fresh.primary!.usedPercent == 0)
        do {
            _ = try GrokBotQuotaClient.parse(data: Data(#"{"usesPooledEnterpriseAllowance":true}"#.utf8))
            preconditionFailure("expected pooled allowance error")
        } catch is QuotaError {}
        print("GoogleQuotaRegression OK")
    }
}
