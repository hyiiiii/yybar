//! 今日额度变化（`quota-history-today.json`，对应 Mac `QuotaHistoryStore`）。
//! 每个账号每个窗口（5H，以及 key 带 `#wk` 的周窗口）记最近一次采样；剩余整数百分比变化时才记一条事件。
//! 只保留本地当天的数据。

use std::collections::HashMap;

use chrono::{Local, NaiveDate, TimeZone};
use serde::{Deserialize, Serialize};

use super::{load_json, save_json};
use crate::paths;
use crate::quota::{QuotaSnapshot, QuotaWindow};
use crate::UsageApp;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HistoryWindow {
    FiveHour,
    Weekly,
}

impl HistoryWindow {
    /// Grok 没有 5H；周期额度在 primary。
    pub fn window(self, snapshot: &QuotaSnapshot) -> Option<&QuotaWindow> {
        match self {
            HistoryWindow::FiveHour => snapshot.five_hour.as_ref(),
            HistoryWindow::Weekly => snapshot.weekly.as_ref().or(snapshot.primary.as_ref()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    pub account_key: String,
    pub app: UsageApp,
    pub sampled_at: i64,
    pub remaining_percent: i32,
    pub resets_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeEvent {
    pub id: String,
    pub account_key: String,
    pub app: UsageApp,
    pub sampled_at: i64,
    pub before_remaining_percent: i32,
    pub after_remaining_percent: i32,
    pub delta_percent: i32,
    pub resets_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaHistory {
    pub day: NaiveDate,
    #[serde(default)]
    pub last_samples: HashMap<String, Sample>,
    #[serde(default)]
    pub events: Vec<ChangeEvent>,
    /// 每个 key 今天第一次采样的时间：曲线从这里开始画。
    #[serde(default)]
    pub first_sampled_at: HashMap<String, i64>,
}

pub mod keys {
    pub fn codex(account_id: Option<&str>) -> String {
        match account_id.map(str::trim).filter(|s| !s.is_empty()) {
            Some(id) => format!("codex:primary:{id}"),
            None => "codex:primary".into(),
        }
    }
    pub fn claude() -> String {
        "claude:primary".into()
    }
    pub fn grok() -> String {
        "grok:primary".into()
    }
    /// 本机 agy 的两个池子：pool 为 "gemini" 或 "3p"（Claude·GPT）。
    pub fn agy(pool: &str) -> String {
        format!("agy:{pool}")
    }
    pub fn weekly(key: &str) -> String {
        format!("{key}#wk")
    }
}

fn day_of(ts: i64) -> NaiveDate {
    Local.timestamp_opt(ts, 0).single().map(|d| d.date_naive()).unwrap_or_else(|| Local::now().date_naive())
}

impl QuotaHistory {
    pub fn empty(now: i64) -> QuotaHistory {
        QuotaHistory { day: day_of(now), last_samples: HashMap::new(), events: Vec::new(), first_sampled_at: HashMap::new() }
    }

    pub fn load(now: i64) -> QuotaHistory {
        load_json::<QuotaHistory>(&paths::data_dir().join("quota-history-today.json"))
            .map(|h| h.pruned(now))
            .unwrap_or_else(|| QuotaHistory::empty(now))
    }

    pub fn save(&self) {
        if let Err(e) = save_json(&paths::data_dir().join("quota-history-today.json"), self, true) {
            log::warn!("[QuotaHistory 额度历史] 写盘失败: {e}");
        }
    }

    /// 只留今天的数据。
    pub fn pruned(mut self, now: i64) -> QuotaHistory {
        let today = day_of(now);
        if self.day != today {
            return QuotaHistory::empty(now);
        }
        self.events.retain(|e| day_of(e.sampled_at) == today);
        self.last_samples.retain(|_, s| day_of(s.sampled_at) == today);
        self.first_sampled_at.retain(|_, t| day_of(*t) == today);
        self
    }

    /// 记一次采样（5H 和周窗口各一份）。返回是否有变化（需要写盘）。
    pub fn record(&mut self, account_key: &str, app: UsageApp, snapshot: &QuotaSnapshot, sampled_at: i64) -> bool {
        let before = self.clone();
        let next = self.clone().pruned(sampled_at);
        *self = next;
        self.record_window(account_key, app, snapshot, sampled_at, HistoryWindow::FiveHour);
        self.record_window(&keys::weekly(account_key), app, snapshot, sampled_at, HistoryWindow::Weekly);
        *self != before
    }

    fn record_window(&mut self, key: &str, app: UsageApp, snapshot: &QuotaSnapshot, at: i64, window: HistoryWindow) {
        let Some(w) = window.window(snapshot) else { return };
        self.first_sampled_at.entry(key.to_string()).or_insert(at);
        let remaining = w.remaining_percent().round().clamp(0.0, 100.0) as i32;
        let previous = self.last_samples.insert(
            key.to_string(),
            Sample { account_key: key.to_string(), app, sampled_at: at, remaining_percent: remaining, resets_at: w.resets_at },
        );
        let Some(previous) = previous else { return };
        if previous.remaining_percent == remaining {
            return;
        }
        self.events.push(ChangeEvent {
            id: format!("{key}|{at}|{}|{remaining}", previous.remaining_percent),
            account_key: key.to_string(),
            app,
            sampled_at: at,
            before_remaining_percent: previous.remaining_percent,
            after_remaining_percent: remaining,
            delta_percent: remaining - previous.remaining_percent,
            resets_at: w.resets_at,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_changes_only() {
        let now = Local::now().timestamp();
        let mut h = QuotaHistory::empty(now);
        let mut s = QuotaSnapshot::empty(UsageApp::Codex, now);
        s.five_hour = Some(QuotaWindow { used_percent: 10.0, resets_at: None, window_seconds: None });
        assert!(h.record("codex:primary", UsageApp::Codex, &s, now));
        assert!(h.events.is_empty());
        h.record("codex:primary", UsageApp::Codex, &s, now + 1);
        assert!(h.events.is_empty());
        s.five_hour.as_mut().unwrap().used_percent = 25.0;
        h.record("codex:primary", UsageApp::Codex, &s, now + 2);
        assert_eq!(h.events.len(), 1);
        assert_eq!(h.events[0].delta_percent, -15);
    }
}
