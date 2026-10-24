//! 读各 CLI 自己的登录凭据（对应 Mac 版 `Core/Credentials`）。
//! Windows 上 Claude Code 把凭据存在 `~/.claude/.credentials.json`（没有钥匙串这一步）。
//! 本机找不到时，再找正在运行的 WSL 发行版里的同名文件（设置 · 刷新「统计 WSL」打开时）。

pub mod claude;
pub mod codex;
pub mod grok;
pub mod jwt;
pub mod renewal;

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::paths::HomeRoot;

pub use claude::ClaudeAccount;
pub use codex::CodexAccount;
pub use grok::GrokAccount;
pub use renewal::SubscriptionRenewal;

pub(crate) fn read_json(path: &Path) -> Option<Value> {
    let data = std::fs::read(path).ok()?;
    if data.is_empty() {
        return None;
    }
    // 有的编辑器会写 UTF-8 BOM
    let data = data.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&data);
    serde_json::from_slice(data).ok()
}

pub(crate) fn str_field<'a>(v: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter()
        .find_map(|k| v.get(*k).and_then(Value::as_str))
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// 先 Windows 本机，再正在运行的 WSL 发行版。
pub(crate) fn candidate_paths(local: PathBuf, wsl: &[HomeRoot], relative: &str) -> Vec<PathBuf> {
    let mut out = vec![local];
    out.extend(wsl.iter().map(|r| r.path.join(relative)));
    out
}

/// ISO 8601（带或不带小数秒、Z 或 +00:00）→ Unix 秒。
pub fn parse_iso(value: Option<&Value>) -> Option<i64> {
    let s = value?.as_str()?;
    chrono::DateTime::parse_from_rfc3339(s.trim()).ok().map(|d| d.timestamp())
}
