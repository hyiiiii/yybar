import Foundation

/// 用各 CLI 自己的 hook 驱动菜单栏呼吸(设置 → 菜单栏 →「用 hook 驱动呼吸」,默认关)。
///
/// 日志监听要等 CLI 往会话日志里写东西才知道在用，停下后还要再等 30 秒才回落，等待审批也只能靠猜。
/// hook 在事件发生时直接触发:yybar 的 hook 脚本把「哪个 CLI 的哪个会话现在是什么状态」写成
/// `activity/<服务>.<会话>` 小文件(内容只有状态和时间),`UsageActivityMonitor` 盯这个目录。
///
/// 安装只往各 CLI 的配置里追加 yybar 自己的条目(按命令里的脚本路径识别),卸载只删这些条目，
/// 用户原有的 hook 不动。改之前把原文件备份到 `hooks/backup/`。
enum ActivityHooks {
    /// hook 脚本写进状态文件的状态。`end` 表示会话结束，脚本直接删掉状态文件。
    nonisolated enum State: String {
        case busy, waiting, idle, end
    }

    /// 一条要挂的 hook:事件名、可选 matcher、触发后写的状态。
    /// `flat` 为 true 时 handler 直接放在事件数组里(agy 的 PreInvocation / Stop 要求这种结构)。
    nonisolated struct Entry {
        var event: String
        var matcher: String?
        var state: State
        var flat = false
    }

    nonisolated enum Format {
        /// `{"hooks": {事件: [matcher 组]}}`:Claude Code settings.json、Codex hooks.json、Grok hook 文件。
        case eventKeyed
        /// `{名字: {事件: [...]}}`:agy 的 hooks.json,yybar 的条目在 `agyHookName` 下。
        case named
    }

    nonisolated struct Target {
        var app: UsageApp
        /// 要改的配置文件。
        var file: URL
        /// CLI 装了才会有的目录;不存在就跳过这个 CLI。
        var requiredDirectory: URL
        var format: Format
        /// 整个文件都是 yybar 的(Grok):卸载时直接删文件。
        var ownsFile: Bool
        var entries: [Entry]
    }

    nonisolated struct Report {
        var changed: [UsageApp] = []
        var skipped: [UsageApp] = []
        var failed: [(app: UsageApp, message: String)] = []
    }

    /// 命令里带这个路径片段的 handler 视为 yybar 的。
    nonisolated static let marker = "/yybar/hooks/yybar-hook.sh"
    nonisolated static let agyHookName = "yybar-activity"
    nonisolated static let timeout = 5

    // MARK: 路径

    nonisolated static var supportDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("yybar", isDirectory: true)
    }

    /// hook 脚本写状态文件的目录(脚本里写死了同一路径)。
    nonisolated static var activityDirectory: URL {
        supportDirectory.appendingPathComponent("activity", isDirectory: true)
    }

    nonisolated static var scriptURL: URL {
        supportDirectory.appendingPathComponent("hooks/yybar-hook.sh", isDirectory: false)
    }

    nonisolated static var backupDirectory: URL {
        supportDirectory.appendingPathComponent("hooks/backup", isDirectory: true)
    }

    nonisolated static func targets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Target] {
        [
            Target(app: .codex,
                   file: home.appendingPathComponent(".codex/hooks.json"),
                   requiredDirectory: home.appendingPathComponent(".codex", isDirectory: true),
                   format: .eventKeyed, ownsFile: false,
                   entries: [
                       Entry(event: "UserPromptSubmit", state: .busy),
                       Entry(event: "PreToolUse", state: .busy),
                       Entry(event: "PostToolUse", state: .busy),
                       Entry(event: "PermissionRequest", state: .waiting),
                       Entry(event: "Stop", state: .idle),
                       Entry(event: "SessionEnd", state: .end),
                   ]),
            Target(app: .claude,
                   file: home.appendingPathComponent(".claude/settings.json"),
                   requiredDirectory: home.appendingPathComponent(".claude", isDirectory: true),
                   format: .eventKeyed, ownsFile: false,
                   entries: [
                       Entry(event: "UserPromptSubmit", state: .busy),
                       Entry(event: "PreToolUse", matcher: "", state: .busy),
                       Entry(event: "PostToolUse", matcher: "", state: .busy),
                       Entry(event: "PostToolUseFailure", matcher: "", state: .busy),
                       Entry(event: "PermissionRequest", matcher: "", state: .waiting),
                       Entry(event: "Notification", matcher: "permission_prompt", state: .waiting),
                       Entry(event: "Notification", matcher: "idle_prompt", state: .idle),
                       Entry(event: "Stop", state: .idle),
                       Entry(event: "SessionEnd", state: .end),
                   ]),
            // Grok 读 ~/.grok/hooks/*.json(全局，免信任);它也会执行 ~/.claude/settings.json 里的条目，
            // 脚本靠 GROK_HOOK_NAME 跳过那些给 Claude 的。
            Target(app: .grok,
                   file: home.appendingPathComponent(".grok/hooks/yybar.json"),
                   requiredDirectory: home.appendingPathComponent(".grok", isDirectory: true),
                   format: .eventKeyed, ownsFile: true,
                   entries: [
                       Entry(event: "UserPromptSubmit", state: .busy),
                       Entry(event: "PreToolUse", matcher: "", state: .busy),
                       Entry(event: "PostToolUse", matcher: "", state: .busy),
                       Entry(event: "PostToolUseFailure", matcher: "", state: .busy),
                       Entry(event: "Notification", matcher: "permission_prompt", state: .waiting),
                       Entry(event: "Stop", state: .idle),
                       Entry(event: "StopFailure", state: .idle),
                       Entry(event: "StopCancelled", state: .idle),
                       Entry(event: "SessionEnd", state: .end),
                   ]),
            // agy 的全局 hooks.json 在 ~/.gemini/config/。没有审批事件;PreToolUse 必须回 decision,不挂。
            Target(app: .agy,
                   file: home.appendingPathComponent(".gemini/config/hooks.json"),
                   requiredDirectory: home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true),
                   format: .named, ownsFile: false,
                   entries: [
                       Entry(event: "PreInvocation", state: .busy, flat: true),
                       Entry(event: "PostToolUse", matcher: "*", state: .busy),
                       Entry(event: "Stop", state: .idle, flat: true),
                   ]),
        ]
    }

    // MARK: 脚本

    /// hook 脚本。只从标准输入取会话 id,不读对话内容;除 agy 要求的 `{}` 外不输出，不影响 CLI 的任何决定。
    nonisolated static let scriptBody = #"""
    #!/bin/sh
    # yybar 活动 hook:由 yybar「设置 → 菜单栏 → 用 hook 驱动呼吸」安装，关掉开关时从各 CLI 配置里移除。
    # 只记录哪个 CLI 的哪个会话处于什么状态(busy / waiting / idle),写到
    # ~/Library/Application Support/yybar/activity/<服务>.<会话>,内容只有状态和时间。
    # 不读对话内容：标准输入只用来取会话 id。除 agy 要求的 {} 外不输出任何东西。
    app="$1"
    state="$2"
    # Grok 也会执行 ~/.claude/settings.json 里的 hook(Claude 兼容层);那几条是给 Claude 的，
    # Grok 走自己的 ~/.grok/hooks/yybar.json。
    if [ "$app" = claude ] && [ -n "${GROK_HOOK_NAME:-}" ]; then
      cat >/dev/null 2>&1
      exit 0
    fi
    sid=$(grep -o -m 1 -E '"(session_id|sessionId|conversationId)"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -n 1 | sed -E 's/.*"([^"]*)"$/\1/' | tr -cd 'A-Za-z0-9_-' | cut -c 1-80)
    cat >/dev/null 2>&1
    [ -n "$sid" ] || sid=default
    case "$app" in claude|codex|grok|agy) ;; *) exit 0 ;; esac
    case "$state" in busy|waiting|idle|end) ;; *) exit 0 ;; esac
    dir="$HOME/Library/Application Support/yybar/activity"
    mkdir -p "$dir" 2>/dev/null
    file="$dir/$app.$sid"
    if [ "$state" = end ]; then
      rm -f "$file"
    else
      tmp="$dir/.$app.$sid.$$"
      printf '%s %s\n' "$state" "$(date +%s)" >"$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null
    fi
    [ "$app" = agy ] && printf '{}\n'
    exit 0

    """#

    nonisolated static func writeScript(to url: URL = scriptURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(scriptBody.utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    nonisolated static func command(app: UsageApp, state: State, script: URL = scriptURL) -> String {
        let quoted = "'" + script.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(app.rawValue) \(state.rawValue)"
    }

    // MARK: 安装 / 卸载

    /// 是否已在该 CLI 的配置里挂了 yybar 的 hook。
    nonisolated static func isInstalled(_ target: Target) -> Bool {
        guard let text = try? String(contentsOf: target.file, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    nonisolated static func installedApps(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [UsageApp] {
        targets(home: home).filter(isInstalled).map(\.app)
    }

    nonisolated static func install(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    script: URL = scriptURL,
                                    backups: URL = backupDirectory) -> Report {
        var report = Report()
        do { try writeScript(to: script) } catch {
            for target in targets(home: home) { report.failed.append((target.app, "写 hook 脚本失败：\(error.localizedDescription)")) }
            return report
        }
        for target in targets(home: home) {
            guard FileManager.default.fileExists(atPath: target.requiredDirectory.path) else {
                report.skipped.append(target.app)
                continue
            }
            do {
                let root = try readObject(target.file)
                let cleaned = removing(from: root, format: target.format)
                let updated = adding(target.entries, app: target.app, script: script, to: cleaned, format: target.format)
                try write(updated, to: target.file, backupTo: backups, app: target.app)
                report.changed.append(target.app)
            } catch {
                report.failed.append((target.app, error.localizedDescription))
            }
        }
        return report
    }

    nonisolated static func uninstall(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                      backups: URL = backupDirectory,
                                      activity: URL = activityDirectory) -> Report {
        var report = Report()
        for target in targets(home: home) {
            guard isInstalled(target) else { continue }
            do {
                if target.ownsFile {
                    try FileManager.default.removeItem(at: target.file)
                } else {
                    let root = try readObject(target.file)
                    try write(removing(from: root, format: target.format), to: target.file, backupTo: backups, app: target.app)
                }
                report.changed.append(target.app)
            } catch {
                report.failed.append((target.app, error.localizedDescription))
            }
        }
        // 状态文件留着会让监听继续以 hook 为准，清掉后回到日志监听。
        if let names = try? FileManager.default.contentsOfDirectory(atPath: activity.path) {
            for name in names { try? FileManager.default.removeItem(at: activity.appendingPathComponent(name)) }
        }
        return report
    }

    // MARK: JSON

    nonisolated struct ConfigError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    nonisolated static func readObject(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError(message: "\(url.path) 不是有效的 JSON 对象，没有修改")
        }
        return object
    }

    /// 写回配置：先备份原文件，跟随符号链接写到真实文件，保留原来的权限。
    nonisolated static func write(_ object: [String: Any], to url: URL, backupTo backups: URL, app: UsageApp) throws {
        let fm = FileManager.default
        let real = url.resolvingSymlinksInPath()
        var permissions: Any?
        if fm.fileExists(atPath: real.path) {
            permissions = (try? fm.attributesOfItem(atPath: real.path))?[.posixPermissions]
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = backups.appendingPathComponent("\(app.rawValue)-\(real.lastPathComponent)-\(stamp)")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: real, to: backup)
        } else {
            try fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: real, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: real.path) }
    }

    nonisolated static func handler(app: UsageApp, state: State, script: URL) -> [String: Any] {
        ["type": "command", "command": command(app: app, state: state, script: script), "timeout": timeout]
    }

    nonisolated static func eventMap(_ entries: [Entry], app: UsageApp, script: URL, into map: [String: Any] = [:]) -> [String: Any] {
        var map = map
        for entry in entries {
            let item: [String: Any]
            if entry.flat {
                item = handler(app: app, state: entry.state, script: script)
            } else {
                var group: [String: Any] = ["hooks": [handler(app: app, state: entry.state, script: script)]]
                if let matcher = entry.matcher { group["matcher"] = matcher }
                item = group
            }
            map[entry.event] = (map[entry.event] as? [Any] ?? []) + [item]
        }
        return map
    }

    nonisolated static func adding(_ entries: [Entry], app: UsageApp, script: URL,
                                   to root: [String: Any], format: Format) -> [String: Any] {
        var root = root
        switch format {
        case .eventKeyed:
            root["hooks"] = eventMap(entries, app: app, script: script, into: root["hooks"] as? [String: Any] ?? [:])
        case .named:
            root[agyHookName] = eventMap(entries, app: app, script: script)
        }
        return root
    }

    /// 删掉 yybar 的条目：命令含 `marker` 的 handler;删空的组和事件也一并去掉。用户自己的条目原样保留。
    nonisolated static func removing(from root: [String: Any], format: Format) -> [String: Any] {
        var root = root
        switch format {
        case .named:
            root.removeValue(forKey: agyHookName)
            // 万一用户把 yybar 的命令放进了别的名字下，也只删那几条。
            for (name, value) in root {
                guard let spec = value as? [String: Any] else { continue }
                let cleaned = removingHandlers(fromEventMap: spec)
                if cleaned.removed { root[name] = cleaned.map }
            }
        case .eventKeyed:
            guard let hooks = root["hooks"] as? [String: Any] else { return root }
            let cleaned = removingHandlers(fromEventMap: hooks)
            guard cleaned.removed else { return root }
            if cleaned.map.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = cleaned.map }
        }
        return root
    }

    nonisolated private static func isOurs(_ value: Any) -> Bool {
        (value as? [String: Any])?["command"].flatMap { $0 as? String }?.contains(marker) == true
    }

    nonisolated private static func removingHandlers(fromEventMap map: [String: Any]) -> (map: [String: Any], removed: Bool) {
        var map = map
        var removedAny = false
        for (event, value) in map {
            guard let items = value as? [Any] else { continue }
            var kept: [Any] = []
            var removedHere = false
            for item in items {
                if isOurs(item) { removedHere = true; continue }
                if var group = item as? [String: Any], let handlers = group["hooks"] as? [Any] {
                    let remaining = handlers.filter { !isOurs($0) }
                    if remaining.count != handlers.count {
                        removedHere = true
                        if remaining.isEmpty { continue }
                        group["hooks"] = remaining
                        kept.append(group)
                        continue
                    }
                }
                kept.append(item)
            }
            guard removedHere else { continue }
            removedAny = true
            if kept.isEmpty { map.removeValue(forKey: event) } else { map[event] = kept }
        }
        return (map, removedAny)
    }
}
