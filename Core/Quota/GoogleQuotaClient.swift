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
// 在私有临时目录里运行，日志也写到这个临时目录(--log-file),不在 ~/.gemini 留文件。一次约 10~15 秒，
// 定时刷新最快 2 分钟一次(见 AppState)。
// agy 没登录或登录刷新失败时会想打开浏览器登录页，yybar 拦掉(见 runUsage 里的 `open` 替身),只报「未登录」。
// 其他 Google 账号：每个账号一个独立目录，用 GEMINI_CLI_HOME 指过去(agy 用它替代 ~/.gemini),
// 同时设 SSH_TTY 让 agy 把登录存成该目录里的文件，不碰钥匙串里本机 agy 的登录。登录只能在终端里
// 交互完成(print 模式不接受授权码),见 `loginCommand(home:)`。
// 实测返回(2026-10, agy 1.3.5):
// {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models",
//   "buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":1,"reset_time":"…Z"},
//              {"id":"gemini-5h","window":"5h",…}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly",…},{"id":"3p-5h",…}]}]}}}

enum GoogleQuotaClient {
    nonisolated struct Result: Sendable {
        var gemini: QuotaSnapshot?
        var agy: QuotaSnapshot?
        /// 套餐名：只在 /usage 输出里带了才有(目前 agy 1.3.5 不带),不另去读凭据。
        var plan: String?
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

    /// `home` 为 nil 时用本机 agy 的登录;否则用该独立目录(其他账号)。
    nonisolated static func fetch(home: URL? = nil) async -> Swift.Result<Result, QuotaError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runUsage(home: home))
            }
        }
    }

    /// 独立目录下的 agy 环境变量。SSH_TTY 让 agy 把登录存成文件(不进钥匙串)。
    nonisolated static func isolatedEnvironment(home: URL) -> [String: String] {
        ["GEMINI_CLI_HOME": home.path, "SSH_TTY": "/dev/ttys000"]
    }

    /// 在终端里给独立目录登录的命令(交互式 agy,按提示在浏览器登录后把授权码粘贴回终端，登录完成后退出 agy)。
    nonisolated static func loginCommand(home: URL) -> String {
        let env = isolatedEnvironment(home: home).sorted { $0.key < $1.key }
            .map { "\($0.key)=\(shellQuote($0.value))" }.joined(separator: " ")
        let binary = binaryURL()?.path ?? "agy"
        return "cd \(shellQuote(home.path)) && \(env) \(shellQuote(binary))"
    }

    /// 在「终端」里打开登录命令(写一个临时 .command 文件交给终端运行)。
    nonisolated static func openLoginInTerminal(home: URL) throws {
        let script = home.appendingPathComponent("yybar-agy-login.command")
        let text = """
        #!/bin/bash
        echo "yybar: 为新的 Google 账号登录 Antigravity(agy)。按提示在浏览器登录，把授权码粘贴回这里;"
        echo "       登录成功后输入 /exit 退出 agy,再回到 yybar 点「完成添加」。"
        echo
        \(loginCommand(home: home))

        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        try process.run()
    }

    /// agy 日志里记录的登录邮箱(`applyAuthResult: email=…`)。只用来给账号起名字，读不到就返回 nil。
    nonisolated static func signedInEmail(home: URL) -> String? {
        let fm = FileManager.default
        var logs: [URL] = []
        for dir in ["antigravity-cli/log", "antigravity/log"] {
            let url = home.appendingPathComponent(dir, isDirectory: true)
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            logs += items.filter { $0.pathExtension == "log" }
        }
        logs.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for log in logs.prefix(5) {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let range = line.range(of: "applyAuthResult: email=") else { continue }
                let email = line[range.upperBound...].prefix { $0 != "," && $0 != " " }
                if email.contains("@") { return String(email) }
            }
        }
        return nil
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func runUsage(home: URL?) -> Swift.Result<Result, QuotaError> {
        guard let binary = binaryURL() else { return .failure(.missingToken) }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("yybar-agy-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return .failure(.transport("agy temp dir: \(error.localizedDescription)")) }
        defer { try? fm.removeItem(at: workDir) }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "/usage", "--output-format", "json",
                             "--log-file", workDir.appendingPathComponent("agy.log").path]
        process.currentDirectoryURL = workDir
        var env = ProcessInfo.processInfo.environment
        // agy 的登录刷新不了时(断网、代理没开、登录过期),print 模式会自己调 `open` 打开浏览器登录页;
        // 定时刷新每跑一次就弹一个网页。PATH 最前面放一个什么都不做的 `open`,这里只查额度，不替用户发起登录。
        let shimDir = workDir.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: shimDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let shim = shimDir.appendingPathComponent("open")
        try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: shim)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        env["PATH"] = [shimDir.path, "/opt/homebrew/bin", "/usr/local/bin", "\(fm.homeDirectoryForCurrentUser.path)/.local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        if let home { env.merge(isolatedEnvironment(home: home)) { _, new in new } }
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
        // 没登录时 agy 会先打印几行提示(登录链接等),最后一行才是 JSON。
        func object(_ data: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        let lastJSONLine = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
            .first { $0.hasPrefix("{") }.flatMap { object(Data($0.utf8)) }
        guard let root = object(data) ?? lastJSONLine else {
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
                // 例:"authentication failed or timed out"(独立目录还没登录)。
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
        result.plan = ["plan", "plan_name", "planName", "tier", "subscription"].lazy
            .compactMap { (payload[$0] ?? root[$0]) as? String }
            .first { !$0.isEmpty }
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
