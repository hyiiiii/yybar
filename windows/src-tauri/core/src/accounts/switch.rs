//! 切换本机 CLI 账号用到的凭据读写（对应 Mac `CLIAccountSwitch`）。流程编排（续期、把原账号存成其他账号、
//! 刷新额度）在外壳的 `app_state.rs`。
//! - Codex：`%USERPROFILE%\.codex\auth.json` 只换 `tokens`（OPENAI_API_KEY 等其余字段沿用）。
//! - Claude Code：`.credentials.json` 只换 `claudeAiOauth`（mcpOAuth 等保留），`.claude.json` 只换 `oauthAccount`
//!   （CLI 和 yybar 都从这里取邮箱；文件解析不了就不写，免得覆盖用户配置）。
//! - Grok：`auth.json` 里只换 xAI 官方账号的记录，自定义 provider 的记录原样保留。
//! 写文件都是原子写入；改之前把原文件另存到 `%APPDATA%\yybar\switch-backups\`（每个服务只留最近一份）。

use std::path::Path;

use serde_json::{Map, Value};

use super::AccountError;
use crate::credentials::{grok, read_json};
use crate::paths;
use crate::tr;

/// 改之前另存原文件，出问题时可以手动恢复。
pub fn backup(name: &str, source: &Path) {
    let Ok(data) = std::fs::read(source) else { return };
    let dir = paths::data_dir().join("switch-backups");
    let _ = std::fs::create_dir_all(&dir);
    let _ = paths::write_atomic(&dir.join(name), &data);
}

fn write_json(path: &Path, value: &Value) -> Result<(), AccountError> {
    let data = serde_json::to_vec_pretty(value).map_err(|e| AccountError::msg(e.to_string()))?;
    paths::write_atomic(path, &data).map_err(|e| AccountError::msg(format!("{}: {e}", path.display())))
}

fn now_iso() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

// ---------- Codex ----------

/// 把目标账号的 tokens 写进本机 `auth.json`，返回本机原来的 `auth.json`（没有时 None）。
pub fn write_codex(local: &Path, target: &Value) -> Result<Option<Value>, AccountError> {
    let tokens = target
        .get("tokens")
        .filter(|t| t.is_object())
        .cloned()
        .ok_or_else(|| AccountError::msg(tr("Saved credentials not found; add the account again", "找不到这个账号保存的凭据，请重新添加")))?;
    let old = read_json(local);
    let mut root = old.as_ref().and_then(|v| v.as_object().cloned()).unwrap_or_else(|| {
        let mut m = Map::new();
        m.insert("OPENAI_API_KEY".into(), Value::Null);
        m
    });
    root.insert("auth_mode".into(), "chatgpt".into());
    root.insert("tokens".into(), tokens);
    root.insert("last_refresh".into(), now_iso().into());
    backup("codex-auth.json", local);
    write_json(local, &Value::Object(root))?;
    Ok(old)
}

// ---------- Claude ----------

/// 本机 Claude Code 的凭据根对象和 `.claude.json` 的 oauthAccount。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ClaudeLocal {
    pub credentials: Option<Value>,
    pub oauth_account: Option<Value>,
}

pub fn read_claude_local(credentials: &Path, config: &Path) -> ClaudeLocal {
    ClaudeLocal {
        credentials: read_json(credentials),
        oauth_account: read_json(config).and_then(|v| v.get("oauthAccount").cloned()),
    }
}

/// 写入目标账号的 `claudeAiOauth`（其余字段保留）和 oauthAccount。
pub fn write_claude(credentials: &Path, config: &Path, oauth: Value, oauth_account: Option<Value>) -> Result<(), AccountError> {
    let mut root = read_json(credentials).and_then(|v| v.as_object().cloned()).unwrap_or_default();
    root.insert("claudeAiOauth".into(), oauth);
    backup("claude-credentials.json", credentials);
    write_json(credentials, &Value::Object(root))?;
    let Some(account) = oauth_account else { return Ok(()) };
    let mut config_root = Map::new();
    if let Ok(data) = std::fs::read(config) {
        if !data.is_empty() {
            let data = data.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&data);
            match serde_json::from_slice::<Value>(data).ok().and_then(|v| v.as_object().cloned()) {
                Some(m) => config_root = m,
                None => {
                    return Err(AccountError::msg(tr(
                        "Couldn't parse .claude.json; it was left unchanged",
                        ".claude.json 无法解析，未修改",
                    )))
                }
            }
        }
    }
    config_root.insert("oauthAccount".into(), account);
    backup("claude.json", config);
    write_json(config, &Value::Object(config_root))
}

// ---------- Grok ----------

/// 把目标 `auth.json` 里的 xAI 官方记录换进本机 `auth.json`（自定义 provider 的记录保留），
/// 返回本机原来的官方记录（没有时 None）。
pub fn write_grok(local: &Path, target: &Value) -> Result<Option<Value>, AccountError> {
    let target_records: Map<String, Value> = target
        .as_object()
        .map(|m| m.iter().filter(|(k, _)| grok::is_first_party(k)).map(|(k, v)| (k.clone(), v.clone())).collect())
        .unwrap_or_default();
    if target_records.is_empty() {
        return Err(AccountError::msg(tr("This account has no xAI sign-in; add it again", "这个账号没有 xAI 官方登录记录，请重新添加")));
    }
    let current = read_json(local).and_then(|v| v.as_object().cloned()).unwrap_or_default();
    let old: Map<String, Value> = current.iter().filter(|(k, _)| grok::is_first_party(k)).map(|(k, v)| (k.clone(), v.clone())).collect();
    let mut next: Map<String, Value> = current.into_iter().filter(|(k, _)| !grok::is_first_party(k)).collect();
    next.extend(target_records);
    backup("grok-auth.json", local);
    write_json(local, &Value::Object(next))?;
    Ok(if old.is_empty() { None } else { Some(Value::Object(old)) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn codex_keeps_other_fields() {
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("auth.json");
        std::fs::write(&local, r#"{"OPENAI_API_KEY":"sk-x","tokens":{"access_token":"old"}}"#).unwrap();
        let old = write_codex(&local, &json!({"tokens": {"access_token": "new"}})).unwrap();
        assert_eq!(old.unwrap()["tokens"]["access_token"], "old");
        let now = read_json(&local).unwrap();
        assert_eq!(now["tokens"]["access_token"], "new");
        assert_eq!(now["OPENAI_API_KEY"], "sk-x");
        assert_eq!(now["auth_mode"], "chatgpt");
    }

    #[test]
    fn claude_replaces_only_its_parts() {
        let dir = tempfile::tempdir().unwrap();
        let creds = dir.path().join(".credentials.json");
        let config = dir.path().join(".claude.json");
        std::fs::write(&creds, r#"{"claudeAiOauth":{"accessToken":"old"},"mcpOAuth":{"x":1}}"#).unwrap();
        std::fs::write(&config, r#"{"oauthAccount":{"emailAddress":"old@x"},"projects":{"p":1}}"#).unwrap();
        let local = read_claude_local(&creds, &config);
        assert_eq!(local.oauth_account.unwrap()["emailAddress"], "old@x");
        write_claude(&creds, &config, json!({"accessToken": "new"}), Some(json!({"emailAddress": "new@x"}))).unwrap();
        let c = read_json(&creds).unwrap();
        assert_eq!(c["claudeAiOauth"]["accessToken"], "new");
        assert_eq!(c["mcpOAuth"]["x"], 1);
        let cfg = read_json(&config).unwrap();
        assert_eq!(cfg["oauthAccount"]["emailAddress"], "new@x");
        assert_eq!(cfg["projects"]["p"], 1);
        // 解析不了的 .claude.json 不碰
        std::fs::write(&config, "{broken").unwrap();
        assert!(write_claude(&creds, &config, json!({"accessToken": "n2"}), Some(json!({}))).is_err());
        assert_eq!(std::fs::read_to_string(&config).unwrap(), "{broken");
    }

    #[test]
    fn grok_swaps_first_party_records() {
        let dir = tempfile::tempdir().unwrap();
        let local = dir.path().join("auth.json");
        std::fs::write(&local, r#"{"https://auth.x.ai::a":{"key":"old"},"https://custom.example":{"key":"mine"}}"#).unwrap();
        let old = write_grok(&local, &json!({"https://auth.x.ai::b": {"key": "new"}})).unwrap().unwrap();
        assert_eq!(old["https://auth.x.ai::a"]["key"], "old");
        let now = read_json(&local).unwrap();
        assert!(now.get("https://auth.x.ai::a").is_none());
        assert_eq!(now["https://auth.x.ai::b"]["key"], "new");
        assert_eq!(now["https://custom.example"]["key"], "mine");
        assert!(write_grok(&local, &json!({"https://custom.example": {"key": "k"}})).is_err());
    }
}
