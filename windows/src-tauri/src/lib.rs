//! yybar for Windows 入口（对应 Mac `YYBarApp.swift` + `AppDelegate.swift`）：
//! 托盘常驻（不占任务栏按钮），组装弹出浮窗 / 主窗口 / 悬浮窗 / 引导窗口，启动后台刷新。

mod app_state;
mod commands;
mod scheduler;
mod tray;
mod tray_render;
mod windows;

use tauri::{AppHandle, Manager};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

use yybar_core::storage::settings::Settings;

use crate::app_state::AppState;
use crate::scheduler::Scheduler;
use crate::tray::TrayState;
use crate::windows::WindowState;

pub fn quit(app: &AppHandle) {
    app.state::<AppState>().inner.lock().unwrap().settings.save();
    app.exit(0);
}

pub fn run() {
    let settings = Settings::load();
    tauri::Builder::default()
        // 再次启动 yybar：打开主窗口
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| windows::open_main(app, None)))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_opener::init())
        .manage(AppState::new(settings))
        .manage(TrayState::default())
        .manage(WindowState::default())
        .manage(Scheduler::default())
        .invoke_handler(commands::handler())
        .setup(|app| {
            let handle = app.handle().clone();
            {
                let state = handle.state::<AppState>();
                state.inner.lock().unwrap().autostart = handle.autolaunch().is_enabled().unwrap_or(false);
            }
            windows::create_popover(&handle)?;
            tray::update(&handle);
            windows::sync_floating(&handle);
            if !handle.state::<AppState>().settings().did_complete_onboarding {
                windows::open_onboarding(&handle);
            }
            handle.state::<Scheduler>().start(&handle);
            let h = handle.clone();
            tauri::async_runtime::spawn(async move { app_state::bootstrap(&h).await });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building yybar")
        .run(|_app, event| {
            // 关掉所有窗口也不退出：托盘常驻
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = event {
                api.prevent_exit();
            }
        });
}
