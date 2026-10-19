import Foundation
import CoreServices

/// 监听各 CLI 的本地会话日志目录，判断哪个服务「正在使用」。
///
/// 额度接口 2 分钟才刷新一次，太慢，不适合驱动菜单栏的呼吸动效;
/// CLI 在对话进行中会持续往会话 `.jsonl` 里追加，用 FSEvents 监听写入即可近实时感知。
/// 最近 `activeWindow` 秒内有写入的服务视为使用中，写入停止后自动回落。
///
/// 等待审批：三个 CLI 都不单独记录「等待用户批准」,但都会先写工具调用、执行完再写结果。
/// 会话日志最后一条相关记录是「还没有结果的工具调用」且 `pendingDelay` 秒内没有新写入时，
/// 视为在等待审批(放进 `waitingApps`,菜单栏图标保持识别色不呼吸),直到有新写入。
/// 局限：长时间运行、期间不写日志的工具(如很长的构建)看起来也一样。
@Observable
final class UsageActivityMonitor {
    static let shared = UsageActivityMonitor()

    /// 当前判定为使用中(呼吸)的服务。
    private(set) var activeApps: Set<UsageApp> = []
    /// 当前判定为等待审批(保持染色)的服务。与 activeApps 不重叠。
    private(set) var waitingApps: Set<UsageApp> = []

    /// 最后一次写入后保持「使用中」的时长。
    static let activeWindow: TimeInterval = 30
    /// 工具调用后多久没有新写入就视为在等待审批。
    static let pendingDelay: TimeInterval = 3
    /// 等待审批最多保持多久(用户离开后不至于一直亮着)。
    static let pendingLimit: TimeInterval = 30 * 60

    @ObservationIgnored private var lastWrite: [UsageApp: Date] = [:]
    /// 没有本地会话日志的服务(Gemini / Antigravity / Grok Bot):额度刷新时发现剩余比上次少，
    /// 就算「使用中」到这个时间(见 `markQuotaActivity`)。
    @ObservationIgnored private var quotaActiveUntil: [UsageApp: Date] = [:]
    /// 最近写入的会话日志结尾是否为「未完成的工具调用」。
    @ObservationIgnored private var pendingTool: [UsageApp: Bool] = [:]
    @ObservationIgnored private var roots: [(app: UsageApp, path: String)] = []
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var expiryTimer: Timer?

    private init() {}

    func start() {
        guard stream == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        roots = [
            (.codex, home + "/.codex/sessions"),
            (.claude, home + "/.claude/projects"),
            (.grok, home + "/.grok/sessions")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            // 事件投递在 main queue(见 FSEventStreamSetDispatchQueue)。
            MainActor.assumeIsolated {
                Unmanaged<UsageActivityMonitor>.fromOpaque(info).takeUnretainedValue().handle(paths)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            roots.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handle(_ paths: [String]) {
        let now = Date()
        for path in paths where path.hasSuffix(".jsonl") {
            guard let root = roots.first(where: { path.hasPrefix($0.path) }) else { continue }
            lastWrite[root.app] = now
            if let pending = Self.endsWithPendingToolCall(path: path, app: root.app) {
                pendingTool[root.app] = pending
            }
        }
        recompute(now: now)
    }

    /// 额度刷新发现该服务的剩余减少了：呼吸到 `until`(通常到下一次刷新之后)。
    func markQuotaActivity(_ app: UsageApp, until: Date) {
        quotaActiveUntil[app] = max(quotaActiveUntil[app] ?? .distantPast, until)
        recompute()
    }

    private func recompute(now: Date = Date()) {
        var active: Set<UsageApp> = []
        var waiting: Set<UsageApp> = []
        for (app, until) in quotaActiveUntil where until > now { active.insert(app) }
        quotaActiveUntil = quotaActiveUntil.filter { $0.value > now }
        for (app, date) in lastWrite {
            let quiet = now.timeIntervalSince(date)
            if pendingTool[app] == true, quiet >= Self.pendingDelay, quiet < Self.pendingLimit {
                waiting.insert(app)
            } else if quiet < Self.activeWindow {
                active.insert(app)
            }
        }
        if active != activeApps { activeApps = active }
        if waiting != waitingApps { waitingApps = waiting }

        // 有服务使用中、或有未完成的工具调用时跑检查(用于转入等待 / 过期);空闲时不占 CPU。
        let pendingSoon = lastWrite.contains { app, date in
            pendingTool[app] == true && now.timeIntervalSince(date) < Self.pendingLimit
        }
        if active.isEmpty && !pendingSoon {
            expiryTimer?.invalidate()
            expiryTimer = nil
        } else if expiryTimer == nil {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { UsageActivityMonitor.shared.recompute() }
            }
        }
    }

    // MARK: Pending tool call detection

    /// 读日志末尾，判断最后一条相关记录是否为还没有结果的工具调用。
    /// 返回 nil 表示这个文件判断不了(如 Grok 的非 updates.jsonl),保持原状态。
    nonisolated static func endsWithPendingToolCall(path: String, app: UsageApp) -> Bool? {
        if app == .grok, !path.hasSuffix("updates.jsonl") { return nil }
        // Grok Bot / Gemini / agy 不监听本地日志。
        if app == .grokBot || app == .gemini || app == .agy { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            switch app {
            case .claude:
                // 只看对话记录;attachment / system 等元数据跳过。
                guard let type = record["type"] as? String, type == "assistant" || type == "user" else { continue }
                guard type == "assistant",
                      let message = record["message"] as? [String: Any] else { return false }
                if message["stop_reason"] as? String == "tool_use" { return true }
                let content = message["content"] as? [[String: Any]] ?? []
                return content.contains { $0["type"] as? String == "tool_use" }
            case .codex:
                let type = record["type"] as? String
                let payloadType = (record["payload"] as? [String: Any])?["type"] as? String
                if type == "event_msg", payloadType == "task_complete" || payloadType == "turn_aborted" { return false }
                guard type == "response_item", let payloadType else { continue }
                return payloadType == "function_call" || payloadType == "custom_tool_call"
            case .grok:
                guard let params = record["params"] as? [String: Any],
                      let update = params["update"] as? [String: Any],
                      let kind = update["sessionUpdate"] as? String else { continue }
                switch kind {
                case "tool_call", "tool_call_update":
                    let status = update["status"] as? String
                    return status != "completed" && status != "failed"
                case "agent_message_chunk", "agent_thought_chunk", "user_message_chunk", "turn_completed":
                    return false
                default:
                    continue
                }
            case .grokBot, .gemini, .agy:
                return nil
            }
        }
        return nil
    }
}
