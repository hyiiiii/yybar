//! 粘贴凭据（对应 Mac `ImportedCodexPaste` / `ExtraAccountPaste`）：把用户从另一台电脑复制来的凭据文件内容
//! 整理成 CLI 自己的格式，写进账号目录。
//! - Codex：完整的 `auth.json`、只有 `tokens` 那一段、或者它们组成的数组（一次加几个）。
//! - Claude Code：`.credentials.json`（带 `claudeAiOauth`），或者直接是 `claudeAiOauth` 那一段。
//! - Grok：`auth.json`，必须含 xAI 官方账号（auth.x.ai）的记录，原样保存。

use serde_json::{json, Map, Value};

use super::AccountError;
use crate::credentials::{codex, grok};
use crate::tr;

fn parse_json(text: &str) -> Result<Value, AccountError> {
    let trimmed = text.trim().trim_start_matches('\u{feff}');
    serde_json::from_str(trimmed).map_err(|_| AccountError::msg(tr("The pasted text isn't valid JSON", "粘贴内容不是合法 JSON")))
}

/// Codex：返回一个或多个可以直接存成 `auth.json` 的对象（跳过数组里读不出账号的项）。
pub fn codex(text: &str) -> Result<Vec<Value>, AccountError> {
    let root = parse_json(text)?;
    let items: Vec<&Value> = match &root {
        Value::Array(list) => list.iter().collect(),
        other => vec![other],
    };
    let mut out: Vec<(String, Value)> = Vec::new();
    let mut last_error = None;
    for item in items {
        match codex_one(item) {
            Ok((id, auth)) => {
                // 同一个账号粘了两次只留后一份
                out.retain(|(other, _)| *other != id);
                out.push((id, auth));
            }
            Err(e) => last_error = Some(e),
        }
    }
    if out.is_empty() {
        return Err(last_error.unwrap_or_else(|| AccountError::msg(tr("No usable credentials found", "没有找到可用的凭据"))));
    }
    Ok(out.into_iter().map(|(_, v)| v).collect())
}

fn codex_one(item: &Value) -> Result<(String, Value), AccountError> {
    let obj = item.as_object().ok_or_else(|| AccountError::msg(tr("The pasted text isn't valid JSON", "粘贴内容不是合法 JSON")))?;
    let tokens = match obj.get("tokens") {
        Some(Value::Object(t)) => t.clone(),
        _ if obj.get("access_token").is_some_and(Value::is_string) => obj.clone(),
        _ => return Err(AccountError::msg(tr("The JSON has no `tokens` field", "JSON 里没有 tokens 字段"))),
    };
    let mut root: Map<String, Value> = if obj.contains_key("tokens") { obj.clone() } else { Map::new() };
    root.entry("OPENAI_API_KEY").or_insert(Value::Null);
    root.insert("auth_mode".into(), "chatgpt".into());
    root.insert("tokens".into(), Value::Object(tokens));
    let auth = Value::Object(root);
    let parsed = codex::parse(&auth, Default::default())
        .ok_or_else(|| AccountError::msg(tr("`tokens.access_token` is missing", "缺少 tokens.access_token")))?;
    let account_id = parsed
        .account_id
        .ok_or_else(|| AccountError::msg(tr("Couldn't find chatgpt_account_id in the token", "无法从 token 里找到 chatgpt_account_id")))?;
    Ok((format!("{account_id}:{}", parsed.chatgpt_user_id.unwrap_or_default()), auth))
}

/// Claude：返回可以存成 `.credentials.json` 的对象 `{ "claudeAiOauth": … }`。
pub fn claude(text: &str) -> Result<Value, AccountError> {
    let root = parse_json(text)?;
    let oauth = root.get("claudeAiOauth").unwrap_or(&root);
    let access = oauth
        .get("accessToken")
        .or_else(|| oauth.get("access_token"))
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty());
    if access.is_none() {
        return Err(AccountError::msg(tr("No usable credentials found: claudeAiOauth.accessToken", "没有找到可用的凭据：claudeAiOauth.accessToken")));
    }
    let mut oauth = oauth.as_object().cloned().unwrap_or_default();
    // 统一成 CLI 用的驼峰字段
    for (snake, camel) in [("access_token", "accessToken"), ("refresh_token", "refreshToken"), ("expires_at", "expiresAt")] {
        if let Some(v) = oauth.remove(snake) {
            oauth.entry(camel).or_insert(v);
        }
    }
    Ok(json!({ "claudeAiOauth": Value::Object(oauth) }))
}

/// Grok：校验有 xAI 官方账号记录，原样返回。
pub fn grok(text: &str) -> Result<Value, AccountError> {
    let root = parse_json(text)?;
    let ok = root.as_object().is_some_and(|m| {
        m.iter()
            .any(|(k, v)| grok::is_first_party(k) && v.get("key").and_then(Value::as_str).is_some_and(|s| !s.is_empty()))
    });
    if !ok {
        return Err(AccountError::msg(tr("No usable credentials found: auth.x.ai", "没有找到可用的凭据：auth.x.ai")));
    }
    Ok(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn jwt(account: &str, user: &str) -> String {
        let claims = json!({"https://api.openai.com/auth": {"chatgpt_account_id": account, "chatgpt_user_id": user}});
        format!("h.{}.s", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string()))
    }

    #[test]
    fn codex_accepts_full_bare_and_arrays() {
        let full = json!({"OPENAI_API_KEY": null, "tokens": {"access_token": jwt("a", "u1"), "refresh_token": "r"}, "last_refresh": "x"});
        let out = codex(&full.to_string()).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["tokens"]["refresh_token"], "r");
        assert_eq!(out[0]["auth_mode"], "chatgpt");

        let bare = json!({"access_token": jwt("b", "u2"), "account_id": "b"});
        assert_eq!(codex(&bare.to_string()).unwrap()[0]["tokens"]["account_id"], "b");

        // 数组：同一账号去重，读不出的项跳过
        let list = json!([bare, {"nope": 1}, {"access_token": jwt("b", "u2")}, full]);
        assert_eq!(codex(&list.to_string()).unwrap().len(), 2);

        assert!(codex("not json").is_err());
        assert!(codex(r#"{"tokens": {"refresh_token": "r"}}"#).is_err());
    }

    #[test]
    fn claude_normalizes_fields() {
        let out = claude(r#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1900000000000,"subscriptionType":"max"},"mcpOAuth":{}}"#).unwrap();
        assert_eq!(out["claudeAiOauth"]["accessToken"], "a");
        assert!(out.get("mcpOAuth").is_none());
        let bare = claude(r#"{"access_token":"a","refresh_token":"r"}"#).unwrap();
        assert_eq!(bare["claudeAiOauth"]["refreshToken"], "r");
        assert!(claude(r#"{"claudeAiOauth":{}}"#).is_err());
    }

    #[test]
    fn grok_requires_first_party() {
        assert!(grok(r#"{"https://auth.x.ai::k":{"key":"k","user_id":"u"}}"#).is_ok());
        assert!(grok(r#"{"https://custom.example":{"key":"k"}}"#).is_err());
    }
}
