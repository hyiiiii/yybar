//! Claude 账号资料（对应 Mac `ClaudeProfileClient`）：`GET api.anthropic.com/api/oauth/profile`。
//! 粘贴的凭据里常常没有邮箱，用它补齐邮箱、订阅等级和订阅开始日（推算续费日）；切换本机 Claude Code 账号时，
//! 没有保存 `oauthAccount` 的账号也用它拼一份写进 `.claude.json`。失败返回 None，不影响添加。

use serde_json::{Map, Value};

use crate::credentials::parse_iso;
use crate::quota::client;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ClaudeProfile {
    pub email: Option<String>,
    /// max / pro / team / enterprise
    pub plan: Option<String>,
    /// 订阅开始日；订阅状态不是 active（已取消等）时没有。
    pub subscription_started_at: Option<i64>,
    /// 拼好的 `.claude.json` oauthAccount（没有邮箱时为 None）。
    pub oauth_account: Option<Value>,
    pub rate_limit_tier: Option<String>,
}

pub async fn fetch(access_token: &str) -> Option<ClaudeProfile> {
    let resp = client()
        .get("https://api.anthropic.com/api/oauth/profile")
        .bearer_auth(access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("Accept", "application/json")
        .timeout(std::time::Duration::from_secs(15))
        .send()
        .await
        .ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let root: Value = resp.json().await.ok()?;
    Some(parse(&root))
}

pub fn parse(root: &Value) -> ClaudeProfile {
    let empty = Value::Object(Map::new());
    let account = root.get("account").unwrap_or(&empty);
    let org = root.get("organization").unwrap_or(&empty);
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).filter(|x| !x.is_empty()).map(str::to_string);
    let email = s(account, "email_address").or_else(|| s(account, "email"));
    let plan = match s(org, "organization_type") {
        // claude_max / claude_pro / claude_team / claude_enterprise → max / pro / team / enterprise
        Some(t) => Some(t.strip_prefix("claude_").unwrap_or(&t).to_string()),
        None if account.get("has_claude_max").and_then(Value::as_bool) == Some(true) => Some("max".into()),
        None if account.get("has_claude_pro").and_then(Value::as_bool) == Some(true) => Some("pro".into()),
        None => None,
    };
    let active = s(org, "subscription_status").map_or(true, |st| st == "active");
    let mut oauth = Map::new();
    for (to, from, src) in [
        ("accountUuid", "uuid", account),
        ("emailAddress", "email_address", account),
        ("displayName", "display_name", account),
        ("fullName", "full_name", account),
        ("organizationUuid", "uuid", org),
        ("organizationName", "name", org),
        ("organizationType", "organization_type", org),
        ("billingType", "billing_type", org),
        ("organizationRateLimitTier", "rate_limit_tier", org),
        ("subscriptionCreatedAt", "subscription_created_at", org),
    ] {
        if let Some(v) = src.get(from).filter(|v| !v.is_null()) {
            oauth.insert(to.into(), v.clone());
        }
    }
    if !oauth.contains_key("emailAddress") {
        if let Some(e) = &email {
            oauth.insert("emailAddress".into(), e.clone().into());
        }
    }
    ClaudeProfile {
        oauth_account: email.as_ref().map(|_| Value::Object(oauth)),
        email,
        plan,
        subscription_started_at: if active { parse_iso(org.get("subscription_created_at")) } else { None },
        rate_limit_tier: s(org, "rate_limit_tier"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_profile() {
        let p = parse(&json!({
            "account": {"uuid": "u", "email_address": "a@b.c", "display_name": "A"},
            "organization": {"uuid": "o", "organization_type": "claude_max", "rate_limit_tier": "default_claude_max_20x",
                             "subscription_status": "active", "subscription_created_at": "2026-09-05T08:00:00Z"}
        }));
        assert_eq!(p.email.as_deref(), Some("a@b.c"));
        assert_eq!(p.plan.as_deref(), Some("max"));
        assert!(p.subscription_started_at.is_some());
        assert_eq!(p.oauth_account.as_ref().unwrap()["organizationType"], "claude_max");
        assert_eq!(p.rate_limit_tier.as_deref(), Some("default_claude_max_20x"));

        let cancelled = parse(&json!({"account": {"has_claude_pro": true}, "organization": {"subscription_status": "canceled", "subscription_created_at": "2026-09-05T08:00:00Z"}}));
        assert_eq!(cancelled.plan.as_deref(), Some("pro"));
        assert!(cancelled.subscription_started_at.is_none());
        assert!(cancelled.oauth_account.is_none());
    }
}
