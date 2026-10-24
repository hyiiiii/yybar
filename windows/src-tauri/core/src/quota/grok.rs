//! Grok：`GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`，和 Grok CLI `/usage` 同一只读接口
//! （对应 Mac `GrokQuotaClient`）。token 将过期或 401 时让本机 `grok models`（只读命令，不发起对话）续期。

use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;

use super::{client, get_json, QuotaError, QuotaSnapshot, QuotaWindow};
use crate::credentials::{parse_iso, GrokAccount};
use crate::paths;
use crate::{now_secs, UsageApp};

pub const ENDPOINT: &str = "https://cli-chat-proxy.grok.com/v1/billing?format=credits";
pub const SETTINGS_ENDPOINT: &str = "https://cli-chat-proxy.grok.com/v1/settings";

pub async fn fetch(account: &GrokAccount) -> Result<QuotaSnapshot, QuotaError> {
    let req = client()
        .get(ENDPOINT)
        .bearer_auth(&account.access_token)
        .header("X-XAI-Token-Auth", "xai-grok-cli")
        .header("Accept", "application/json")
        .timeout(Duration::from_secs(20));
    let root = match get_json(req).await {
        // 不把响应正文带进错误（可能含账号信息）
        Err(QuotaError::Http(code, _)) => return Err(QuotaError::Http(code, "Grok billing request failed".into())),
        other => other?,
    };
    parse(&root, now_secs())
}

/// 订阅等级展示名（如 "SuperGrok"）。拿不到时返回 None，不影响额度。
pub async fn fetch_plan(account: &GrokAccount) -> Option<String> {
    let req = client()
        .get(SETTINGS_ENDPOINT)
        .bearer_auth(&account.access_token)
        .header("X-XAI-Token-Auth", "xai-grok-cli")
        .header("Accept", "application/json")
        .timeout(Duration::from_secs(20));
    let root = get_json(req).await.ok()?;
    root.get("subscription_tier_display")?.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

pub fn parse(root: &Value, now: i64) -> Result<QuotaSnapshot, QuotaError> {
    let invalid = || QuotaError::Decode("Grok billing response has no valid usage period".into());
    let config = root.get("config").ok_or_else(invalid)?;
    let period = config.get("currentPeriod").ok_or_else(invalid)?;
    let (Some(start), Some(end)) = (parse_iso(period.get("start")), parse_iso(period.get("end"))) else {
        return Err(invalid());
    };
    if end <= start {
        return Err(invalid());
    }
    // 新周期刚开始时接口会省略为 0 的字段：缺失按 0；null、布尔、负数等仍算解析失败。
    let used = match config.get("creditUsagePercent") {
        None => 0.0,
        Some(v) => match v.as_f64() {
            Some(n) if n.is_finite() && n >= 0.0 && !v.is_boolean() => n,
            _ => return Err(QuotaError::Decode("Grok billing response has an invalid usage percentage".into())),
        },
    };
    let kind = period.get("type").and_then(Value::as_str).unwrap_or("");
    let label = match kind {
        "USAGE_PERIOD_TYPE_WEEKLY" => "WEEK · 本周",
        "USAGE_PERIOD_TYPE_MONTHLY" => "MONTH · 本月",
        "USAGE_PERIOD_TYPE_DAILY" => "DAY · 今日",
        _ => "PERIOD · 当前周期",
    };
    let window = QuotaWindow { used_percent: used, resets_at: Some(end), window_seconds: Some(end - start) };
    let mut snap = QuotaSnapshot::empty(UsageApp::Grok, now);
    if kind == "USAGE_PERIOD_TYPE_WEEKLY" {
        snap.weekly = Some(window.clone());
    }
    snap.primary = Some(window);
    snap.primary_label = Some(label.into());
    Ok(snap)
}

/// 本机 grok CLI。
pub fn binary() -> Option<PathBuf> {
    let home = paths::home();
    paths::find_executable("grok", &[home.join(".grok").join("bin"), home.join(".local").join("bin")])
}

/// 让已安装的 CLI 自己续期 token（`grok models` 只读、不产生对话或计费）。最多等 25 秒。
pub async fn refresh_credentials() -> bool {
    let Some(binary) = binary() else { return false };
    let mut cmd = tokio::process::Command::new(binary);
    cmd.arg("models")
        .current_dir(paths::grok_dir())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    paths::hide_console(&mut cmd);
    let Ok(mut child) = cmd.spawn() else { return false };
    match tokio::time::timeout(Duration::from_secs(25), child.wait()).await {
        Ok(Ok(status)) => status.success(),
        _ => {
            let _ = child.kill().await;
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn missing_usage_is_zero() {
        let v = json!({"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-13T00:00:00Z", "end": "2026-10-20T00:00:00Z"}}});
        let s = parse(&v, 0).unwrap();
        assert_eq!(s.primary.as_ref().unwrap().used_percent, 0.0);
        assert!(s.weekly.is_some());
        assert_eq!(s.primary_label.as_deref(), Some("WEEK · 本周"));
        let bad = json!({"config": {"creditUsagePercent": true, "currentPeriod": {"start": "2026-10-13T00:00:00Z", "end": "2026-10-20T00:00:00Z"}}});
        assert!(parse(&bad, 0).is_err());
    }
}
