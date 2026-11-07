//! 用量数据结构（对应 Mac `UsageModels.swift`）。

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::UsageApp;

/// 单次调用解析出的用量（内存中流转，不直接持久化）。
#[derive(Debug, Clone, PartialEq)]
pub struct UsageEntry {
    pub app: UsageApp,
    pub model: String,
    /// 本地日期
    pub day: NaiveDate,
    /// 已扣 cache read（Codex 解析时已处理）
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_creation_tokens: i64,
    pub cost_usd: f64,
}

/// (day, app, model) 聚合桶。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageBucket {
    pub app: UsageApp,
    pub model: String,
    pub day: NaiveDate,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_creation_tokens: i64,
    #[serde(rename = "costUSD")]
    pub cost_usd: f64,
}

impl UsageBucket {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens + self.cache_read_tokens + self.cache_creation_tokens
    }
}

/// 单个日志文件 / 会话库的扫描进度（对应 Mac `ScanFileState`）。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanFileState {
    /// 修改时间（Unix 秒，带小数）
    pub mtime: f64,
    /// 已扫到的字节数
    pub offset: u64,
    /// Codex：当前会话最近一次 `turn_context` 里的模型
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_model: Option<String>,
    /// Codex：累计 token（去重复通知用）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_total_usage: Option<std::collections::BTreeMap<String, i64>>,
    /// Grok：已记过的 prompt_id；agy：已记过的 step idx
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seen_turn_ids: Option<Vec<String>>,
}

/// 一个扫描器一次扫描的结果。
#[derive(Debug, Default)]
pub struct ScanResult {
    pub entries: Vec<UsageEntry>,
    pub new_state: std::collections::HashMap<String, ScanFileState>,
    pub files_scanned: usize,
    pub lines_parsed: usize,
}
