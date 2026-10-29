//! yybar 网站账号（对应 Mac `YYBarWebAccount`）：连接（GitHub 授权拿上传令牌）、显示头像、
//! 把本地用量传上去换筹码（花费 $1 = 1 筹码，换多少以网站按它自己的价格表算的为准）。
//!
//! 连接：浏览器打开 `<网站>/connect?state=随机串` → 用户用 GitHub 登录、点「授权」→ 网站跳回
//! `yybar://connect?token=…&state=…` → 核对 state 后保存令牌，再拉头像和已上传的日期。
//! 令牌和头像信息存在 `%APPDATA%\yybar\web-account.json`（只有当前 Windows 用户能读）。
//!
//! 上传（每一天的每个服务只算一份，网站和本机两边都记）：
//! - 只传今天以前、已经过完的天（本地日期），按 天 × 服务 × 模型 汇总；Windows 上是 Codex / Claude / Grok / Antigravity。
//! - 网站对每个（日期, 服务）记一份和它的量（token 总数）：再传同一天，量更多才整份换掉，否则跳过。本机也按（日期, 服务）
//!   打标签（`web-uploads-<login>.json`）、记下网站上的量：没标签的传；有标签的，本机这一天的量比记下的多（比如新加了一个
//!   Codex 目录，找到了另一个账号以前的会话）也传。启动、连上、每次上传前用 `GET /api/v1/usage/days` 补齐标签和量。
//! - 一次最多 100 天，多了分批。
//!
//! 订阅（网站个人主页 @ 后面那一排）：各服务账号的套餐，一个账号一条 `{ app, account, plan }`，`account` 是账号的摘要，
//! 不传邮箱；`PUT /api/v1/accounts`，带上这台电脑固定的设备 id（`%APPDATA%\yybar\device-id`），
//! 网站把这台设备上次传的整份替换（重新连接换了令牌也一样）。

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::credentials::read_json;
use crate::paths;
use crate::quota::client;
use crate::usage::UsageBucket;
use crate::UsageApp;

pub const SITE: &str = "https://yybar-web.hyi030618.workers.dev";

/// 按用量桶上传的服务（和网站 usage.ts 的 APPS 对应）。
pub const UPLOAD_APPS: [UsageApp; 4] = [UsageApp::Codex, UsageApp::Claude, UsageApp::Grok, UsageApp::Agy];
/// 旧版网站只按日期记，那时只收这三家。
const LEGACY_APPS: [&str; 3] = ["codex", "claude", "grok"];
const DAYS_PER_REQUEST: usize = 100;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    pub login: String,
    pub name: Option<String>,
    pub avatar_url: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct Stored {
    token: String,
    profile: Profile,
}

fn account_file() -> PathBuf {
    paths::data_dir().join("web-account.json")
}

pub fn load_account() -> Option<(String, Profile)> {
    let stored: Stored = serde_json::from_value(read_json(&account_file())?).ok()?;
    Some((stored.token, stored.profile))
}

pub fn save_account(token: &str, profile: &Profile) -> std::io::Result<()> {
    let data = serde_json::to_vec_pretty(&Stored { token: token.to_string(), profile: profile.clone() })?;
    paths::write_atomic(&account_file(), &data)
}

pub fn delete_account() {
    let _ = std::fs::remove_file(account_file());
}

// ---------- 本机标签 ----------

/// 每个 GitHub 账号一份：传过的（日期, 服务）、上次上传时间、一键上传用掉的那天、自动上传做过的那天。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ledger {
    /// 「日期|服务」，例如 2026-10-21|agy
    #[serde(default)]
    pub uploaded: BTreeSet<String>,
    #[serde(default)]
    pub last_upload_at: Option<i64>,
    #[serde(default)]
    pub manual_upload_day: Option<String>,
    #[serde(default)]
    pub auto_upload_day: Option<String>,
    /// 「日期|服务」→ 网站上这一天这个服务的量和花费。本机的量比它多就再传一次；旧文件、旧网站没有，那些天照旧只传一次。
    #[serde(default)]
    pub sent: BTreeMap<String, Sent>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sent {
    /// token 总数，和网站 usage_uploads.total 一样算
    pub total: i64,
    /// 花费（微美元），只用来估这次能多换多少筹码
    pub cost_micro: i64,
}

impl Ledger {
    pub fn contains(&self, day: &str, app: &str) -> bool {
        self.uploaded.contains(&format!("{day}|{app}"))
    }

    pub fn insert(&mut self, day: &str, app: &str) {
        self.uploaded.insert(format!("{day}|{app}"));
    }

    pub fn record(&mut self, day: &str, app: &str, sent: Sent) {
        self.insert(day, app);
        self.sent.insert(format!("{day}|{app}"), sent);
    }

    /// 传过东西的天数（去重）。
    pub fn day_count(&self) -> usize {
        self.uploaded.iter().filter_map(|k| k.split('|').next()).collect::<BTreeSet<_>>().len()
    }
}

fn ledger_file(login: &str) -> PathBuf {
    let safe: String = login.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    paths::data_dir().join(format!("web-uploads-{safe}.json"))
}

pub fn load_ledger(login: &str) -> Ledger {
    read_json(&ledger_file(login)).and_then(|v| serde_json::from_value(v).ok()).unwrap_or_default()
}

pub fn save_ledger(login: &str, ledger: &Ledger) {
    if let Ok(data) = serde_json::to_vec_pretty(ledger) {
        if let Err(e) = paths::write_atomic(&ledger_file(login), &data) {
            log::warn!("[yybar 网站] 上传标签写盘失败: {e}");
        }
    }
}

// ---------- 待上传 ----------

/// 今天以前、要传的（日期, 服务）：还没打标签的，和本机的量比网站上记的多的。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pending {
    pub days: Vec<String>,
    pub pairs: BTreeSet<String>,
    pub cost_usd: f64,
    /// 按本机价格估的筹码（$1 = 1，向下取整）；实际以网站按它自己的价格表算的为准
    pub chips: i64,
}

pub fn pending(buckets: &[UsageBucket], ledger: &Ledger, today: NaiveDate) -> Pending {
    let mut out = Pending::default();
    let mut days = BTreeSet::new();
    for (pair, mine) in local_totals(buckets, today) {
        let Some((day, app)) = pair.split_once('|') else { continue };
        let mut cost = mine.cost_micro;
        if ledger.contains(day, app) {
            // 传过了：本机的量更多才再传，筹码按多出来的花费估
            match ledger.sent.get(&pair) {
                Some(before) if mine.total > before.total => cost = (cost - before.cost_micro).max(0),
                _ => continue,
            }
        }
        out.cost_usd += cost as f64 / 1e6;
        days.insert(day.to_string());
        out.pairs.insert(pair);
    }
    out.days = days.into_iter().collect();
    out.chips = chips(out.cost_usd);
    out
}

/// 本机每个（日期, 服务）的量（token 总数，和网站一样算）和花费（微美元）。
pub fn local_totals(buckets: &[UsageBucket], today: NaiveDate) -> BTreeMap<String, Sent> {
    let mut out: BTreeMap<String, Sent> = BTreeMap::new();
    for b in buckets.iter().filter(|b| b.day < today && UPLOAD_APPS.contains(&b.app)) {
        let e = out.entry(format!("{}|{}", b.day.format("%Y-%m-%d"), b.app.key())).or_default();
        e.total += b.input_tokens.max(0) + b.output_tokens.max(0) + b.cache_read_tokens.max(0) + b.cache_creation_tokens.max(0);
        e.cost_micro += (b.cost_usd.max(0.0) * 1e6).round() as i64;
    }
    out
}

pub fn chips(usd: f64) -> i64 {
    (usd.max(0.0) + 1e-9).floor() as i64
}

/// 花费写成网站认的十进制字符串：保留 6 位小数（网站按微美元存），不会出现科学计数法。
pub fn cost_string(usd: f64) -> String {
    format!("{:.6}", usd.max(0.0))
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub app: String,
    pub model: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_creation_tokens: i64,
    #[serde(rename = "costUSD")]
    pub cost_usd: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UploadDay {
    pub day: String,
    pub entries: Vec<Entry>,
}

/// 按天整理成网站要的格式：每天只放还没传过的服务。
pub fn build_days(buckets: &[UsageBucket], todo: &Pending) -> Vec<UploadDay> {
    todo.days
        .iter()
        .map(|day| UploadDay {
            day: day.clone(),
            entries: buckets
                .iter()
                .filter(|b| b.day.format("%Y-%m-%d").to_string() == *day && todo.pairs.contains(&format!("{day}|{}", b.app.key())))
                .map(|b| Entry {
                    app: b.app.key().to_string(),
                    model: b.model.chars().take(120).collect(),
                    input_tokens: b.input_tokens.max(0),
                    output_tokens: b.output_tokens.max(0),
                    cache_read_tokens: b.cache_read_tokens.max(0),
                    cache_creation_tokens: b.cache_creation_tokens.max(0),
                    cost_usd: cost_string(b.cost_usd),
                })
                .collect(),
        })
        .collect()
}

// ---------- 连接 ----------

/// 一次性的随机 state（只用字母数字，网站要求 8~128 位）。
pub fn random_state() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

pub fn connect_url(state: &str) -> String {
    format!("{SITE}/connect?state={state}")
}

/// `yybar://connect?token=…&state=…` → (token, state)。不是连接回调返回 None。
pub fn parse_callback(url: &str) -> Option<(String, String)> {
    let rest = url.strip_prefix("yybar://connect")?;
    let query = rest.trim_start_matches('/').strip_prefix('?')?;
    let mut token = None;
    let mut state = None;
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
        let v = percent_decode(v);
        match k {
            "token" => token = Some(v),
            "state" => state = Some(v),
            _ => {}
        }
    }
    Some((token.unwrap_or_default(), state.unwrap_or_default()))
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = bytes.get(i + 1..i + 3).and_then(|h| std::str::from_utf8(h).ok()).and_then(|h| u8::from_str_radix(h, 16).ok());
        match (bytes[i], hex) {
            (b'%', Some(b)) => {
                out.push(b);
                i += 3;
                continue;
            }
            (b'+', _) => out.push(b' '),
            (b, _) => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// ---------- 网络 ----------

#[derive(Debug, Clone, PartialEq)]
pub enum WebError {
    /// 网站不再认这个令牌
    Unauthorized,
    Server(String),
    Transport(String),
}

impl std::fmt::Display for WebError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WebError::Unauthorized => write!(f, "Unauthorized"),
            WebError::Server(m) | WebError::Transport(m) => write!(f, "{m}"),
        }
    }
}

async fn send(req: reqwest::RequestBuilder, token: &str) -> Result<Value, WebError> {
    let resp = req
        .bearer_auth(token)
        .timeout(std::time::Duration::from_secs(30))
        .send()
        .await
        .map_err(|e| WebError::Transport(crate::quota::describe_error(&e)))?;
    let status = resp.status().as_u16();
    let body: Value = resp.json().await.unwrap_or(Value::Null);
    if status == 401 {
        return Err(WebError::Unauthorized);
    }
    if !(200..300).contains(&status) {
        let text = body.get("error").and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| format!("HTTP {status}"));
        return Err(WebError::Server(text));
    }
    Ok(body)
}

pub async fn whoami(token: &str) -> Result<Profile, WebError> {
    let v = send(client().get(format!("{SITE}/api/v1/whoami")), token).await?;
    let user = v.get("user").ok_or_else(|| WebError::Server("whoami".into()))?;
    let s = |k: &str| user.get(k).and_then(Value::as_str).filter(|x| !x.is_empty()).map(str::to_string);
    Ok(Profile { login: s("login").ok_or_else(|| WebError::Server("whoami".into()))?, name: s("name"), avatar_url: s("avatarUrl") })
}

/// 网站上已经传过的一个（日期, 服务）；`sent` 是网站记的量和花费（旧版网站没有）。
#[derive(Debug, Clone, PartialEq)]
pub struct Uploaded {
    pub day: String,
    pub app: String,
    pub sent: Option<Sent>,
}

/// 网站上已经传过的（日期, 服务）。旧版网站只有 days，当作 Codex / Claude / Grok 都传过了。
pub async fn uploaded_pairs(token: &str) -> Result<Vec<Uploaded>, WebError> {
    let v = send(client().get(format!("{SITE}/api/v1/usage/days")), token).await?;
    Ok(parse_uploaded(&v))
}

pub fn parse_uploaded(v: &Value) -> Vec<Uploaded> {
    if let Some(list) = v.get("uploads").and_then(Value::as_array) {
        return list
            .iter()
            .filter_map(|u| {
                let sent = u.get("total").and_then(Value::as_i64).map(|total| Sent { total, cost_micro: u.get("costMicro").and_then(Value::as_i64).unwrap_or(0) });
                Some(Uploaded { day: u.get("day")?.as_str()?.to_string(), app: u.get("app")?.as_str()?.to_string(), sent })
            })
            .collect();
    }
    v.get("days")
        .and_then(Value::as_array)
        .map(|days| {
            days.iter()
                .filter_map(Value::as_str)
                .flat_map(|d| LEGACY_APPS.iter().map(move |a| Uploaded { day: d.to_string(), app: a.to_string(), sent: None }))
                .collect()
        })
        .unwrap_or_default()
}

/// 一个账号的订阅。`account` 是「yybar:服务:账号（小写）」的 SHA-256 前 16 位十六进制，和 Mac 版算法一样：
/// 同一个账号在 Mac 和 Windows 上传，网站认得出是同一个，不重复计数。
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AccountPlan {
    pub app: &'static str,
    pub account: String,
    pub plan: String,
}

impl AccountPlan {
    pub fn new(app: &'static str, identity: &str, plan: &str) -> Self {
        let digest = Sha256::digest(format!("yybar:{app}:{}", identity.to_lowercase()).as_bytes());
        AccountPlan {
            app,
            account: digest[..8].iter().map(|b| format!("{b:02x}")).collect(),
            plan: plan.trim().chars().take(40).collect(),
        }
    }
}

/// Claude 的套餐：Max 按 rateLimitTier（default_claude_max_20x）写成 max_20x / max_5x，其他照 subscriptionType（和 Mac 一样）。
pub fn claude_plan(subscription_type: Option<&str>, rate_limit_tier: Option<&str>) -> Option<String> {
    let is_max = subscription_type.is_none_or(|s| s.to_lowercase().contains("max"));
    let tier = rate_limit_tier.map(str::to_lowercase).filter(|_| is_max).and_then(|t| {
        let start = t.find("max_")?;
        let rest = &t[start + 4..];
        let digits = rest.chars().take_while(char::is_ascii_digit).count();
        (digits > 0 && rest[digits..].starts_with('x')).then(|| t[start..start + 4 + digits + 1].to_string())
    });
    tier.or_else(|| subscription_type.map(str::to_string))
}

/// 这台电脑固定的设备 id（第一次传订阅时生成）：网站按它替换这台设备上次传的订阅。
fn device_id() -> String {
    let file = paths::data_dir().join("device-id");
    if let Some(id) = std::fs::read_to_string(&file).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
        return id;
    }
    let id = uuid::Uuid::new_v4().to_string();
    let _ = paths::write_atomic(&file, id.as_bytes());
    id
}

/// 把这台电脑上各账号的订阅交给网站（整份替换这台电脑上次传的）。
pub async fn put_accounts(token: &str, accounts: &[AccountPlan]) -> Result<(), WebError> {
    let body = serde_json::json!({ "device": device_id(), "accounts": accounts });
    send(client().put(format!("{SITE}/api/v1/accounts")).json(&body), token).await?;
    Ok(())
}

/// 传一批（最多 100 天）。返回（这次有新服务收下的天数，整天都传过、跳过的天数）。
pub async fn upload_chunk(token: &str, days: &[UploadDay]) -> Result<(usize, usize), WebError> {
    let body = serde_json::json!({ "days": days });
    let v = send(client().post(format!("{SITE}/api/v1/usage")).json(&body), token).await?;
    let count = |k: &str| v.get(k).and_then(Value::as_array).map_or(0, Vec::len);
    Ok((count("accepted"), count("skipped")))
}

pub fn chunks(days: &[UploadDay]) -> impl Iterator<Item = &[UploadDay]> {
    days.chunks(DAYS_PER_REQUEST)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bucket(app: UsageApp, day: &str, model: &str, cost: f64) -> UsageBucket {
        UsageBucket {
            app,
            model: model.into(),
            day: NaiveDate::parse_from_str(day, "%Y-%m-%d").unwrap(),
            input_tokens: 10,
            output_tokens: 5,
            cache_read_tokens: 100,
            cache_creation_tokens: 0,
            cost_usd: cost,
        }
    }

    #[test]
    fn pending_skips_today_and_tagged_pairs() {
        let today = NaiveDate::parse_from_str("2026-10-26", "%Y-%m-%d").unwrap();
        let buckets = vec![
            bucket(UsageApp::Codex, "2026-10-24", "gpt-5", 1.5),
            bucket(UsageApp::Claude, "2026-10-24", "claude-opus-4-5", 2.25),
            bucket(UsageApp::Agy, "2026-10-25", "gemini-3-flash", 0.5),
            bucket(UsageApp::Codex, "2026-10-26", "gpt-5", 9.0),
        ];
        let mut ledger = Ledger::default();
        ledger.insert("2026-10-24", "claude");
        let p = pending(&buckets, &ledger, today);
        assert_eq!(p.days, vec!["2026-10-24", "2026-10-25"]);
        assert!(p.pairs.contains("2026-10-24|codex") && !p.pairs.contains("2026-10-24|claude"));
        assert_eq!(p.chips, 2);
        let days = build_days(&buckets, &p);
        assert_eq!(days[0].entries.len(), 1);
        assert_eq!(days[0].entries[0].cost_usd, "1.500000");
        assert_eq!(days[1].entries[0].app, "agy");
        assert_eq!(ledger.day_count(), 1);
    }

    #[test]
    fn pending_reuploads_a_day_that_grew() {
        let today = NaiveDate::parse_from_str("2026-10-26", "%Y-%m-%d").unwrap();
        let mut buckets = vec![bucket(UsageApp::Codex, "2026-10-24", "gpt-5", 1.5)];
        let mut ledger = Ledger::default();
        for (pair, sent) in local_totals(&buckets, today) {
            let (day, app) = pair.split_once('|').unwrap();
            ledger.record(day, app, sent);
        }
        assert!(pending(&buckets, &ledger, today).days.is_empty());
        // 新加的 Codex 目录里有这一天另一个账号的会话：量变多了，再传，筹码按多出来的估
        buckets.push(bucket(UsageApp::Codex, "2026-10-24", "gpt-5-pro", 3.0));
        let p = pending(&buckets, &ledger, today);
        assert_eq!(p.days, vec!["2026-10-24"]);
        assert_eq!(p.chips, 3);
        assert_eq!(build_days(&buckets, &p)[0].entries.len(), 2);
        // 旧标签（没记量）照旧不再传
        let mut legacy = Ledger::default();
        legacy.insert("2026-10-24", "codex");
        assert!(pending(&buckets, &legacy, today).days.is_empty());
    }

    #[test]
    fn parses_callback_and_uploads() {
        assert_eq!(parse_callback("yybar://connect?token=yyb_a%2Bb&state=s1"), Some(("yyb_a+b".into(), "s1".into())));
        assert_eq!(parse_callback("yybar://connect/?state=s2&token=t"), Some(("t".into(), "s2".into())));
        assert_eq!(parse_callback("yybar://other?token=t"), None);
        let v = serde_json::json!({"days": ["2026-10-20"], "uploads": [{"day": "2026-10-20", "app": "agy"}, {"day": "2026-10-21", "app": "codex", "total": 42, "costMicro": 7}]});
        assert_eq!(
            parse_uploaded(&v),
            vec![
                Uploaded { day: "2026-10-20".into(), app: "agy".into(), sent: None },
                Uploaded { day: "2026-10-21".into(), app: "codex".into(), sent: Some(Sent { total: 42, cost_micro: 7 }) },
            ]
        );
        let legacy = serde_json::json!({"days": ["2026-10-20"]});
        assert_eq!(parse_uploaded(&legacy).len(), 3);
        assert!(random_state().len() >= 32);
    }

    #[test]
    fn claude_max_tiers() {
        assert_eq!(claude_plan(Some("max"), Some("default_claude_max_20x")).as_deref(), Some("max_20x"));
        assert_eq!(claude_plan(Some("max"), Some("default_claude_max_5x")).as_deref(), Some("max_5x"));
        assert_eq!(claude_plan(Some("max"), None).as_deref(), Some("max"));
        assert_eq!(claude_plan(Some("pro"), Some("default_claude_ai")).as_deref(), Some("pro"));
        assert_eq!(claude_plan(Some("team"), Some("default_claude_max_5x")).as_deref(), Some("team"));
        assert_eq!(claude_plan(None, Some("default_claude_max_20x")).as_deref(), Some("max_20x"));
    }

    #[test]
    fn account_digest_matches_mac() {
        // Mac：SHA256("yybar:codex:a@example.com") 前 8 字节
        let a = AccountPlan::new("codex", "A@Example.com", "  pro ");
        assert_eq!(a.account, "b3a1bda91f071c46");
        assert_eq!(a.plan, "pro");
        assert_eq!(serde_json::to_value(&a).unwrap(), serde_json::json!({"app": "codex", "account": "b3a1bda91f071c46", "plan": "pro"}));
    }
}
