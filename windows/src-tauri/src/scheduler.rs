//! 后台循环（对应 Mac `Core/Scheduler.swift`）：
//! - 额度：按设置间隔（1 / 2 / 3 / 5 / 10 分钟，默认 2 分钟）；
//! - 本地日志扫描：按设置间隔（默认 2 分钟）；
//! - 官方服务状态：固定 5 分钟。
//! 改了间隔后立即按新间隔重启对应循环，不用重启 App。

use std::sync::Mutex;
use std::time::Duration;

use tauri::async_runtime::JoinHandle;
use tauri::{AppHandle, Manager};

use yybar_core::quota::RefreshReason;

use crate::app_state::{self, AppState};

const SERVICE_STATUS_INTERVAL: Duration = Duration::from_secs(5 * 60);

#[derive(Default)]
pub struct Scheduler {
    quota: Mutex<Option<(u64, JoinHandle<()>)>>,
    usage: Mutex<Option<(u64, JoinHandle<()>)>>,
    status: Mutex<Option<JoinHandle<()>>>,
}

impl Scheduler {
    pub fn start(&self, app: &AppHandle) {
        self.apply_intervals(app);
        let h = app.clone();
        *self.status.lock().unwrap() = Some(tauri::async_runtime::spawn(async move {
            loop {
                tokio::time::sleep(SERVICE_STATUS_INTERVAL).await;
                app_state::refresh_service_status(&h).await;
            }
        }));
    }

    /// 设置变化后调用：间隔变了才重启对应循环。
    pub fn apply_intervals(&self, app: &AppHandle) {
        let settings = app.state::<AppState>().settings();
        restart(&self.quota, settings.quota_interval_secs(), app, |h| async move {
            app_state::refresh_quotas(&h, RefreshReason::Periodic).await;
        });
        restart(&self.usage, settings.usage_interval_secs(), app, |h| async move {
            app_state::scan_usage(&h).await;
        });
    }
}

fn restart<F, Fut>(slot: &Mutex<Option<(u64, JoinHandle<()>)>>, secs: u64, app: &AppHandle, tick: F)
where
    F: Fn(AppHandle) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    let mut guard = slot.lock().unwrap();
    if guard.as_ref().is_some_and(|(s, _)| *s == secs) {
        return;
    }
    if let Some((_, handle)) = guard.take() {
        handle.abort();
    }
    let h = app.clone();
    let handle = tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(secs)).await;
            tick(h.clone()).await;
        }
    });
    *guard = Some((secs, handle));
}
