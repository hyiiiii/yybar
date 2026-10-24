import CoreGraphics
import Foundation
import Observation
import ServiceManagement

enum QuotaIntervalChoice: String, CaseIterable, Identifiable {
    case m1
    case m2
    case m3
    case m5
    case m10

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .m1: return 60
        case .m2: return 2 * 60
        case .m3: return 3 * 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .m1: return "1 分钟"
        case .m2: return "2 分钟"
        case .m3: return "3 分钟"
        case .m5: return "5 分钟"
        case .m10: return "10 分钟"
        }
    }
}

enum UsageIntervalChoice: String, CaseIterable, Identifiable {
    case m1
    case m2
    case m3
    case m5
    case m10

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .m1: return 60
        case .m2: return 2 * 60
        case .m3: return 3 * 60
        case .m5: return 5 * 60
        case .m10: return 10 * 60
        }
    }

    var displayName: String {
        switch self {
        case .m1: return "1 分钟"
        case .m2: return "2 分钟"
        case .m3: return "3 分钟"
        case .m5: return "5 分钟"
        case .m10: return "10 分钟"
        }
    }
}

enum ResetTimeDisplay: String, CaseIterable, Identifiable {
    case relative
    case absolute

    var id: String { rawValue }
}

enum MenuBarWindowChoice: String, CaseIterable, Identifiable {
    case fiveHour
    case weekly
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveHour: return "5H 窗口"
        case .weekly: return "WK 窗口"
        case .both: return "两者都显示"
        }
    }
}

@Observable
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    // 账号
    var showCodex: Bool { didSet { defaults.set(showCodex, forKey: Keys.showCodex) } }
    var showGrok: Bool { didSet { defaults.set(showGrok, forKey: Keys.showGrok) } }
    var menuBarShowGrok: Bool { didSet { defaults.set(menuBarShowGrok, forKey: Keys.menuBarShowGrok) } }
    var showClaude: Bool { didSet { defaults.set(showClaude, forKey: Keys.showClaude) } }
    /// Grok Bot / Gemini / agy:没设置过时按本机是否装了对应 App / CLI 决定默认值(见 init)。
    var showGrokBot: Bool { didSet { defaults.set(showGrokBot, forKey: Keys.showGrokBot) } }
    var showGemini: Bool { didSet { defaults.set(showGemini, forKey: Keys.showGemini) } }
    var showAgy: Bool { didSet { defaults.set(showAgy, forKey: Keys.showAgy) } }
    /// 用户在设置里「删除」的本机账号:provider(codex/claude/grok)→ 账号身份。
    /// 只是不再在 yybar 里显示和刷新，不会退出本机 CLI;CLI 换成别的账号后身份不同，自动重新出现。
    var removedLocalAccounts: [String: String] { didSet { defaults.set(removedLocalAccounts, forKey: Keys.removedLocalAccounts) } }

    // 菜单栏
    var menuBarShowCodex: Bool { didSet { defaults.set(menuBarShowCodex, forKey: Keys.menuBarShowCodex) } }
    var menuBarShowClaude: Bool { didSet { defaults.set(menuBarShowClaude, forKey: Keys.menuBarShowClaude) } }
    var menuBarShowGrokBot: Bool { didSet { defaults.set(menuBarShowGrokBot, forKey: Keys.menuBarShowGrokBot) } }
    var menuBarShowGemini: Bool { didSet { defaults.set(menuBarShowGemini, forKey: Keys.menuBarShowGemini) } }
    var menuBarShowAgy: Bool { didSet { defaults.set(menuBarShowAgy, forKey: Keys.menuBarShowAgy) } }
    var menuBarWindow: MenuBarWindowChoice { didSet { defaults.set(menuBarWindow.rawValue, forKey: Keys.menuBarWindow) } }
    /// 服务正在消耗额度(本地会话日志近期有写入)时，菜单栏图标以识别色呼吸闪烁
    var menuBarBreatheWhenActive: Bool { didSet { defaults.set(menuBarBreatheWhenActive, forKey: Keys.menuBarBreatheWhenActive) } }
    /// CLI 等待审批(工具调用尚无结果)时，菜单栏图标保持识别色不变
    var menuBarHoldColorWhileWaiting: Bool { didSet { defaults.set(menuBarHoldColorWhileWaiting, forKey: Keys.menuBarHoldColorWhileWaiting) } }
    /// 用 CLI 的 hook 驱动呼吸(见 `ActivityHooks`)。只记用户的选择;真正的安装 / 卸载由设置页调用。
    var activityHooksEnabled: Bool { didSet { defaults.set(activityHooksEnabled, forKey: Keys.activityHooksEnabled) } }

    // 悬浮窗（占位，M8 接）
    var floatingEnabled: Bool { didSet { defaults.set(floatingEnabled, forKey: Keys.floatingEnabled) } }
    var floatingShowCodex: Bool { didSet { defaults.set(floatingShowCodex, forKey: Keys.floatingShowCodex) } }
    var floatingShowClaude: Bool { didSet { defaults.set(floatingShowClaude, forKey: Keys.floatingShowClaude) } }
    var floatingShowGrok: Bool { didSet { defaults.set(floatingShowGrok, forKey: Keys.floatingShowGrok) } }
    var floatingShowGrokBot: Bool { didSet { defaults.set(floatingShowGrokBot, forKey: Keys.floatingShowGrokBot) } }
    var floatingShowGemini: Bool { didSet { defaults.set(floatingShowGemini, forKey: Keys.floatingShowGemini) } }
    var floatingShowAgy: Bool { didSet { defaults.set(floatingShowAgy, forKey: Keys.floatingShowAgy) } }

    // 刷新
    var claudeCloudUsageEnabled: Bool { didSet { defaults.set(claudeCloudUsageEnabled, forKey: Keys.claudeCloudUsageEnabled) } }
    var quotaInterval: QuotaIntervalChoice { didSet { defaults.set(quotaInterval.rawValue, forKey: Keys.quotaInterval) } }
    var usageInterval: UsageIntervalChoice { didSet { defaults.set(usageInterval.rawValue, forKey: Keys.usageInterval) } }
    var resetTimeDisplay: ResetTimeDisplay { didSet { defaults.set(resetTimeDisplay.rawValue, forKey: Keys.resetTimeDisplay) } }

    /// 是否在 Popover 中显示 OpenAI / Anthropic 服务状态圆点
    var showServiceStatus: Bool { didSet { defaults.set(showServiceStatus, forKey: Keys.showServiceStatus) } }

    // 通用
    var appLanguage: AppLanguage { didSet { defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) } }

    /// 是否已经向用户解释过"接下来会出现 Keychain 授权弹窗"
    var didShowKeychainPrompt: Bool {
        didSet { defaults.set(didShowKeychainPrompt, forKey: Keys.didShowKeychainPrompt) }
    }

    /// 是否已经完成首次启动引导
    var didCompleteOnboarding: Bool {
        didSet { defaults.set(didCompleteOnboarding, forKey: Keys.didCompleteOnboarding) }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 账号
        showGrok = defaults.object(forKey: Keys.showGrok) as? Bool ?? true
        menuBarShowGrok = defaults.object(forKey: Keys.menuBarShowGrok) as? Bool ?? true
        showCodex = defaults.object(forKey: Keys.showCodex) as? Bool ?? true
        showClaude = defaults.object(forKey: Keys.showClaude) as? Bool ?? true
        showGrokBot = defaults.object(forKey: Keys.showGrokBot) as? Bool ?? GrokBotQuotaClient.isInstalled
        showGemini = defaults.object(forKey: Keys.showGemini) as? Bool ?? GoogleQuotaClient.isGeminiInstalled
        showAgy = defaults.object(forKey: Keys.showAgy) as? Bool ?? GoogleQuotaClient.isAgyInstalled
        removedLocalAccounts = defaults.dictionary(forKey: Keys.removedLocalAccounts) as? [String: String] ?? [:]
        // 菜单栏
        menuBarShowCodex = defaults.object(forKey: Keys.menuBarShowCodex) as? Bool ?? true
        menuBarShowClaude = defaults.object(forKey: Keys.menuBarShowClaude) as? Bool ?? true
        // 本机装了 Grok Bot 才默认放进菜单栏 / 悬浮窗。
        menuBarShowGrokBot = defaults.object(forKey: Keys.menuBarShowGrokBot) as? Bool ?? GrokBotQuotaClient.isInstalled
        menuBarShowGemini = defaults.object(forKey: Keys.menuBarShowGemini) as? Bool ?? true
        menuBarShowAgy = defaults.object(forKey: Keys.menuBarShowAgy) as? Bool ?? true
        let mbWindowRaw = defaults.string(forKey: Keys.menuBarWindow) ?? MenuBarWindowChoice.fiveHour.rawValue
        menuBarWindow = MenuBarWindowChoice(rawValue: mbWindowRaw) ?? .fiveHour
        menuBarBreatheWhenActive = defaults.object(forKey: Keys.menuBarBreatheWhenActive) as? Bool ?? true
        menuBarHoldColorWhileWaiting = defaults.object(forKey: Keys.menuBarHoldColorWhileWaiting) as? Bool ?? true
        activityHooksEnabled = defaults.object(forKey: Keys.activityHooksEnabled) as? Bool ?? false
        // 悬浮窗
        floatingEnabled = defaults.object(forKey: Keys.floatingEnabled) as? Bool ?? false
        floatingShowCodex = defaults.object(forKey: Keys.floatingShowCodex) as? Bool ?? true
        floatingShowClaude = defaults.object(forKey: Keys.floatingShowClaude) as? Bool ?? true
        floatingShowGrok = defaults.object(forKey: Keys.floatingShowGrok) as? Bool ?? true
        floatingShowGrokBot = defaults.object(forKey: Keys.floatingShowGrokBot) as? Bool ?? GrokBotQuotaClient.isInstalled
        floatingShowGemini = defaults.object(forKey: Keys.floatingShowGemini) as? Bool ?? true
        floatingShowAgy = defaults.object(forKey: Keys.floatingShowAgy) as? Bool ?? true
        // 刷新
        let qiRaw = defaults.string(forKey: Keys.quotaInterval) ?? QuotaIntervalChoice.m2.rawValue
        quotaInterval = QuotaIntervalChoice(rawValue: qiRaw) ?? .m2
        let uiRaw = defaults.string(forKey: Keys.usageInterval) ?? UsageIntervalChoice.m2.rawValue
        claudeCloudUsageEnabled = defaults.bool(forKey: Keys.claudeCloudUsageEnabled)
        usageInterval = UsageIntervalChoice(rawValue: uiRaw) ?? .m2
        let rtdRaw = defaults.string(forKey: Keys.resetTimeDisplay) ?? ResetTimeDisplay.relative.rawValue
        resetTimeDisplay = ResetTimeDisplay(rawValue: rtdRaw) ?? .relative
        showServiceStatus = defaults.object(forKey: Keys.showServiceStatus) as? Bool ?? true
        // 通用：launchAtLogin 以系统当前注册状态为准
        let langRaw = defaults.string(forKey: Keys.appLanguage) ?? AppLanguage.system.rawValue
        appLanguage = AppLanguage(rawValue: langRaw) ?? .system
        let stored = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        launchAtLogin = stored
        didShowKeychainPrompt = defaults.object(forKey: Keys.didShowKeychainPrompt) as? Bool ?? false
        didCompleteOnboarding = defaults.object(forKey: Keys.didCompleteOnboarding) as? Bool ?? false
    }

    /// 账号与菜单栏开关的合取，最终决定菜单栏该不该画该应用
    var effectiveMenuBarShowGrok: Bool { showGrok && menuBarShowGrok }
    var effectiveMenuBarShowCodex: Bool { showCodex && menuBarShowCodex }
    var effectiveMenuBarShowClaude: Bool { showClaude && menuBarShowClaude }
    var effectiveMenuBarShowGrokBot: Bool { showGrokBot && menuBarShowGrokBot }
    var effectiveMenuBarShowGemini: Bool { showGemini && menuBarShowGemini }
    var effectiveMenuBarShowAgy: Bool { showAgy && menuBarShowAgy }

    /// 悬浮窗的行可见性同样需要叠加全局「显示该应用」开关
    var effectiveFloatingShowCodex: Bool { showCodex && floatingShowCodex }
    var effectiveFloatingShowClaude: Bool { showClaude && floatingShowClaude }
    var effectiveFloatingShowGrok: Bool { showGrok && floatingShowGrok }
    var effectiveFloatingShowGrokBot: Bool { showGrokBot && floatingShowGrokBot }
    var effectiveFloatingShowGemini: Bool { showGemini && floatingShowGemini }
    var effectiveFloatingShowAgy: Bool { showAgy && floatingShowAgy }

    /// 按服务取「启用 / 菜单栏 / 悬浮窗」开关(已叠加启用开关)。
    func isEnabled(_ app: UsageApp) -> Bool {
        switch app {
        case .codex: return showCodex
        case .claude: return showClaude
        case .grok: return showGrok
        case .grokBot: return showGrokBot
        case .gemini: return showGemini
        case .agy: return showAgy
        }
    }

    func effectiveMenuBarShow(_ app: UsageApp) -> Bool {
        switch app {
        case .codex: return effectiveMenuBarShowCodex
        case .claude: return effectiveMenuBarShowClaude
        case .grok: return effectiveMenuBarShowGrok
        case .grokBot: return effectiveMenuBarShowGrokBot
        case .gemini: return effectiveMenuBarShowGemini
        case .agy: return effectiveMenuBarShowAgy
        }
    }

    func effectiveFloatingShow(_ app: UsageApp) -> Bool {
        switch app {
        case .codex: return effectiveFloatingShowCodex
        case .claude: return effectiveFloatingShowClaude
        case .grok: return effectiveFloatingShowGrok
        case .grokBot: return effectiveFloatingShowGrokBot
        case .gemini: return effectiveFloatingShowGemini
        case .agy: return effectiveFloatingShowAgy
        }
    }

    /// 把 `appLanguage` 解析为最终渲染语言。`.system` 看系统首选语言是否以 `zh` 开头。
    /// 不用 `Locale.current`:它返回的是 App 当前生效的本地化语言,工程未添加中文资源时会回退到开发语言 `en`,
    /// 导致即便系统设为中文也判定为英文。`Locale.preferredLanguages.first` 反映用户在系统设置中排首位的语言,
    /// 与 App 本地化无关,例如 `zh-Hans-CN` / `zh-Hant-TW`,前缀判断对简繁均成立。
    var resolvedLanguage: ResolvedLanguage {
        switch appLanguage {
        case .system:
            let code = Locale.preferredLanguages.first ?? "en"
            return code.hasPrefix("zh") ? .zh : .en
        case .zh: return .zh
        case .en: return .en
        }
    }

    // MARK: - Floating panel frame

    /// 悬浮窗 frame，nil 表示尚未拖动过；启动时由 controller 还原
    var floatingPanelFrame: CGRect? {
        get {
            guard
                let x = defaults.object(forKey: Keys.floatingFrameX) as? Double,
                let y = defaults.object(forKey: Keys.floatingFrameY) as? Double,
                let w = defaults.object(forKey: Keys.floatingFrameW) as? Double,
                let h = defaults.object(forKey: Keys.floatingFrameH) as? Double,
                w > 0, h > 0
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        set {
            if let r = newValue {
                defaults.set(Double(r.origin.x), forKey: Keys.floatingFrameX)
                defaults.set(Double(r.origin.y), forKey: Keys.floatingFrameY)
                defaults.set(Double(r.size.width), forKey: Keys.floatingFrameW)
                defaults.set(Double(r.size.height), forKey: Keys.floatingFrameH)
            } else {
                defaults.removeObject(forKey: Keys.floatingFrameX)
                defaults.removeObject(forKey: Keys.floatingFrameY)
                defaults.removeObject(forKey: Keys.floatingFrameW)
                defaults.removeObject(forKey: Keys.floatingFrameH)
            }
        }
    }

    // MARK: - Launch at login

    /// 当前系统记录的注册状态
    var launchAtLoginRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 切换开机自启；失败时抛出原始错误
    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        launchAtLogin = enabled
    }

    private enum Keys {
        static let showGrok = "yybar.settings.showGrok"
        static let menuBarShowGrok = "yybar.settings.menuBarShowGrok"
        static let showCodex = "yybar.settings.showCodex"
        static let showClaude = "yybar.settings.showClaude"
        static let showGrokBot = "yybar.settings.showGrokBot"
        static let showGemini = "yybar.settings.showGemini"
        static let showAgy = "yybar.settings.showAgy"
        static let menuBarShowGrokBot = "yybar.settings.menuBarShowGrokBot"
        static let menuBarShowGemini = "yybar.settings.menuBarShowGemini"
        static let menuBarShowAgy = "yybar.settings.menuBarShowAgy"
        static let floatingShowGrokBot = "yybar.settings.floatingShowGrokBot"
        static let floatingShowGemini = "yybar.settings.floatingShowGemini"
        static let floatingShowAgy = "yybar.settings.floatingShowAgy"
        static let removedLocalAccounts = "yybar.settings.removedLocalAccounts"
        static let menuBarShowCodex = "yybar.settings.menuBarShowCodex"
        static let menuBarShowClaude = "yybar.settings.menuBarShowClaude"
        static let menuBarWindow = "yybar.settings.menuBarWindow"
        static let menuBarBreatheWhenActive = "yybar.settings.menuBarBreatheWhenActive"
        static let menuBarHoldColorWhileWaiting = "yybar.settings.menuBarHoldColorWhileWaiting"
        static let activityHooksEnabled = "yybar.settings.activityHooksEnabled"
        static let floatingEnabled = "yybar.settings.floatingEnabled"
        static let floatingShowCodex = "yybar.settings.floatingShowCodex"
        static let floatingShowClaude = "yybar.settings.floatingShowClaude"
        static let floatingShowGrok = "yybar.settings.floatingShowGrok"
        static let quotaInterval = "yybar.settings.quotaInterval"
        static let claudeCloudUsageEnabled = "yybar.settings.claudeCloudUsageEnabled"
        static let usageInterval = "yybar.settings.usageInterval"
        static let resetTimeDisplay = "yybar.settings.resetTimeDisplay"
        static let showServiceStatus = "yybar.settings.showServiceStatus"
        static let launchAtLogin = "yybar.settings.launchAtLogin"
        static let appLanguage = "yybar.settings.appLanguage"
        static let didShowKeychainPrompt = "yybar.settings.didShowKeychainPrompt"
        static let didCompleteOnboarding = "yybar.settings.didCompleteOnboarding"
        static let floatingFrameX = "yybar.settings.floatingFrame.x"
        static let floatingFrameY = "yybar.settings.floatingFrame.y"
        static let floatingFrameW = "yybar.settings.floatingFrame.w"
        static let floatingFrameH = "yybar.settings.floatingFrame.h"
    }
}

// MARK: - 旧版本数据迁移

/// 旧版本(bundle id `com.nanvon.ccbar`、数据目录 `CCBar`、设置键 `ccbar.settings.*`)的数据，启动时一次性搬到 yybar 名下。
/// 必须在 `AppState` / `SettingsStore` 第一次读数据之前调用(见 `AppDelegate.init`)。
/// 目录用 rename 整体搬走，`account-tokens/`(0700 / 0600)等权限原样保留;新目录已存在时只补搬缺少的项。
/// 设置从旧 bundle id 的 UserDefaults 域复制，新域已有的键不覆盖;旧域保留不删。
enum LegacyDataMigration {
    nonisolated private static let legacyBundleId = "com.nanvon.ccbar"
    nonisolated private static let legacyDirectory = "CCBar"
    nonisolated private static let legacyKeyPrefix = "ccbar.settings."
    nonisolated private static let keyPrefix = "yybar.settings."
    nonisolated private static let doneKey = "yybar.legacyDefaultsMigrated"

    static func run() {
        let fm = FileManager.default
        for base in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            guard let root = fm.urls(for: base, in: .userDomainMask).first else { continue }
            moveDirectory(root.appendingPathComponent(legacyDirectory, isDirectory: true),
                          to: root.appendingPathComponent("yybar", isDirectory: true))
        }
        migrateDefaults()
    }

    private static func moveDirectory(_ old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        guard fm.fileExists(atPath: new.path) else {
            try? fm.moveItem(at: old, to: new)
            return
        }
        let items = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        for name in items where !fm.fileExists(atPath: new.appendingPathComponent(name).path) {
            try? fm.moveItem(at: old.appendingPathComponent(name), to: new.appendingPathComponent(name))
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: old)
        }
    }

    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        if let legacy = defaults.persistentDomain(forName: legacyBundleId) {
            for (key, value) in legacy {
                let newKey = key.hasPrefix(legacyKeyPrefix) ? keyPrefix + key.dropFirst(legacyKeyPrefix.count) : key
                if defaults.object(forKey: newKey) == nil {
                    defaults.set(value, forKey: newKey)
                }
            }
        }
        defaults.set(true, forKey: doneKey)
    }
}
