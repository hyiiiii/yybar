import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 全局状态。由 AppDelegate 持有，菜单栏图标、主窗口、悬浮窗共用。
    let appState: AppState

    override init() {
        // 旧版本的数据目录和设置要在 AppState 第一次读取之前搬好。
        LegacyDataMigration.run()
        appState = AppState()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        WindowCoordinator.shared.attach(appState: appState)
        StatusItemController.shared.attach(appState: appState)
        // 开机自动启动按 App 登记;开着这项但登记失效(新 bundle id 首次启动、换了位置等)时补登记。
        if SettingsStore.shared.launchAtLogin, SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        Task {
            await appState.bootstrap()
            FloatingPanelController.shared.attach(appState: appState)
            FloatingPanelController.shared.sync()
            // hook 脚本随 App 更新;开着「用 hook 驱动呼吸」时每次启动重写一遍。
            if SettingsStore.shared.activityHooksEnabled { try? ActivityHooks.writeScript() }
            UsageActivityMonitor.shared.start()
            if appState.shouldShowOnboarding {
                appState.shouldShowOnboarding = false
                WindowCoordinator.shared.showOnboarding()
            }
        }
    }

    /// Dock / Finder 再次打开 App 时，显示主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowCoordinator.shared.showMain(nil)
        return false
    }
}
