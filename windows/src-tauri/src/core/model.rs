//! 前后端共用的数据结构，字段名按 camelCase 序列化给前端。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum App {
    Codex,
    Claude,
    Grok,
}

impl App {
    /// 显示顺序：Codex 永远在 Claude 前，Grok 在 Claude 后。
    pub const ALL: [App; 3] = [App::Codex, App::Claude, App::Grok];

    pub fn display_name(self) -> &'static str {
        match self {
            App::Codex => "Codex",
            App::Claude => "Claude",
            App::Grok => "Grok",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    /// 0~100，已用百分比
    pub used_percent: f64,
    /// 重置时间（Unix 秒）
    pub resets_at: Option<i64>,
    pub window_seconds: Option<i64>,
}

impl QuotaWindow {
    pub fn remaining_percent(&self) -> f64 {
        (100.0 - self.used_percent).clamp(0.0, 100.0)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub five_hour: Option<QuotaWindow>,
    pub weekly: Option<QuotaWindow>,
    /// 非 5 小时周期的主额度（Grok 的周 / 月额度）
    pub primary: Option<QuotaWindow>,
    pub primary_label: Option<String>,
    pub plan_type: Option<String>,
    pub fetched_at: i64,
}

impl QuotaSnapshot {
    /// 这个服务里最紧张（剩余最少）的那一档。
    pub fn tightest_remaining(&self) -> Option<f64> {
        [&self.five_hour, &self.weekly, &self.primary]
            .into_iter()
            .flatten()
            .map(QuotaWindow::remaining_percent)
            .reduce(f64::min)
    }
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceView {
    pub app: Option<App>,
    pub enabled: bool,
    /// 本机找到了登录凭据
    pub detected: bool,
    pub account: Option<String>,
    pub quota: Option<QuotaSnapshot>,
    pub error: Option<String>,
    pub last_success_at: Option<i64>,
    pub backoff_until: Option<i64>,
    pub in_flight: bool,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageTotals {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cost_usd: f64,
}

impl UsageTotals {
    pub fn total_tokens(&self) -> u64 {
        self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_creation_tokens
    }

    pub fn add(&mut self, other: &UsageTotals) {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.cache_creation_tokens += other.cache_creation_tokens;
        self.cost_usd += other.cost_usd;
    }
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeriodSummary {
    pub cost_usd: f64,
    pub tokens: u64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppUsage {
    pub app: Option<App>,
    pub today: PeriodSummary,
    pub week: PeriodSummary,
    pub month: PeriodSummary,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageSummary {
    pub today: PeriodSummary,
    pub week: PeriodSummary,
    pub month: PeriodSummary,
    pub per_app: Vec<AppUsage>,
    /// 近 30 天每天的花费，旧 → 新
    pub daily: Vec<DailyPoint>,
    pub scanned_at: Option<i64>,
    pub scanning: bool,
    pub files_scanned: usize,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DailyPoint {
    /// YYYY-MM-DD（本地时区）
    pub day: String,
    pub codex: f64,
    pub claude: f64,
    pub grok: f64,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub services: Vec<ServiceView>,
    pub usage: UsageSummary,
    pub settings: crate::settings::Settings,
}

pub fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}
