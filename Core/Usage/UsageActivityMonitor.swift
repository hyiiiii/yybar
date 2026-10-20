import Foundation
import CoreServices

/// 监听各 CLI 的本地会话日志目录，判断哪个服务「正在使用」。
///
/// 额度接口 2 分钟才刷新一次，太慢，不适合驱动菜单栏的呼吸动效;
/// CLI 在对话进行中会持续往会话 `.jsonl` 里追加，用 FSEvents 监听写入即可近实时感知。
/// 最近 `activeWindow` 秒内有写入的服务视为使用中，写入停止后自动回落。
/// agy 没有 `.jsonl`,看会话库(`conversations/<uuid>.db` 和 `-wal`)的修改事件，不打开库读内容。
///
/// 等待审批：三个 CLI 都不单独记录「等待用户批准」,但都会先写工具调用、执行完再写结果。
/// 会话日志最后一条相关记录是「还没有结果的工具调用」且 `pendingDelay` 秒内没有新写入时，
/// 视为在等待审批(放进 `waitingApps`,菜单栏图标保持识别色不呼吸),直到有新写入。
/// 局限：长时间运行、期间不写日志的工具(如很长的构建)看起来也一样。
///
/// hook(见 `ActivityHooks`,设置里打开后安装):CLI 的 hook 把每个会话的状态写到 `activity/<服务>.<会话>`,
/// 这里用延迟很短的 FSEvents 盯这个目录。有状态文件的服务以 hook 为准(提问 / 工具调用即呼吸，
/// 请求审批即保持颜色，回答结束即停),不再用日志猜;没有状态文件的服务仍走日志监听。
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
    /// hook 报「使用中」后，多久既没有新事件也没有日志写入就当作已停(CLI 崩溃 / 被强退时不会触发结束 hook)。
    static let hookBusyStale: TimeInterval = 15 * 60
    /// agy 没有审批事件，等审批时只能靠超时回落，所以短一些。
    static let agyHookBusyStale: TimeInterval = 90
    /// 状态文件超过这个时间没更新就删掉(会话没触发结束 hook 留下的)。
    static let hookFileLifetime: TimeInterval = 24 * 3600

    private struct HookSession {
        var state: ActivityHooks.State
        var at: Date
    }

    /// FSEvents 回调的接收者(context 里只能放指针)。
    private final class StreamHandler {
        let handle: ([String]) -> Void
        init(_ handle: @escaping ([String]) -> Void) { self.handle = handle }
    }

    @ObservationIgnored private var lastWrite: [UsageApp: Date] = [:]
    /// 没有本地会话日志的服务(Gemini / Antigravity / Grok Bot):额度刷新时发现剩余比上次少，
    /// 就算「使用中」到这个时间(见 `markQuotaActivity`)。
    @ObservationIgnored private var quotaActiveUntil: [UsageApp: Date] = [:]
    /// 最近写入的会话日志结尾是否为「未完成的工具调用」。
    @ObservationIgnored private var pendingTool: [UsageApp: Bool] = [:]
    /// hook 状态：服务 → 会话 id → 状态。有条目的服务以 hook 为准。
    @ObservationIgnored private var hookSessions: [UsageApp: [String: HookSession]] = [:]
    /// 日志里看到的中断(Ctrl-C / 拒绝审批时 Claude、Codex 不触发 Stop hook):"服务.会话" → 时间。
    @ObservationIgnored private var interruptedAt: [String: Date] = [:]
    @ObservationIgnored private var roots: [(app: UsageApp, path: String)] = []
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var hookStream: FSEventStreamRef?
    @ObservationIgnored private var handlers: [StreamHandler] = []
    @ObservationIgnored private var expiryTimer: Timer?

    private init() {}

    func start() {
        guard stream == nil, hookStream == nil else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        roots = [
            (.codex, home + "/.codex/sessions"),
            (.claude, home + "/.claude/projects"),
            (.grok, home + "/.grok/sessions"),
            (.agy, home + "/.gemini/antigravity-cli/conversations"),
            (.agy, home + "/.gemini/antigravity/conversations")
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        if !roots.isEmpty {
            stream = makeStream(paths: roots.map(\.path), latency: 1.0) { [weak self] in self?.handle($0) }
        }

        let activity = ActivityHooks.activityDirectory
        try? FileManager.default.createDirectory(at: activity, withIntermediateDirectories: true)
        hookStream = makeStream(paths: [activity.path], latency: 0.05) { [weak self] _ in self?.reloadHookStates() }
        reloadHookStates()
    }

    private func makeStream(paths: [String], latency: CFTimeInterval,
                            handle: @escaping ([String]) -> Void) -> FSEventStreamRef? {
        let handler = StreamHandler(handle)
        handlers.append(handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            // 事件投递在 main queue(见 FSEventStreamSetDispatchQueue)。
            MainActor.assumeIsolated {
                Unmanaged<StreamHandler>.fromOpaque(info).takeUnretainedValue().handle(paths)
            }
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        return stream
    }

    private func handle(_ paths: [String]) {
        let now = Date()
        for path in paths {
            guard let root = roots.first(where: { path.hasPrefix($0.path) }) else { continue }
            if root.app == .agy {
                // 会话库：只看修改事件，不打开读内容。
                guard path.hasSuffix(".db") || path.hasSuffix(".db-wal") else { continue }
                lastWrite[.agy] = now
                continue
            }
            guard path.hasSuffix(".jsonl") else { continue }
            lastWrite[root.app] = now
            if hookSessions[root.app] != nil {
                // 以 hook 为准;日志只用来发现 hook 报不出来的中断。
                if Self.endsWithInterrupt(path: path, app: root.app) {
                    for sid in (hookSessions[root.app] ?? [:]).keys where path.contains(sid) {
                        interruptedAt["\(root.app.rawValue).\(sid)"] = now
                    }
                }
                continue
            }
            if let pending = Self.endsWithPendingToolCall(path: path, app: root.app) {
                pendingTool[root.app] = pending
            }
        }
        recompute(now: now)
    }

    /// 重新读 hook 状态目录。文件名 `<服务>.<会话>`,内容 `<状态> <unix 秒>`;点开头的是脚本的临时文件。
    func reloadHookStates() {
        let now = Date()
        let fm = FileManager.default
        let dir = ActivityHooks.activityDirectory
        var sessions: [UsageApp: [String: HookSession]] = [:]
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let app = UsageApp(rawValue: String(parts[0])) else { continue }
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, let state = ActivityHooks.State(rawValue: String(first)) else { continue }
            let stamp = fields.count > 1 ? Double(fields[1]) : nil
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let at = stamp.map(Date.init(timeIntervalSince1970:)) ?? modified ?? now
            if now.timeIntervalSince(at) > Self.hookFileLifetime {
                try? fm.removeItem(at: url)
                continue
            }
            sessions[app, default: [:]][String(parts[1])] = HookSession(state: state, at: at)
        }
        hookSessions = sessions
        interruptedAt = interruptedAt.filter { now.timeIntervalSince($0.value) < Self.hookFileLifetime }
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
        for (app, date) in lastWrite where hookSessions[app] == nil {
            let quiet = now.timeIntervalSince(date)
            if pendingTool[app] == true, quiet >= Self.pendingDelay, quiet < Self.pendingLimit {
                waiting.insert(app)
            } else if quiet < Self.activeWindow {
                active.insert(app)
            }
        }
        for (app, sessions) in hookSessions {
            let stale = app == .agy ? Self.agyHookBusyStale : Self.hookBusyStale
            for (sid, session) in sessions {
                if let interrupted = interruptedAt["\(app.rawValue).\(sid)"], interrupted >= session.at { continue }
                switch session.state {
                case .busy:
                    let last = max(session.at, lastWrite[app] ?? .distantPast)
                    if now.timeIntervalSince(last) < stale { active.insert(app) }
                case .waiting:
                    if now.timeIntervalSince(session.at) < Self.pendingLimit { waiting.insert(app) }
                case .idle, .end:
                    break
                }
            }
        }
        waiting.subtract(active)
        if active != activeApps { activeApps = active }
        if waiting != waitingApps { waitingApps = waiting }

        // 有服务使用中 / 等待中、或有未完成的工具调用时跑检查(用于转入等待 / 过期);空闲时不占 CPU。
        let pendingSoon = lastWrite.contains { app, date in
            pendingTool[app] == true && now.timeIntervalSince(date) < Self.pendingLimit
        }
        if active.isEmpty && waiting.isEmpty && !pendingSoon {
            expiryTimer?.invalidate()
            expiryTimer = nil
        } else if expiryTimer == nil {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { UsageActivityMonitor.shared.recompute() }
            }
        }
    }

    // MARK: Interrupt detection (hook mode)

    /// 会话日志最后一条相关记录是否为用户中断。Claude 记 "[Request interrupted by user…]",
    /// Codex 记 `turn_aborted`;两者中断时都不触发 Stop hook。Grok 有 StopCancelled hook,不用看。
    nonisolated static func endsWithInterrupt(path: String, app: UsageApp) -> Bool {
        guard app == .claude || app == .codex, let text = tail(path: path) else { return false }
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if app == .claude {
                guard let type = record["type"] as? String, type == "assistant" || type == "user" else { continue }
                guard type == "user", let message = record["message"] as? [String: Any] else { return false }
                let texts: [String]
                if let content = message["content"] as? String {
                    texts = [content]
                } else {
                    texts = (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                }
                return texts.contains { $0.hasPrefix("[Request interrupted by user") }
            } else {
                let type = record["type"] as? String
                let payloadType = (record["payload"] as? [String: Any])?["type"] as? String
                if type == "event_msg", payloadType == "turn_aborted" { return true }
                if type == "event_msg", payloadType == "task_complete" { return false }
                if type == "response_item" { return false }
            }
        }
        return false
    }

    nonisolated private static func tail(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        // 从中间截断可能切开多字节字符，宽松解码(第一行本来就不完整，会被 JSON 解析跳过)。
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Pending tool call detection

    /// 读日志末尾，判断最后一条相关记录是否为还没有结果的工具调用。
    /// 返回 nil 表示这个文件判断不了(如 Grok 的非 updates.jsonl),保持原状态。
    nonisolated static func endsWithPendingToolCall(path: String, app: UsageApp) -> Bool? {
        if app == .grok, !path.hasSuffix("updates.jsonl") { return nil }
        // Grok Bot / Gemini 不监听本地日志;agy 只看会话库有没有修改，不判断审批。
        if app == .grokBot || app == .gemini || app == .agy { return nil }
        guard let text = tail(path: path) else { return nil }

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
