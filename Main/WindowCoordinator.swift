import AppKit
import SwiftUI

// MARK: - WindowCoordinator
//
// 主窗口与引导窗口用 AppKit NSWindow + NSHostingController 托管，
// 这样菜单栏图标(StatusItemController)、快捷键、引导页都能直接打开，不依赖 SwiftUI 的 openWindow。
// 主窗口关闭后释放整个窗口和视图(统计页常驻要多占 50~100 MB,菜单栏 App 大部分时间窗口是关着的);
// 再次打开时重建，定位到关窗前所在的部分，统计页的时间范围、筛选、排序等选择由 StatsSelections 恢复。

final class WindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = WindowCoordinator()

    /// 主窗口第一次打开(还没记住位置)时的大小，放在主屏中央;屏幕小时不超过可见区域的 85%。
    /// 2026-10-29 前按内容撑开、再退回 1240 × 780,13 寸屏上一打开就差不多占满整个屏幕。
    private static let defaultMainSize = NSSize(width: 960, height: 640)

    private var appState: AppState?
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func attach(appState: AppState) {
        self.appState = appState
    }

    /// 打开主窗口;传入 tab 时定位到该部分(统计 / 设置大页里滚动到对应位置)。
    func showMain(_ tab: MainTab?) {
        guard let appState else { return }
        if let tab { appState.select(tab) }
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainWindowRootView().environment(appState))
            hosting.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "yybar"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // 由 mainWindow 持有、关闭后在 windowWillClose 里放掉，不让 AppKit 在关闭时提前释放。
            window.isReleasedWhenClosed = false
            window.delegate = self
            let toggle = NSHostingView(rootView: SidebarToggleButton().environment(appState))
            toggle.frame = NSRect(x: 0, y: 0, width: 36, height: 28)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = toggle
            accessory.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessory)
            if !window.setFrameUsingName("yybar.main"), let screen = NSScreen.main ?? NSScreen.screens.first {
                Self.center(window, on: screen)
            }
            window.setFrameAutosaveName("yybar.main")
            mainWindow = window
        }
        if let mainWindow {
            Self.ensureOnScreen(mainWindow)
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
    }

    /// 窗口大半不在任何屏幕的可见区域内(如保存的位置在已断开的显示器上)时，放回主屏中央。
    private static func ensureOnScreen(_ window: NSWindow) {
        let frame = window.frame
        let visible = NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width * overlap.height >= frame.width * frame.height * 0.6
        }
        guard !visible || frame.width < 400, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        center(window, on: screen)
    }

    /// 按默认大小放在这块屏幕中央。
    private static func center(_ window: NSWindow, on screen: NSScreen) {
        let area = screen.visibleFrame
        let size = NSSize(width: min(defaultMainSize.width, area.width * 0.85),
                          height: min(defaultMainSize.height, area.height * 0.85))
        window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // 关闭动画走完后再放掉，窗口和 SwiftUI 视图随之释放。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mainWindow === window, !window.isVisible else { return }
            window.delegate = nil
            self.mainWindow = nil
        }
    }

    func showOnboarding() {
        guard let appState else { return }
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView().environment(appState))
            let window = NSWindow(contentViewController: hosting)
            window.title = tr("Welcome", "欢迎")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
        onboardingWindow?.orderFrontRegardless()
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }
}
