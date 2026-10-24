//! 持久化（对应 Mac 版 `Core/Storage`）。
//!
//! | 位置 | 文件 | 内容 |
//! |---|---|---|
//! | `%APPDATA%\yybar\` | `settings.json` | 全部设置 + 悬浮窗位置 + 引导标记 |
//! | `%APPDATA%\yybar\` | `quota-cache.json` | 额度快照 |
//! | `%APPDATA%\yybar\` | `quota-history-today.json` | 今日额度变化 |
//! | `%APPDATA%\yybar\` | `usage-rollup.json` | (day, app, model) 聚合桶 |
//! | `%APPDATA%\yybar\` | `custom-model-prices.json` | 自定义模型价格 |
//! | `%LOCALAPPDATA%\yybar\` | `scan-state.json` | 每个日志文件的扫描进度 |

pub mod quota_cache;
pub mod quota_history;
pub mod scan_cache;
pub mod settings;

use std::path::Path;

use serde::de::DeserializeOwned;
use serde::Serialize;

pub(crate) fn load_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

pub(crate) fn save_json<T: Serialize>(path: &Path, value: &T, pretty: bool) -> std::io::Result<()> {
    let data = if pretty { serde_json::to_vec_pretty(value) } else { serde_json::to_vec(value) }
        .map_err(std::io::Error::other)?;
    crate::paths::write_atomic(path, &data)
}
