//! 全局状态 + 刷新协调（对应 Mac `Core/AppState.swift`）。
//!
//! - 启动：先读额度缓存、今日额度变化、用量汇总让界面立刻有数，再读凭据、启动调度器。
//! - 每次刷新（手动 / 定时）都先重读本机凭据：CLI 换了账号（身份变了）就清掉旧额度和缓存，避免「新账号 + 旧额度」。
//! - 同一服务两次成功之间至少 60 秒（定时触发不足就跳过）；429 后退避 10 分钟，手动刷新也遵守。
//! - 网络失败保留已有快照，只记错误。
//!
//! 锁只在同步代码里短暂持有，绝不跨 await。

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};

use yybar_core::accounts::{self as other_accounts, login::LoginSession, profile, OtherAccount, Provider};
use yybar_core::credentials::{self, ClaudeAccount, CodexAccount, GrokAccount, SubscriptionRenewal};
use yybar_core::paths::{self, HomeRoot};
use yybar_core::quota::status::{self as service_status, ServiceStatus};
use yybar_core::quota::{self, claude_refresh, codex_refresh, google, QuotaError, QuotaSnapshot, QuotaSource, RefreshReason, RefreshState};
use yybar_core::storage::quota_cache::{QuotaCache, QuotaCacheRecord};
use yybar_core::storage::quota_history::{keys as history_keys, QuotaHistory};
use yybar_core::storage::settings::{FloatingStyle, Settings};
use yybar_core::usage::activity::ActivityMonitor;
use yybar_core::usage::pricing::{self, ModelPrice};
use yybar_core::usage::service::{self as usage_service, Reprice, ScanRoots, UsageService};
use yybar_core::usage::UsageBucket;
use yybar_core::web::{self as site, AccountPlan};
use yybar_core::{l10n, now_secs, tr, UsageApp};

use crate::accounts::{self, OtherAccountView, SwitchNotice};
use crate::web::{self, WebState, WebView};

const MIN_SUCCESS_INTERVAL: i64 = 60;
const RATE_LIMIT_BACKOFF: i64 = 10 * 60;
/// agy 一次要跑 10~15 秒，定时刷新至少间隔 100 秒。
const GOOGLE_MIN_PERIODIC_INTERVAL: i64 = 100;

pub struct AppState {
    pub inner: Mutex<Inner>,
    pub usage: Mutex<UsageService>,
    pub activity: ActivityMonitor,
    /// 正在进行的浏览器登录（添加账号）
    pub logins: Mutex<HashMap<String, Arc<LoginSession>>>,
    /// bar 页的 yybar 网站账号（连接、上传）
    pub web: Mutex<WebState>,
    scan_lock: tokio::sync::Mutex<()>,
    refresh_lock: tokio::sync::Mutex<()>,
}

pub struct Inner {
    pub settings: Settings,
    pub codex: Option<CodexAccount>,
    pub claude: Option<ClaudeAccount>,
    pub grok: Option<GrokAccount>,
    pub codex_quota: Option<QuotaSnapshot>,
    pub claude_quota: Option<QuotaSnapshot>,
    pub grok_quota: Option<QuotaSnapshot>,
    /// agy 的 Gemini 池 / Claude·GPT 池
    pub agy_gemini: Option<QuotaSnapshot>,
    pub agy_third: Option<QuotaSnapshot>,
    pub refresh: HashMap<UsageApp, RefreshState>,
    pub grok_plan: Option<String>,
    grok_plan_at: Option<i64>,
    /// 本机 Claude 账号的资料接口结果（每 6 小时一次）：凭据里的 subscriptionType 是登录那一刻的，
    /// 订阅过期后还写着 pro，显示、上传订阅都以这里为准（只在内存里，不写回 CLI 的凭据）
    claude_profile: Option<LocalClaudeProfile>,
    pub google_email: Option<String>,
    pub google_plan: Option<String>,
    pub status: HashMap<UsageApp, ServiceStatus>,
    pub(crate) cache: QuotaCache,
    pub history: QuotaHistory,
    pub repricing: bool,
    /// 主窗口关闭后保留的界面选择（时间范围、筛选、排序……），只在内存里，退出后回到默认。
    pub ui_state: Value,
    pub autostart: bool,
    pub wsl: Vec<HomeRoot>,
    /// 上次扫描用到的其他 Codex 目录（目录, 是不是自动找到的），设置页列出来
    pub codex_dirs: Vec<(std::path::PathBuf, bool)>,
    /// 其他账号（设置 · 服务里「添加账号…」加进来的，见 accounts.rs）
    pub others: Vec<OtherAccount>,
    /// 其他账号的额度：键是账号 id；Google 账号的 Antigravity 池是 `id#3p`
    pub other_quotas: HashMap<String, QuotaSnapshot>,
    pub other_refresh: HashMap<String, RefreshState>,
    /// 其他账号上次更新订阅等级 / 订阅开始日的时间
    pub other_profile_at: HashMap<String, i64>,
    /// 正在把本机 CLI 切换到的账号 id（设置页该行转圈，其他行暂不可切换）
    pub switching: Option<String>,
    pub switch_notice: Option<SwitchNotice>,
}

// ---------- 给前端的快照 ----------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceView {
    pub app: UsageApp,
    pub enabled: bool,
    /// 本机找到了登录（agy：装了 CLI）
    pub detected: bool,
    /// 用户在设置里删除了这个本机账号
    pub removed: bool,
    pub email: Option<String>,
    pub plan: Option<String>,
    pub quota: Option<QuotaSnapshot>,
    pub refresh: RefreshState,
    pub status: Option<ServiceStatus>,
    pub renewal: Option<SubscriptionRenewal>,
    /// 凭据位置（引导页显示）
    pub source: Option<String>,
    /// 今日额度变化里这个账号的 key（周窗口再加 `#wk`）；Antigravity 两个池子分别是 agy:gemini / agy:3p。
    pub history_keys: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityView {
    pub active: Vec<UsageApp>,
    pub waiting: Vec<UsageApp>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageMeta {
    pub version: u64,
    pub last_scan_at: Option<i64>,
    pub scanning: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PricesView {
    pub builtin: HashMap<String, ModelPrice>,
    pub custom: HashMap<String, ModelPrice>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateSnapshot {
    pub services: Vec<ServiceView>,
    pub settings: Settings,
    pub chinese: bool,
    pub activity: ActivityView,
    pub history: QuotaHistory,
    pub usage: UsageMeta,
    pub prices: PricesView,
    pub repricing: bool,
    pub autostart: bool,
    pub agy_installed: bool,
    pub version: String,
    pub others: Vec<OtherAccountView>,
    pub switching: Option<String>,
    pub switch_notice: Option<SwitchNotice>,
    /// 本机装了哪些官方 CLI（添加账号时「在浏览器中登录」要用）
    pub clis: CliPresence,
    /// bar 页：yybar 网站账号和待上传
    pub web: WebView,
    /// 统计到的其他 Codex 目录
    pub codex_dirs: Vec<CodexDirView>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexDirView {
    pub path: String,
    /// 自动找到的（家目录下的 .codex-*、环境变量 CODEX_HOME），设置里不能删
    pub auto: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliPresence {
    pub codex: bool,
    pub claude: bool,
    pub grok: bool,
    pub agy: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsagePayload {
    pub version: u64,
    pub buckets: Vec<UsageBucket>,
}

impl AppState {
    pub fn new(settings: Settings) -> AppState {
        l10n::set_chinese(settings.resolved_chinese());
        let now = now_secs();
        let cache = QuotaCache::load();
        let mut refresh: HashMap<UsageApp, RefreshState> = HashMap::new();
        let mut from_cache = |record: &Option<QuotaCacheRecord>, app: UsageApp| -> Option<QuotaSnapshot> {
            let r = record.as_ref()?;
            refresh.insert(app, RefreshState { last_success_at: Some(r.updated_at), source: Some(QuotaSource::Cache), ..Default::default() });
            Some(r.snapshot.clone())
        };
        let codex_quota = from_cache(&cache.codex, UsageApp::Codex);
        let claude_quota = from_cache(&cache.claude, UsageApp::Claude);
        let grok_quota = from_cache(&cache.grok, UsageApp::Grok);
        let agy_gemini = from_cache(&cache.gemini, UsageApp::Agy);
        let agy_third = cache.agy.as_ref().map(|r| r.snapshot.clone());
        if agy_gemini.is_none() {
            from_cache(&cache.agy, UsageApp::Agy);
        }
        let mut others = other_accounts::load_all();
        let mut settings = settings;
        if !settings.floating_follows_checks {
            // 悬浮窗改成跟着勾选走（2026-10-29）：以前总开关关着的，悬浮窗勾选都清掉，免得一升级悬浮窗就冒出来
            if !settings.floating_enabled {
                settings.floating_show_codex = false;
                settings.floating_show_claude = false;
                settings.floating_show_grok = false;
                settings.floating_show_agy = false;
                if others.iter().any(|o| o.show_in_floating) {
                    others.iter_mut().for_each(|o| o.show_in_floating = false);
                    let _ = other_accounts::save_all(&others);
                }
            }
            settings.floating_follows_checks = true;
            settings.save();
        }
        let other_quotas: HashMap<String, QuotaSnapshot> = cache.other.iter().map(|(k, r)| (k.clone(), r.snapshot.clone())).collect();
        let other_refresh: HashMap<String, RefreshState> = cache
            .other
            .iter()
            .map(|(k, r)| (k.clone(), RefreshState { last_success_at: Some(r.updated_at), source: Some(QuotaSource::Cache), ..Default::default() }))
            .collect();
        AppState {
            inner: Mutex::new(Inner {
                settings,
                codex: None,
                claude: None,
                grok: None,
                codex_quota,
                claude_quota,
                grok_quota,
                agy_gemini,
                agy_third,
                refresh,
                grok_plan: None,
                grok_plan_at: None,
                claude_profile: None,
                google_email: None,
                google_plan: None,
                status: HashMap::new(),
                cache,
                history: QuotaHistory::load(now),
                repricing: false,
                ui_state: Value::Object(Default::default()),
                autostart: false,
                wsl: Vec::new(),
                codex_dirs: Vec::new(),
                others,
                other_quotas,
                other_refresh,
                other_profile_at: HashMap::new(),
                switching: None,
                switch_notice: None,
            }),
            usage: Mutex::new(UsageService::bootstrap()),
            activity: ActivityMonitor::new(),
            logins: Mutex::new(HashMap::new()),
            web: Mutex::new(WebState::default()),
            scan_lock: tokio::sync::Mutex::new(()),
            refresh_lock: tokio::sync::Mutex::new(()),
        }
    }

    pub fn settings(&self) -> Settings {
        self.inner.lock().unwrap().settings.clone()
    }

    pub fn snapshot(&self) -> StateSnapshot {
        let g = self.inner.lock().unwrap();
        let usage = self.usage.lock().unwrap();
        let web = web::view(&self.web.lock().unwrap(), &usage.buckets());
        let activity = self.activity.snapshot();
        let now = now_secs();
        let services = UsageApp::ALL.iter().map(|app| g.service_view(*app, now)).collect();
        StateSnapshot {
            services,
            settings: g.settings.clone(),
            chinese: l10n::is_chinese(),
            activity: ActivityView { active: activity.active.into_iter().collect(), waiting: activity.waiting.into_iter().collect() },
            history: g.history.clone(),
            usage: UsageMeta { version: usage.version, last_scan_at: usage.last_scan_at, scanning: usage.scanning },
            prices: PricesView {
                builtin: pricing::TABLE.iter().map(|(k, p)| (k.to_string(), *p)).collect(),
                custom: pricing::custom_prices(),
            },
            repricing: g.repricing,
            autostart: g.autostart,
            agy_installed: google::is_installed(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            others: g.other_views(now),
            codex_dirs: g.codex_dirs.iter().map(|(p, auto)| CodexDirView { path: p.to_string_lossy().into_owned(), auto: *auto }).collect(),
            switching: g.switching.clone(),
            switch_notice: g.switch_notice.clone(),
            clis: CliPresence {
                codex: other_accounts::login::binary(Provider::Codex).is_some(),
                claude: other_accounts::login::binary(Provider::Claude).is_some(),
                grok: other_accounts::login::binary(Provider::Grok).is_some(),
                agy: google::is_installed(),
            },
            web,
        }
    }

    pub fn usage_payload(&self) -> UsagePayload {
        let usage = self.usage.lock().unwrap();
        UsagePayload { version: usage.version, buckets: usage.buckets() }
    }
}

/// 本机 Claude 账号上次从资料接口读到的订阅（`email` 是当时的账号，换了账号就不再用）。
#[derive(Debug, Clone)]
struct LocalClaudeProfile {
    email: Option<String>,
    plan: Option<String>,
    started_at: Option<i64>,
    rate_limit_tier: Option<String>,
    at: i64,
}

/// 本机 Claude 账号每次读资料接口的结果写进 `%APPDATA%\yybar\claude-plan-check.json`（不含邮箱、id、令牌）：
/// 订阅过期了还显示 Pro 时，让用户把这个文件发来看资料接口到底说了什么。
fn write_claude_plan_check(checked: &Result<profile::ClaudeProfile, String>) {
    let body = match checked {
        Ok(p) => serde_json::json!({ "checkedAt": now_secs(), "ok": true, "plan": p.plan, "profile": p.check }),
        Err(e) => serde_json::json!({ "checkedAt": now_secs(), "ok": false, "error": e }),
    };
    if let Ok(data) = serde_json::to_vec_pretty(&body) {
        let _ = paths::write_atomic(&paths::data_dir().join("claude-plan-check.json"), &data);
    }
}

/// 本机 Claude 账号的订阅等级 / 订阅开始日多久从资料接口更新一次（和其他账号一样）。
const CLAUDE_PROFILE_INTERVAL: i64 = 6 * 3600;

impl Inner {
    /// 悬浮窗要不要显示（对应 Mac `FloatingPanelController.sync`）：有勾了「悬浮窗」的账号就显示——本机账号看服务开关和
    /// 悬浮窗勾选，以及账号是否实际列出；其他账号看它那一行的启用和勾选。与前端账号列表保持一致，
    /// 一个都没有或样式选了「隐藏」就关掉；额度刷新失败不影响已有账号的显示。
    pub fn floating_wanted(&self) -> bool {
        self.settings.floating_style != FloatingStyle::Hidden
            && UsageApp::ALL
            .iter()
            .any(|&app| (self.settings.floating_shows(app) && self.local_shown(app)) || !self.shown_others(app, false).is_empty())
    }

    /// 把资料接口读到的订阅盖到本机 Claude 账号上（同一个账号才盖）：等级、订阅开始日（订阅不是 active 时没有，就不显示续费日）、档位。
    fn with_claude_profile(&self, mut account: ClaudeAccount) -> ClaudeAccount {
        let same = |p: &LocalClaudeProfile| p.email.as_deref().map(str::to_lowercase) == account.email.as_deref().map(str::to_lowercase);
        if let Some(p) = self.claude_profile.as_ref().filter(|p| same(p)) {
            account.subscription_type = p.plan.clone().or(account.subscription_type);
            account.subscription_created_at = p.started_at;
            account.rate_limit_tier = p.rate_limit_tier.clone().or(account.rate_limit_tier);
        }
        account
    }

    fn claude_profile_due(&self, account: &ClaudeAccount, now: i64) -> bool {
        self.claude_profile.as_ref().map_or(true, |p| now - p.at > CLAUDE_PROFILE_INTERVAL || p.email != account.email)
    }

    /// 本机账号的身份（用于「删除本机账号」：CLI 换成别的账号后身份不同，自动重新出现）。
    pub fn identity(&self, app: UsageApp) -> Option<String> {
        match app {
            UsageApp::Codex => self.codex.as_ref().and_then(|a| a.account_id.clone().or_else(|| a.email.clone())),
            UsageApp::Claude => self.claude.as_ref().map(|a| a.email.clone().unwrap_or_else(|| "local".into())),
            UsageApp::Grok => self.grok.as_ref().map(|a| a.identity.clone()),
            UsageApp::Agy => Some(self.google_email.clone().unwrap_or_else(|| "local".into())),
        }
    }

    pub fn is_removed(&self, app: UsageApp) -> bool {
        match (self.settings.removed_local_accounts.get(app.key()), self.identity(app)) {
            (Some(removed), Some(current)) => *removed == current,
            _ => false,
        }
    }

    /// 切换本机账号后，先把目标账号最近一次的额度当作本机额度显示，刷新回来再换成新的。
    pub fn seed_local_quota(&mut self, app: UsageApp, snapshot: QuotaSnapshot) {
        let record = Some(QuotaCacheRecord { snapshot: snapshot.clone(), source: QuotaSource::Cache, updated_at: snapshot.fetched_at });
        match app {
            UsageApp::Codex => {
                self.codex_quota = Some(snapshot);
                self.cache.codex = record;
            }
            UsageApp::Claude => {
                self.claude_quota = Some(snapshot);
                self.cache.claude = record;
            }
            UsageApp::Grok => {
                self.grok_quota = Some(snapshot);
                self.cache.grok = record;
            }
            UsageApp::Agy => {}
        }
    }

    pub fn quota(&self, app: UsageApp) -> Option<QuotaSnapshot> {
        match app {
            UsageApp::Codex => self.codex_quota.clone(),
            UsageApp::Claude => self.claude_quota.clone(),
            UsageApp::Grok => self.grok_quota.clone(),
            UsageApp::Agy => QuotaSnapshot::antigravity(self.agy_gemini.as_ref(), self.agy_third.as_ref()),
        }
    }

    /// 本机账号在 yybar 里出现：本机 CLI 登录着（agy 为装了 CLI），且没被用户从列表删掉。
    /// 没有时设置页不列、托盘 / 悬浮窗 / 弹出窗口也不显示它。
    pub fn local_shown(&self, app: UsageApp) -> bool {
        self.detected(app) && !self.is_removed(app)
    }

    /// 网站个人主页 @ 后面的订阅：App 里启用着的账号各一条（服务 + 套餐 + 账号摘要，不传邮箱），免费的也传，
    /// 没读到套餐的不传。Claude Max 的 5x / 20x 拼成 max_5x / max_20x。和 Mac 一样，Antigravity 的套餐是 Google 订阅，记成 gemini。
    pub fn web_account_plans(&self) -> Vec<AccountPlan> {
        let mut plans: Vec<AccountPlan> = Vec::new();
        let mut add = |app: &'static str, identity: Option<&str>, plan: Option<&str>| {
            let (Some(identity), Some(plan)) = (identity.filter(|i| !i.is_empty()), plan.filter(|p| !p.trim().is_empty())) else { return };
            let entry = AccountPlan::new(app, identity, plan);
            if !plans.iter().any(|p| p.app == entry.app && p.account == entry.account) {
                plans.push(entry);
            }
        };
        let shown = |app: UsageApp| self.settings.is_enabled(app) && self.local_shown(app);
        if shown(UsageApp::Codex) {
            let codex = self.codex.as_ref();
            let plan = codex.and_then(|a| a.plan_type.clone()).or_else(|| self.codex_quota.as_ref().and_then(|q| q.plan_type.clone()));
            add("codex", codex.and_then(|a| a.email.as_deref().or(a.account_id.as_deref())), plan.as_deref());
        }
        if shown(UsageApp::Claude) {
            let claude = self.claude.as_ref();
            let plan = site::claude_plan(claude.and_then(|a| a.subscription_type.as_deref()), claude.and_then(|a| a.rate_limit_tier.as_deref()));
            add("claude", claude.and_then(|a| a.email.as_deref()), plan.as_deref());
        }
        if shown(UsageApp::Grok) {
            let grok = self.grok.as_ref();
            add("grok", grok.map(|a| a.email.as_deref().unwrap_or(&a.identity)), self.grok_plan.as_deref());
        }
        if shown(UsageApp::Agy) {
            add("gemini", self.google_email.as_deref(), self.google_plan.as_deref());
        }
        // 其他账号看它自己那一行的「启用」
        for a in self.listed_others().into_iter().filter(|a| a.enabled) {
            let (app, service) = match a.provider {
                Provider::Codex => ("codex", UsageApp::Codex),
                Provider::Claude => ("claude", UsageApp::Claude),
                Provider::Grok => ("grok", UsageApp::Grok),
                Provider::Google => ("gemini", UsageApp::Agy),
            };
            let plan = match a.provider {
                Provider::Claude => site::claude_plan(a.plan.as_deref(), a.rate_limit_tier.as_deref()),
                _ => a.plan.clone(),
            };
            if self.settings.is_enabled(service) {
                add(app, Some(a.email.as_deref().unwrap_or(&a.id)), plan.as_deref());
            }
        }
        plans
    }

    fn detected(&self, app: UsageApp) -> bool {
        match app {
            UsageApp::Codex => self.codex.is_some(),
            UsageApp::Claude => self.claude.is_some(),
            UsageApp::Grok => self.grok.is_some(),
            UsageApp::Agy => google::is_installed(),
        }
    }

    fn service_view(&self, app: UsageApp, now: i64) -> ServiceView {
        let quota = self.quota(app);
        let (email, plan, renewal, source) = match app {
            UsageApp::Codex => (
                self.codex.as_ref().and_then(|a| a.email.clone()),
                self.codex.as_ref().and_then(|a| a.plan_type.clone()).or_else(|| quota.as_ref().and_then(|q| q.plan_type.clone())),
                self.codex.as_ref().and_then(|a| SubscriptionRenewal::codex(a.subscription_active_until, now)),
                self.codex.as_ref().map(|a| a.path.to_string_lossy().into_owned()),
            ),
            UsageApp::Claude => (
                self.claude.as_ref().and_then(|a| a.email.clone()),
                // Max 按档位写成 max_5x / max_20x（显示成 Max / Ultra）
                site::claude_plan(
                    self.claude.as_ref().and_then(|a| a.subscription_type.as_deref()),
                    self.claude.as_ref().and_then(|a| a.rate_limit_tier.as_deref()),
                ),
                self.claude.as_ref().and_then(|a| SubscriptionRenewal::monthly(a.subscription_created_at, now)),
                self.claude.as_ref().map(|a| a.path.to_string_lossy().into_owned()),
            ),
            UsageApp::Grok => (
                self.grok.as_ref().and_then(|a| a.email.clone()),
                self.grok_plan.clone(),
                None,
                self.grok.as_ref().map(|a| a.path.to_string_lossy().into_owned()),
            ),
            UsageApp::Agy => (self.google_email.clone(), self.google_plan.clone(), None, google::binary().map(|p| p.to_string_lossy().into_owned())),
        };
        ServiceView {
            app,
            enabled: self.settings.is_enabled(app),
            detected: self.detected(app),
            removed: self.is_removed(app),
            email,
            plan,
            quota,
            refresh: self.refresh.get(&app).cloned().unwrap_or_default(),
            status: if self.settings.show_service_status { self.status.get(&app).cloned() } else { None },
            renewal,
            source,
            history_keys: match app {
                UsageApp::Codex => vec![history_keys::codex(self.codex.as_ref().and_then(|a| a.account_id.as_deref()))],
                UsageApp::Claude => vec![history_keys::claude()],
                UsageApp::Grok => vec![history_keys::grok()],
                UsageApp::Agy => vec![history_keys::agy("gemini"), history_keys::agy("3p")],
            },
        }
    }

    fn state_mut(&mut self, app: UsageApp) -> &mut RefreshState {
        self.refresh.entry(app).or_default()
    }

    /// 刷新前置检查（对应 Mac `beginCodexRefresh`）：在飞行中 / 退避中 / 定时触发间隔不足 60 秒时跳过。
    fn begin(&mut self, app: UsageApp, reason: RefreshReason, now: i64) -> bool {
        if !self.settings.is_enabled(app) || self.is_removed(app) {
            return false;
        }
        let state = self.state_mut(app);
        if state.in_flight {
            return false;
        }
        if let Some(until) = state.backoff_until.filter(|u| *u > now) {
            state.last_error = Some(format!("{}{}", tr("Rate limited; retry in ", "请求太频繁，"), retry_text(until - now)));
            return false;
        }
        if reason == RefreshReason::Periodic && state.last_success_at.is_some_and(|t| now - t < MIN_SUCCESS_INTERVAL) {
            return false;
        }
        state.in_flight = true;
        state.last_attempt_at = Some(now);
        true
    }

    fn fail(&mut self, app: UsageApp, error: &QuotaError) {
        let message = error.message(app);
        let state = self.state_mut(app);
        state.in_flight = false;
        state.last_error = Some(message);
        if error.is_rate_limited() {
            state.backoff_until = Some(now_secs() + RATE_LIMIT_BACKOFF);
        }
    }

    fn succeed(&mut self, app: UsageApp, source: QuotaSource, at: i64) {
        let state = self.state_mut(app);
        state.in_flight = false;
        state.last_error = None;
        state.backoff_until = None;
        state.last_success_at = Some(at);
        state.source = Some(source);
    }

    fn record_history(&mut self, key: &str, app: UsageApp, snapshot: &QuotaSnapshot) {
        if self.history.record(key, app, snapshot, snapshot.fetched_at) {
            self.history.save();
        }
    }
}

fn retry_text(seconds: i64) -> String {
    let minutes = (seconds + 59) / 60;
    tr(&format!("{minutes}m"), &format!("{minutes} 分钟后重试"))
}

// ---------- 发布 ----------

/// 推送最新状态给所有窗口，并更新托盘图标。
pub fn publish(app: &AppHandle) {
    let snapshot = app.state::<AppState>().snapshot();
    let _ = app.emit("state", &snapshot);
    crate::tray::update(app);
}

// ---------- 启动 ----------

pub async fn bootstrap(app: &AppHandle) {
    let state = app.state::<AppState>();
    {
        let mut g = state.inner.lock().unwrap();
        g.wsl = if g.settings.scan_wsl { paths::wsl_homes() } else { Vec::new() };
    }
    load_credentials(app);
    {
        let state = app.state::<AppState>();
        let others = state.inner.lock().unwrap().others.clone();
        accounts::cleanup_orphan_dirs(&others);
    }
    start_activity_monitor(app);
    web::bootstrap(app);
    publish(app);
    let h = app.clone();
    tauri::async_runtime::spawn(async move { scan_usage(&h).await });
    let h = app.clone();
    tauri::async_runtime::spawn(async move { refresh_service_status(&h).await });
    refresh_quotas(app, RefreshReason::UserInitiated).await;
}

/// 监听各 CLI 的会话日志目录（使用中呼吸）。
pub fn start_activity_monitor(app: &AppHandle) {
    let gemini = paths::gemini_dir();
    let mut roots = vec![
        (UsageApp::Codex, paths::codex_dir().join("sessions")),
        (UsageApp::Claude, paths::claude_dir().join("projects")),
        (UsageApp::Grok, paths::grok_dir().join("sessions")),
        (UsageApp::Agy, gemini.join("antigravity-cli").join("conversations")),
        (UsageApp::Agy, gemini.join("antigravity").join("conversations")),
    ];
    let wsl = app.state::<AppState>().inner.lock().unwrap().wsl.clone();
    for home in wsl {
        roots.push((UsageApp::Codex, home.path.join(".codex").join("sessions")));
        roots.push((UsageApp::Claude, home.path.join(".claude").join("projects")));
        roots.push((UsageApp::Grok, home.path.join(".grok").join("sessions")));
    }
    let h = app.clone();
    app.state::<AppState>().activity.start(roots, move || crate::tray::activity_changed(&h));
}

// ---------- 凭据 ----------

/// 重读本机凭据（切换本机账号后调用）。
pub fn reload_credentials(app: &AppHandle) {
    load_credentials(app);
}

/// 重读凭据后只刷新一个服务的本机账号（切换本机账号后用）。
pub async fn refresh_service(app: &AppHandle, service: UsageApp) {
    load_credentials(app);
    publish(app);
    let reason = RefreshReason::UserInitiated;
    match service {
        UsageApp::Codex => load_codex_quota(app, reason).await,
        UsageApp::Claude => load_claude_quota(app, reason).await,
        UsageApp::Grok => load_grok_quota(app, reason).await,
        UsageApp::Agy => load_google_quota(app, reason).await,
    }
    publish(app);
}

/// 重读本机凭据，再同步其他 Codex 目录里登录着的账号（accounts::sync_codex_homes）。
fn load_credentials(app: &AppHandle) {
    load_local_credentials(app);
    accounts::sync_codex_homes(app);
    // 本机 CLI 登录 / 退出后，悬浮窗要不要显示可能变了
    crate::windows::sync_floating(app);
}

/// 重读本机凭据。身份变了（外部切换了账号）就清掉旧额度和磁盘缓存。
fn load_local_credentials(app: &AppHandle) {
    let state = app.state::<AppState>();
    let wsl = state.inner.lock().unwrap().wsl.clone();
    let codex = credentials::codex::load(&wsl);
    let claude = credentials::claude::load(&wsl);
    let grok = credentials::grok::load(&wsl);
    let mut g = state.inner.lock().unwrap();
    let mut cache_dirty = false;

    let codex_id = codex.as_ref().and_then(|a| a.account_id.clone().or_else(|| a.email.clone()));
    if let (Some(prev), Some(next)) = (g.cache.codex_account_id.clone(), codex_id.clone()) {
        if prev != next {
            g.codex_quota = None;
            g.cache.codex = None;
            g.refresh.remove(&UsageApp::Codex);
            cache_dirty = true;
        }
    }
    if codex_id.is_some() && g.cache.codex_account_id != codex_id {
        g.cache.codex_account_id = codex_id;
        cache_dirty = true;
    }
    g.codex = codex;

    let claude_email = claude.as_ref().map(|a| a.email.clone().unwrap_or_default());
    if let (Some(prev), Some(next)) = (g.cache.claude_email.clone(), claude_email.clone()) {
        if prev != next {
            g.claude_quota = None;
            g.cache.claude = None;
            g.refresh.remove(&UsageApp::Claude);
            cache_dirty = true;
        }
    }
    if claude_email.is_some() && g.cache.claude_email != claude_email {
        g.cache.claude_email = claude_email;
        cache_dirty = true;
    }
    let claude = claude.map(|a| g.with_claude_profile(a));
    g.claude = claude;

    let grok_id = grok.as_ref().map(|a| a.identity.clone());
    if let (Some(prev), Some(next)) = (g.cache.grok_account_id.clone(), grok_id.clone()) {
        if prev != next {
            g.grok_quota = None;
            g.grok_plan = None;
            g.grok_plan_at = None;
            g.cache.grok = None;
            g.refresh.remove(&UsageApp::Grok);
            cache_dirty = true;
        }
    }
    if grok_id.is_some() && g.cache.grok_account_id != grok_id {
        g.cache.grok_account_id = grok_id;
        cache_dirty = true;
    }
    g.grok = grok;
    if cache_dirty {
        g.cache.save();
    }
}

// ---------- 额度 ----------

/// 手动刷新：额度 + 日志扫描 + 服务状态。已有刷新在跑就直接返回（连点去重）。
pub async fn refresh_now(app: &AppHandle) {
    let state = app.state::<AppState>();
    let Ok(_guard) = state.refresh_lock.try_lock() else { return };
    refresh_quotas(app, RefreshReason::UserInitiated).await;
    scan_usage(app).await;
    refresh_service_status(app).await;
}

pub async fn refresh_quotas(app: &AppHandle, reason: RefreshReason) {
    {
        let state = app.state::<AppState>();
        let scan_wsl = state.settings().scan_wsl;
        let wsl = if scan_wsl { paths::wsl_homes() } else { Vec::new() };
        state.inner.lock().unwrap().wsl = wsl;
    }
    load_credentials(app);
    publish(app);
    tokio::join!(
        load_codex_quota(app, reason),
        load_claude_quota(app, reason),
        load_grok_quota(app, reason),
        load_google_quota(app, reason),
        accounts::refresh_all(app, reason),
    );
    publish(app);
}

async fn load_codex_quota(app: &AppHandle, reason: RefreshReason) {
    let state = app.state::<AppState>();
    let account = {
        let mut g = state.inner.lock().unwrap();
        if !g.begin(UsageApp::Codex, reason, now_secs()) {
            return;
        }
        match g.codex.clone() {
            Some(a) => a,
            None => {
                g.fail(UsageApp::Codex, &QuotaError::MissingToken);
                return;
            }
        }
    };
    publish(app);
    let mut account = account;
    let result = match codex_refresh::ensure_fresh(&mut account).await {
        Ok(token) => quota::codex::fetch(&token, account.account_id.as_deref()).await,
        Err(e) => Err(e),
    };
    let mut g = state.inner.lock().unwrap();
    if g.codex.as_ref().map(|a| &a.path) == Some(&account.path) {
        g.codex = Some(account.clone());
    }
    match result {
        Ok(snapshot) => {
            let at = snapshot.fetched_at;
            g.codex_quota = Some(snapshot.clone());
            g.succeed(UsageApp::Codex, QuotaSource::Api, at);
            g.cache.codex = Some(QuotaCacheRecord { snapshot: snapshot.clone(), source: QuotaSource::Api, updated_at: at });
            g.cache.save();
            g.record_history(&history_keys::codex(account.account_id.as_deref()), UsageApp::Codex, &snapshot);
        }
        Err(e) => g.fail(UsageApp::Codex, &e),
    }
}

async fn load_claude_quota(app: &AppHandle, reason: RefreshReason) {
    let state = app.state::<AppState>();
    let account = {
        let mut g = state.inner.lock().unwrap();
        if !g.begin(UsageApp::Claude, reason, now_secs()) {
            return;
        }
        match g.claude.clone() {
            Some(a) => a,
            None => {
                g.fail(UsageApp::Claude, &QuotaError::MissingToken);
                return;
            }
        }
    };
    publish(app);
    let mut account = account;
    let profile_due = state.inner.lock().unwrap().claude_profile_due(&account, now_secs());
    let mut fresh_profile = None;
    let result = match claude_refresh::ensure_fresh(&mut account).await {
        Ok(token) => {
            let result = quota::claude::fetch(&token).await;
            // 每 6 小时顺带从资料接口更新一次订阅（凭据里的是登录那一刻的）；额度没拿到也更新（免费账号的额度接口可能不给）
            if profile_due {
                let checked = profile::fetch_checked(&token).await;
                write_claude_plan_check(&checked);
                fresh_profile = checked.ok();
            }
            result
        }
        Err(e) => Err(e),
    };
    let mut g = state.inner.lock().unwrap();
    if let Some(p) = fresh_profile {
        g.claude_profile = Some(LocalClaudeProfile {
            email: account.email.clone(),
            plan: p.plan,
            started_at: p.subscription_started_at,
            rate_limit_tier: p.rate_limit_tier,
            at: now_secs(),
        });
    }
    if g.claude.as_ref().map(|a| &a.path) == Some(&account.path) {
        let account = g.with_claude_profile(account);
        g.claude = Some(account);
    }
    match result {
        Ok(snapshot) => {
            let at = snapshot.fetched_at;
            g.claude_quota = Some(snapshot.clone());
            g.succeed(UsageApp::Claude, QuotaSource::Api, at);
            g.cache.claude = Some(QuotaCacheRecord { snapshot: snapshot.clone(), source: QuotaSource::Api, updated_at: at });
            g.cache.save();
            g.record_history(&history_keys::claude(), UsageApp::Claude, &snapshot);
        }
        Err(e) => g.fail(UsageApp::Claude, &e),
    }
}

async fn load_grok_quota(app: &AppHandle, reason: RefreshReason) {
    let state = app.state::<AppState>();
    let wsl = {
        let mut g = state.inner.lock().unwrap();
        if !g.begin(UsageApp::Grok, reason, now_secs()) {
            return;
        }
        if g.grok.is_none() {
            g.grok_quota = None;
            g.cache.grok = None;
            g.cache.save();
            g.fail(UsageApp::Grok, &QuotaError::MissingToken);
            return;
        }
        g.wsl.clone()
    };
    publish(app);
    let result = fetch_grok(&wsl).await;
    let mut g = state.inner.lock().unwrap();
    match result {
        Ok((account, snapshot, plan)) => {
            let at = snapshot.fetched_at;
            g.grok = Some(account.clone());
            g.grok_quota = Some(snapshot.clone());
            g.succeed(UsageApp::Grok, QuotaSource::Api, at);
            g.cache.grok = Some(QuotaCacheRecord { snapshot: snapshot.clone(), source: QuotaSource::Api, updated_at: at });
            g.cache.grok_account_id = Some(account.identity.clone());
            g.cache.save();
            g.record_history(&history_keys::grok(), UsageApp::Grok, &snapshot);
            if let Some(plan) = plan {
                g.grok_plan = Some(plan);
                g.grok_plan_at = Some(now_secs());
            }
        }
        Err(e) => g.fail(UsageApp::Grok, &e),
    }
}

/// Grok：将过期或 401 时让 CLI 续期再试；请求期间 CLI 换了账号就丢弃结果。订阅等级每 6 小时取一次。
async fn fetch_grok(wsl: &[HomeRoot]) -> Result<(GrokAccount, QuotaSnapshot, Option<String>), QuotaError> {
    let mut account = credentials::grok::load(wsl).ok_or(QuotaError::MissingToken)?;
    if account.expires_at.is_some_and(|e| e - now_secs() < 300) {
        if !quota::grok::refresh_credentials().await {
            return Err(QuotaError::TokenRefreshFailed(tr("Grok token renewal failed; run grok login", "Grok 续期失败，请运行 grok login")));
        }
        account = credentials::grok::load(wsl).ok_or(QuotaError::MissingToken)?;
    }
    let mut result = quota::grok::fetch(&account).await;
    if matches!(result, Err(QuotaError::Http(401, _))) && quota::grok::refresh_credentials().await {
        account = credentials::grok::load(wsl).ok_or(QuotaError::MissingToken)?;
        result = quota::grok::fetch(&account).await;
    }
    let snapshot = result?;
    if credentials::grok::load(wsl).map(|a| a.identity) != Some(account.identity.clone()) {
        return Err(QuotaError::Transport(tr("Grok account changed; refresh again", "Grok 账号刚换过，请再刷新一次")));
    }
    let plan = quota::grok::fetch_plan(&account).await;
    Ok((account, snapshot, plan))
}

async fn load_google_quota(app: &AppHandle, reason: RefreshReason) {
    let state = app.state::<AppState>();
    {
        let mut g = state.inner.lock().unwrap();
        let now = now_secs();
        if reason == RefreshReason::Periodic
            && g.refresh.get(&UsageApp::Agy).and_then(|s| s.last_attempt_at).is_some_and(|t| now - t < GOOGLE_MIN_PERIODIC_INTERVAL)
        {
            return;
        }
        if !g.begin(UsageApp::Agy, RefreshReason::UserInitiated, now) {
            return;
        }
    }
    publish(app);
    let result = google::fetch().await;
    let email = google::signed_in_email();
    let mut g = state.inner.lock().unwrap();
    match result {
        Ok(r) => {
            let dropped = consumed(g.agy_gemini.as_ref(), r.gemini.as_ref()) || consumed(g.agy_third.as_ref(), r.third_party.as_ref());
            if dropped {
                // Antigravity 没有可区分两池的本地日志：额度下降时呼吸到下次刷新之后。
                let hold = (g.settings.quota_interval_secs() as f64 * 1.5).max(180.0);
                state.activity.mark_quota_activity(UsageApp::Agy, Duration::from_secs_f64(hold));
            }
            g.google_email = email.or(g.google_email.take());
            if let Some(plan) = r.plan {
                g.google_plan = Some(plan);
            }
            let now = now_secs();
            if let Some(gemini) = r.gemini {
                g.cache.gemini = Some(QuotaCacheRecord { snapshot: gemini.clone(), source: QuotaSource::AgyCli, updated_at: now });
                g.record_history(&history_keys::agy("gemini"), UsageApp::Agy, &gemini);
                g.agy_gemini = Some(gemini);
            }
            if let Some(third) = r.third_party {
                g.cache.agy = Some(QuotaCacheRecord { snapshot: third.clone(), source: QuotaSource::AgyCli, updated_at: now });
                g.record_history(&history_keys::agy("3p"), UsageApp::Agy, &third);
                g.agy_third = Some(third);
            }
            g.cache.save();
            g.succeed(UsageApp::Agy, QuotaSource::AgyCli, now);
        }
        Err(e) => {
            if matches!(e, QuotaError::MissingToken) && !google::is_installed() {
                let state = g.state_mut(UsageApp::Agy);
                state.in_flight = false;
                state.last_error = Some(tr(
                    "agy CLI not found (Antigravity quota is read through it)",
                    "没有找到 agy CLI（Antigravity 额度通过它读取）",
                ));
            } else {
                g.fail(UsageApp::Agy, &e);
            }
        }
    }
}

/// 两次刷新之间剩余减少了（5H 或 WK）。窗口重置不算。
fn consumed(old: Option<&QuotaSnapshot>, new: Option<&QuotaSnapshot>) -> bool {
    let (Some(old), Some(new)) = (old, new) else { return false };
    let dropped = |a: &Option<quota::QuotaWindow>, b: &Option<quota::QuotaWindow>| -> bool {
        let (Some(a), Some(b)) = (a, b) else { return false };
        if let (Some(ra), Some(rb)) = (a.resets_at, b.resets_at) {
            if rb - ra > 60 {
                return false;
            }
        }
        b.used_percent - a.used_percent > 0.05
    };
    dropped(&old.five_hour, &new.five_hour) || dropped(&old.weekly, &new.weekly)
}

// ---------- 服务状态 ----------

/// OpenAI / Anthropic / xAI / Google 并发拉取，失败保留上一份。
pub async fn refresh_service_status(app: &AppHandle) {
    let (openai, anthropic, xai, google_status) = tokio::join!(
        service_status::fetch_statuspage(service_status::OPENAI_URL, service_status::OPENAI_COMPONENTS),
        service_status::fetch_statuspage(service_status::ANTHROPIC_URL, service_status::ANTHROPIC_COMPONENTS),
        service_status::fetch_xai(),
        service_status::fetch_google(),
    );
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        for (app, status) in [(UsageApp::Codex, openai), (UsageApp::Claude, anthropic), (UsageApp::Grok, xai), (UsageApp::Agy, google_status)] {
            if let Some(s) = status {
                g.status.insert(app, s);
            }
        }
    }
    publish(app);
}

// ---------- 本地用量 ----------

/// 扫一遍本地日志（防重入：已经在扫就返回，排队的全量重建由扫完后接着做）。
pub async fn scan_usage(app: &AppHandle) {
    let state = app.state::<AppState>();
    let Ok(_guard) = state.scan_lock.try_lock() else { return };
    loop {
        let (prev, rebuild) = state.usage.lock().unwrap().begin_scan();
        let (wsl, manual, ignored) = {
            let g = state.inner.lock().unwrap();
            (g.wsl.clone(), g.settings.extra_codex_dirs.clone(), g.settings.ignored_codex_homes.clone())
        };
        if rebuild.is_some() {
            state.inner.lock().unwrap().repricing = true;
        }
        publish(app);
        let output = tauri::async_runtime::spawn_blocking(move || {
            let extra = paths::extra_codex_dirs(&manual, &ignored);
            let dirs: Vec<_> = extra.iter().map(|(d, _)| d.clone()).collect();
            (usage_service::run_scan(&prev, &ScanRoots::build(&wsl, &dirs)), extra)
        })
        .await;
        let output = output.map(|(output, extra)| {
            state.inner.lock().unwrap().codex_dirs = extra;
            output
        });
        let changed = {
            let mut usage = state.usage.lock().unwrap();
            let before = usage.version;
            match output {
                Ok(output) => usage.finish_scan(output, rebuild, now_secs()),
                Err(_) => usage.scanning = false,
            }
            usage.version != before
        };
        state.inner.lock().unwrap().repricing = false;
        if changed {
            let _ = app.emit("usage", state.usage.lock().unwrap().version);
        }
        publish(app);
        if !state.usage.lock().unwrap().has_pending_rebuild() {
            break;
        }
    }
    // 扫描完：到点了就自动上传（每天 12:00 一次）
    web::usage_did_update(app);
}

/// 改了某个模型的自定义价格：历史费用按新价格重算（全量重建，日志已删的历史保留）。
pub fn set_custom_price(app: &AppHandle, key: &str, price: Option<ModelPrice>) {
    pricing::set_custom(key, price);
    let mut keys = std::collections::HashSet::new();
    keys.insert(key.to_string());
    app.state::<AppState>().usage.lock().unwrap().request_rebuild(Reprice::Keys(keys));
    publish(app);
    let h = app.clone();
    tauri::async_runtime::spawn(async move {
        // 连续改几格时合并成一次重算
        tokio::time::sleep(Duration::from_millis(800)).await;
        scan_usage(&h).await;
    });
}

// ---------- 账号删除 ----------

pub fn remove_local_account(app: &AppHandle, service: UsageApp) {
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        if let Some(identity) = g.identity(service) {
            g.settings.removed_local_accounts.insert(service.key().to_string(), identity);
            g.settings.save();
        }
    }
    publish(app);
    crate::windows::sync_floating(app);
}

pub fn restore_removed_accounts(app: &AppHandle) {
    {
        let state = app.state::<AppState>();
        let mut g = state.inner.lock().unwrap();
        g.settings.removed_local_accounts.clear();
        g.settings.save();
    }
    publish(app);
    crate::windows::sync_floating(app);
    let h = app.clone();
    tauri::async_runtime::spawn(async move { refresh_quotas(&h, RefreshReason::UserInitiated).await });
}
