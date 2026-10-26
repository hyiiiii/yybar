//! 其他账号的流程编排（对应 Mac `AppState` 里 Extra / Imported 账号那几段）：
//! 添加（粘贴凭据 / 浏览器登录 / Google 在控制台里用 agy 登录）、刷新额度、改别名和开关、删除、切换本机 CLI 账号。
//! 凭据格式和文件读写在 core 的 `accounts`；这里管状态、事件和顺序。
//!
//! - 和本机 CLI 正在用的是同一个账号的其他账号（切换后留下的旧副本、或者手动添加了本机账号）不单独列出。
//! - 刷新：跟本机账号一起刷新；同一账号两次成功至少隔 60 秒（Google 100 秒），429 退避 10 分钟。
//! - 切换：先把目标账号的 token 续好，本机原来的账号存成其他账号（沿用目标账号的开关），再改写 CLI 的凭据文件；
//!   额度先沿用各自最近一次的结果，再立即刷新本机账号。已在运行的 CLI 会话要重启后才用新账号。

use std::collections::HashSet;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

use yybar_core::accounts::login::{LoginSession, LoginView, Phase};
use yybar_core::accounts::{self, paste, profile, switch, AccountError, Identified, OtherAccount, Provider};
use yybar_core::credentials::{self, SubscriptionRenewal};
use yybar_core::quota::{self, claude_refresh, codex_refresh, google, QuotaError, QuotaSnapshot, QuotaSource, RefreshReason, RefreshState};
use yybar_core::storage::quota_cache::QuotaCacheRecord;
use yybar_core::{now_secs, tr, UsageApp};

use crate::app_state::{self, AppState, Inner};

const MIN_SUCCESS_INTERVAL: i64 = 60;
const GOOGLE_MIN_PERIODIC_INTERVAL: i64 = 100;
const RATE_LIMIT_BACKOFF: i64 = 10 * 60;
/// 订阅等级 / 订阅开始日每 6 小时顺带更新一次。
const PROFILE_INTERVAL: i64 = 6 * 3600;

/// 设置页账号卡片下方的切换结果（8 秒后淡出）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SwitchNotice {
    pub seq: u64,
    pub text: String,
    pub is_error: bool,
    /// 什么时候切换的（界面只在 8 秒内显示，关窗再开不会重播旧的）
    pub at: i64,
}

/// 给界面的其他账号。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OtherAccountView {
    pub id: String,
    pub provider: Provider,
    pub app: UsageApp,
    /// 别名 > 邮箱 @ 前 > 服务名
    pub name: String,
    pub alias: String,
    pub email: Option<String>,
    pub plan: Option<String>,
    pub enabled: bool,
    pub show_in_tray: bool,
    pub show_in_floating: bool,
    pub quota: Option<QuotaSnapshot>,
    pub refresh: RefreshState,
    pub renewal: Option<SubscriptionRenewal>,
    /// 今日额度变化里的 key（周窗口加 #wk）；Google 账号两个池子各一个。
    pub history_keys: Vec<String>,
    /// 能把本机 CLI 切换到这个账号（Google 不行：不能切换本机 agy 的登录）
    pub switchable: bool,
}

pub fn history_key(id: &str) -> String {
    format!("other:{id}")
}

// ---------- 状态 ----------

impl Inner {
    /// 和本机 CLI 正在用的是同一个账号。
    pub fn mirrors_local(&self, a: &OtherAccount) -> bool {
        match a.provider {
            Provider::Codex => self.codex.as_ref().is_some_and(|c| {
                let local = match (c.account_id.as_deref(), c.chatgpt_user_id.as_deref().filter(|u| !u.is_empty())) {
                    (Some(acc), Some(user)) => format!("codex:{acc}:{user}"),
                    (Some(acc), None) => format!("codex:{acc}"),
                    _ => return false,
                };
                a.id == local || a.id.starts_with(&format!("{local}:"))
            }),
            Provider::Claude => match (self.claude.as_ref().and_then(|c| c.email.as_deref()), a.email.as_deref()) {
                (Some(l), Some(e)) => l.eq_ignore_ascii_case(e),
                _ => false,
            },
            Provider::Grok => self.grok.as_ref().is_some_and(|g| a.id == format!("grok:{}", g.identity)),
            Provider::Google => match (self.google_email.as_deref(), a.email.as_deref()) {
                (Some(l), Some(e)) => l.eq_ignore_ascii_case(e),
                _ => false,
            },
        }
    }

    /// 设置页、托盘、悬浮窗里列出来的其他账号（去掉和本机账号相同的）。
    pub fn listed_others(&self) -> Vec<&OtherAccount> {
        self.others.iter().filter(|a| !self.mirrors_local(a)).collect()
    }

    pub fn other_quota(&self, a: &OtherAccount) -> Option<QuotaSnapshot> {
        match a.provider {
            Provider::Google => QuotaSnapshot::antigravity(self.other_quotas.get(&a.id), self.other_quotas.get(&a.pool_key())),
            _ => self.other_quotas.get(&a.id).cloned(),
        }
    }

    /// 某服务里勾了「任务栏」（tray = true）或「悬浮窗」且启用的其他账号，按添加顺序。
    pub fn shown_others(&self, app: UsageApp, tray: bool) -> Vec<&OtherAccount> {
        self.listed_others()
            .into_iter()
            .filter(|a| a.provider.app() == app && a.enabled && if tray { a.show_in_tray } else { a.show_in_floating })
            .collect()
    }

    pub fn other_views(&self, now: i64) -> Vec<OtherAccountView> {
        self.listed_others()
            .into_iter()
            .map(|a| OtherAccountView {
                id: a.id.clone(),
                provider: a.provider,
                app: a.provider.app(),
                name: a.display_name(),
                alias: a.alias.clone(),
                email: a.email.clone(),
                plan: a.plan.clone(),
                enabled: a.enabled,
                show_in_tray: a.show_in_tray,
                show_in_floating: a.show_in_floating,
                quota: self.other_quota(a),
                refresh: self.other_refresh.get(&a.id).cloned().unwrap_or_default(),
                renewal: match a.provider {
                    Provider::Codex => SubscriptionRenewal::codex(a.subscription_active_until, now),
                    Provider::Claude => SubscriptionRenewal::monthly(a.subscription_started_at, now),
                    _ => None,
                },
                history_keys: match a.provider {
                    Provider::Google => vec![history_key(&a.id), history_key(&a.pool_key())],
                    _ => vec![history_key(&a.id)],
                },
                switchable: a.provider != Provider::Google,
            })
            .collect()
    }

    fn store_other(&mut self, key: &str, app: UsageApp, snapshot: QuotaSnapshot, source: QuotaSource) {
        let at = snapshot.fetched_at;
        if self.history.record(&history_key(key), app, &snapshot, at) {
            self.history.save();
        }
        self.cache.other.insert(key.to_string(), QuotaCacheRecord { snapshot: snapshot.clone(), source, updated_at: at });
        self.other_quotas.insert(key.to_string(), snapshot);
    }

    fn save_others(&self) {
        if let Err(e) = accounts::save_all(&self.others) {
            log::warn!("[其他账号] 写盘失败: {e}");
        }
    }

    /// 账号删掉后清掉它的额度、刷新状态和缓存。
    fn forget_other(&mut self, a: &OtherAccount) {
        for key in [a.id.clone(), a.pool_key()] {
            self.other_quotas.remove(&key);
            self.other_refresh.remove(&key);
            self.cache.other.remove(&key);
        }
        self.cache.save();
    }
}

// ---------- 刷新 ----------

/// 刷新所有启用的其他账号（并发）。
pub async fn refresh_all(app: &AppHandle, reason: RefreshReason) {
    let ids: Vec<String> = {
        let state = app.state::<AppState>();
        let g = state.inner.lock().unwrap();
        g.listed_others().into_iter().filter(|a| a.enabled).map(|a| a.id.clone()).collect()
    };
    let handles: Vec<_> = ids
        .into_iter()
        .map(|id| {
            let h = app.clone();
            tauri::async_runtime::spawn(async move { refresh_one(&h, &id, reason).await })
        })
        .collect();
    for h in handles {
        let _ = h.await;
    }
}

pub async fn refresh_one(app: &AppHandle, id: &str, reason: RefreshReason) {
    let state = app.state::<AppState>();
    let account = {
        let mut g = state.inner.lock().unwrap();
        let Some(account) = g.others.iter().find(|a| a.id == id).cloned() else { return };
        let now = now_secs();
        let st = g.other_refresh.entry(id.to_string()).or_default();
        if st.in_flight || st.backoff_until.is_some_and(|u| u > now) {
            return;
        }
        if reason == RefreshReason::Periodic {
            if st.last_success_at.is_some_and(|t| now - t < MIN_SUCCESS_INTERVAL) {
                return;
            }
            if account.provider == Provider::Google && st.last_attempt_at.is_some_and(|t| now - t < GOOGLE_MIN_PERIODIC_INTERVAL) {
                return;
            }
        }
        st.in_flight = true;
        st.last_attempt_at = Some(now);
        account
    };
    app_state::publish(app);
    let profile_due = {
        let g = state.inner.lock().unwrap();
        g.other_profile_at.get(id).map_or(true, |t| now_secs() - t > PROFILE_INTERVAL)
    };
    let result = fetch(&account, profile_due).await;
    {
        let mut g = state.inner.lock().unwrap();
        let app_kind = account.provider.app();
        match result {
            Ok(fetched) => {
                let source = if account.provider == Provider::Google { QuotaSource::AgyCli } else { QuotaSource::Api };
                if let Some(s) = fetched.main {
                    g.store_other(&account.id, app_kind, s, source);
                }
                if let Some(s) = fetched.pool {
                    g.store_other(&account.pool_key(), app_kind, s, source);
                }
                g.cache.save();
                if fetched.profile_checked {
                    g.other_profile_at.insert(account.id.clone(), now_secs());
                }
                // 套餐、邮箱、续费日有变化就更新资料
                if let Some(a) = g.others.iter_mut().find(|a| a.id == account.id) {
                    let mut changed = false;
                    for (slot, value) in [(&mut a.plan, fetched.plan), (&mut a.email, fetched.email)] {
                        if let Some(v) = value.filter(|v| Some(v) != slot.as_ref()) {
                            *slot = Some(v);
                            changed = true;
                        }
                    }
                    if fetched.renewal_checked && a.subscription_active_until != fetched.active_until && a.provider == Provider::Codex {
                        a.subscription_active_until = fetched.active_until;
                        changed = true;
                    }
                    if fetched.profile_checked && a.provider == Provider::Claude && a.subscription_started_at != fetched.started_at {
                        a.subscription_started_at = fetched.started_at;
                        changed = true;
                    }
                    if changed {
                        g.save_others();
                    }
                }
                let st = g.other_refresh.entry(account.id.clone()).or_default();
                st.in_flight = false;
                st.last_error = None;
                st.backoff_until = None;
                st.last_success_at = Some(now_secs());
                st.source = Some(source);
            }
            Err(e) => {
                let st = g.other_refresh.entry(account.id.clone()).or_default();
                st.in_flight = false;
                st.last_error = Some(error_message(&e, app_kind));
                if e.is_rate_limited() {
                    st.backoff_until = Some(now_secs() + RATE_LIMIT_BACKOFF);
                }
            }
        }
    }
    app_state::publish(app);
}

/// 其他账号登录失效时提示重新添加（不是在终端里登录本机 CLI）。
fn error_message(e: &QuotaError, app: UsageApp) -> String {
    match e {
        QuotaError::MissingToken | QuotaError::TokenRevoked | QuotaError::TokenRefreshFailed(_) => {
            tr("This account's sign-in has expired; add it again.", "这个账号的登录已失效，请重新添加")
        }
        e if e.is_auth_failure() => tr("This account's sign-in has expired; add it again.", "这个账号的登录已失效，请重新添加"),
        e => e.message(app),
    }
}

#[derive(Default)]
struct Fetched {
    main: Option<QuotaSnapshot>,
    /// Google 账号的 Antigravity（Claude·GPT）池
    pool: Option<QuotaSnapshot>,
    plan: Option<String>,
    email: Option<String>,
    profile_checked: bool,
    started_at: Option<i64>,
    renewal_checked: bool,
    active_until: Option<i64>,
}

async fn fetch(a: &OtherAccount, profile_due: bool) -> Result<Fetched, QuotaError> {
    let path = a.credential_path();
    match a.provider {
        Provider::Codex => {
            let mut acc = credentials::read_json(&path)
                .and_then(|v| credentials::codex::parse(&v, path.clone()))
                .ok_or(QuotaError::MissingToken)?;
            let token = codex_refresh::ensure_fresh(&mut acc).await?;
            let snapshot = quota::codex::fetch(&token, acc.account_id.as_deref()).await?;
            // 续期后 id_token 换了，付费周期结束日可能跟着变
            let fresh = credentials::read_json(&path).and_then(|v| credentials::codex::parse(&v, path.clone())).unwrap_or(acc);
            Ok(Fetched {
                plan: fresh.plan_type.clone().or_else(|| snapshot.plan_type.clone()),
                main: Some(snapshot),
                renewal_checked: true,
                active_until: fresh.subscription_active_until,
                ..Default::default()
            })
        }
        Provider::Claude => {
            let mut acc = credentials::read_json(&path)
                .and_then(|v| credentials::claude::parse(&v, path.clone()))
                .ok_or(QuotaError::MissingToken)?;
            let mut token = claude_refresh::ensure_fresh(&mut acc).await?;
            let mut result = quota::claude::fetch(&token).await;
            if matches!(result, Err(QuotaError::Http(401, _))) && acc.refresh_token.is_some() {
                // token 被提前作废：当作过期，续一次再试
                acc.expires_at = Some(0);
                token = claude_refresh::ensure_fresh(&mut acc).await?;
                result = quota::claude::fetch(&token).await;
            }
            let snapshot = result?;
            let mut out = Fetched { main: Some(snapshot), ..Default::default() };
            if profile_due {
                if let Some(p) = profile::fetch(&token).await {
                    out.profile_checked = true;
                    out.plan = p.plan;
                    out.email = p.email;
                    out.started_at = p.subscription_started_at;
                }
            }
            Ok(out)
        }
        Provider::Grok => {
            let dir = a.dir();
            let load = || credentials::read_json(&path).and_then(|v| credentials::grok::parse(&v, path.clone())).ok_or(QuotaError::MissingToken);
            let mut acc = load()?;
            if acc.expires_at.is_some_and(|e| e - now_secs() < 300) {
                if !quota::grok::refresh_credentials_in(Some(&dir)).await {
                    return Err(QuotaError::TokenRefreshFailed("grok".into()));
                }
                acc = load()?;
            }
            let mut result = quota::grok::fetch(&acc).await;
            if matches!(result, Err(QuotaError::Http(401, _))) && quota::grok::refresh_credentials_in(Some(&dir)).await {
                acc = load()?;
                result = quota::grok::fetch(&acc).await;
            }
            let snapshot = result?;
            let plan = if profile_due { quota::grok::fetch_plan(&acc).await } else { None };
            Ok(Fetched { main: Some(snapshot), profile_checked: profile_due, plan, ..Default::default() })
        }
        Provider::Google => {
            let r = google::fetch_in(Some(&a.dir())).await?;
            if r.gemini.is_none() && r.third_party.is_none() {
                return Err(QuotaError::MissingToken);
            }
            Ok(Fetched { main: r.gemini, pool: r.third_party, plan: r.plan, ..Default::default() })
        }
    }
}

// ---------- 添加 ----------

/// 新账号加进列表（同一身份覆盖凭据，别名和开关沿用），立即刷一次额度。返回显示名。
fn finish_add(app: &AppHandle, provider: Provider, folder: String, id: Identified, plan: Option<String>) -> String {
    let state = app.state::<AppState>();
    let saved = {
        let mut g = state.inner.lock().unwrap();
        let account = OtherAccount {
            id: id.id,
            provider,
            alias: String::new(),
            email: id.email,
            plan: plan.or(id.plan),
            enabled: true,
            show_in_tray: false,
            show_in_floating: false,
            added_at: now_secs(),
            folder,
            subscription_started_at: id.subscription_started_at,
            subscription_active_until: id.subscription_active_until,
        };
        let saved = accounts::upsert(&mut g.others, account);
        g.save_others();
        if provider == Provider::Claude || provider == Provider::Grok {
            g.other_profile_at.insert(saved.id.clone(), now_secs());
        }
        saved
    };
    app_state::publish(app);
    let h = app.clone();
    let id = saved.id.clone();
    tauri::async_runtime::spawn(async move { refresh_one(&h, &id, RefreshReason::UserInitiated).await });
    saved.display_name()
}

/// 本机账号的身份，用来拦下「添加的就是本机账号」。
fn is_local(app: &AppHandle, provider: Provider, id: &Identified) -> bool {
    let state = app.state::<AppState>();
    let g = state.inner.lock().unwrap();
    let probe = OtherAccount {
        id: id.id.clone(),
        provider,
        alias: String::new(),
        email: id.email.clone(),
        plan: None,
        enabled: true,
        show_in_tray: false,
        show_in_floating: false,
        added_at: 0,
        folder: String::new(),
        subscription_started_at: None,
        subscription_active_until: None,
    };
    g.mirrors_local(&probe)
}

/// 账号目录里已经有了凭据（粘贴写入或 CLI 登录写入），认出账号并加进列表。失败时删掉目录。
async fn import_folder(app: &AppHandle, provider: Provider, folder: String) -> Result<String, AccountError> {
    let dir = accounts::provider_dir(provider).join(&folder);
    let result = identify_folder(provider, &dir).await;
    let (ident, plan) = match result {
        Ok(v) => v,
        Err(e) => {
            accounts::remove_dir(provider, &folder);
            return Err(e);
        }
    };
    if is_local(app, provider, &ident) {
        accounts::remove_dir(provider, &folder);
        return Err(AccountError::AlreadyLocal);
    }
    Ok(finish_add(app, provider, folder, ident, plan))
}

async fn identify_folder(provider: Provider, dir: &Path) -> Result<(Identified, Option<String>), AccountError> {
    match provider {
        Provider::Codex => Ok((accounts::identify_codex(dir)?, None)),
        Provider::Claude => {
            let creds = dir.join(".credentials.json");
            if !creds.is_file() {
                return Err(AccountError::msg(tr(
                    "Signed in, but couldn't read the new Claude credentials. Paste them instead.",
                    "已登录，但读不到新的 Claude 凭据，请改用粘贴凭据",
                )));
            }
            // 资料接口补齐邮箱、订阅；CLI 没写 oauthAccount 时替它写一份（邮箱从这里读）
            let token = credentials::read_json(&creds)
                .and_then(|v| credentials::claude::parse(&v, creds.clone()))
                .and_then(|a| a.access_token);
            let mut plan = None;
            if let Some(token) = token {
                if let Some(p) = profile::fetch(&token).await {
                    plan = p.plan.clone();
                    let existing = credentials::read_json(&dir.join(".claude.json")).and_then(|v| v.get("oauthAccount").cloned());
                    if existing.is_none() {
                        if let Some(oauth) = &p.oauth_account {
                            accounts::write_claude_oauth_account(dir, oauth)?;
                        }
                    }
                }
            }
            let mut ident = accounts::identify_claude(dir)?;
            ident.plan = ident.plan.or(plan.clone());
            Ok((ident, plan))
        }
        Provider::Grok => {
            let ident = accounts::identify_grok(dir)?;
            let path = dir.join("auth.json");
            let plan = match credentials::read_json(&path).and_then(|v| credentials::grok::parse(&v, path.clone())) {
                Some(acc) => quota::grok::fetch_plan(&acc).await,
                None => None,
            };
            Ok((ident, plan))
        }
        Provider::Google => Err(AccountError::msg("google")),
    }
}

/// 粘贴凭据添加。Codex 可以一次粘几个账号。返回显示名（几个时用顿号连起来）。
pub async fn add_pasted(app: &AppHandle, provider: Provider, text: &str) -> Result<String, String> {
    let roots: Vec<(Value, &str)> = match provider {
        Provider::Codex => paste::codex(text).map_err(|e| e.message())?.into_iter().map(|v| (v, "auth.json")).collect(),
        Provider::Claude => vec![(paste::claude(text).map_err(|e| e.message())?, ".credentials.json")],
        Provider::Grok => vec![(paste::grok(text).map_err(|e| e.message())?, "auth.json")],
        Provider::Google => return Err("Google accounts can't be pasted".into()),
    };
    let mut names = Vec::new();
    let mut last_error = None;
    for (root, file) in roots {
        let (folder, dir) = accounts::new_dir(provider).map_err(|e| e.to_string())?;
        let data = serde_json::to_vec_pretty(&root).map_err(|e| e.to_string())?;
        if let Err(e) = yybar_core::paths::write_atomic(&dir.join(file), &data) {
            accounts::remove_dir(provider, &folder);
            return Err(e.to_string());
        }
        match import_folder(app, provider, folder).await {
            Ok(name) => names.push(name),
            Err(e) => last_error = Some(e),
        }
    }
    if names.is_empty() {
        return Err(last_error.map(|e| e.message()).unwrap_or_default());
    }
    Ok(names.join("、"))
}

// ---------- 浏览器登录 ----------

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LoginResult {
    id: String,
    ok: bool,
    name: Option<String>,
    error: Option<String>,
}

/// 用官方 CLI 在新账号目录里登录。进度通过 `login` 事件推给界面，登录成功后自动添加并推 `login-result`。
pub async fn login_start(app: &AppHandle, provider: Provider) -> Result<LoginView, String> {
    let h = app.clone();
    let importing: Arc<std::sync::Mutex<HashSet<String>>> = Default::default();
    let on_change = Arc::new(move |view: LoginView| {
        let _ = h.emit("login", &view);
        if view.phase == (Phase::Exited { succeeded: true }) && importing.lock().unwrap().insert(view.id.clone()) {
            let h2 = h.clone();
            tauri::async_runtime::spawn(async move { import_login(&h2, &view.id).await });
        }
    });
    let session = LoginSession::start(provider, on_change).map_err(|e| e.message())?;
    let view = session.view();
    app.state::<AppState>().logins.lock().unwrap().insert(session.id.clone(), session);
    Ok(view)
}

async fn import_login(app: &AppHandle, id: &str) {
    let session = app.state::<AppState>().logins.lock().unwrap().remove(id);
    let Some(session) = session else { return };
    let result = import_folder(app, session.provider, session.folder.clone()).await;
    let payload = match result {
        Ok(name) => LoginResult { id: id.to_string(), ok: true, name: Some(name), error: None },
        Err(e) => LoginResult { id: id.to_string(), ok: false, name: None, error: Some(e.message()) },
    };
    let _ = app.emit("login-result", &payload);
}

pub async fn login_submit_code(app: &AppHandle, id: &str, code: &str) {
    let session = app.state::<AppState>().logins.lock().unwrap().get(id).cloned();
    if let Some(s) = session {
        s.submit_code(code).await;
    }
}

/// 取消（关掉添加窗口也会调用）：结束 CLI、删掉还没添加的目录。
pub fn login_cancel(app: &AppHandle, id: &str) {
    let session = app.state::<AppState>().logins.lock().unwrap().remove(id);
    if let Some(s) = session {
        s.cancel();
    }
}

// ---------- Google（Gemini · Antigravity） ----------

/// 新建目录并打开控制台窗口运行 agy 登录。返回目录名，登录完回来调 `google_login_finish`。
pub fn google_login_start() -> Result<String, String> {
    if !google::is_installed() {
        return Err(tr("agy CLI not found. Install Antigravity's agy first.", "没有找到 agy CLI，请先安装 Antigravity 的 agy"));
    }
    let (folder, dir) = accounts::new_dir(Provider::Google).map_err(|e| e.to_string())?;
    google::open_login_console(&dir).map_err(|e| {
        accounts::remove_dir(Provider::Google, &folder);
        e.to_string()
    })?;
    Ok(folder)
}

/// 重新打开控制台（用户把窗口关了）。
pub fn google_login_reopen(folder: &str) -> Result<(), String> {
    google::open_login_console(&accounts::provider_dir(Provider::Google).join(folder)).map_err(|e| e.to_string())
}

/// 控制台里登录完成后：跑一次 `/usage` 确认登录、读邮箱，加进列表。没登录成功时保留目录以便重试。
pub async fn google_login_finish(app: &AppHandle, folder: &str) -> Result<String, String> {
    let dir = accounts::provider_dir(Provider::Google).join(folder);
    let result = match google::fetch_in(Some(&dir)).await {
        Ok(r) if r.gemini.is_some() || r.third_party.is_some() => r,
        Ok(_) | Err(QuotaError::MissingToken) => {
            return Err(tr(
                "Not signed in yet. Finish signing in in the console window, then try again.",
                "还没有登录成功：请在控制台窗口里完成登录后再点「完成添加」",
            ))
        }
        Err(e) => return Err(e.message(UsageApp::Agy)),
    };
    let email = google::signed_in_email_in(&dir);
    let ident = Identified { id: format!("google:{}", email.as_deref().map(str::to_lowercase).unwrap_or_else(|| folder.to_string())), email, ..Default::default() };
    if is_local(app, Provider::Google, &ident) {
        return Err(tr("This is the Google account agy on this PC already uses.", "这就是本机 agy 正在使用的 Google 账号，不需要重复添加"));
    }
    let name = finish_add(app, Provider::Google, folder.to_string(), ident.clone(), result.plan.clone());
    let state = app.state::<AppState>();
    {
        let mut g = state.inner.lock().unwrap();
        let pool_key = format!("{}#3p", ident.id);
        if let Some(s) = result.gemini {
            g.store_other(&ident.id, UsageApp::Agy, s, QuotaSource::AgyCli);
        }
        if let Some(s) = result.third_party {
            g.store_other(&pool_key, UsageApp::Agy, s, QuotaSource::AgyCli);
        }
        g.cache.save();
        let st = g.other_refresh.entry(ident.id.clone()).or_default();
        st.last_success_at = Some(now_secs());
        st.source = Some(QuotaSource::AgyCli);
    }
    app_state::publish(app);
    Ok(name)
}

pub fn google_login_cancel(folder: &str) {
    accounts::remove_dir(Provider::Google, folder);
}

/// 启动时清掉没有账号用的目录（上次添加到一半退出留下的）。
pub fn cleanup_orphan_dirs(accounts_in_use: &[OtherAccount]) {
    let used: HashSet<(Provider, &str)> = accounts_in_use.iter().map(|a| (a.provider, a.folder.as_str())).collect();
    for provider in [Provider::Codex, Provider::Claude, Provider::Grok, Provider::Google] {
        let Ok(entries) = std::fs::read_dir(accounts::provider_dir(provider)) else { continue };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if e.path().is_dir() && !used.contains(&(provider, name.as_str())) {
                accounts::remove_dir(provider, &name);
            }
        }
    }
}

// ---------- 改开关 / 删除 ----------

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OtherPatch {
    pub alias: Option<String>,
    pub enabled: Option<bool>,
    pub show_in_tray: Option<bool>,
    pub show_in_floating: Option<bool>,
}

pub fn update(app: &AppHandle, id: &str, patch: OtherPatch) {
    let state = app.state::<AppState>();
    let turned_on = {
        let mut g = state.inner.lock().unwrap();
        let Some(a) = g.others.iter_mut().find(|a| a.id == id) else { return };
        let was = a.enabled;
        if let Some(v) = patch.alias {
            a.alias = v.trim().to_string();
        }
        if let Some(v) = patch.enabled {
            a.enabled = v;
        }
        if let Some(v) = patch.show_in_tray {
            a.show_in_tray = v;
        }
        if let Some(v) = patch.show_in_floating {
            a.show_in_floating = v;
        }
        let on = !was && a.enabled;
        g.save_others();
        on
    };
    app_state::publish(app);
    crate::windows::sync_floating(app);
    if turned_on {
        let h = app.clone();
        let id = id.to_string();
        tauri::async_runtime::spawn(async move { refresh_one(&h, &id, RefreshReason::UserInitiated).await });
    }
}

pub fn remove(app: &AppHandle, id: &str) {
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        if let Some(a) = accounts::remove(&mut g.others, id) {
            g.forget_other(&a);
        }
        g.save_others();
    }
    app_state::publish(app);
    crate::windows::sync_floating(app);
}

// ---------- 切换本机 CLI 账号 ----------

/// 把本机 CLI（Codex / Claude Code / Grok）切换到这个其他账号。
pub async fn switch_to(app: &AppHandle, id: &str) {
    let state = app.state::<AppState>();
    let target = {
        let mut g = state.inner.lock().unwrap();
        if g.switching.is_some() {
            return;
        }
        let Some(t) = g.others.iter().find(|a| a.id == id).cloned() else { return };
        g.switching = Some(id.to_string());
        t
    };
    app_state::publish(app);
    let service = target.provider.app();
    wait_while_refreshing(app, service, id).await;
    let label = target.email.clone().unwrap_or_else(|| target.display_name());
    let result = match target.provider {
        Provider::Codex => switch_codex(app, &target).await,
        Provider::Claude => switch_claude(app, &target).await,
        Provider::Grok => switch_grok(app, &target).await,
        Provider::Google => Err(AccountError::msg(tr("Google accounts can't switch agy's sign-in on this PC", "Google 账号不支持切换本机 agy 的登录"))),
    };
    let notice = match &result {
        Ok(()) => (
            tr(
                &format!("The {} CLI now uses {label}. Restart sessions that are already running.", service.display_name()),
                &format!("本机 {} CLI 已切换到 {label}。已在运行的会话需重启后生效。", service.display_name()),
            ),
            false,
        ),
        Err(e) => (format!("{}{}", tr("Couldn't switch: ", "切换失败："), e.message()), true),
    };
    {
        let mut g = state.inner.lock().unwrap();
        g.switching = None;
        let seq = g.switch_notice.as_ref().map_or(1, |n| n.seq + 1);
        g.switch_notice = Some(SwitchNotice { seq, text: notice.0, is_error: notice.1, at: now_secs() });
    }
    app_state::publish(app);
    crate::windows::sync_floating(app);
    if result.is_ok() {
        app_state::refresh_service(app, service).await;
    }
}

/// 等本机 / 目标账号正在进行的刷新结束（最多 5 秒），免得刷新写回的旧 token 盖掉刚切换的凭据。
async fn wait_while_refreshing(app: &AppHandle, service: UsageApp, id: &str) {
    for _ in 0..50 {
        let busy = {
            let state = app.state::<AppState>();
            let g = state.inner.lock().unwrap();
            g.refresh.get(&service).is_some_and(|s| s.in_flight) || g.other_refresh.get(id).is_some_and(|s| s.in_flight)
        };
        if !busy {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// 切换完成后的共同收尾：本机原来的账号存成其他账号（沿用目标账号的开关、额度沿用最近一次），
/// 目标账号从其他账号里拿掉、额度先当作本机账号的额度显示。
fn after_switch(app: &AppHandle, target: &OtherAccount, old_snapshot: Option<QuotaSnapshot>, saved_old: Option<(String, Identified, Option<String>)>) {
    let state = app.state::<AppState>();
    // 重读凭据：身份变了会清掉本机账号的旧额度，下面再用目标账号的额度顶上
    app_state::reload_credentials(app);
    let mut g = state.inner.lock().unwrap();
    let service = target.provider.app();
    if let Some((folder, ident, plan)) = saved_old {
        let account = OtherAccount {
            id: ident.id,
            provider: target.provider,
            alias: String::new(),
            email: ident.email,
            plan: ident.plan.or(plan),
            enabled: target.enabled,
            show_in_tray: target.show_in_tray,
            show_in_floating: target.show_in_floating,
            added_at: now_secs(),
            folder,
            subscription_started_at: ident.subscription_started_at,
            subscription_active_until: ident.subscription_active_until,
        };
        let saved = accounts::upsert(&mut g.others, account);
        if let Some(s) = old_snapshot {
            g.store_other(&saved.id, service, s, QuotaSource::Cache);
        }
    }
    let seed = g.other_quota(target);
    if let Some(a) = accounts::remove(&mut g.others, &target.id) {
        g.forget_other(&a);
    }
    g.save_others();
    if let Some(seed) = seed {
        g.seed_local_quota(service, seed);
    }
    g.cache.save();
}

async fn switch_codex(app: &AppHandle, target: &OtherAccount) -> Result<(), AccountError> {
    let path = target.credential_path();
    let mut acc = credentials::read_json(&path)
        .and_then(|v| credentials::codex::parse(&v, path.clone()))
        .ok_or_else(|| AccountError::msg(tr("Saved credentials not found; add the account again", "找不到这个账号保存的凭据，请重新添加")))?;
    // 临期先续期，交给 CLI 的是可用的
    codex_refresh::ensure_fresh(&mut acc)
        .await
        .map_err(|e| AccountError::msg(format!("{}（{e}）", tr("This account's sign-in has expired; add it again", "这个账号的登录已失效，请重新添加"))))?;
    let target_root = credentials::read_json(&path).ok_or_else(|| AccountError::msg("auth.json"))?;
    let local = local_path(app, UsageApp::Codex);
    let old_snapshot = local_quota(app, UsageApp::Codex);
    let old = switch::write_codex(&local, &target_root)?;
    let saved = match old {
        Some(old) => save_old(Provider::Codex, "auth.json", &old, None, |dir| accounts::identify_codex(dir))?,
        None => None,
    };
    after_switch(app, target, old_snapshot, keep_if_different(target, saved));
    Ok(())
}

async fn switch_claude(app: &AppHandle, target: &OtherAccount) -> Result<(), AccountError> {
    let dir = target.dir();
    let creds_path = dir.join(".credentials.json");
    let mut acc = credentials::read_json(&creds_path)
        .and_then(|v| credentials::claude::parse(&v, creds_path.clone()))
        .ok_or_else(|| AccountError::msg(tr("Saved credentials not found; add the account again", "找不到这个账号保存的凭据，请重新添加")))?;
    let token = claude_refresh::ensure_fresh(&mut acc)
        .await
        .map_err(|e| AccountError::msg(format!("{}（{e}）", tr("This account's sign-in has expired; add it again", "这个账号的登录已失效，请重新添加"))))?;
    let local_creds = local_path(app, UsageApp::Claude);
    let old_snapshot = local_quota(app, UsageApp::Claude);
    let local_config = credentials::claude::config_path_for(&local_creds);
    let local = switch::read_claude_local(&local_creds, &local_config);

    // 本机原来的账号（凭据 + oauthAccount）存成其他账号，切回时原样还原
    let local_email = local
        .oauth_account
        .as_ref()
        .and_then(|o| o.get("emailAddress"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| app.state::<AppState>().inner.lock().unwrap().claude.as_ref().and_then(|c| c.email.clone()));
    let local_oauth = local.credentials.as_ref().and_then(|c| c.get("claudeAiOauth")).cloned();
    let differs = match (local_email.as_deref(), target.email.as_deref()) {
        (Some(l), Some(t)) => !l.eq_ignore_ascii_case(t),
        _ => true,
    };
    let saved = match (&local_oauth, differs) {
        (Some(oauth), true) if oauth.get("accessToken").and_then(Value::as_str).is_some_and(|s| !s.is_empty()) => save_old(
            Provider::Claude,
            ".credentials.json",
            &json!({ "claudeAiOauth": oauth }),
            local.oauth_account.clone(),
            |dir| accounts::identify_claude(dir),
        )?,
        _ => None,
    };

    // 目标账号的 claudeAiOauth：用目录里的完整对象（scopes / subscriptionType 等），缺 scopes 时沿用本机的
    let mut oauth = credentials::read_json(&creds_path)
        .and_then(|v| v.get("claudeAiOauth").and_then(Value::as_object).cloned())
        .unwrap_or_default();
    oauth.insert("accessToken".into(), token.clone().into());
    if !oauth.contains_key("scopes") {
        if let Some(scopes) = local_oauth.as_ref().and_then(|o| o.get("scopes")) {
            oauth.insert("scopes".into(), scopes.clone());
        }
    }
    let mut oauth_account = credentials::read_json(&dir.join(".claude.json")).and_then(|v| v.get("oauthAccount").cloned());
    if oauth_account.is_none() || !oauth.contains_key("rateLimitTier") {
        if let Some(p) = profile::fetch(&token).await {
            if !oauth.contains_key("rateLimitTier") {
                if let Some(t) = p.rate_limit_tier {
                    oauth.insert("rateLimitTier".into(), t.into());
                }
            }
            oauth_account = oauth_account.or(p.oauth_account);
        }
    }
    if !oauth.contains_key("subscriptionType") {
        if let Some(plan) = &target.plan {
            oauth.insert("subscriptionType".into(), plan.clone().into());
        }
    }
    let oauth_account = oauth_account.or_else(|| target.email.as_ref().map(|e| json!({ "emailAddress": e })));
    switch::write_claude(&local_creds, &local_config, Value::Object(oauth), oauth_account)?;
    after_switch(app, target, old_snapshot, keep_if_different(target, saved));
    Ok(())
}

async fn switch_grok(app: &AppHandle, target: &OtherAccount) -> Result<(), AccountError> {
    let target_root = credentials::read_json(&target.credential_path())
        .ok_or_else(|| AccountError::msg(tr("Saved credentials not found; add the account again", "找不到这个账号保存的凭据，请重新添加")))?;
    let local = local_path(app, UsageApp::Grok);
    let old_snapshot = local_quota(app, UsageApp::Grok);
    let old = switch::write_grok(&local, &target_root)?;
    let saved = match old {
        Some(old) => save_old(Provider::Grok, "auth.json", &old, None, |dir| accounts::identify_grok(dir))?,
        None => None,
    };
    after_switch(app, target, old_snapshot, keep_if_different(target, saved));
    Ok(())
}

fn local_quota(app: &AppHandle, service: UsageApp) -> Option<QuotaSnapshot> {
    app.state::<AppState>().inner.lock().unwrap().quota(service)
}

/// 切走的本机账号和目标账号是同一个时不另存（丢掉目录）。
fn keep_if_different(target: &OtherAccount, saved: Option<(String, Identified, Option<String>)>) -> Option<(String, Identified, Option<String>)> {
    match saved {
        Some((folder, ident, _)) if ident.id == target.id => {
            accounts::remove_dir(target.provider, &folder);
            None
        }
        other => other,
    }
}

/// 本机 CLI 的凭据文件（本机找到的那份；WSL 里的账号也写回原处）。
fn local_path(app: &AppHandle, service: UsageApp) -> std::path::PathBuf {
    let state = app.state::<AppState>();
    let g = state.inner.lock().unwrap();
    match service {
        UsageApp::Codex => g.codex.as_ref().map(|a| a.path.clone()).unwrap_or_else(credentials::codex::auth_file),
        UsageApp::Claude => g.claude.as_ref().map(|a| a.path.clone()).unwrap_or_else(credentials::claude::credentials_file),
        _ => g.grok.as_ref().map(|a| a.path.clone()).unwrap_or_else(credentials::grok::auth_file),
    }
}

/// 把切走的本机账号凭据存进一个新的账号目录，认出身份。认不出来就不存（丢掉目录）。
fn save_old(
    provider: Provider,
    file: &str,
    root: &Value,
    claude_oauth_account: Option<Value>,
    identify: impl Fn(&Path) -> Result<Identified, AccountError>,
) -> Result<Option<(String, Identified, Option<String>)>, AccountError> {
    let (folder, dir) = accounts::new_dir(provider)?;
    let data = serde_json::to_vec_pretty(root).map_err(|e| AccountError::msg(e.to_string()))?;
    yybar_core::paths::write_atomic(&dir.join(file), &data)?;
    if let Some(oauth) = claude_oauth_account {
        accounts::write_claude_oauth_account(&dir, &oauth)?;
    }
    match identify(&dir) {
        Ok(ident) => Ok(Some((folder, ident, None))),
        Err(_) => {
            accounts::remove_dir(provider, &folder);
            Ok(None)
        }
    }
}
