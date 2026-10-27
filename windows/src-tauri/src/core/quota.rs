//! 三个服务的额度接口，和 Mac 版 `Core/Quota/*QuotaClient.swift` 同一套接口与解析规则。

use std::time::Duration;

use serde_json::Value;

use super::credentials::{ClaudeCredential, CodexCredential, GrokCredential};
use super::model::{now_secs, QuotaSnapshot, QuotaWindow};

#[derive(Debug)]
pub enum QuotaError {
    Http(u16, String),
    Transport(String),
    Decode(String),
}

impl QuotaError {
    pub fn is_rate_limited(&self) -> bool {
        matches!(self, QuotaError::Http(429, _))
    }

    pub fn user_message(&self, service: &str) -> String {
        match self {
            QuotaError::Http(401 | 403, _) => match service {
                "Claude" => "Claude 登录已失效，在终端运行一次 claude 会自动续期".into(),
                "Codex" => "Codex 登录已失效，在终端运行 codex login 重新登录".into(),
                _ => format!("{service} 登录已失效，请在 CLI 里重新登录"),
            },
            QuotaError::Http(429, _) => "请求太频繁，已暂停 10 分钟".into(),
            QuotaError::Http(code, msg) => {
                let first: String = msg.lines().next().unwrap_or("").chars().take(110).collect();
                format!("HTTP {code} {first}").trim().to_string()
            }
            QuotaError::Transport(msg) => format!("网络错误：{}", msg.chars().take(110).collect::<String>()),
            QuotaError::Decode(msg) => format!("解析失败：{msg}"),
        }
    }
}

fn client() -> reqwest::Client {
    // reqwest 会读取 Windows 的系统代理设置（Internet 选项里的代理）以及 HTTPS_PROXY 环境变量。
    reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .expect("http client")
}

async fn get_json(req: reqwest::RequestBuilder) -> Result<Value, QuotaError> {
    let resp = req.send().await.map_err(|e| QuotaError::Transport(e.to_string()))?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| QuotaError::Transport(e.to_string()))?;
    if !status.is_success() {
        return Err(QuotaError::Http(status.as_u16(), body));
    }
    serde_json::from_str(&body).map_err(|e| QuotaError::Decode(e.to_string()))
}

fn num(v: Option<&Value>) -> Option<f64> {
    v.and_then(|v| v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
}

fn parse_iso(v: Option<&Value>) -> Option<i64> {
    let s = v?.as_str()?;
    chrono::DateTime::parse_from_rfc3339(s).ok().map(|d| d.timestamp())
}

// ---------- Claude ----------

pub async fn fetch_claude(cred: &ClaudeCredential) -> Result<QuotaSnapshot, QuotaError> {
    let req = client()
        .get("https://api.anthropic.com/api/oauth/usage")
        .bearer_auth(&cred.access_token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .header("Accept", "application/json")
        .header("User-Agent", "claude-code/2.1.0");
    let root = get_json(req).await?;
    Ok(parse_claude(&root, cred.subscription.clone()))
}

pub fn parse_claude(root: &Value, plan: Option<String>) -> QuotaSnapshot {
    let window = |key: &str| -> Option<QuotaWindow> {
        let w = root.get(key).filter(|v| v.is_object())?;
        Some(QuotaWindow {
            used_percent: num(w.get("utilization")).unwrap_or(0.0),
            resets_at: parse_iso(w.get("resets_at")).or_else(|| num(w.get("resets_at")).map(|n| n as i64)),
            window_seconds: None,
        })
    };
    QuotaSnapshot {
        five_hour: window("five_hour"),
        weekly: window("seven_day"),
        primary: None,
        primary_label: None,
        plan_type: plan,
        fetched_at: now_secs(),
    }
}

// ---------- Codex ----------

pub async fn fetch_codex(cred: &CodexCredential) -> Result<QuotaSnapshot, QuotaError> {
    let mut req = client()
        .get("https://chatgpt.com/backend-api/wham/usage")
        .bearer_auth(&cred.access_token)
        .header("Accept", "application/json")
        .header("User-Agent", "codex-cli");
    if let Some(id) = &cred.account_id {
        req = req.header("ChatGPT-Account-Id", id);
    }
    let root = get_json(req).await?;
    let mut snap = parse_codex(&root);
    if snap.plan_type.is_none() {
        snap.plan_type = cred.plan_type.clone();
    }
    Ok(snap)
}

pub fn parse_codex(root: &Value) -> QuotaSnapshot {
    let now = now_secs();
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
    QuotaSnapshot {
        five_hour: window("primary_window"),
        weekly: window("secondary_window"),
        primary: None,
        primary_label: None,
        plan_type: root.get("plan_type").and_then(Value::as_str).map(str::to_string),
        fetched_at: now,
    }
}

// ---------- Grok ----------

pub async fn fetch_grok(cred: &GrokCredential) -> Result<QuotaSnapshot, QuotaError> {
    let req = client()
        .get("https://cli-chat-proxy.grok.com/v1/billing?format=credits")
        .bearer_auth(&cred.access_token)
        .header("X-XAI-Token-Auth", "xai-grok-cli")
        .header("Accept", "application/json")
        .timeout(Duration::from_secs(20));
    let root = get_json(req).await?;
    parse_grok(&root)
}

pub fn parse_grok(root: &Value) -> Result<QuotaSnapshot, QuotaError> {
    let config = root.get("config").ok_or_else(|| QuotaError::Decode("no config".into()))?;
    let period = config.get("currentPeriod").ok_or_else(|| QuotaError::Decode("no currentPeriod".into()))?;
    let (Some(start), Some(end)) = (parse_iso(period.get("start")), parse_iso(period.get("end"))) else {
        return Err(QuotaError::Decode("Grok billing response has no valid usage period".into()));
    };
    if end <= start {
        return Err(QuotaError::Decode("Grok billing period is empty".into()));
    }
    // 新周期刚开始时接口会省略为 0 的字段：缺失按 0，类型不对算解析失败。
    let used = match config.get("creditUsagePercent") {
        None => 0.0,
        Some(v) => match v.as_f64() {
            Some(n) if n.is_finite() && n >= 0.0 => n,
            _ => return Err(QuotaError::Decode("Grok usage percentage invalid".into())),
        },
    };
    let kind = period.get("type").and_then(Value::as_str).unwrap_or("");
    let label = match kind {
        "USAGE_PERIOD_TYPE_WEEKLY" => "本周",
        "USAGE_PERIOD_TYPE_MONTHLY" => "本月",
        "USAGE_PERIOD_TYPE_DAILY" => "今日",
        _ => "当前周期",
    };
    let window = QuotaWindow { used_percent: used, resets_at: Some(end), window_seconds: Some(end - start) };
    Ok(QuotaSnapshot {
        five_hour: None,
        weekly: None,
        primary: Some(window),
        primary_label: Some(label.into()),
        plan_type: None,
        fetched_at: now_secs(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn codex_windows() {
        let v = json!({"plan_type": "plus", "rate_limit": {
            "primary_window": {"used_percent": 58, "reset_at": 1_900_000_000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 69.5, "reset_after_seconds": 100}
        }});
        let s = parse_codex(&v);
        assert_eq!(s.five_hour.as_ref().unwrap().remaining_percent(), 42.0);
        assert_eq!(s.weekly.as_ref().unwrap().used_percent, 69.5);
        assert_eq!(s.plan_type.as_deref(), Some("plus"));
        assert_eq!(s.tightest_remaining(), Some(30.5));
    }

    #[test]
    fn claude_windows() {
        let v = json!({"five_hour": {"utilization": 22.0, "resets_at": "2026-10-19T05:00:00.123+00:00"}, "seven_day": {"utilization": 36}, "seven_day_opus": null});
        let s = parse_claude(&v, None);
        assert_eq!(s.five_hour.unwrap().resets_at, Some(1_792_386_000));
        assert_eq!(s.weekly.unwrap().used_percent, 36.0);
    }

    #[test]
    fn grok_missing_usage_is_zero() {
        let v = json!({"config": {"currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY", "start": "2026-10-13T00:00:00Z", "end": "2026-10-20T00:00:00Z"}}});
        let s = parse_grok(&v).unwrap();
        assert_eq!(s.primary.unwrap().used_percent, 0.0);
        assert_eq!(s.primary_label.as_deref(), Some("本周"));
        let bad = json!({"config": {"creditUsagePercent": true, "currentPeriod": {"start": "2026-10-13T00:00:00Z", "end": "2026-10-20T00:00:00Z"}}});
        assert!(parse_grok(&bad).is_err());
    }
}
