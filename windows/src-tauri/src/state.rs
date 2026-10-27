//! 全局状态与刷新调度。额度按设置的间隔刷新，本地日志每分钟增量扫一次。
//! 网络失败保留上次快照；429 后退避 10 分钟，手动刷新也遵守。

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tauri::{AppHandle, Emitter, Manager};

use crate::core::credentials;
use crate::core::model::{now_secs, App, ServiceView, Snapshot, UsageSummary};
use crate::core::paths;
use crate::core::quota::{self, QuotaError};
use crate::core::usage::Scanner;
use crate::settings::Settings;

const RATE_LIMIT_BACKOFF: i64 = 10 * 60;
const USAGE_INTERVAL: Duration = Duration::from_secs(60);

pub struct Inner {
    pub settings: Settings,
    pub services: Vec<ServiceView>,
    pub usage: UsageSummary,
    pub settings_dirty: bool,
}

#[derive(Clone)]
pub struct AppState(pub Arc<Mutex<Inner>>);

impl AppState {
    pub fn new(settings: Settings) -> AppState {
        let services = App::ALL
            .iter()
            .map(|a| ServiceView { app: Some(*a), enabled: is_enabled(&settings, *a), ..Default::default() })
            .collect();
        AppState(Arc::new(Mutex::new(Inner { settings, services, usage: UsageSummary::default(), settings_dirty: false })))
    }

    pub fn snapshot(&self) -> Snapshot {
        let g = self.0.lock().unwrap();
        Snapshot { services: g.services.clone(), usage: g.usage.clone(), settings: g.settings.clone() }
    }

    pub fn settings(&self) -> Settings {
        self.0.lock().unwrap().settings.clone()
    }

    /// 托盘和悬浮条用的那个数：所有启用服务里剩余最少的一档。
    pub fn tightest_remaining(&self) -> Option<f64> {
        let g = self.0.lock().unwrap();
        g.services
            .iter()
            .filter(|s| s.enabled)
            .filter_map(|s| s.quota.as_ref()?.tightest_remaining())
            .reduce(f64::min)
    }
}

pub fn is_enabled(settings: &Settings, app: App) -> bool {
    match app {
        App::Codex => settings.show_codex,
        App::Claude => settings.show_claude,
        App::Grok => settings.show_grok,
    }
}

fn index(app: App) -> usize {
    App::ALL.iter().position(|a| *a == app).unwrap()
}

/// 推送最新快照给所有窗口，并重画托盘图标。
pub fn publish(handle: &AppHandle) {
    let state = handle.state::<AppState>();
    let _ = handle.emit("snapshot", state.snapshot());
    crate::update_tray(handle);
}

pub fn spawn_loops(handle: AppHandle) {
    let h = handle.clone();
    tauri::async_runtime::spawn(async move {
        loop {
            refresh_quotas(&h, false).await;
            let secs = h.state::<AppState>().settings().quota_interval();
            tokio::time::sleep(Duration::from_secs(secs)).await;
        }
    });
    tauri::async_runtime::spawn(async move {
        let scanner = Arc::new(Mutex::new(None::<Scanner>));
        loop {
            scan_usage(&handle, scanner.clone()).await;
            tokio::time::sleep(USAGE_INTERVAL).await;
        }
    });
}

async fn scan_usage(handle: &AppHandle, scanner: Arc<Mutex<Option<Scanner>>>) {
    let state = handle.state::<AppState>().inner().clone();
    let include_wsl = state.settings().scan_wsl;
    {
        state.0.lock().unwrap().usage.scanning = true;
    }
    publish(handle);
    let result = tauri::async_runtime::spawn_blocking(move || {
        let mut slot = scanner.lock().unwrap();
        let s = slot.get_or_insert_with(Scanner::load);
        s.scan(&paths::home_roots(include_wsl));
        s.save();
        let mut summary = s.summary(chrono::Local::now().date_naive());
        summary.scanned_at = Some(now_secs());
        summary
    })
    .await;
    {
        let mut g = state.0.lock().unwrap();
        match result {
            Ok(summary) => g.usage = summary,
            Err(_) => g.usage.scanning = false,
        }
        if g.settings_dirty {
            g.settings.save();
            g.settings_dirty = false;
        }
    }
    publish(handle);
}

/// `manual` 只是语义标记：手动刷新同样遵守 429 退避。
pub async fn refresh_quotas(handle: &AppHandle, _manual: bool) {
    let state = handle.state::<AppState>().inner().clone();
    let settings = state.settings();
    let roots = paths::home_roots(settings.scan_wsl);
    let now = now_secs();

    let mut jobs = Vec::new();
    {
        let mut g = state.0.lock().unwrap();
        for app in App::ALL {
            let svc = &mut g.services[index(app)];
            svc.enabled = is_enabled(&settings, app);
            if !svc.enabled || svc.in_flight || svc.backoff_until.is_some_and(|t| t > now) {
                continue;
            }
            svc.in_flight = true;
            jobs.push(app);
        }
    }
    publish(handle);

    let tasks: Vec<_> = jobs
        .into_iter()
        .map(|app| {
            let roots = roots.clone();
            let state = state.clone();
            let handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                let result = fetch_one(app, &roots).await;
                apply_result(&state, app, result);
                publish(&handle);
            })
        })
        .collect();
    for t in tasks {
        let _ = t.await;
    }
}

enum FetchResult {
    NoCredential,
    Expired(Option<String>),
    Done(Option<String>, Result<crate::core::model::QuotaSnapshot, QuotaError>),
}

async fn fetch_one(app: App, roots: &[paths::HomeRoot]) -> FetchResult {
    match app {
        App::Claude => {
            let Some(c) = credentials::load_claude(roots) else { return FetchResult::NoCredential };
            if c.expires_at.is_some_and(|t| t < now_secs()) {
                return FetchResult::Expired(c.email.clone());
            }
            FetchResult::Done(c.email.clone(), quota::fetch_claude(&c).await)
        }
        App::Codex => {
            let Some(c) = credentials::load_codex(roots) else { return FetchResult::NoCredential };
            FetchResult::Done(c.email.clone(), quota::fetch_codex(&c).await)
        }
        App::Grok => {
            let Some(c) = credentials::load_grok(roots) else { return FetchResult::NoCredential };
            FetchResult::Done(c.email.clone(), quota::fetch_grok(&c).await)
        }
    }
}

fn apply_result(state: &AppState, app: App, result: FetchResult) {
    let mut g = state.0.lock().unwrap();
    let svc = &mut g.services[index(app)];
    svc.in_flight = false;
    match result {
        FetchResult::NoCredential => {
            svc.detected = false;
            svc.error = None;
        }
        FetchResult::Expired(email) => {
            svc.detected = true;
            svc.account = email.or(svc.account.take());
            svc.error = Some("Claude 登录已过期，在终端运行一次 claude 会自动续期".into());
        }
        FetchResult::Done(email, Ok(snap)) => {
            svc.detected = true;
            svc.account = email.or(svc.account.take());
            svc.quota = Some(snap);
            svc.error = None;
            svc.last_success_at = Some(now_secs());
            svc.backoff_until = None;
        }
        FetchResult::Done(email, Err(e)) => {
            // 失败保留上次快照
            svc.detected = true;
            svc.account = email.or(svc.account.take());
            if e.is_rate_limited() {
                svc.backoff_until = Some(now_secs() + RATE_LIMIT_BACKOFF);
            }
            svc.error = Some(e.user_message(app.display_name()));
        }
    }
}
