//! Codex：`GET https://chatgpt.com/backend-api/wham/usage`（对应 Mac `CodexQuotaClient`）。

use serde_json::Value;

use super::{client, get_json, num, QuotaError, QuotaSnapshot, QuotaWindow};
use crate::{now_secs, UsageApp};

pub const ENDPOINT: &str = "https://chatgpt.com/backend-api/wham/usage";

pub async fn fetch(access_token: &str, account_id: Option<&str>) -> Result<QuotaSnapshot, QuotaError> {
    let mut req = client()
        .get(ENDPOINT)
        .bearer_auth(access_token)
        .header("Accept", "application/json")
        .header("User-Agent", "codex-cli");
    if let Some(id) = account_id.filter(|s| !s.is_empty()) {
        req = req.header("ChatGPT-Account-Id", id);
    }
    let root = get_json(req).await?;
    Ok(parse(&root, now_secs()))
}

pub fn parse(root: &Value, now: i64) -> QuotaSnapshot {
    let rate = root.get("rate_limit");
    let window = |key: &str| -> Option<QuotaWindow> {
        let w = rate?.get(key).filter(|v| v.is_object())?;
        let resets_at = num(w.get("reset_at"))
            .map(|n| n as i64)
            .or_else(|| num(w.get("reset_after_seconds")).map(|s| now + s as i64));
        Some(QuotaWindow {
            used_percent: num(w.get("used_percent")).unwrap_or(0.0),
            resets_at,
            window_seconds: num(w.get("limit_window_seconds")).map(|n| n as i64),
        })
    };
    let mut snap = QuotaSnapshot::empty(UsageApp::Codex, now);
    snap.five_hour = window("primary_window");
    snap.weekly = window("secondary_window");
    snap.plan_type = root.get("plan_type").and_then(Value::as_str).map(str::to_string);
    snap
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn windows() {
        let v = json!({"plan_type": "plus", "rate_limit": {
            "primary_window": {"used_percent": 58, "reset_at": 1_900_000_000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 69.5, "reset_after_seconds": 100}
        }});
        let s = parse(&v, 1000);
        assert_eq!(s.five_hour.as_ref().unwrap().remaining_percent(), 42.0);
        assert_eq!(s.weekly.as_ref().unwrap().resets_at, Some(1100));
        assert_eq!(s.plan_type.as_deref(), Some("plus"));
    }
}
