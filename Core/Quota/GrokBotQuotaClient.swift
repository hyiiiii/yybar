import Foundation

// MARK: - Grok Bot(额度未接通)
//
// Grok Bot 桌面 App(/Applications/Grok Bot.app,bundle id com.anysphere.sand,Electron)用 Cursor 账号登录，
// 「设置 → 用量与账单」里的每周额度来自 Cursor 后端(App 包内 app.asar 0.71.2 的代码):
//   POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus  (Connect 协议，请求体 {},Bearer token)
//   响应 GetSandUsageStatusResponse:usagePercent(已用 %)、nextResetTimestampUtc(下次重置)、currentPeriodStart、
//   usesPooledEnterpriseAllowance、grokPlanLabel / cursorPlanName 等。
//
// 还没接通的一步是 token:App 把 Cursor access token 用 Electron safeStorage 加密后存在
// ~/Library/Application Support/Grok Bot/sand-secrets.json,解密要读钥匙串「Grok Bot Safe Storage」。
// 这一步没有实现(待确认是否允许 yybar 解密其他 App 的登录存储),所以目前只显示「未接通」。
// 接通时只需提供 token,`fetch(accessToken:)` / `parse(data:)` 已按 App 的接口写好。

enum GrokBotQuotaClient {
    nonisolated static let appPath = "/Applications/Grok Bot.app"
    nonisolated static let endpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    /// 本机装了 Grok Bot(默认启用的依据)。
    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
    }

    /// 额度是否已接通(见文件头)。UI 据此显示「未接通」。
    nonisolated static let isConnected = false

    nonisolated static func fetch(accessToken: String) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, "Grok Bot usage request failed"))
            }
            return .success(try parse(data: data))
        } catch let error as QuotaError { return .failure(error) }
        catch { return .failure(.transport(error.localizedDescription)) }
    }

    /// 解析 GetSandUsageStatusResponse(Connect JSON:字段 lowerCamelCase,Timestamp 为 RFC 3339 字符串)。
    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("Grok Bot usage response is not JSON")
        }
        // 企业共享额度没有个人百分比,App 自己也不显示周额度条。
        if root["usesPooledEnterpriseAllowance"] as? Bool == true {
            throw QuotaError.decode("Grok Bot uses a pooled enterprise allowance")
        }
        // proto3 JSON 省略零值：没有 usagePercent 视为 0(新周期)。
        let used: Double
        if let raw = root["usagePercent"] {
            guard let value = GrokQuotaClient.double(raw), value.isFinite else {
                throw QuotaError.decode("Grok Bot usage percent is invalid")
            }
            used = max(0, value)
        } else {
            used = 0
        }
        let reset = GrokQuotaClient.parseDate(root["nextResetTimestampUtc"])
        let start = GrokQuotaClient.parseDate(root["currentPeriodStart"])
        var seconds = 7 * 86400
        if let reset, let start, reset > start { seconds = Int(reset.timeIntervalSince(start)) }
        let window = QuotaWindow(usedPercent: min(100, used), resetsAt: reset, windowSeconds: seconds)
        let plan = [root["grokPlanLabel"], root["cursorPlanName"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return QuotaSnapshot(app: .grokBot, fiveHour: nil, weekly: window, weeklyOpus: nil, weeklySonnet: nil,
                             planType: plan, fetchedAt: now, primary: window, primaryLabel: "WEEK · 本周")
    }
}
