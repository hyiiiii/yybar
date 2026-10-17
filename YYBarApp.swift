import SwiftUI

// 菜单栏图标由 StatusItemController(AppKit NSStatusItem)负责：左键直接打开主窗口的统计概览，
// 右键弹出小菜单(打开统计 / 设置 / 立即刷新 / 退出)。主窗口和引导窗口由 WindowCoordinator 管理。
// 启动流程在 AppDelegate。这里只保留一个空的 Settings scene 承载全局快捷键。

@main
struct YYBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            AppCommands(appState: appDelegate.appState)
        }
    }
}

/// 主窗口 / 刷新 / 设置 的全局快捷键。⌘Q 由系统默认提供。
private struct AppCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(tr("Preferences…", "设置")) {
                WindowCoordinator.shared.showMain(.settings)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .windowList) {
            Button(tr("Statistics", "统计")) {
                WindowCoordinator.shared.showMain(.stats)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button(tr("Refresh now", "立即刷新")) {
                Task { await appState.refreshNow() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(tr("Show/Hide Sidebar", "显示 / 隐藏侧边栏")) {
                withAnimation(.easeInOut(duration: 0.2)) { appState.sidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}
