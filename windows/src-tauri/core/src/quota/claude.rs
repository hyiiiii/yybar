//! Claude：`GET https://api.anthropic.com/api/oauth/usage`（对应 Mac `ClaudeQuotaClient`）。

use serde_json::Value;

use super::{client, get_json, num, QuotaError, QuotaSnapshot, QuotaWindow};
use crate::credentials::parse_iso;
use crate::{now_secs, UsageApp};

pub const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";

pub async fn fetch(access_token: &str) -> Result<QuotaSnapshot, QuotaError> {
    let req = client()
        .get(ENDPOINT)
        .bearer_auth(access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("Accept", "application/json")
        .header("User-Agent", "claude-code/2.1.0");
    let root = get_json(req).await?;
    Ok(parse(&root, now_secs()))
}

pub fn parse(root: &Value, now: i64) -> QuotaSnapshot {
    let window = |key: &str| -> Option<QuotaWindow> {
        let w = root.get(key).filter(|v| v.is_object())?;
        Some(QuotaWindow {
            used_percent: num(w.get("utilization")).unwrap_or(0.0),
            resets_at: parse_iso(w.get("resets_at")).or_else(|| num(w.get("resets_at")).map(|n| n as i64)),
            window_seconds: None,
        })
    };
    let mut snap = QuotaSnapshot::empty(UsageApp::Claude, now);
    snap.five_hour = window("five_hour");
    snap.weekly = window("seven_day");
    snap.weekly_opus = window("seven_day_opus");
    snap.weekly_sonnet = window("seven_day_sonnet");
    snap
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn windows() {
        let v = json!({"five_hour": {"utilization": 22.0, "resets_at": "2026-10-19T05:00:00.123+00:00"}, "seven_day": {"utilization": 36}, "seven_day_opus": null});
        let s = parse(&v, 0);
        assert_eq!(s.five_hour.unwrap().resets_at, Some(1_792_386_000));
        assert_eq!(s.weekly.unwrap().used_percent, 36.0);
        assert!(s.weekly_opus.is_none());
    }
}
