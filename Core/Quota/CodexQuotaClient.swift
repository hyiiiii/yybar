import Foundation

enum CodexQuotaClient {
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    nonisolated static func fetch(
        accessToken: String,
        accountId: String?
    ) async -> Result<QuotaSnapshot, QuotaError> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { return .failure(.transport("\(error)")) }
        guard let http = resp as? HTTPURLResponse else {
            return .failure(.transport("non-http"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            return .failure(.http(http.statusCode, msg))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.decode("not json object"))
        }
        return .success(parse(root: root))
    }

    nonisolated private static func parse(root: [String: Any]) -> QuotaSnapshot {
        let planType = root["plan_type"] as? String
        let rate = root["rate_limit"] as? [String: Any] ?? [:]
        let (fiveHour, long) = slot(primary: parseWindow(rate["primary_window"] as? [String: Any]),
                                    secondary: parseWindow(rate["secondary_window"] as? [String: Any]))
        return QuotaSnapshot(
            app: .codex,
            fiveHour: fiveHour,
            weekly: long,
            weeklyOpus: nil,
            weeklySonnet: nil,
            planType: planType,
            fetchedAt: Date()
        )
    }

    /// 按窗口长度放格子，不按接口里的先后：不到一天的是 5H,一天以上的是长窗口(每周，或免费账号的每月，标签按长度写 WK / MO)。
    /// ChatGPT Pro 现在只有周额度、免费账号只有月额度，它们排在 primary_window,以前都被当成了 5H。没给长度时照先后。
    nonisolated static func slot(primary: QuotaWindow?, secondary: QuotaWindow?) -> (fiveHour: QuotaWindow?, long: QuotaWindow?) {
        var fiveHour: QuotaWindow?
        var long: QuotaWindow?
        for (index, window) in [primary, secondary].enumerated() {
            guard let window else { continue }
            let isLong = window.windowSeconds.map { $0 >= 86_400 } ?? (index == 1)
            if isLong {
                // 两个都是长窗口时(周 + 月),格子里放短的那个
                if let current = long, (current.windowSeconds ?? 0) <= (window.windowSeconds ?? 0) { continue }
                long = window
            } else if fiveHour == nil {
                fiveHour = window
            }
        }
        return (fiveHour, long)
    }

    nonisolated private static func parseWindow(_ dict: [String: Any]?) -> QuotaWindow? {
        guard let dict else { return nil }
        let used: Double = {
            if let d = dict["used_percent"] as? Double { return d }
            if let i = dict["used_percent"] as? Int { return Double(i) }
            return 0
        }()
        var resetAt: Date?
        if let n = dict["reset_at"] as? Double {
            resetAt = Date(timeIntervalSince1970: n)
        } else if let i = dict["reset_at"] as? Int {
            resetAt = Date(timeIntervalSince1970: Double(i))
        } else if let secs = dict["reset_after_seconds"] as? Double {
            resetAt = Date(timeIntervalSinceNow: secs)
        } else if let secs = dict["reset_after_seconds"] as? Int {
            resetAt = Date(timeIntervalSinceNow: Double(secs))
        }
        let window: Int? = (dict["limit_window_seconds"] as? Int)
            ?? (dict["limit_window_seconds"] as? Double).map { Int($0) }
        return QuotaWindow(usedPercent: used, resetsAt: resetAt, windowSeconds: window)
    }
}
