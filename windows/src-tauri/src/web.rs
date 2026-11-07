//! bar 页的 yybar 网站账号：状态和流程（对应 Mac `YYBarWebAccount`）。格式、标签、请求在 core 的 `web`。
//!
//! - 连接：浏览器打开 `<网站>/connect?state=…`，授权后网站跳回 `yybar://connect?token=…&state=…`；
//!   Windows 把这个链接交给 yybar（安装时注册了 `yybar:` 协议；已经在运行时由单实例插件转给正在运行的那个）。
//!   state 对得上才收令牌；不是从这里发起的链接拒绝；已经连着、也没在等授权时多余的回调直接忽略。
//! - 一键上传：每天只能成功点一次，点过当天变灰；没传成功（断网等）可以再点。自动上传不占这一次。
//! - 自动上传（默认关）：每天 0:30 先扫一遍本地统计再传没标签的天；0:30 时电脑在睡眠或没开 yybar，
//!   之后第一次扫描完补传。一天只自动传一次，没传成功下次扫描完再试。
//! - 网站不再认令牌（401）时自动断开，提示重新连接；其他失败保留标签和设置，下次再传。
//! - 订阅（网站个人主页 @ 后面那一排）：随用量一起上传，每次上传（一键 / 自动，不管有没有新的天）都把当前的订阅
//!   整份交给网站；没传成功不影响用量上传，下次上传再传。

use std::time::Duration;

use chrono::{Local, NaiveDate, TimeZone, Timelike};
use serde::Serialize;
use tauri::async_runtime::JoinHandle;
use tauri::{AppHandle, Manager};
use tauri_plugin_opener::OpenerExt;

use yybar_core::usage::UsageBucket;
use yybar_core::web::{self as site, Ledger, Pending, Profile, WebError};
use yybar_core::{now_secs, tr};

use crate::app_state::{self, AppState};

/// 自动上传每天几点传（本地时间）。
const AUTO_UPLOAD_HOUR: u32 = 0;
const AUTO_UPLOAD_MINUTE: u32 = 30;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    #[default]
    Idle,
    /// 已打开浏览器，等网站跳回来
    WaitingForBrowser,
    Uploading,
}

#[derive(Default)]
pub struct WebState {
    token: Option<String>,
    pub profile: Option<Profile>,
    pub ledger: Ledger,
    pub phase: Phase,
    pending_state: Option<String>,
    message: Option<(String, bool)>,
    noon_task: Option<JoinHandle<()>>,
}

impl WebState {
    pub fn connected(&self) -> bool {
        self.token.is_some() && self.profile.is_some()
    }

    fn set_message(&mut self, text: impl Into<String>, error: bool) {
        self.message = Some((text.into(), error));
    }
}

/// 给界面的 bar 页上传卡片和侧边栏头像。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebView {
    pub site: &'static str,
    pub connected: bool,
    pub profile: Option<Profile>,
    pub phase: Phase,
    pub message: Option<String>,
    pub message_is_error: bool,
    pub pending: Pending,
    pub uploaded_days: usize,
    pub last_upload_at: Option<i64>,
    /// 今天已经成功点过一键上传（按钮变灰）
    pub used_manual_today: bool,
}

fn today() -> NaiveDate {
    Local::now().date_naive()
}

fn day_key(d: NaiveDate) -> String {
    d.format("%Y-%m-%d").to_string()
}

pub fn view(w: &WebState, buckets: &[UsageBucket]) -> WebView {
    let today = today();
    WebView {
        site: site::SITE,
        connected: w.connected(),
        profile: w.profile.clone(),
        phase: w.phase,
        message: w.message.as_ref().map(|m| m.0.clone()),
        message_is_error: w.message.as_ref().is_some_and(|m| m.1),
        pending: if w.connected() { site::pending(buckets, &w.ledger, today) } else { site::pending(buckets, &Ledger::default(), today) },
        uploaded_days: w.ledger.day_count(),
        last_upload_at: w.ledger.last_upload_at,
        used_manual_today: w.ledger.manual_upload_day.as_deref() == Some(day_key(today).as_str()),
    }
}

// ---------- 启动 / 连接 ----------

pub fn bootstrap(app: &AppHandle) {
    {
        let state = app.state::<AppState>();
        let mut w = state.web.lock().unwrap();
        if let Some((token, profile)) = site::load_account() {
            w.ledger = site::load_ledger(&profile.login);
            // 对一下网站上各天的量：bar 页「待上传」能算上本机量变多了的天
            let h = app.clone();
            let (t, login) = (token.clone(), profile.login.clone());
            tauri::async_runtime::spawn(async move { sync_uploaded(&h, &t, &login).await });
            w.token = Some(token);
            w.profile = Some(profile);
        }
    }
    schedule_noon(app);
}

/// 打开网站的授权页，等它跳回 yybar://connect。
pub fn connect(app: &AppHandle) {
    let state = site::random_state();
    {
        let s = app.state::<AppState>();
        let mut w = s.web.lock().unwrap();
        w.pending_state = Some(state.clone());
        w.phase = Phase::WaitingForBrowser;
        w.message = None;
    }
    app_state::publish(app);
    if let Err(e) = app.opener().open_url(site::connect_url(&state), None::<&str>) {
        let s = app.state::<AppState>();
        let mut w = s.web.lock().unwrap();
        w.phase = Phase::Idle;
        w.pending_state = None;
        w.set_message(format!("{}{e}", tr("Couldn't open the browser: ", "无法打开浏览器：")), true);
    }
    app_state::publish(app);
}

pub fn cancel_connect(app: &AppHandle) {
    {
        let s = app.state::<AppState>();
        let mut w = s.web.lock().unwrap();
        w.pending_state = None;
        if w.phase == Phase::WaitingForBrowser {
            w.phase = Phase::Idle;
        }
    }
    app_state::publish(app);
}

/// 收到 `yybar://` 链接（深链接）。是连接回调就处理，并打开主窗口的 bar 页。
pub fn handle_url(app: &AppHandle, url: &str) {
    let Some((token, state)) = site::parse_callback(url) else { return };
    let accepted = {
        let s = app.state::<AppState>();
        let mut w = s.web.lock().unwrap();
        if w.pending_state.is_none() && w.connected() {
            // 已经连着、这边也没在等授权：多点了一次授权页之类的旧链接，直接忽略
            None
        } else if token.is_empty() || w.pending_state.as_deref() != Some(state.as_str()) {
            w.set_message(
                tr(
                    "This link didn't come from the connect button here. Click \"Connect GitHub\" again.",
                    "这个链接不是从这里点「连接 GitHub」发起的，请重新连接。",
                ),
                true,
            );
            Some(false)
        } else {
            w.pending_state = None;
            Some(true)
        }
    };
    crate::windows::open_main(app, Some("bar"));
    app_state::publish(app);
    if accepted == Some(true) {
        let h = app.clone();
        tauri::async_runtime::spawn(async move { finish_connect(&h, token).await });
    }
}

async fn finish_connect(app: &AppHandle, token: String) {
    match site::whoami(&token).await {
        Ok(profile) => {
            let saved = site::save_account(&token, &profile);
            {
                let s = app.state::<AppState>();
                let mut w = s.web.lock().unwrap();
                w.phase = Phase::Idle;
                if let Err(e) = saved {
                    w.set_message(format!("{}{e}", tr("Couldn't save the sign-in: ", "保存登录失败：")), true);
                    return;
                }
                w.ledger = site::load_ledger(&profile.login);
                w.token = Some(token.clone());
                w.set_message(tr(&format!("Connected as @{}.", profile.login), &format!("已连接 @{}。", profile.login)), false);
                w.profile = Some(profile.clone());
            }
            app_state::publish(app);
            sync_uploaded(app, &token, &profile.login).await;
            schedule_noon(app);
            trigger_auto_upload(app);
        }
        Err(e) => {
            {
                let s = app.state::<AppState>();
                let mut w = s.web.lock().unwrap();
                w.phase = Phase::Idle;
                // 浏览器里授权成功、这里却连不上网站：多半是代理只对浏览器生效（浏览器插件、或代理软件没开「系统代理」）
                let hint = if matches!(e, WebError::Transport(_)) {
                    tr(
                        " If the browser could open the site, your proxy may only cover the browser: turn on the proxy app's system proxy (or TUN / global mode) and connect again.",
                        "。浏览器能打开网站这里却连不上时，多半是代理只对浏览器生效：在代理软件里打开「系统代理」（或 TUN / 全局模式）后再连接",
                    )
                } else {
                    String::new()
                };
                w.set_message(format!("{}{e}{hint}", tr("Couldn't connect: ", "连接失败：")), true);
            }
            app_state::publish(app);
        }
    }
}

/// 网站上已经传过的（日期, 服务）和它们的量补进本机标签（换了台电脑、重装过都不会再传一遍；别的电脑传的量更多，这里就不再传）。
async fn sync_uploaded(app: &AppHandle, token: &str, login: &str) {
    let Ok(pairs) = site::uploaded_pairs(token).await else { return };
    {
        let s = app.state::<AppState>();
        let mut w = s.web.lock().unwrap();
        for u in pairs {
            match u.sent {
                Some(sent) => w.ledger.record(&u.day, &u.app, sent),
                None => w.ledger.insert(&u.day, &u.app),
            }
        }
        site::save_ledger(login, &w.ledger);
    }
    app_state::publish(app);
}

/// 上传没成功：回到空闲并说明原因；网站不再认令牌就断开，让用户重新连接。
fn upload_failed(app: &AppHandle, e: WebError) {
    let s = app.state::<AppState>();
    if e == WebError::Unauthorized {
        disconnect(app);
        s.web.lock().unwrap().set_message(
            tr("The website no longer accepts this PC's token. Connect GitHub again.", "网站不再认这台电脑的授权了，请重新连接 GitHub。"),
            true,
        );
    } else {
        let mut w = s.web.lock().unwrap();
        w.phase = Phase::Idle;
        // 连不上（超时、被拒）多半是网络或代理：代理软件后开的现在不用重开 yybar（会按新代理重连），点一下重试就行
        let hint = if matches!(e, WebError::Transport(_)) {
            tr(
                " Check the network or proxy (turn on the proxy app's system proxy, or TUN / global mode), then try again.",
                "。请检查网络或代理（在代理软件里打开「系统代理」或 TUN / 全局模式）后再试一次",
            )
        } else {
            String::new()
        };
        w.set_message(format!("{}{e}{hint}", tr("Upload failed: ", "上传失败：")), true);
    }
    app_state::publish(app);
}

/// 断开：删掉本机的令牌（网站上的令牌可在「我的」页撤销）。本机的上传标签留着，下次连同一个账号还能用。
pub fn disconnect(app: &AppHandle) {
    {
        let s = app.state::<AppState>();
        let mut w = s.web.lock().unwrap();
        site::delete_account();
        w.token = None;
        w.profile = None;
        w.ledger = Ledger::default();
        w.phase = Phase::Idle;
        w.message = None;
    }
    schedule_noon(app);
    app_state::publish(app);
}

// ---------- 上传 ----------

/// 一键上传：每天只能成功点一次。
pub async fn upload_now(app: &AppHandle) {
    let used = {
        let s = app.state::<AppState>();
        let w = s.web.lock().unwrap();
        w.ledger.manual_upload_day.as_deref() == Some(day_key(today()).as_str())
    };
    if !used {
        upload(app, true).await;
    }
}

/// 本地统计扫描完调用：开着自动上传、过了今天 0:30 还没自动传过，就传。
pub fn usage_did_update(app: &AppHandle) {
    trigger_auto_upload(app);
}

fn auto_due(app: &AppHandle) -> bool {
    let s = app.state::<AppState>();
    if !s.settings().web_auto_upload || s.usage.lock().unwrap().last_scan_at.is_none() {
        return false;
    }
    let w = s.web.lock().unwrap();
    let now = Local::now();
    w.connected() && w.phase == Phase::Idle && (now.hour(), now.minute()) >= (AUTO_UPLOAD_HOUR, AUTO_UPLOAD_MINUTE) && w.ledger.auto_upload_day.as_deref() != Some(day_key(now.date_naive()).as_str())
}

fn trigger_auto_upload(app: &AppHandle) {
    if auto_due(app) {
        let h = app.clone();
        tauri::async_runtime::spawn(async move { upload(&h, false).await });
    }
}

async fn upload(app: &AppHandle, manual: bool) {
    let s = app.state::<AppState>();
    let today = today();
    let (token, login) = {
        let mut w = s.web.lock().unwrap();
        let (Some(token), Some(login)) = (w.token.clone(), w.profile.as_ref().map(|p| p.login.clone())) else { return };
        if w.phase != Phase::Idle {
            return;
        }
        w.phase = Phase::Uploading;
        // 上一次的结果（比如「上传失败」）不留到这次：不然转圈的时候还挂着旧的报错
        w.message = None;
        (token, login)
    };
    app_state::publish(app);
    // 订阅随用量一起传，不管有没有新的天；没传成功不影响用量。
    // 但连不上网站（超时、被拒）就直接报失败：后面几步一样连不上，每步都要等二三十秒
    let plans = s.inner.lock().unwrap().web_account_plans();
    if let Err(e @ WebError::Transport(_)) = site::put_accounts(&token, &plans).await {
        upload_failed(app, e);
        return;
    }
    // 先对一下网站上各天的量（别的电脑传过更多的就不用再传）
    sync_uploaded(app, &token, &login).await;
    let buckets = s.usage.lock().unwrap().buckets();
    let todo = {
        let mut w = s.web.lock().unwrap();
        let todo = site::pending(&buckets, &w.ledger, today);
        if todo.days.is_empty() {
            w.phase = Phase::Idle;
            if manual {
                w.set_message(tr("Nothing new to upload — every finished day is already in.", "没有新的天要传：今天以前的都传过了。"), false);
            } else {
                w.ledger.auto_upload_day = Some(day_key(today));
                site::save_ledger(&login, &w.ledger);
            }
            drop(w);
            app_state::publish(app);
            return;
        }
        todo
    };
    let days = site::build_days(&buckets, &todo);
    let local = site::local_totals(&buckets, today);
    let mut accepted = 0;
    let mut skipped = 0;
    for chunk in site::chunks(&days) {
        match site::upload_chunk(&token, chunk).await {
            Ok((a, sk)) => {
                accepted += a;
                skipped += sk;
                // 这一批传的（日期, 服务）不管是新收下的还是网站上早就有的，都打上标签、记下这次的量，量不再变多就不再传
                let mut w = s.web.lock().unwrap();
                for d in chunk {
                    for e in &d.entries {
                        match local.get(&format!("{}|{}", d.day, e.app)) {
                            Some(&sent) => w.ledger.record(&d.day, &e.app, sent),
                            None => w.ledger.insert(&d.day, &e.app),
                        }
                    }
                }
                w.ledger.last_upload_at = Some(now_secs());
                site::save_ledger(&login, &w.ledger);
            }
            Err(e) => {
                upload_failed(app, e);
                return;
            }
        }
    }
    {
        let mut w = s.web.lock().unwrap();
        // 一键上传每天只能成功点一次；自动上传每天传一次
        if manual {
            w.ledger.manual_upload_day = Some(day_key(today));
        } else {
            w.ledger.auto_upload_day = Some(day_key(today));
        }
        site::save_ledger(&login, &w.ledger);
        w.phase = Phase::Idle;
        let text = if skipped == 0 {
            tr(
                &format!("Uploaded {accepted} days · about {} chips.", todo.chips),
                &format!("已上传 {accepted} 天，约 {} 筹码。", todo.chips),
            )
        } else {
            tr(
                &format!("Uploaded {accepted} days; {skipped} were already on the website and didn't count again."),
                &format!("已上传 {accepted} 天；另有 {skipped} 天网站上已经有了，不再重复计入。"),
            )
        };
        w.set_message(text, false);
    }
    app_state::publish(app);
}

/// 开着自动上传时，每天 0:30 扫一遍本地统计（扫完 usage_did_update 就会传）。按墙上时间每分钟看一次，
/// 电脑睡眠跨过 0:30 时醒来马上补上。
pub fn schedule_noon(app: &AppHandle) {
    let s = app.state::<AppState>();
    let on = s.settings().web_auto_upload;
    let mut w = s.web.lock().unwrap();
    if let Some(task) = w.noon_task.take() {
        task.abort();
    }
    if !on || !w.connected() {
        return;
    }
    let h = app.clone();
    w.noon_task = Some(tauri::async_runtime::spawn(async move {
        loop {
            let now = Local::now();
            let next = next_noon(now);
            loop {
                let left = (next - Local::now()).num_seconds();
                if left <= 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_secs(left.clamp(1, 60) as u64)).await;
            }
            app_state::scan_usage(&h).await;
            trigger_auto_upload(&h);
        }
    }));
}

/// 下一个本地 0:30。
fn next_noon(now: chrono::DateTime<Local>) -> chrono::DateTime<Local> {
    let at = |d: NaiveDate| d.and_hms_opt(AUTO_UPLOAD_HOUR, AUTO_UPLOAD_MINUTE, 0).and_then(|t| Local.from_local_datetime(&t).earliest());
    match at(now.date_naive()) {
        Some(noon) if noon > now => noon,
        _ => at(now.date_naive() + chrono::Duration::days(1)).unwrap_or(now + chrono::Duration::hours(24)),
    }
}

/// 设置里切换了自动上传。
pub fn auto_upload_changed(app: &AppHandle) {
    schedule_noon(app);
    trigger_auto_upload(app);
}

