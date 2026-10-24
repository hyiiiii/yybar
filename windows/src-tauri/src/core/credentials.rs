//! 只读各 CLI 自己的登录凭据，不刷新、不回写：token 轮换交给 CLI 自己，
//! 避免和 CLI 抢 refresh token 导致对方被登出。

use std::path::{Path, PathBuf};

use base64::Engine;
use serde_json::Value;

use super::paths::{self, HomeRoot};

#[derive(Debug, Clone)]
pub struct ClaudeCredential {
    pub access_token: String,
    pub expires_at: Option<i64>,
    pub email: Option<String>,
    pub subscription: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CodexCredential {
    pub access_token: String,
    pub account_id: Option<String>,
    pub email: Option<String>,
    pub plan_type: Option<String>,
}

#[derive(Debug, Clone)]
pub struct GrokCredential {
    pub access_token: String,
    pub email: Option<String>,
}

fn read_json(path: &Path) -> Option<Value> {
    let data = std::fs::read(path).ok()?;
    serde_json::from_slice(&data).ok()
}

fn str_field<'a>(v: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|k| v.get(*k).and_then(Value::as_str))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// 先找 Windows 本机，再找正在运行的 WSL 发行版。
fn candidate_paths(windows_path: PathBuf, roots: &[HomeRoot], relative: &str) -> Vec<PathBuf> {
    let mut out = vec![windows_path];
    out.extend(roots.iter().filter(|r| r.wsl_distro.is_some()).map(|r| r.path.join(relative)));
    out
}

pub fn load_claude(roots: &[HomeRoot]) -> Option<ClaudeCredential> {
    let candidates = candidate_paths(paths::claude_dir().join(".credentials.json"), roots, ".claude/.credentials.json");
    for path in candidates {
        let Some(root) = read_json(&path) else { continue };
        let Some(cred) = parse_claude(&root) else { continue };
        let mut cred = cred;
        if cred.email.is_none() {
            // CLI 把账号信息另存在主目录的 .claude.json 的 oauthAccount 里
            let config = path.parent().and_then(Path::parent).map(|h| h.join(".claude.json"));
            if let Some(cfg) = config.as_deref().and_then(read_json) {
                cred.email = cfg
                    .get("oauthAccount")
                    .and_then(|o| str_field(o, &["emailAddress"]))
                    .map(str::to_string);
            }
        }
        return Some(cred);
    }
    None
}

pub fn parse_claude(root: &Value) -> Option<ClaudeCredential> {
    let oauth = root.get("claudeAiOauth")?;
    let access_token = str_field(oauth, &["accessToken", "access_token"])?.to_string();
    let expires_at = oauth.get("expiresAt").and_then(|v| {
        let n = v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))?;
        Some(if n > 10_000_000_000.0 { (n / 1000.0) as i64 } else { n as i64 })
    });
    Some(ClaudeCredential {
        access_token,
        expires_at,
        email: str_field(oauth, &["emailAddress", "email"]).map(str::to_string),
        subscription: str_field(oauth, &["subscriptionType"]).map(str::to_string),
    })
}

pub fn load_codex(roots: &[HomeRoot]) -> Option<CodexCredential> {
    let candidates = candidate_paths(paths::codex_dir().join("auth.json"), roots, ".codex/auth.json");
    candidates.iter().find_map(|p| read_json(p).and_then(|v| parse_codex(&v)))
}

pub fn parse_codex(root: &Value) -> Option<CodexCredential> {
    let tokens = root.get("tokens")?;
    let access_token = str_field(tokens, &["access_token"])?.to_string();
    let id_claims = str_field(tokens, &["id_token"]).and_then(jwt_payload);
    let access_claims = jwt_payload(&access_token);
    let auth_claim = |key: &str| -> Option<String> {
        [&id_claims, &access_claims].into_iter().flatten().find_map(|c| {
            c.get("https://api.openai.com/auth")
                .and_then(|a| str_field(a, &[key]))
                .map(str::to_string)
        })
    };
    Some(CodexCredential {
        account_id: str_field(tokens, &["account_id"])
            .map(str::to_string)
            .or_else(|| auth_claim("chatgpt_account_id")),
        email: id_claims.as_ref().and_then(|c| str_field(c, &["email"])).map(str::to_string),
        plan_type: auth_claim("chatgpt_plan_type"),
        access_token,
    })
}

pub fn load_grok(roots: &[HomeRoot]) -> Option<GrokCredential> {
    let candidates = candidate_paths(paths::grok_dir().join("auth.json"), roots, ".grok/auth.json");
    candidates.iter().find_map(|p| read_json(p).and_then(|v| parse_grok(&v)))
}

/// 只认 xAI 自己的账号记录，绝不把自定义 provider 的密钥发给 xAI。
pub fn parse_grok(root: &Value) -> Option<GrokCredential> {
    let map = root.as_object()?;
    let mut records: Vec<&Value> = map
        .iter()
        .filter(|(k, _)| k.starts_with("https://auth.x.ai::") || k.as_str() == "https://accounts.x.ai/sign-in")
        .map(|(_, v)| v)
        .collect();
    records.sort_by_key(|r| std::cmp::Reverse(r.get("expires_at").and_then(Value::as_str).unwrap_or("").to_string()));
    let record = records.into_iter().find(|r| str_field(r, &["key"]).is_some() && str_field(r, &["user_id"]).is_some())?;
    Some(GrokCredential {
        access_token: str_field(record, &["key"])?.to_string(),
        email: str_field(record, &["email"]).map(str::to_string),
    })
}

fn jwt_payload(token: &str) -> Option<Value> {
    let part = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(part.trim_end_matches('='))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn claude_millis_expiry() {
        let v = json!({"claudeAiOauth": {"accessToken": "a", "expiresAt": 1_900_000_000_000i64}});
        let c = parse_claude(&v).unwrap();
        assert_eq!(c.expires_at, Some(1_900_000_000));
    }

    #[test]
    fn codex_reads_jwt_claims() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            json!({"email": "a@b.c", "https://api.openai.com/auth": {"chatgpt_plan_type": "plus", "chatgpt_account_id": "acc"}}).to_string(),
        );
        let id = format!("x.{payload}.y");
        let v = json!({"tokens": {"access_token": "tok", "id_token": id}});
        let c = parse_codex(&v).unwrap();
        assert_eq!(c.email.as_deref(), Some("a@b.c"));
        assert_eq!(c.plan_type.as_deref(), Some("plus"));
        assert_eq!(c.account_id.as_deref(), Some("acc"));
    }

    #[test]
    fn grok_ignores_custom_providers() {
        let v = json!({"https://custom.example": {"key": "secret", "user_id": "u"}});
        assert!(parse_grok(&v).is_none());
        let v = json!({"https://auth.x.ai::abc": {"key": "k", "user_id": "u"}});
        assert_eq!(parse_grok(&v).unwrap().access_token, "k");
    }
}
