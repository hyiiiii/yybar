//! 官方服务状态圆点（对应 Mac `ServiceStatusClient`）。
//! - OpenAI / Anthropic：Statuspage.io 的 summary.json，只看和 CLI 相关的组件。
//! - xAI：status.x.ai 的 JSON 被 Cloudflare 拦，只读 RSS（feed.xml）。
//! - Google（Antigravity）：两份公开的 incidents.json，只看受影响产品名含 Gemini、还没结束的事件。
//! 拉取失败时调用方保留上一份，不清空。

use std::time::Duration;

use serde::Serialize;
use serde_json::Value;

use super::client;
use crate::credentials::parse_iso;
use crate::l10n::tr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Indicator {
    None,
    Minor,
    Major,
    Critical,
    Maintenance,
    Unknown,
}

impl Indicator {
    fn rank(self) -> i32 {
        match self {
            Indicator::Unknown => -1,
            Indicator::None => 0,
            Indicator::Maintenance => 1,
            Indicator::Minor => 2,
            Indicator::Major => 3,
            Indicator::Critical => 4,
        }
    }

    pub fn label(self) -> String {
        match self {
            Indicator::None => tr("All systems normal", "服务正常"),
            Indicator::Minor => tr("Minor issue", "轻微故障"),
            Indicator::Major => tr("Major issue", "重大故障"),
            Indicator::Critical => tr("Critical outage", "严重故障"),
            Indicator::Maintenance => tr("Maintenance", "维护中"),
            Indicator::Unknown => tr("Status unknown", "状态未知"),
        }
    }

    fn from_statuspage(s: &str) -> Indicator {
        match s {
            "none" => Indicator::None,
            "minor" => Indicator::Minor,
            "major" => Indicator::Major,
            "critical" => Indicator::Critical,
            "maintenance" => Indicator::Maintenance,
            _ => Indicator::Unknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceStatus {
    pub indicator: Indicator,
    pub description: Option<String>,
    pub updated_at: Option<i64>,
    pub fetched_at: i64,
}

pub const OPENAI_URL: &str = "https://status.openai.com/api/v2/summary.json";
pub const ANTHROPIC_URL: &str = "https://status.claude.com/api/v2/summary.json";
pub const OPENAI_COMPONENTS: &[&str] = &["Codex", "Responses", "Login"];
pub const ANTHROPIC_COMPONENTS: &[&str] = &["Claude Code", "Claude API"];
pub const XAI_FEED: &str = "https://status.x.ai/feed.xml";
const XAI_COMPONENTS: &[&str] = &["Grok (Build)", "Global (api.x.ai)"];
pub const GOOGLE_FEEDS: &[&str] = &[
    "https://www.google.com/appsstatus/dashboard/incidents.json",
    "https://status.cloud.google.com/incidents.json",
];

async fn get_text(url: &str) -> Option<String> {
    let resp = client().get(url).timeout(Duration::from_secs(10)).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    resp.text().await.ok()
}

pub async fn fetch_statuspage(url: &str, components: &[&str]) -> Option<ServiceStatus> {
    let text = get_text(url).await?;
    parse_statuspage(&serde_json::from_str(&text).ok()?, components, crate::now_secs())
}

pub fn parse_statuspage(root: &Value, relevant: &[&str], now: i64) -> Option<ServiceStatus> {
    let status = root.get("status")?;
    let updated_at = parse_iso(root.get("page").and_then(|p| p.get("updated_at")));
    let matched: Vec<&Value> = root
        .get("components")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|c| {
            let name = c.get("name").and_then(Value::as_str).unwrap_or("").to_lowercase();
            relevant.iter().any(|r| name.starts_with(&r.to_lowercase()))
        })
        .collect();
    if matched.is_empty() {
        return Some(ServiceStatus {
            indicator: Indicator::from_statuspage(status.get("indicator").and_then(Value::as_str).unwrap_or("")),
            description: status.get("description").and_then(Value::as_str).map(str::to_string),
            updated_at,
            fetched_at: now,
        });
    }
    let mut worst = Indicator::None;
    let mut affected = Vec::new();
    for c in matched {
        let indicator = match c.get("status").and_then(Value::as_str).unwrap_or("") {
            "operational" => Indicator::None,
            "degraded_performance" => Indicator::Minor,
            "partial_outage" => Indicator::Major,
            "major_outage" => Indicator::Critical,
            "under_maintenance" => Indicator::Maintenance,
            _ => Indicator::Unknown,
        };
        if indicator != Indicator::None {
            affected.push(c.get("name").and_then(Value::as_str).unwrap_or("").to_string());
        }
        if indicator.rank() > worst.rank() {
            worst = indicator;
        }
    }
    let description = if affected.is_empty() { worst.label() } else { format!("{}: {}", worst.label(), affected.join(", ")) };
    Some(ServiceStatus { indicator: worst, description: Some(description), updated_at, fetched_at: now })
}

pub async fn fetch_xai() -> Option<ServiceStatus> {
    let xml = get_text(XAI_FEED).await?;
    if !xml.contains("<channel>") {
        return None;
    }
    Some(parse_xai_feed(&xml, crate::now_secs()))
}

fn tags<'a>(name: &str, text: &'a str) -> Vec<&'a str> {
    let (open, close) = (format!("<{name}>"), format!("</{name}>"));
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find(&open) {
        let after = &rest[start + open.len()..];
        let Some(end) = after.find(&close) else { break };
        out.push(after[..end].trim());
        rest = &after[end + close.len()..];
    }
    out
}

/// RSS 的 description 里有 HTML 实体，按标签直接截取。相关组件下未结束的事件决定颜色。
pub fn parse_xai_feed(xml: &str, now: i64) -> ServiceStatus {
    let mut worst = Indicator::None;
    let mut worst_title: Option<String> = None;
    let mut latest: Option<i64> = None;
    for item in tags("item", xml) {
        let Some(title) = tags("title", item).first().copied() else { continue };
        if !XAI_COMPONENTS.iter().any(|c| title.starts_with(&format!("[{c}]"))) {
            continue;
        }
        if let Some(date) = tags("pubDate", item).first().and_then(|d| chrono::DateTime::parse_from_rfc2822(d).ok()) {
            latest = Some(latest.map_or(date.timestamp(), |l| l.max(date.timestamp())));
        }
        let categories: Vec<String> = tags("category", item).iter().map(|c| c.to_lowercase()).collect();
        if categories.iter().any(|c| ["resolved", "completed", "postmortem"].contains(&c.as_str())) {
            continue;
        }
        let indicator = if categories.iter().any(|c| c == "maintenance" || c == "scheduled") {
            Indicator::Maintenance
        } else if categories.iter().any(|c| c == "outage") {
            Indicator::Major
        } else {
            Indicator::Minor
        };
        if indicator.rank() > worst.rank() {
            worst = indicator;
            worst_title = Some(title.to_string());
        }
    }
    ServiceStatus { indicator: worst, description: Some(worst_title.unwrap_or_else(|| Indicator::None.label())), updated_at: latest, fetched_at: now }
}

pub async fn fetch_google() -> Option<ServiceStatus> {
    let mut feeds = Vec::new();
    for url in GOOGLE_FEEDS {
        if let Some(text) = get_text(url).await {
            if let Ok(v) = serde_json::from_str::<Value>(&text) {
                feeds.push(v);
            }
        }
    }
    if feeds.is_empty() {
        return None;
    }
    Some(parse_google(&feeds, crate::now_secs()))
}

pub fn parse_google(feeds: &[Value], now: i64) -> ServiceStatus {
    let mut worst = Indicator::None;
    let mut title: Option<String> = None;
    for incident in feeds.iter().filter_map(Value::as_array).flatten() {
        let gemini = incident
            .get("affected_products")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|p| p.get("title").and_then(Value::as_str))
            .any(|t| t.to_lowercase().contains("gemini"));
        if !gemini {
            continue;
        }
        if incident.get("end").and_then(Value::as_str).is_some_and(|e| !e.is_empty()) {
            continue;
        }
        let indicator = match incident.get("status_impact").and_then(Value::as_str) {
            Some("SERVICE_OUTAGE") => Indicator::Major,
            Some("SERVICE_DISRUPTION") => Indicator::Minor,
            _ => Indicator::None,
        };
        if indicator.rank() > worst.rank() {
            worst = indicator;
            title = incident.get("external_desc").and_then(Value::as_str).map(str::to_string);
        }
    }
    ServiceStatus { indicator: worst, description: Some(title.unwrap_or_else(|| Indicator::None.label())), updated_at: None, fetched_at: now }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn statuspage_components() {
        let v = json!({"status": {"indicator": "minor", "description": "x"}, "components": [
            {"name": "Codex Web", "status": "operational"}, {"name": "Responses", "status": "partial_outage"}, {"name": "Sora", "status": "major_outage"}]});
        let s = parse_statuspage(&v, OPENAI_COMPONENTS, 0).unwrap();
        assert_eq!(s.indicator, Indicator::Major);
    }

    #[test]
    fn xai_feed() {
        let xml = "<rss><channel><item><title>[Grok (Build)] Slow</title><category>Outage</category></item><item><title>[Grok Web] Down</title><category>outage</category></item><item><title>[Global (api.x.ai)] old</title><category>resolved</category></item></channel></rss>";
        assert_eq!(parse_xai_feed(xml, 0).indicator, Indicator::Major);
    }
}
