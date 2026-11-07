//! 最近一次成功的额度快照（`quota-cache.json`），启动时先读它让界面立刻有数（对应 Mac `QuotaCache`）。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::{load_json, save_json};
use crate::paths;
use crate::quota::{QuotaSnapshot, QuotaSource};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaCacheRecord {
    pub snapshot: QuotaSnapshot,
    pub source: QuotaSource,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaCache {
    #[serde(default)]
    pub codex: Option<QuotaCacheRecord>,
    #[serde(default)]
    pub codex_account_id: Option<String>,
    #[serde(default)]
    pub claude: Option<QuotaCacheRecord>,
    #[serde(default)]
    pub claude_email: Option<String>,
    #[serde(default)]
    pub grok: Option<QuotaCacheRecord>,
    #[serde(default)]
    pub grok_account_id: Option<String>,
    /// agy 的 Gemini 池
    #[serde(default)]
    pub gemini: Option<QuotaCacheRecord>,
    /// agy 的 Claude·GPT 池
    #[serde(default)]
    pub agy: Option<QuotaCacheRecord>,
    /// 其他账号（键是账号 id；Google 账号的 Antigravity 池是 `id#3p`）
    #[serde(default)]
    pub other: HashMap<String, QuotaCacheRecord>,
}

impl QuotaCache {
    pub fn load() -> QuotaCache {
        load_json(&paths::data_dir().join("quota-cache.json")).unwrap_or_default()
    }

    pub fn save(&self) {
        if let Err(e) = save_json(&paths::data_dir().join("quota-cache.json"), self, true) {
            log::warn!("[QuotaCache 额度缓存] 写盘失败: {e}");
        }
    }
}
