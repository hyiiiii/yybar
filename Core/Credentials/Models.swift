import Foundation

enum CredentialSource: String, Sendable {
    case file
    case keychain
}

struct CodexAccount: Sendable, Equatable {
    var email: String?
    var planType: String?
    var accountId: String?
    var chatgptUserId: String?
    var lastRefresh: Date?
    var expiredGuess: Bool
    var rawClaimKeys: [String]
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    /// id_token 里的 `chatgpt_subscription_active_until`:当前付费周期结束日(= 下次续费日)。免费账号没有。
    var subscriptionActiveUntil: Date? = nil
}

struct ClaudeAccount: Sendable, Equatable {
    var source: CredentialSource
    var email: String?
    var subscriptionType: String?
    var expiresAt: Date?
    var expiredGuess: Bool
    /// 仅内存使用，不打印 / 不持久化到 UserDefaults
    var accessToken: String?
    var refreshToken: String?
    /// `~/.claude.json` oauthAccount 的 `subscriptionCreatedAt`(订阅开始日),用来推算续费日。
    var subscriptionCreatedAt: Date? = nil
    /// 凭据里的 `rateLimitTier`(如 default_claude_max_20x):Max 分 5x / 20x 两档，只有这里区分得出来。
    var rateLimitTier: String? = nil
}

/// 下次续费日。
/// - Codex:id_token 的 `chatgpt_subscription_active_until` 就是当前付费周期结束日，准确;
///   日期已过(令牌很久没刷新)时按月往后推，标为推算。
/// - Claude:接口只给订阅开始日，按每月同一天续费推算(年付或中途改过套餐时可能不准)。
/// - Grok:接口没有订阅续费信息，不显示。
nonisolated struct SubscriptionRenewal: Sendable, Equatable {
    var date: Date
    var estimated: Bool
    /// 推算依据：Codex 为周期结束日，Claude 为订阅开始日。
    var basis: Date

    static func codex(activeUntil: Date?, now: Date = Date()) -> SubscriptionRenewal? {
        guard let activeUntil else { return nil }
        if activeUntil > now { return SubscriptionRenewal(date: activeUntil, estimated: false, basis: activeUntil) }
        return SubscriptionRenewal(date: nextMonthly(anchor: activeUntil, after: now), estimated: true, basis: activeUntil)
    }

    static func monthly(from start: Date?, now: Date = Date()) -> SubscriptionRenewal? {
        guard let start else { return nil }
        return SubscriptionRenewal(date: nextMonthly(anchor: start, after: now), estimated: true, basis: start)
    }

    /// anchor 之后每月同一天里，第一个晚于 now 的日子(31 号等月末日由日历自动顺延到当月最后一天)。
    static func nextMonthly(anchor: Date, after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for months in 1...1200 {
            if let date = calendar.date(byAdding: .month, value: months, to: anchor), date > now { return date }
        }
        return anchor
    }

    /// ISO 8601(带或不带小数秒、Z 或 +00:00)。
    static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

enum CredentialError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case invalidJSON(String)
    case keychainUnavailable(String)
    case decodeFailed(String)

    var description: String {
        switch self {
        case .fileNotFound(let p): return "file not found: \(p)"
        case .invalidJSON(let p): return "invalid JSON at: \(p)"
        case .keychainUnavailable(let m): return "keychain unavailable: \(m)"
        case .decodeFailed(let m): return "decode failed: \(m)"
        }
    }
}
