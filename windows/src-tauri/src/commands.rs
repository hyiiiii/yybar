//! 前端可调用的命令。
//! 会新建窗口（直接或间接）的命令都写成 async：Windows 上在同步命令里建 WebView2 窗口会卡死（见 windows.rs 文件头）。

use serde_json::Value;
use tauri::{AppHandle, Manager, WebviewWindow};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_opener::OpenerExt;

use yybar_core::accounts::login::LoginView;
use yybar_core::accounts::Provider;
use yybar_core::quota::RefreshReason;
use yybar_core::storage::settings::Settings;
use yybar_core::usage::pricing::ModelPrice;
use yybar_core::{l10n, paths, UsageApp};

use crate::accounts::{self, OtherPatch};
use crate::app_state::{self, AppState, StateSnapshot, UsagePayload};
use crate::scheduler::Scheduler;
use crate::windows::{self, WindowState};

pub fn handler() -> impl Fn(tauri::ipc::Invoke) -> bool + Send + Sync + 'static {
    tauri::generate_handler![
        get_state,
        get_usage,
        refresh_now,
        update_settings,
        set_autostart,
        set_custom_price,
        remove_local_account,
        restore_removed_accounts,
        add_account_paste,
        login_start,
        login_submit_code,
        login_cancel,
        google_login_start,
        google_login_reopen,
        google_login_finish,
        google_login_cancel,
        update_other_account,
        remove_other_account,
        switch_account,
        web_connect,
        web_cancel_connect,
        web_disconnect,
        web_upload_now,
        open_site,
        open_main,
        take_pending_tab,
        get_ui_state,
        set_ui_state,
        hide_popover,
        fit_popover,
        fit_floating,
        expand_floating,
        drag_floating,
        finish_onboarding,
        open_url,
        backdrop,
        quit
    ]
}

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> StateSnapshot {
    state.snapshot()
}

#[tauri::command]
fn get_usage(state: tauri::State<AppState>) -> UsagePayload {
    state.usage_payload()
}

#[tauri::command]
async fn refresh_now(app: AppHandle) {
    app_state::refresh_now(&app).await;
}

/// 合并前端传来的部分设置（只改传了的字段，悬浮窗位置等不会被旧值覆盖），并按变化做相应处理。
#[tauri::command]
async fn update_settings(app: AppHandle, patch: Value) -> Result<(), String> {
    let state = app.state::<AppState>();
    let (before, after) = {
        let mut g = state.inner.lock().unwrap();
        let before = g.settings.clone();
        let mut merged = serde_json::to_value(&before).map_err(|e| e.to_string())?;
        if let (Some(target), Some(src)) = (merged.as_object_mut(), patch.as_object()) {
            for (k, v) in src {
                target.insert(k.clone(), v.clone());
            }
        }
        let after: Settings = serde_json::from_value(merged).map_err(|e| e.to_string())?;
        g.settings = after.clone();
        g.settings.save();
        (before, after)
    };
    if before.app_language != after.app_language {
        l10n::set_chinese(after.resolved_chinese());
    }
    if before.quota_interval != after.quota_interval || before.usage_interval != after.usage_interval {
        app.state::<Scheduler>().apply_intervals(&app);
    }
    if before.floating_enabled != after.floating_enabled {
        windows::sync_floating(&app);
    }
    if before.text_size != after.text_size {
        windows::apply_text_size(&app);
    }
    if before.web_auto_upload != after.web_auto_upload {
        crate::web::auto_upload_changed(&app);
    }
    let newly_enabled = UsageApp::ALL.iter().any(|a| after.is_enabled(*a) && !before.is_enabled(*a));
    if newly_enabled {
        let h = app.clone();
        tauri::async_runtime::spawn(async move { app_state::refresh_quotas(&h, RefreshReason::UserInitiated).await });
    }
    if before.scan_wsl != after.scan_wsl {
        let h = app.clone();
        tauri::async_runtime::spawn(async move {
            {
                let state = h.state::<AppState>();
                let wsl = if state.settings().scan_wsl { paths::wsl_homes() } else { Vec::new() };
                state.inner.lock().unwrap().wsl = wsl;
            }
            app_state::start_activity_monitor(&h);
            app_state::scan_usage(&h).await;
            app_state::refresh_quotas(&h, RefreshReason::UserInitiated).await;
        });
    }
    app_state::publish(&app);
    Ok(())
}

#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> Result<bool, String> {
    let launcher = app.autolaunch();
    let result = if enabled { launcher.enable() } else { launcher.disable() };
    let now = launcher.is_enabled().unwrap_or(false);
    app.state::<AppState>().inner.lock().unwrap().autostart = now;
    app_state::publish(&app);
    result.map(|_| now).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_custom_price(app: AppHandle, key: String, price: Option<ModelPrice>) {
    app_state::set_custom_price(&app, &key, price);
}

#[tauri::command]
async fn remove_local_account(app: AppHandle, service: UsageApp) {
    app_state::remove_local_account(&app, service);
}

#[tauri::command]
async fn restore_removed_accounts(app: AppHandle) {
    app_state::restore_removed_accounts(&app);
}

// ---------- 其他账号（添加 / 登录 / 切换），流程见 accounts.rs ----------

/// 粘贴凭据添加账号，返回显示名。
#[tauri::command]
async fn add_account_paste(app: AppHandle, provider: Provider, text: String) -> Result<String, String> {
    accounts::add_pasted(&app, provider, &text).await
}

/// 用官方 CLI 在浏览器里登录；进度推 `login` 事件，成功后自动添加并推 `login-result`。
#[tauri::command]
async fn login_start(app: AppHandle, provider: Provider) -> Result<LoginView, String> {
    accounts::login_start(&app, provider).await
}

#[tauri::command]
async fn login_submit_code(app: AppHandle, id: String, code: String) {
    accounts::login_submit_code(&app, &id, &code).await;
}

#[tauri::command]
async fn login_cancel(app: AppHandle, id: String) {
    accounts::login_cancel(&app, &id);
}

/// Google：打开控制台窗口用 agy 登录，返回账号目录名。
#[tauri::command]
async fn google_login_start() -> Result<String, String> {
    accounts::google_login_start()
}

#[tauri::command]
async fn google_login_reopen(folder: String) -> Result<(), String> {
    accounts::google_login_reopen(&folder)
}

#[tauri::command]
async fn google_login_finish(app: AppHandle, folder: String) -> Result<String, String> {
    accounts::google_login_finish(&app, &folder).await
}

#[tauri::command]
async fn google_login_cancel(folder: String) {
    accounts::google_login_cancel(&folder);
}

#[tauri::command]
async fn update_other_account(app: AppHandle, id: String, patch: OtherPatch) {
    accounts::update(&app, &id, patch);
}

#[tauri::command]
async fn remove_other_account(app: AppHandle, id: String) {
    accounts::remove(&app, &id);
}

/// 把本机 CLI 切换到这个其他账号。
#[tauri::command]
async fn switch_account(app: AppHandle, id: String) {
    accounts::switch_to(&app, &id).await;
}

// ---------- bar：yybar 网站（见 web.rs） ----------

#[tauri::command]
async fn web_connect(app: AppHandle) {
    crate::web::connect(&app);
}

#[tauri::command]
async fn web_cancel_connect(app: AppHandle) {
    crate::web::cancel_connect(&app);
}

#[tauri::command]
async fn web_disconnect(app: AppHandle) {
    crate::web::disconnect(&app);
}

#[tauri::command]
async fn web_upload_now(app: AppHandle) {
    crate::web::upload_now(&app).await;
}

/// 用浏览器打开 yybar 网站（德州大厅）。
#[tauri::command]
fn open_site(app: AppHandle) -> Result<(), String> {
    app.opener().open_url(yybar_core::web::SITE, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
async fn open_main(app: AppHandle, tab: Option<String>) {
    windows::open_main(&app, tab.as_deref());
}

/// 主窗口加载后取「要打开哪个部分」（只取一次）。
#[tauri::command]
fn take_pending_tab(app: AppHandle) -> Option<String> {
    app.state::<WindowState>().pending_tab.lock().unwrap().take()
}

#[tauri::command]
fn get_ui_state(state: tauri::State<AppState>) -> Value {
    state.inner.lock().unwrap().ui_state.clone()
}

#[tauri::command]
fn set_ui_state(state: tauri::State<AppState>, value: Value) {
    state.inner.lock().unwrap().ui_state = value;
}

#[tauri::command]
fn hide_popover(app: AppHandle) {
    windows::hide_popover(&app);
}

#[tauri::command]
fn fit_popover(app: AppHandle, height: f64) {
    windows::fit_popover(&app, height);
}

#[tauri::command]
fn fit_floating(app: AppHandle, width: f64, height: f64) {
    windows::fit_floating(&app, width, height);
}

/// 在悬浮窗上按下并拖动：交给系统拖，松手后吸附 / 收起 / 展开。
#[tauri::command]
fn drag_floating(app: AppHandle) {
    windows::drag_floating(&app);
}

/// 点悬浮窗收起后的窄条：展开。
#[tauri::command]
fn expand_floating(app: AppHandle) {
    windows::expand_floating(&app);
}

/// 引导完成：记下来，关掉引导窗口，可直接打开统计。
#[tauri::command]
async fn finish_onboarding(app: AppHandle, open_stats: bool) {
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        g.settings.did_complete_onboarding = true;
        g.settings.save();
    }
    windows::close_onboarding(&app);
    if open_stats {
        windows::open_main(&app, Some("overview"));
    }
    app_state::publish(&app);
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://")) {
        return Err("unsupported url".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn backdrop(window: WebviewWindow) -> &'static str {
    windows::apply_backdrop(&window)
}

#[tauri::command]
fn quit(app: AppHandle) {
    crate::quit(&app);
}
