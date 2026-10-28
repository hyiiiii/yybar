import Foundation

enum QuotaApp: String, Sendable, Codable {
    case codex
    case claude
    case grok
    case grokBot
    case gemini
    case agy
}

enum QuotaSnapshotSource: String, Sendable, Codable {
    case api
    case cache
    case cliFallback
    /// `agy -p /usage`(Gemini / agy 额度)。
    case agyCLI

    var displayName: String {
        switch self {
        case .api: return "API"
        case .cache: return "缓存"
        case .cliFallback: return "Claude CLI"
        case .agyCLI: return "agy CLI"
        }
    }
}

enum QuotaRefreshReason: Sendable {
    case periodic
    case userInitiated
}

struct QuotaRefreshState: Sendable, Equatable {
    var lastSuccessAt: Date?
    var lastAttemptAt: Date?
    var backoffUntil: Date?
    var lastError: String?
    var inFlight: Bool = false
    var source: QuotaSnapshotSource?
}

struct QuotaWindow: Sendable, Equatable, Codable {
    /// 0~100，已用百分比
    var usedPercent: Double
    /// 窗口重置时间
    var resetsAt: Date?
    /// 窗口长度（秒），可空
    var windowSeconds: Int?

    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

struct QuotaSnapshot: Sendable, Equatable, Codable {
    var app: QuotaApp
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var weeklyOpus: QuotaWindow?      // 仅 Claude
    var weeklySonnet: QuotaWindow?    // 仅 Claude
    var planType: String?
    var fetchedAt: Date
    /// Server-defined primary period for services with billing cycles other than 5h.
    var primary: QuotaWindow? = nil
    var primaryLabel: String? = nil
    /// 一个格子包含多个额度池时(Antigravity = agy 的 Gemini 池 + Claude·GPT 池)逐池列出;
    /// 此时 fiveHour / weekly 是各池里剩余最少的那个，供菜单栏 / 悬浮窗等只有一个数字的地方用。
    var pools: [QuotaPool]? = nil
}

struct QuotaPool: Sendable, Equatable, Codable {
    /// 行首短标签，如 "Gemini"、"Claude·GPT"。
    var label: String
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?

    /// Antigravity 的展示快照:agy 两个池子合在一起(按工具归属，2026-10-20)。两个池都没有时返回 nil。
    static func antigravity(gemini: QuotaSnapshot?, thirdParty: QuotaSnapshot?) -> QuotaSnapshot? {
        guard gemini != nil || thirdParty != nil else { return nil }
        let pools = [
            QuotaPool(label: "Gemini", fiveHour: gemini?.fiveHour, weekly: gemini?.weekly),
            QuotaPool(label: "Claude·GPT", fiveHour: thirdParty?.fiveHour, weekly: thirdParty?.weekly)
        ]
        func tightest(_ windows: [QuotaWindow?]) -> QuotaWindow? {
            windows.compactMap { $0 }.max { $0.usedPercent < $1.usedPercent }
        }
        let fetched = [gemini?.fetchedAt, thirdParty?.fetchedAt].compactMap { $0 }.max() ?? Date()
        return QuotaSnapshot(app: .agy, fiveHour: tightest(pools.map(\.fiveHour)), weekly: tightest(pools.map(\.weekly)),
                             weeklyOpus: nil, weeklySonnet: nil, planType: nil, fetchedAt: fetched, pools: pools)
    }
}

enum QuotaError: Error, CustomStringConvertible {
    case missingToken
    /// Google 网页验证 / 异常流量拦截，与登录凭据是否有效无关。
    case webVerificationRequired
    case http(Int, String)
    case transport(String)
    case decode(String)
    case tokenRefreshFailed(String)
    /// OAuth 服务端拒绝了 refresh_token(典型为 `invalid_grant`),
    /// 通常是 Claude Code CLI / Desktop / cc-switch 等其他客户端抢先刷新使旧 token 失效,
    /// 或用户主动退登 / 改密码。此时只能重新登录。
    case tokenRevoked

    var description: String {
        switch self {
        case .missingToken: return "missing access token"
        case .webVerificationRequired: return "Google 要求网页验证，请在 Chrome 打开 Gemini 检查后重试"
        case .http(let code, let msg): return "http \(code): \(msg)"
        case .transport(let msg): return "transport: \(msg)"
        case .decode(let msg): return "decode: \(msg)"
        case .tokenRefreshFailed(let msg): return "token refresh failed: \(msg)"
        case .tokenRevoked:
            return "Claude 登录已失效,请在终端运行 claude 重新登录后再回来刷新"
        }
    }

    var httpStatusCode: Int? {
        if case .http(let code, _) = self { return code }
        return nil
    }

    var isRateLimited: Bool {
        httpStatusCode == 429
    }

    var requiresBrowserVerification: Bool {
        if case .webVerificationRequired = self { return true }
        return false
    }

    var isAuthFailure: Bool {
        httpStatusCode == 401 || httpStatusCode == 403
    }

    /// 借用的网页登录(Gemini App 用的 Chrome Cookie)被 Google 拒绝：跳去登录页、401 / 403,或要求网页验证。
    var rejectsWebLogin: Bool {
        if case .missingToken = self { return true }
        return isAuthFailure || requiresBrowserVerification
    }

    /// 是否为"需要用户重新登录"级别的失败。UI 可据此降级提示文案。
    var isAuthRevoked: Bool {
        if case .tokenRevoked = self { return true }
        return false
    }
}
