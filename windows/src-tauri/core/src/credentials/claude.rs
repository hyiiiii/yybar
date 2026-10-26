//! Claude Code：`~/.claude/.credentials.json`（或 `CLAUDE_CONFIG_DIR`），邮箱兜底读 `~/.claude.json` 的 `oauthAccount`
//! （对应 Mac `ClaudeAuth`；Windows 上没有钥匙串这一步）。

use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{candidate_paths, read_json, str_field};
use crate::paths::{self, HomeRoot};

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ClaudeAccount {
    pub email: Option<String>,
    pub subscription_type: Option<String>,
    /// access_token 过期时间（Unix 秒）
    pub expires_at: Option<i64>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    /// `~/.claude.json` oauthAccount 的订阅开始日，用来推算续费日。
    pub subscription_created_at: Option<i64>,
    /// 凭据文件位置（续期后写回这里）。
    pub path: PathBuf,
}

pub fn credentials_file() -> PathBuf {
    paths::claude_dir().join(".credentials.json")
}

pub fn load(wsl: &[HomeRoot]) -> Option<ClaudeAccount> {
    for path in candidate_paths(credentials_file(), wsl, ".claude/.credentials.json") {
        let Some(root) = read_json(&path) else { continue };
        let Some(mut account) = parse(&root, path.clone()) else { continue };
        if let Some(oauth) = config_for(&path).and_then(|c| c.get("oauthAccount").cloned()) {
            if account.email.is_none() {
                account.email = str_field(&oauth, &["emailAddress"]).map(str::to_string);
            }
            account.subscription_created_at = super::parse_iso(oauth.get("subscriptionCreatedAt"));
        }
        return Some(account);
    }
    None
}

/// 和凭据同一个主目录下的 `.claude.json`（CLI 把账号信息另存在这里）。
fn config_for(credentials: &Path) -> Option<Value> {
    read_json(&config_path_for(credentials))
}

/// `.claude.json` 的位置：CLAUDE_CONFIG_DIR 时在该目录里；默认在主目录（`~/.claude` 的上一级）。
pub fn config_path_for(credentials: &Path) -> PathBuf {
    let claude_dir = credentials.parent().unwrap_or(Path::new("."));
    let inside = claude_dir.join(".claude.json");
    if inside.is_file() {
        return inside;
    }
    match claude_dir.parent() {
        Some(home) if claude_dir.file_name().is_some_and(|n| n == ".claude") => home.join(".claude.json"),
        _ => inside,
    }
}

pub fn parse(root: &Value, path: PathBuf) -> Option<ClaudeAccount> {
    let oauth = root.get("claudeAiOauth")?;
    let access_token = str_field(oauth, &["accessToken", "access_token"])?.to_string();
    Some(ClaudeAccount {
        email: str_field(oauth, &["emailAddress", "email"]).map(str::to_string),
        subscription_type: str_field(oauth, &["subscriptionType"]).map(str::to_string),
        expires_at: parse_expiry(oauth.get("expiresAt")),
        refresh_token: str_field(oauth, &["refreshToken", "refresh_token"]).map(str::to_string),
        access_token: Some(access_token),
        subscription_created_at: None,
        path,
    })
}

/// CLI 用毫秒时间戳；兼容秒和字符串。
pub fn parse_expiry(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    let n = v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))?;
    Some(if n > 10_000_000_000.0 { (n / 1000.0) as i64 } else { n as i64 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn millis_expiry() {
        let v = json!({"claudeAiOauth": {"accessToken": "a", "refreshToken": "r", "expiresAt": 1_900_000_000_000i64, "subscriptionType": "max"}});
        let c = parse(&v, PathBuf::new()).unwrap();
        assert_eq!(c.expires_at, Some(1_900_000_000));
        assert_eq!(c.subscription_type.as_deref(), Some("max"));
    }
}
