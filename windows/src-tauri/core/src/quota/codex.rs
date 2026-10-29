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
    (snap.five_hour, snap.weekly) = slot(window("primary_window"), window("secondary_window"));
    snap.plan_type = root.get("plan_type").and_then(Value::as_str).map(str::to_string);
    snap
}

/// 按窗口长度放格子，不按接口里的先后：不到一天的是 5H，一天以上的是长窗口（每周，或免费账号的每月，标签按长度写 WK / MO）。
/// ChatGPT Pro 现在只有周额度、免费账号只有月额度，它们排在 primary_window，以前都被当成了 5H。没给长度时照先后。
fn slot(primary: Option<QuotaWindow>, secondary: Option<QuotaWindow>) -> (Option<QuotaWindow>, Option<QuotaWindow>) {
    let mut five_hour = None;
    let mut long: Option<QuotaWindow> = None;
    for (index, window) in [primary, secondary].into_iter().enumerate() {
        let Some(window) = window else { continue };
        let is_long = window.window_seconds.map_or(index == 1, |s| s >= 86_400);
        if is_long {
            // 两个都是长窗口时（周 + 月），格子里放短的那个
            if long.as_ref().is_some_and(|cur| cur.window_seconds.unwrap_or(0) <= window.window_seconds.unwrap_or(0)) {
                continue;
            }
            long = Some(window);
        } else if five_hour.is_none() {
            five_hour = Some(window);
        }
    }
    (five_hour, long)
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

    #[test]
    fn weekly_only_and_monthly_go_to_the_long_slot() {
        // ChatGPT Pro：只有周额度，放在 primary_window
        let pro = json!({"plan_type": "pro", "rate_limit": {"primary_window": {"used_percent": 30, "limit_window_seconds": 604800}}});
        let s = parse(&pro, 0);
        assert!(s.five_hour.is_none());
        assert_eq!(s.weekly.as_ref().unwrap().window_seconds, Some(604800));
        // 免费账号：只有月额度
        let free = json!({"plan_type": "free", "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 2592000}}});
        let s = parse(&free, 0);
        assert!(s.five_hour.is_none());
        assert_eq!(s.weekly.as_ref().unwrap().window_seconds, Some(2592000));
        // 5 小时 + 每周照旧
        let plus = json!({"rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2, "limit_window_seconds": 604800}}});
        let s = parse(&plus, 0);
        assert_eq!(s.five_hour.as_ref().unwrap().window_seconds, Some(18000));
        assert_eq!(s.weekly.as_ref().unwrap().window_seconds, Some(604800));
    }
}
