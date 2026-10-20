import Foundation

// 此独立回归只在临时目录里造假的 ~/.claude、~/.codex、~/.grok、~/.gemini,不碰真实配置。
// 验证：安装只追加 yybar 的条目、重复安装不重复、卸载后恢复原样;hook 脚本只按会话写状态文件。
@main
enum ActivityHooksRegression {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory())
        let home = root.appendingPathComponent("home", isDirectory: true)
        let script = home.appendingPathComponent("Library/Application Support/yybar/hooks/yybar-hook.sh")
        let backups = root.appendingPathComponent("backup", isDirectory: true)
        let activity = home.appendingPathComponent("Library/Application Support/yybar/activity", isDirectory: true)

        func write(_ path: String, _ text: String) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func json(_ path: String) -> NSDictionary {
            let data = try! Data(contentsOf: home.appendingPathComponent(path))
            return try! JSONSerialization.jsonObject(with: data) as! NSDictionary
        }

        let claudeOriginal = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/mine.sh"}]}]}}"#
        let codexOriginal = #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"/other/bridge","timeout":5}]}]}}"#
        let agyOriginal = #"{"lint":{"PostToolUse":[{"matcher":"run_command","hooks":[{"command":"./lint.sh"}]}]}}"#
        try write(".claude/settings.json", claudeOriginal)
        try write(".codex/hooks.json", codexOriginal)
        try fm.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"), withIntermediateDirectories: true)
        try write(".gemini/config/hooks.json", agyOriginal)
        let claudeBefore = json(".claude/settings.json"), codexBefore = json(".codex/hooks.json"), agyBefore = json(".gemini/config/hooks.json")

        // 1. 安装两次：每个事件只有一条 yybar 的，用户原有的保留。
        _ = ActivityHooks.install(home: home, script: script, backups: backups)
        let report = ActivityHooks.install(home: home, script: script, backups: backups)
        precondition(report.failed.isEmpty, "install failed: \(report.failed)")
        precondition(Set(report.changed) == [.codex, .claude, .grok, .agy])
        precondition(Set(ActivityHooks.installedApps(home: home)) == [.codex, .claude, .grok, .agy])

        let claude = json(".claude/settings.json")
        precondition(claude["model"] as? String == "opus")
        let claudeHooks = claude["hooks"] as! [String: [[String: Any]]]
        precondition(claudeHooks["Stop"]!.count == 2)
        precondition((claudeHooks["Stop"]![0]["hooks"] as! [[String: Any]])[0]["command"] as? String == "~/mine.sh")
        precondition(claudeHooks["Notification"]!.count == 2)
        let stopCommand = (claudeHooks["Stop"]![1]["hooks"] as! [[String: Any]])[0]["command"] as! String
        precondition(stopCommand.hasSuffix(" claude idle") && stopCommand.contains(ActivityHooks.marker))
        precondition((json(".codex/hooks.json")["hooks"] as! [String: [Any]])["PreToolUse"]!.count == 2)
        let agy = json(".gemini/config/hooks.json")
        precondition(agy["lint"] != nil)
        let agySpec = agy[ActivityHooks.agyHookName] as! [String: [[String: Any]]]
        precondition(agySpec["Stop"]![0]["command"] != nil, "agy Stop must be flat")
        precondition(agySpec["PostToolUse"]![0]["matcher"] as? String == "*")
        precondition(fm.fileExists(atPath: home.appendingPathComponent(".grok/hooks/yybar.json").path))
        let backupCount = try fm.contentsOfDirectory(atPath: backups.path).count
        precondition(backupCount >= 3)

        // 2. 脚本：按会话写状态文件，不输出(agy 输出 {});Grok 跑到 Claude 的条目时跳过;end 删文件。
        func run(_ args: [String], stdin: String, env: [String: String] = [:]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path] + args
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"].merging(env) { $1 }
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        func state(_ name: String) -> String? {
            (try? String(contentsOf: activity.appendingPathComponent(name), encoding: .utf8))?.split(separator: " ").first.map(String.init)
        }
        let payload = #"{"session_id":"abc-123","transcript_path":"/x","tool_input":{"note":"\"session_id\":\"evil\""}}"#
        let silent = try run(["claude", "busy"], stdin: payload)
        precondition(silent == "")
        precondition(state("claude.abc-123") == "busy")
        _ = try run(["claude", "waiting"], stdin: payload)
        precondition(state("claude.abc-123") == "waiting")
        _ = try run(["claude", "busy"], stdin: #"{"sessionId":"g-1"}"#, env: ["GROK_HOOK_NAME": "user:stop[0]"])
        precondition(state("claude.g-1") == nil)
        _ = try run(["grok", "busy"], stdin: #"{"hookEventName":"pre_tool_use","sessionId":"g-1"}"#, env: ["GROK_HOOK_NAME": "x"])
        precondition(state("grok.g-1") == "busy")
        let agyOutput = try run(["agy", "busy"], stdin: #"{"conversationId":"c/../9"}"#)
        precondition(agyOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
        precondition(state("agy.c9") == "busy")
        _ = try run(["claude", "end"], stdin: payload)
        precondition(state("claude.abc-123") == nil)
        _ = try run(["claude", "rm -rf"], stdin: payload)
        precondition(state("claude.abc-123") == nil)
        let leftovers = try fm.contentsOfDirectory(atPath: activity.path).filter { $0.hasPrefix(".") }
        precondition(leftovers.isEmpty, "temp files left: \(leftovers)")

        // 3. 卸载：恢复原样，Grok 文件删掉，状态文件清空。
        let removed = ActivityHooks.uninstall(home: home, backups: backups, activity: activity)
        precondition(removed.failed.isEmpty && Set(removed.changed) == [.codex, .claude, .grok, .agy])
        precondition(json(".claude/settings.json") == claudeBefore)
        precondition(json(".codex/hooks.json") == codexBefore)
        precondition(json(".gemini/config/hooks.json") == agyBefore)
        precondition(!fm.fileExists(atPath: home.appendingPathComponent(".grok/hooks/yybar.json").path))
        precondition(ActivityHooks.installedApps(home: home).isEmpty)
        let remaining = try fm.contentsOfDirectory(atPath: activity.path)
        precondition(remaining.isEmpty)

        // 4. 配置不是 JSON:不改、报错;没装的 CLI 跳过。
        try write(".claude/settings.json", "{ not json")
        try fm.removeItem(at: home.appendingPathComponent(".grok"))
        let broken = ActivityHooks.install(home: home, script: script, backups: backups)
        precondition(broken.failed.map(\.app) == [.claude] && broken.skipped == [.grok])
        let untouched = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        precondition(untouched == "{ not json")

        print("ActivityHooksRegression OK")
    }
}
