//! 其他账号（对应 Mac `ExtraAccount` + `ImportedCodexAccount`）：用户在设置 · 服务里「添加账号…」加进来的账号，
//! 和本机 CLI 正在用的账号互不影响。
//!
//! - 每个账号一个独立目录 `%APPDATA%\yybar\accounts\<服务>\<随机目录名>\`，里面放 CLI 自己格式的凭据：
//!   Codex `auth.json`、Claude Code `.credentials.json`（+ `.claude.json` 的 oauthAccount）、Grok `auth.json`、
//!   Google（Gemini · Antigravity）就是 agy 的 `GEMINI_CLI_HOME`。这样读凭据、续期写回、额度查询都直接复用本机账号的那套代码，
//!   用官方 CLI 在浏览器里登录时也直接把这个目录交给它（`CODEX_HOME` / `CLAUDE_CONFIG_DIR` / `GROK_HOME`）。
//! - 账号资料（别名、邮箱、套餐、启用 / 任务栏 / 悬浮窗开关）存在 `%APPDATA%\yybar\other-accounts.json`。
//! - Mac 版把 token 存成本用户私有文件（不进钥匙串）；Windows 上 `%APPDATA%` 本来就只有本用户能读。
//!
//! 切换本机 CLI 账号见 `switch.rs`，浏览器登录见 `login.rs`，粘贴凭据见 `paste.rs`。

pub mod login;
pub mod paste;
pub mod profile;
pub mod switch;

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::credentials::{self, read_json};
use crate::paths;
use crate::{tr, UsageApp};

/// 能添加其他账号的服务。Google 一个账号对应 Gemini 和 Antigravity 两个额度池，都显示在 Antigravity 下。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Provider {
    Codex,
    Claude,
    Grok,
    Google,
}

impl Provider {
    pub fn key(self) -> &'static str {
        match self {
            Provider::Codex => "codex",
            Provider::Claude => "claude",
            Provider::Grok => "grok",
            Provider::Google => "google",
        }
    }

    /// 额度显示在哪个服务下。
    pub fn app(self) -> UsageApp {
        match self {
            Provider::Codex => UsageApp::Codex,
            Provider::Claude => UsageApp::Claude,
            Provider::Grok => UsageApp::Grok,
            Provider::Google => UsageApp::Agy,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Provider::Codex => "Codex",
            Provider::Claude => "Claude Code",
            Provider::Grok => "Grok",
            Provider::Google => "Google",
        }
    }

    /// 目录里的凭据文件；Google 整个目录就是 agy 的 GEMINI_CLI_HOME。
    fn credential_file(self) -> Option<&'static str> {
        match self {
            Provider::Codex | Provider::Grok => Some("auth.json"),
            Provider::Claude => Some(".credentials.json"),
            Provider::Google => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OtherAccount {
    /// `<服务>:<身份>`：Codex `codex:<account_id>:<user_id>`，Claude `claude:<邮箱>`，Grok `grok:<user_id>:<team_id>`，
    /// Google `google:<邮箱>`。同一个身份再添加一次就覆盖凭据。
    pub id: String,
    pub provider: Provider,
    #[serde(default)]
    pub alias: String,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub plan: Option<String>,
    /// 刷新这个账号的额度（设置里的「启用」）。
    #[serde(default = "yes")]
    pub enabled: bool,
    /// 在任务栏 / 悬浮窗显示这个账号的额度（需同时启用）。
    #[serde(default)]
    pub show_in_tray: bool,
    #[serde(default)]
    pub show_in_floating: bool,
    pub added_at: i64,
    /// `accounts\<服务>\` 下的目录名。
    pub folder: String,
    /// 仅 Claude：订阅开始日（推算续费日），订阅不是 active 时没有。
    #[serde(default)]
    pub subscription_started_at: Option<i64>,
    /// 仅 Codex：当前付费周期结束日（下次续费日）。
    #[serde(default)]
    pub subscription_active_until: Option<i64>,
    /// 仅 Claude：凭据 / 资料接口的 rate_limit_tier（default_claude_max_5x / _20x），区分 Max 的两档。旧数据没有。
    #[serde(default)]
    pub rate_limit_tier: Option<String>,
    /// 仅 Codex：本机另一个 Codex 目录（第二个 Codex 用 CODEX_HOME 放在别处，和主目录同时在用）。
    /// 有它时凭据直接读写这个目录里的 auth.json（folder 为空，yybar 不另存副本、也不删这个目录）；
    /// 它算本机账号（一直在用），不能切换过去，但可以把别的账号切换进这个目录。
    #[serde(default)]
    pub home: Option<String>,
}

fn yes() -> bool {
    true
}

impl OtherAccount {
    pub fn dir(&self) -> PathBuf {
        match &self.home {
            Some(home) => PathBuf::from(home),
            None => provider_dir(self.provider).join(&self.folder),
        }
    }

    /// 凭据文件（Google 是目录本身）。
    pub fn credential_path(&self) -> PathBuf {
        match self.provider.credential_file() {
            Some(name) => self.dir().join(name),
            None => self.dir(),
        }
    }

    /// 列表 / 悬浮窗上的名字：别名 > 邮箱 @ 前 > 服务名。
    pub fn display_name(&self) -> String {
        if !self.alias.trim().is_empty() {
            return self.alias.trim().to_string();
        }
        if let Some(email) = self.email.as_deref().filter(|e| !e.is_empty()) {
            return email.split('@').next().unwrap_or(email).to_string();
        }
        self.provider.title().to_string()
    }

    /// Google 账号 Antigravity（Claude·GPT）池的额度键；Gemini 池用 `id` 本身。
    pub fn pool_key(&self) -> String {
        format!("{}#3p", self.id)
    }
}

/// 添加 / 切换账号时给用户看的错误。
#[derive(Debug, Clone, PartialEq)]
pub enum AccountError {
    /// 要添加的就是本机 CLI 正在用的账号。
    AlreadyLocal,
    Message(String),
}

impl AccountError {
    pub fn msg(text: impl Into<String>) -> AccountError {
        AccountError::Message(text.into())
    }

    pub fn message(&self) -> String {
        match self {
            AccountError::AlreadyLocal => tr(
                "This account is already signed in on this PC; it's shown above.",
                "这个账号已经是本机登录的账号，已显示在上方",
            ),
            AccountError::Message(m) => m.clone(),
        }
    }
}

impl From<std::io::Error> for AccountError {
    fn from(e: std::io::Error) -> AccountError {
        AccountError::Message(e.to_string())
    }
}

// ---------- 存储 ----------

/// `%APPDATA%\yybar\accounts`
pub fn root() -> PathBuf {
    paths::data_dir().join("accounts")
}

pub fn provider_dir(provider: Provider) -> PathBuf {
    root().join(provider.key())
}

fn store_file() -> PathBuf {
    paths::data_dir().join("other-accounts.json")
}

#[derive(Serialize, Deserialize)]
struct Payload {
    version: u32,
    accounts: Vec<OtherAccount>,
}

pub fn load_all() -> Vec<OtherAccount> {
    load_from(&store_file())
}

pub fn save_all(accounts: &[OtherAccount]) -> std::io::Result<()> {
    save_to(&store_file(), accounts)
}

fn load_from(path: &Path) -> Vec<OtherAccount> {
    read_json(path)
        .and_then(|v| serde_json::from_value::<Payload>(v).ok())
        .filter(|p| p.version == 1)
        .map(|p| p.accounts)
        .unwrap_or_default()
}

fn save_to(path: &Path, accounts: &[OtherAccount]) -> std::io::Result<()> {
    let data = serde_json::to_vec_pretty(&Payload { version: 1, accounts: accounts.to_vec() })?;
    paths::write_atomic(path, &data)
}

/// 新建一个空的账号目录，返回（目录名，路径）。
pub fn new_dir(provider: Provider) -> std::io::Result<(String, PathBuf)> {
    let folder = uuid::Uuid::new_v4().simple().to_string();
    let dir = provider_dir(provider).join(&folder);
    std::fs::create_dir_all(&dir)?;
    Ok((folder, dir))
}

pub fn remove_dir(provider: Provider, folder: &str) {
    if folder.is_empty() || folder.contains(['/', '\\']) || folder.contains("..") {
        return;
    }
    let _ = std::fs::remove_dir_all(provider_dir(provider).join(folder));
}

/// 新增或覆盖：同 id 时换成新的凭据目录和资料，别名、开关和添加时间沿用旧的，旧目录删掉。返回保存的账号。
pub fn upsert(list: &mut Vec<OtherAccount>, account: OtherAccount) -> OtherAccount {
    match list.iter_mut().find(|a| a.id == account.id) {
        Some(old) => {
            if old.folder != account.folder {
                remove_dir(old.provider, &old.folder);
            }
            let merged = OtherAccount {
                alias: old.alias.clone(),
                enabled: old.enabled,
                show_in_tray: old.show_in_tray,
                show_in_floating: old.show_in_floating,
                added_at: old.added_at,
                ..account
            };
            *old = merged.clone();
            merged
        }
        None => {
            list.push(account.clone());
            account
        }
    }
}

/// 删除账号和它的凭据目录。
pub fn remove(list: &mut Vec<OtherAccount>, id: &str) -> Option<OtherAccount> {
    let idx = list.iter().position(|a| a.id == id)?;
    let account = list.remove(idx);
    remove_dir(account.provider, &account.folder);
    Some(account)
}

// ---------- 从目录里认出账号 ----------

/// 登录或粘贴后，从账号目录里读出的身份和资料。
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Identified {
    pub id: String,
    pub email: Option<String>,
    pub plan: Option<String>,
    pub subscription_active_until: Option<i64>,
    pub subscription_started_at: Option<i64>,
    pub rate_limit_tier: Option<String>,
}

/// Codex：`auth.json` → `codex:<account_id>[:<user_id>]`（Team 下同一个 account 不同用户是不同账号）。
pub fn identify_codex(dir: &Path) -> Result<Identified, AccountError> {
    let path = dir.join("auth.json");
    let account = read_json(&path)
        .and_then(|v| credentials::codex::parse(&v, path.clone()))
        .ok_or_else(|| AccountError::msg(tr("No Codex sign-in found in this folder", "没有找到 Codex 登录")))?;
    let account_id = account
        .account_id
        .clone()
        .ok_or_else(|| AccountError::msg(tr("Couldn't find chatgpt_account_id in the token", "无法从 token 里找到 chatgpt_account_id")))?;
    let id = match account.chatgpt_user_id.as_deref().filter(|u| !u.is_empty()) {
        Some(user) => format!("codex:{account_id}:{user}"),
        None => format!("codex:{account_id}"),
    };
    Ok(Identified {
        id,
        email: account.email,
        plan: account.plan_type,
        subscription_active_until: account.subscription_active_until,
        ..Default::default()
    })
}

/// Claude：`.credentials.json`，邮箱 / 订阅开始日从同目录的 `.claude.json` 补。邮箱读不到时 id 用随机串。
pub fn identify_claude(dir: &Path) -> Result<Identified, AccountError> {
    let path = dir.join(".credentials.json");
    let account = read_json(&path)
        .and_then(|v| credentials::claude::parse(&v, path.clone()))
        .ok_or_else(|| AccountError::msg(tr("No Claude sign-in found in this folder", "没有找到 Claude 登录")))?;
    let oauth = read_json(&dir.join(".claude.json")).and_then(|v| v.get("oauthAccount").cloned());
    let email = account
        .email
        .or_else(|| oauth.as_ref().and_then(|o| credentials::str_field(o, &["emailAddress"])).map(str::to_string));
    let id = match email.as_deref() {
        Some(e) => format!("claude:{}", e.to_lowercase()),
        None => format!("claude:{}", uuid::Uuid::new_v4().simple()),
    };
    Ok(Identified {
        id,
        email,
        plan: account.subscription_type,
        subscription_active_until: None,
        subscription_started_at: oauth.as_ref().and_then(|o| credentials::parse_iso(o.get("subscriptionCreatedAt"))),
        rate_limit_tier: account.rate_limit_tier,
    })
}

/// Grok：`auth.json` 里 xAI 官方账号的记录 → `grok:<user_id>:<team_id>`。
pub fn identify_grok(dir: &Path) -> Result<Identified, AccountError> {
    let path = dir.join("auth.json");
    let account = read_json(&path)
        .and_then(|v| credentials::grok::parse(&v, path.clone()))
        .ok_or_else(|| AccountError::msg(tr("No xAI sign-in (auth.x.ai) found", "没有找到 xAI 官方账号（auth.x.ai）的登录")))?;
    Ok(Identified { id: format!("grok:{}", account.identity), email: account.email, ..Default::default() })
}

/// 把 `.claude.json` 的 oauthAccount 写进账号目录（CLI 自己也是这么存的，读邮箱和订阅开始日都从这里）。
pub fn write_claude_oauth_account(dir: &Path, oauth_account: &Value) -> std::io::Result<()> {
    let path = dir.join(".claude.json");
    let mut root = read_json(&path).and_then(|v| v.as_object().cloned()).unwrap_or_default();
    root.insert("oauthAccount".into(), oauth_account.clone());
    paths::write_atomic(&path, &serde_json::to_vec_pretty(&Value::Object(root))?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account(id: &str, folder: &str) -> OtherAccount {
        OtherAccount {
            id: id.into(),
            provider: Provider::Claude,
            alias: String::new(),
            email: Some("a@b.c".into()),
            plan: None,
            enabled: true,
            show_in_tray: false,
            show_in_floating: false,
            added_at: 1,
            folder: folder.into(),
            subscription_started_at: None,
            subscription_active_until: None,
            rate_limit_tier: None,
            home: None,
        }
    }

    #[test]
    fn upsert_keeps_user_choices() {
        let mut list = vec![OtherAccount { alias: "工作".into(), show_in_tray: true, ..account("claude:a@b.c", "old") }];
        let saved = upsert(&mut list, OtherAccount { plan: Some("max".into()), added_at: 9, ..account("claude:a@b.c", "new") });
        assert_eq!(list.len(), 1);
        assert_eq!(saved.alias, "工作");
        assert!(saved.show_in_tray);
        assert_eq!(saved.added_at, 1);
        assert_eq!(saved.folder, "new");
        assert_eq!(saved.plan.as_deref(), Some("max"));
        upsert(&mut list, account("claude:x@y.z", "other"));
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn store_round_trip_and_names() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("other-accounts.json");
        let list = vec![account("claude:a@b.c", "f1")];
        save_to(&file, &list).unwrap();
        assert_eq!(load_from(&file), list);
        assert_eq!(list[0].display_name(), "a");
        assert_eq!(OtherAccount { alias: " 备用 ".into(), ..list[0].clone() }.display_name(), "备用");
        assert_eq!(OtherAccount { email: None, ..list[0].clone() }.display_name(), "Claude Code");
    }

    #[test]
    fn identifies_accounts_from_folders() {
        use base64::Engine;
        let dir = tempfile::tempdir().unwrap();
        let claims = serde_json::json!({"email": "x@y.z", "https://api.openai.com/auth": {"chatgpt_plan_type": "plus", "chatgpt_account_id": "acc", "chatgpt_user_id": "u1"}});
        let jwt = format!("h.{}.s", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string()));
        std::fs::write(dir.path().join("auth.json"), serde_json::json!({"tokens": {"access_token": jwt, "id_token": jwt}}).to_string()).unwrap();
        let c = identify_codex(dir.path()).unwrap();
        assert_eq!(c.id, "codex:acc:u1");
        assert_eq!(c.email.as_deref(), Some("x@y.z"));
        assert_eq!(c.plan.as_deref(), Some("plus"));

        std::fs::write(dir.path().join(".credentials.json"), r#"{"claudeAiOauth":{"accessToken":"a","subscriptionType":"max"}}"#).unwrap();
        write_claude_oauth_account(dir.path(), &serde_json::json!({"emailAddress": "Me@X.com", "subscriptionCreatedAt": "2026-09-05T00:00:00Z"})).unwrap();
        let c = identify_claude(dir.path()).unwrap();
        assert_eq!(c.id, "claude:me@x.com");
        assert_eq!(c.plan.as_deref(), Some("max"));
        assert!(c.subscription_started_at.is_some());

        std::fs::write(dir.path().join("auth.json"), r#"{"https://auth.x.ai::k":{"key":"k","user_id":"u","team_id":"t","email":"g@x.ai"}}"#).unwrap();
        assert_eq!(identify_grok(dir.path()).unwrap().id, "grok:u:t");
    }
}
