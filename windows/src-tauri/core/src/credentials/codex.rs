//! Codex：`~/.codex/auth.json`（或 `CODEX_HOME`），解析 JWT 拿邮箱 / plan / accountId（对应 Mac `CodexAuth`）。

use std::path::PathBuf;

use serde_json::Value;

use super::{candidate_paths, jwt, read_json, str_field};
use crate::paths::{self, HomeRoot};

#[derive(Debug, Clone, PartialEq, Default)]
pub struct CodexAccount {
    pub email: Option<String>,
    pub plan_type: Option<String>,
    pub account_id: Option<String>,
    pub chatgpt_user_id: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub id_token: Option<String>,
    /// 当前付费周期结束日（下次续费日），免费账号没有。
    pub subscription_active_until: Option<i64>,
    /// 凭据文件位置（续期后写回这里）。
    pub path: PathBuf,
}

pub fn auth_file() -> PathBuf {
    paths::codex_dir().join("auth.json")
}

pub fn load(wsl: &[HomeRoot]) -> Option<CodexAccount> {
    candidate_paths(auth_file(), wsl, ".codex/auth.json")
        .into_iter()
        .find_map(|p| read_json(&p).and_then(|v| parse(&v, p.clone())))
}

pub fn parse(root: &Value, path: PathBuf) -> Option<CodexAccount> {
    let tokens = root.get("tokens")?;
    let access_token = str_field(tokens, &["access_token"]).map(str::to_string);
    let id_token = str_field(tokens, &["id_token"]).map(str::to_string);
    access_token.as_ref()?;
    let id_claims = id_token.as_deref().and_then(jwt::decode_payload);
    let access_claims = access_token.as_deref().and_then(jwt::decode_payload);
    let auth_claim = |claims: &Option<Value>, key: &str| -> Option<String> {
        claims
            .as_ref()?
            .get("https://api.openai.com/auth")
            .and_then(|a| str_field(a, &[key]))
            .map(str::to_string)
    };
    let plan_type = auth_claim(&id_claims, "chatgpt_plan_type")
        .or_else(|| id_claims.as_ref().and_then(|c| str_field(c, &["chatgpt_plan_type"])).map(str::to_string))
        .or_else(|| auth_claim(&access_claims, "chatgpt_plan_type"));
    let account_id = str_field(tokens, &["account_id"])
        .map(str::to_string)
        .or_else(|| auth_claim(&access_claims, "chatgpt_account_id"))
        .or_else(|| auth_claim(&id_claims, "chatgpt_account_id"));
    let chatgpt_user_id = auth_claim(&access_claims, "chatgpt_user_id").or_else(|| auth_claim(&id_claims, "chatgpt_user_id"));
    let subscription_active_until = id_claims
        .as_ref()
        .and_then(|c| c.get("https://api.openai.com/auth"))
        .and_then(|a| super::parse_iso(a.get("chatgpt_subscription_active_until")));
    Some(CodexAccount {
        email: id_claims.as_ref().and_then(|c| str_field(c, &["email"])).map(str::to_string),
        plan_type,
        account_id,
        chatgpt_user_id,
        refresh_token: str_field(tokens, &["refresh_token"]).map(str::to_string),
        access_token,
        id_token,
        subscription_active_until,
        path,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use serde_json::json;

    #[test]
    fn reads_jwt_claims() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
            json!({"email": "a@b.c", "https://api.openai.com/auth": {"chatgpt_plan_type": "plus", "chatgpt_account_id": "acc",
                "chatgpt_subscription_active_until": "2026-11-20T00:00:00Z"}})
            .to_string(),
        );
        let id = format!("x.{payload}.y");
        let v = json!({"tokens": {"access_token": "tok", "id_token": id, "refresh_token": "r"}});
        let c = parse(&v, PathBuf::new()).unwrap();
        assert_eq!(c.email.as_deref(), Some("a@b.c"));
        assert_eq!(c.plan_type.as_deref(), Some("plus"));
        assert_eq!(c.account_id.as_deref(), Some("acc"));
        assert_eq!(c.subscription_active_until, Some(1_795_132_800));
        assert_eq!(c.refresh_token.as_deref(), Some("r"));
    }
}
