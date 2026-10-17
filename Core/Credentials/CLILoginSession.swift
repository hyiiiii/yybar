import Foundation

// MARK: - AccountProvider

/// 「添加账号」可选的三个服务商。
enum AccountProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case grok

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .grok: return "Grok"
        }
    }

    var vendor: String {
        switch self {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        case .grok: return "xAI"
        }
    }

    var logoName: String { rawValue }

    /// 浏览器登录调用的官方命令(展示用)。
    var loginCommand: String {
        switch self {
        case .codex: return "codex login"
        case .claude: return "claude auth login"
        case .grok: return "grok login --oauth"
        }
    }

    /// 粘贴方式对应的凭据文件(展示用)。
    var credentialsFile: String {
        switch self {
        case .codex: return "~/.codex/auth.json"
        case .claude: return "~/.claude/.credentials.json"
        case .grok: return "~/.grok/auth.json"
        }
    }
}

// MARK: - CLILoginSession
//
// 用官方 CLI 在独立目录里完成浏览器登录，不影响本机 CLI 已登录的账号:
// - Codex:`CODEX_HOME=<dir> codex login`(本地回调，浏览器授权后自动结束)
// - Claude:`CLAUDE_CONFIG_DIR=<dir> claude auth login --claudeai`(浏览器页面给出授权码，需粘贴回 CLI)
// - Grok:`GROK_HOME=<dir> grok login --oauth`(本地回调，自动结束)
// CLI 退出码 0 视为登录成功，之后由 AppState 从 `home` 读取凭据导入。

@Observable
final class CLILoginSession {
    enum Phase: Equatable {
        case starting
        case waitingForBrowser
        case needsCode
        case exited(succeeded: Bool)
        case failed(String)
    }

    let provider: AccountProvider
    /// 本次登录使用的独立目录。Codex / Claude 用临时目录，导入后删除;Grok 的目录即该账号长期使用的 GROK_HOME。
    let home: URL
    /// 仅 Grok:home 对应的目录名。
    let grokFolder: String?

    private(set) var phase: Phase = .starting
    private(set) var loginURL: URL?
    /// CLI 最近的输出(失败时展示最后几行)。
    private(set) var outputTail: String = ""

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdinPipe: Pipe?
    @ObservationIgnored private var buffer = ""

    init(provider: AccountProvider) throws {
        self.provider = provider
        if provider == .grok {
            let made = try ExtraAccountStore.makeGrokHome()
            home = made.url
            grokFolder = made.folder
        } else {
            let dir = ExtraAccountStore.supportDirectory()
                .appendingPathComponent("login-tmp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            home = dir
            grokFolder = nil
        }
    }

    func start() {
        guard process == nil else { return }
        guard let binary = Self.binary(for: provider) else {
            phase = .failed(tr("Couldn't find the \(provider.loginCommand.components(separatedBy: " ")[0]) command on this Mac. Install the CLI first, or paste credentials instead.",
                               "本机没有找到 \(provider.loginCommand.components(separatedBy: " ")[0]) 命令。请先安装对应 CLI,或改用粘贴凭据。"))
            return
        }

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = home
        var env = ProcessInfo.processInfo.environment
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        // 从 Finder 启动的 App 的 PATH 很短，补上常见安装位置，脚本型 CLI 才能找到 node 等依赖。
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(userHome)/.local/bin", "\(userHome)/.grok/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        switch provider {
        case .codex:
            env["CODEX_HOME"] = home.path
            process.arguments = ["login"]
        case .claude:
            env["CLAUDE_CONFIG_DIR"] = home.path
            process.arguments = ["auth", "login", "--claudeai"]
        case .grok:
            env["GROK_HOME"] = home.path
            process.arguments = ["login", "--oauth"]
        }
        process.environment = env

        let out = Pipe()
        let stdin = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdin
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.consume(text) }
            }
        }
        process.terminationHandler = { proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    out.fileHandleForReading.readabilityHandler = nil
                    self.finish(status: status)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.stdinPipe = stdin
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Claude:把浏览器页面上显示的授权码交给 CLI。
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = (trimmed + "\n").data(using: .utf8) else { return }
        stdinPipe?.fileHandleForWriting.write(data)
        phase = .waitingForBrowser
    }

    /// 取消:结束 CLI,并清理本次登录目录(Grok 目录未被导入时一并删除)。
    func cancel() {
        if let process, process.isRunning { process.terminate() }
        cleanup()
    }

    /// 导入完成或放弃后删除临时目录。Grok 的目录在导入成功后由账号继续使用，不在这里删。
    func cleanup(keepGrokHome: Bool = false) {
        if provider == .grok, keepGrokHome { return }
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Output

    private func consume(_ text: String) {
        buffer += text
        outputTail = String(buffer.suffix(600))
        if loginURL == nil, let url = Self.firstLoginURL(in: buffer) {
            loginURL = url
            if phase == .starting { phase = .waitingForBrowser }
        }
        if provider == .claude, buffer.lowercased().contains("paste code") {
            if phase == .starting || phase == .waitingForBrowser { phase = .needsCode }
        }
    }

    private func finish(status: Int32) {
        process = nil
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
        if case .failed = phase { return }
        phase = .exited(succeeded: status == 0)
    }

    /// 同一个登录链接，加上 OIDC 标准参数 `prompt=login`,要求服务商重新显示登录表单，
    /// 而不是直接沿用浏览器里已登录的账号。state / PKCE 不变,CLI 仍能接住回调。
    /// 服务商不支持该参数时会忽略它，用户仍可在页面上手动「退出登录」。
    var switchAccountURL: URL? {
        guard let loginURL, var components = URLComponents(url: loginURL, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "prompt" }
        items.append(URLQueryItem(name: "prompt", value: "login"))
        components.queryItems = items
        return components.url
    }

    nonisolated private static func firstLoginURL(in text: String) -> URL? {
        let pattern = #"https://[^\s"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let candidate = String(text[r])
            if candidate.contains("authorize") || candidate.contains("oauth") {
                return URL(string: candidate)
            }
        }
        return nil
    }

    // MARK: Binary lookup

    nonisolated static func binary(for provider: AccountProvider) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String]
        switch provider {
        case .codex:
            candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                          "\(home)/.npm-global/bin/codex", "\(home)/.bun/bin/codex"]
        case .claude:
            candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .grok:
            return GrokQuotaClient.binaryURL()
        }
        return candidates.map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
