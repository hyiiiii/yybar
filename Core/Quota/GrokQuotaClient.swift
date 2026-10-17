import Foundation
import CoreFoundation
import Darwin

struct GrokAccount: Sendable {
    var accessToken: String
    var identity: String
    var email: String?
    var expiresAt: Date?

    /// `home` 为 nil 时读本机 ~/.grok;额外账号传入各自独立的 GROK_HOME。
    nonisolated static func load(home: URL? = nil) throws -> GrokAccount {
        let base = home ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        let url = base.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            throw QuotaError.missingToken
        }
        // First-party accounts only. Never send a custom provider's credential to xAI.
        let candidates = records.filter {
            $0.key.hasPrefix("https://auth.x.ai::") || $0.key == "https://accounts.x.ai/sign-in"
        }.sorted {
            let a = GrokQuotaClient.parseDate($0.value["expires_at"]) ?? .distantPast
            let b = GrokQuotaClient.parseDate($1.value["expires_at"]) ?? .distantPast
            return a > b
        }
        guard let record = candidates.first?.value,
              let key = record["key"] as? String, !key.isEmpty,
              let id = record["user_id"] as? String else { throw QuotaError.missingToken }
        return .init(accessToken: key,
                     identity: id + ":" + (record["team_id"] as? String ?? ""),
                     email: record["email"] as? String,
                     expiresAt: GrokQuotaClient.parseDate(record["expires_at"]))
    }
}

enum GrokQuotaClient {
    /// Same read-only billing route as Grok CLI's /usage command.
    nonisolated static let endpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!

    nonisolated static func fetch(account: GrokAccount) async -> Result<QuotaSnapshot, QuotaError> {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure(.transport("non-http")) }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode, "Grok billing request failed"))
            }
            return try .success(parse(data: data))
        } catch let error as QuotaError { return .failure(error) }
        catch { return .failure(.transport(error.localizedDescription)) }
    }

    /// Same settings route the Grok CLI reads at startup; read-only.
    nonisolated static let settingsEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

    /// 订阅等级展示名(如 "SuperGrok"),取自 `subscription_tier_display`。拿不到时返回 nil,不影响额度。
    nonisolated static func fetchPlan(account: GrokAccount) async -> String? {
        var request = URLRequest(url: settingsEndpoint, timeoutInterval: 20)
        request.setValue("Bearer \(account.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plan = root["subscription_tier_display"] as? String else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func parse(data: Data, now: Date = Date()) throws -> QuotaSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let end = parseDate(period["end"]),
              let start = parseDate(period["start"]), end > start else {
            throw QuotaError.decode("Grok billing response has no valid usage period")
        }
        // The billing API omits zero-valued scalar fields (including usage) at a
        // fresh period. Only an absent field defaults to zero; null, booleans,
        // malformed values and negative percentages remain decoding errors.
        let used: Double
        if let raw = config["creditUsagePercent"] {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = double(raw), value.isFinite, value >= 0 else {
                throw QuotaError.decode("Grok billing response has an invalid usage percentage")
            }
            used = value
        } else {
            used = 0
        }
        // The shared subscription pool and its product breakdown must not be added together.
        let type = period["type"] as? String ?? ""
        let label: String
        switch type {
        case "USAGE_PERIOD_TYPE_WEEKLY": label = "WEEK · 本周"
        case "USAGE_PERIOD_TYPE_MONTHLY": label = "MONTH · 本月"
        case "USAGE_PERIOD_TYPE_DAILY": label = "DAY · 今日"
        default: label = "PERIOD · 当前周期"
        }
        let window = QuotaWindow(usedPercent: used, resetsAt: end, windowSeconds: Int(end.timeIntervalSince(start)))
        return QuotaSnapshot(app: .grok, fiveHour: nil,
                             weekly: type == "USAGE_PERIOD_TYPE_WEEKLY" ? window : nil,
                             weeklyOpus: nil, weeklySonnet: nil,
                             planType: nil, fetchedAt: now, primary: window, primaryLabel: label)
    }

    nonisolated static func parseDate(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    nonisolated static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    /// Let the installed CLI own token rotation and auth.json locking.
    /// The models command is read-only: no chat turn or billable inference.
    /// `grokHome` 为 nil 时续期本机 ~/.grok 的凭据，否则续期该独立 GROK_HOME 的凭据。
    nonisolated static func refreshCredentials(grokHome: URL? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runCredentialRefresh(grokHome: grokHome))
            }
        }
    }

    nonisolated static func binaryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".grok/bin/grok"),
                          home.appendingPathComponent(".local/bin/grok")]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    nonisolated private static func runCredentialRefresh(grokHome: URL?) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let binary = binaryURL() else { return false }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["models"]
        process.currentDirectoryURL = grokHome ?? home.appendingPathComponent(".grok")
        if let grokHome {
            var env = ProcessInfo.processInfo.environment
            env["GROK_HOME"] = grokHome.path
            process.environment = env
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return false }
        if exited.wait(timeout: .now() + 25) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            return false
        }
        return process.terminationStatus == 0
    }
}
