import Foundation
import Darwin

// MARK: - GoogleQuotaClient
//
// Gemini / agy(Google Antigravity CLI)的额度。额度挂在 Google 账号上，只有两个池子:
// - 「Gemini Models」:Gemini Pro 和 Flash 共用 → yybar 的 Gemini 格子
// - 「Claude and GPT models」:Claude Opus / Sonnet、GPT-OSS 共用 → yybar 的 agy 格子
// 每个池子各有 5 小时和每周两层限制。
//
// 数据来源：本机 agy CLI 的只读命令 `agy -p /usage --output-format json`(agy ≥ 1.1.11)。
// 它用 agy 自己的登录(钥匙串里的 Google 账号)查额度，不发模型请求、不消耗额度，yybar 不碰任何凭据。
// 在私有临时目录里运行，避免在用户目录留下会话文件。一次约 10 秒，所以定时刷新最快 5 分钟一次(见 AppState)。
// 实测返回(2026-10, agy 1.3.5):
// {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models",
//   "buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":1,"reset_time":"…Z"},
//              {"id":"gemini-5h","window":"5h",…}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly",…},{"id":"3p-5h",…}]}]}}}

enum GoogleQuotaClient {
    nonisolated struct Result: Sendable {
        var gemini: QuotaSnapshot?
        var agy: QuotaSnapshot?
    }

    /// agy CLI 位置：PATH 常见目录(Homebrew / ~/.local/bin)。Gemini.app 内置的 agy 走宿主 App 的登录，不能单独调用。
    nonisolated static func binaryURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/agy"),
                          URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
                          URL(fileURLWithPath: "/usr/local/bin/agy")]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    /// 本机装了 agy CLI(agy 格子默认启用的依据)。
    nonisolated static var isAgyInstalled: Bool { binaryURL() != nil }

    /// 本机有 agy CLI 或 Google 的 Gemini 桌面 App(Gemini 格子默认启用的依据)。
    nonisolated static var isGeminiInstalled: Bool {
        isAgyInstalled || FileManager.default.fileExists(atPath: "/Applications/Gemini.app")
    }

    nonisolated static func fetch() async -> Swift.Result<Result, QuotaError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runUsage())
            }
        }
    }

    nonisolated private static func runUsage() -> Swift.Result<Result, QuotaError> {
        guard let binary = binaryURL() else { return .failure(.missingToken) }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("yybar-agy-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return .failure(.transport("agy temp dir: \(error.localizedDescription)")) }
        defer { try? fm.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice

        // 边跑边读，避免输出超过管道缓冲时子进程阻塞;最多收 1 MiB。
        let collected = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { collected.append(chunk) }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return .failure(.transport("agy launch failed: \(error.localizedDescription)"))
        }
        if exited.wait(timeout: .now() + 90) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            out.fileHandleForReading.readabilityHandler = nil
            return .failure(.transport("agy /usage timed out"))
        }
        out.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFile())
        let data = collected.data
        do {
            return .success(try parse(data: data))
        } catch let error as QuotaError {
            return .failure(error)
        } catch {
            return .failure(.decode(error.localizedDescription))
        }
    }

    /// 解析 `agy -p /usage --output-format json` 的输出。
    nonisolated static func parse(data: Data, now: Date = Date()) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decode("agy /usage output is not JSON")
        }
        let status = root["status"] as? String ?? ""
        guard status == "SUCCESS" else {
            let message = (root["error"] as? String) ?? (root["response"] as? String) ?? status
            // 限流 / 额度接口拒绝按 429 处理，走统一的退避。
            if message.contains("429") || message.localizedCaseInsensitiveContains("RESOURCE_EXHAUSTED") {
                throw QuotaError.http(429, "agy usage rate limited")
            }
            if message.localizedCaseInsensitiveContains("login") || message.localizedCaseInsensitiveContains("auth") {
                throw QuotaError.missingToken
            }
            throw QuotaError.decode("agy /usage status \(status.isEmpty ? "unknown" : status)")
        }
        guard let command = root["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]] else {
            throw QuotaError.decode("agy /usage has no quota groups")
        }

        var result = Result()
        for group in groups {
            let name = (group["name"] as? String ?? "").lowercased()
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            let isGemini = name.contains("gemini")
            let isThirdParty = name.contains("claude") || name.contains("gpt")
            guard isGemini || isThirdParty else { continue }
            var fiveHour: QuotaWindow?
            var weekly: QuotaWindow?
            for bucket in buckets {
                // 没有 remaining_fraction 的档位算「未知」,不当成用完。
                guard let fraction = GrokQuotaClient.double(bucket["remaining_fraction"]), fraction.isFinite else { continue }
                let window = (bucket["window"] as? String ?? "").lowercased()
                let id = (bucket["id"] as? String ?? "").lowercased()
                let used = max(0, min(100, (1 - fraction) * 100))
                let resets = GrokQuotaClient.parseDate(bucket["reset_time"])
                if window == "5h" || id.hasSuffix("5h") {
                    // 同一窗口有多档时取剩余最少的。
                    if (fiveHour?.usedPercent ?? -1) < used {
                        fiveHour = QuotaWindow(usedPercent: used, resetsAt: resets, windowSeconds: 5 * 3600)
                    }
                } else if window == "weekly" || id.hasSuffix("weekly") {
                    if (weekly?.usedPercent ?? -1) < used {
                        weekly = QuotaWindow(usedPercent: used, resetsAt: resets, windowSeconds: 7 * 86400)
                    }
                }
            }
            if case .none = fiveHour, case .none = weekly { continue }
            let snapshot = QuotaSnapshot(app: isGemini ? .gemini : .agy, fiveHour: fiveHour, weekly: weekly,
                                         weeklyOpus: nil, weeklySonnet: nil, planType: nil, fetchedAt: now)
            if isGemini { result.gemini = snapshot } else { result.agy = snapshot }
        }
        if case .none = result.gemini, case .none = result.agy {
            throw QuotaError.decode("agy /usage has no known quota buckets")
        }
        return result
    }

    nonisolated private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let limit = 1 << 20

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            guard buffer.count < limit else { return }
            buffer.append(chunk.prefix(limit - buffer.count))
        }

        var data: Data {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }
}
