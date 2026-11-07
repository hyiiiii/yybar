//! Grok：`~/.grok/auth.json` 里的 first-party xAI 账号（对应 Mac `GrokAccount`）。
//! 只认 xAI 自己的记录，绝不把自定义 provider 的密钥发给 xAI。

use std::path::PathBuf;

use serde_json::Value;

use super::{candidate_paths, parse_iso, read_json, str_field};
use crate::paths::{self, HomeRoot};

#[derive(Debug, Clone, PartialEq, Default)]
pub struct GrokAccount {
    pub access_token: String,
    /// user_id:team_id，用来发现 CLI 换了账号。
    pub identity: String,
    pub email: Option<String>,
    pub expires_at: Option<i64>,
    pub path: PathBuf,
}

pub fn auth_file() -> PathBuf {
    paths::grok_dir().join("auth.json")
}

pub fn load(wsl: &[HomeRoot]) -> Option<GrokAccount> {
    candidate_paths(auth_file(), wsl, ".grok/auth.json")
        .into_iter()
        .find_map(|p| read_json(&p).and_then(|v| parse(&v, p.clone())))
}

pub fn is_first_party(key: &str) -> bool {
    key.starts_with("https://auth.x.ai::") || key == "https://accounts.x.ai/sign-in"
}

pub fn parse(root: &Value, path: PathBuf) -> Option<GrokAccount> {
    let map = root.as_object()?;
    let mut records: Vec<&Value> = map.iter().filter(|(k, _)| is_first_party(k)).map(|(_, v)| v).collect();
    records.sort_by_key(|r| std::cmp::Reverse(parse_iso(r.get("expires_at")).unwrap_or(i64::MIN)));
    let record = records.into_iter().next()?;
    let key = str_field(record, &["key"])?;
    let user = str_field(record, &["user_id"])?;
    Some(GrokAccount {
        access_token: key.to_string(),
        identity: format!("{user}:{}", str_field(record, &["team_id"]).unwrap_or("")),
        email: str_field(record, &["email"]).map(str::to_string),
        expires_at: parse_iso(record.get("expires_at")),
        path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ignores_custom_providers() {
        let v = json!({"https://custom.example": {"key": "secret", "user_id": "u"}});
        assert!(parse(&v, PathBuf::new()).is_none());
        let v = json!({"https://auth.x.ai::abc": {"key": "k", "user_id": "u", "team_id": "t", "expires_at": "2026-10-20T00:00:00Z"}});
        let a = parse(&v, PathBuf::new()).unwrap();
        assert_eq!(a.access_token, "k");
        assert_eq!(a.identity, "u:t");
    }
}
