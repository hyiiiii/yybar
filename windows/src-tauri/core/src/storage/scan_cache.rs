//! 扫描进度（`%LOCALAPPDATA%\yybar\scan-state.json`）和聚合结果（`%APPDATA%\yybar\usage-rollup.json`），
//! 对应 Mac `ScanCache.swift`。`version` 管结构变更，`pricing_fingerprint` 管价格变更：
//! 进度文件指纹不一致即丢弃（全量重扫）；汇总照常载入，由第一次扫描全量重建并保留日志已删除的历史。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::{load_json, save_json};
use crate::paths;
use crate::usage::models::{ScanFileState, UsageBucket};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanState {
    pub version: u32,
    pub pricing_fingerprint: String,
    #[serde(default)]
    pub claude: HashMap<String, ScanFileState>,
    #[serde(default)]
    pub codex: HashMap<String, ScanFileState>,
    #[serde(default)]
    pub grok: HashMap<String, ScanFileState>,
    #[serde(default)]
    pub agy: HashMap<String, ScanFileState>,
    #[serde(default)]
    pub claude_seen_message_ids: Vec<String>,
}

impl ScanState {
    pub const VERSION: u32 = 1;

    pub fn is_empty(&self) -> bool {
        self.claude.is_empty() && self.codex.is_empty() && self.grok.is_empty() && self.agy.is_empty()
    }

    pub fn load(fingerprint: &str) -> ScanState {
        load_json::<ScanState>(&paths::cache_dir().join("scan-state.json"))
            .filter(|s| s.version == Self::VERSION && s.pricing_fingerprint == fingerprint)
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        save_json(&paths::cache_dir().join("scan-state.json"), self, false)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRollup {
    pub version: u32,
    pub pricing_fingerprint: String,
    pub buckets: Vec<UsageBucket>,
    pub updated_at: i64,
}

impl UsageRollup {
    pub const VERSION: u32 = 1;

    pub fn load() -> UsageRollup {
        load_json::<UsageRollup>(&paths::data_dir().join("usage-rollup.json"))
            .filter(|r| r.version == Self::VERSION)
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        save_json(&paths::data_dir().join("usage-rollup.json"), self, false)
    }
}
