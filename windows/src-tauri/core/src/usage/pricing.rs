//! 模型价格（USD / 百万 token，对应 Mac `Pricing.swift`，两边改价时一起改）。命中不到的模型费用记 0，token 仍记录。
//! 用户在「设置 · 通用 · 模型价格」里填的自定义价格优先于内置表，存在 `%APPDATA%\yybar\custom-model-prices.json`。

use std::collections::{BTreeMap, HashMap};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::paths;
use crate::UsageApp;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelPrice {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_creation: f64,
}

const fn p(input: f64, output: f64, cache_read: f64, cache_creation: f64) -> ModelPrice {
    ModelPrice { input, output, cache_read, cache_creation }
}

/// 内置价格表（与 Mac 版一致）。键为归一化后的模型名。
pub const TABLE: &[(&str, ModelPrice)] = &[
    // Claude（input 已不含 cache_read）。cacheCreation 用 5 分钟缓存写入价。
    ("claude-fable-5-1", p(10.0, 50.0, 0.25, 12.50)),
    ("claude-fable-5", p(10.0, 50.0, 1.00, 12.50)),
    ("claude-opus-5-5", p(4.0, 20.0, 0.20, 5.0)),
    ("claude-opus-5", p(5.0, 25.0, 0.50, 6.25)),
    ("claude-opus-4-8", p(5.0, 25.0, 0.50, 6.25)),
    ("claude-opus-4-7", p(5.0, 25.0, 0.50, 6.25)),
    ("claude-opus-4-6", p(5.0, 25.0, 0.50, 6.25)),
    ("claude-opus-4-5", p(5.0, 25.0, 0.50, 6.25)),
    ("claude-opus-4-1", p(15.0, 75.0, 1.50, 18.75)),
    ("claude-opus-4", p(15.0, 75.0, 1.50, 18.75)),
    ("claude-sonnet-5-5", p(2.0, 10.0, 0.10, 2.50)),
    ("claude-sonnet-5", p(2.0, 10.0, 0.20, 2.50)),
    ("claude-sonnet-4-7", p(3.0, 15.0, 0.30, 3.75)),
    ("claude-sonnet-4-6", p(3.0, 15.0, 0.30, 3.75)),
    ("claude-sonnet-4-5", p(3.0, 15.0, 0.30, 3.75)),
    ("claude-sonnet-4", p(3.0, 15.0, 0.30, 3.75)),
    ("claude-haiku-4-5", p(1.0, 5.0, 0.10, 1.25)),
    ("claude-haiku-4", p(0.8, 4.0, 0.08, 1.0)),
    // Codex / GPT-5 系（input 含 cache_read，调用侧已扣 billable）。
    ("gpt-5", p(1.25, 10.0, 0.125, 0.0)),
    ("gpt-5-mini", p(0.25, 2.0, 0.025, 0.0)),
    ("gpt-5-nano", p(0.05, 0.40, 0.005, 0.0)),
    ("gpt-5-codex", p(1.25, 10.0, 0.125, 0.0)),
    ("gpt-5.1", p(1.25, 10.0, 0.125, 0.0)),
    ("gpt-5.1-codex", p(1.25, 10.0, 0.125, 0.0)),
    ("gpt-5.2", p(1.25, 10.0, 0.125, 0.0)),
    ("gpt-5.3", p(1.25, 10.0, 0.125, 0.0)),
    ("gpt-5.4", p(2.50, 15.0, 0.25, 0.0)),
    ("gpt-5.4-codex", p(2.50, 15.0, 0.25, 0.0)),
    ("gpt-5.5", p(5.0, 30.0, 0.50, 0.0)),
    ("gpt-5.5-codex", p(5.0, 30.0, 0.50, 0.0)),
    ("gpt-5.5-pro", p(5.0, 30.0, 0.50, 0.0)),
    ("gpt-5.6", p(4.0, 20.0, 0.40, 5.0)),
    ("gpt-5.6-sol", p(4.0, 20.0, 0.40, 5.0)),
    ("gpt-5.6-terra", p(2.0, 12.0, 0.20, 2.5)),
    ("gpt-5.6-luna", p(0.2, 1.2, 0.02, 0.25)),
    ("gpt-6-astra", p(10.0, 50.0, 1.0, 12.5)),
    ("gpt-6.1-sol", p(2.0, 10.0, 0.10, 2.5)),
    ("gpt-6-sol", p(2.0, 10.0, 0.20, 2.5)),
    ("gpt-6-luna", p(0.10, 0.50, 0.01, 0.125)),
    // Gemini（agy 会话库；Gemini Developer API 标准档）。
    ("gemini-4-argon", p(2.0, 10.0, 0.10, 0.0)),
    ("gemini-3.8-flash", p(0.75, 3.75, 0.075, 0.0)),
    ("gemini-3.6-flash", p(0.75, 3.75, 0.075, 0.0)),
    ("gemini-3.5-flash-lite", p(0.30, 2.50, 0.03, 0.0)),
    ("gemini-3.1-pro-preview", p(2.0, 12.0, 0.20, 0.0)),
    ("gemini-3.1-pro", p(2.0, 12.0, 0.20, 0.0)),
    ("gemini-3.1-flash-lite", p(0.25, 1.50, 0.025, 0.0)),
    ("gemini-3-flash-preview", p(0.50, 3.0, 0.05, 0.0)),
    ("gemini-3-flash", p(0.50, 3.0, 0.05, 0.0)),
    ("gemini-2.5-pro", p(1.25, 10.0, 0.125, 0.0)),
    ("gemini-2.5-flash", p(0.30, 2.50, 0.03, 0.0)),
    ("codex-mini-latest", p(1.50, 6.0, 0.375, 0.0)),
];

/// >272K 输入时输入与缓存 2 倍、输出 1.5 倍的模型。
const LONG_CONTEXT: &[&str] = &["gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"];

pub fn builtin(key: &str) -> Option<ModelPrice> {
    TABLE.iter().find(|(k, _)| *k == key).map(|(_, p)| *p)
}

fn custom_store() -> &'static RwLock<HashMap<String, ModelPrice>> {
    static STORE: OnceLock<RwLock<HashMap<String, ModelPrice>>> = OnceLock::new();
    STORE.get_or_init(|| {
        let loaded = std::fs::read(custom_file())
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default();
        RwLock::new(loaded)
    })
}

fn custom_file() -> std::path::PathBuf {
    paths::data_dir().join("custom-model-prices.json")
}

pub fn custom_prices() -> HashMap<String, ModelPrice> {
    custom_store().read().unwrap().clone()
}

/// 设置或清除（None）某个模型的自定义价格。
pub fn set_custom(key: &str, price: Option<ModelPrice>) {
    let snapshot: BTreeMap<String, ModelPrice> = {
        let mut map = custom_store().write().unwrap();
        match price {
            Some(p) => map.insert(key.to_string(), p),
            None => map.remove(key),
        };
        map.iter().map(|(k, v)| (k.clone(), *v)).collect()
    };
    if let Ok(data) = serde_json::to_vec_pretty(&snapshot) {
        let _ = paths::write_atomic(&custom_file(), &data);
    }
}

/// 实际使用的价格：自定义优先，其次内置表。
pub fn price(key: &str) -> Option<ModelPrice> {
    custom_store().read().unwrap().get(key).copied().or_else(|| builtin(key))
}

pub fn has_price(model: &str) -> bool {
    price(&normalize(model)).is_some()
}

/// 费用能不能显示：Grok 的费用来自日志，算已知；其他服务有价格或有正数费用才算。
pub fn has_displayable_cost(app: UsageApp, model: &str, cost: f64) -> bool {
    app == UsageApp::Grok || cost > 0.0 || has_price(model)
}

/// 归一化：去 `openai/` 前缀；剥 Vertex 的 `@日期`、Anthropic 的 `-YYYYMMDD` / `-YYYY-MM-DD` 后缀；小写。
pub fn normalize(model: &str) -> String {
    let mut m = model.strip_prefix("openai/").unwrap_or(model).to_string();
    if let Some(at) = m.find('@') {
        m.truncate(at);
    }
    let bytes = m.as_bytes();
    let is_digits = |s: &[u8]| s.iter().all(u8::is_ascii_digit);
    let len = bytes.len();
    if len > 11 && bytes[len - 11] == b'-' && bytes[len - 6] == b'-' && bytes[len - 3] == b'-'
        && is_digits(&bytes[len - 10..len - 6]) && is_digits(&bytes[len - 5..len - 3]) && is_digits(&bytes[len - 2..])
    {
        m.truncate(len - 11);
    } else if len > 9 && bytes[len - 9] == b'-' && is_digits(&bytes[len - 8..]) {
        m.truncate(len - 9);
    }
    m.to_lowercase()
}

/// 一次调用的费用（美元）。`request_input` 为这次请求的输入 token（判断长上下文加价）。
pub fn cost(model: &str, input: i64, output: i64, cache_read: i64, cache_creation: i64, request_input: Option<i64>) -> f64 {
    let key = normalize(model);
    let Some(p) = price(&key) else { return 0.0 };
    let per = 1_000_000.0;
    let i = input as f64 * p.input / per;
    let o = output as f64 * p.output / per;
    let cr = cache_read as f64 * p.cache_read / per;
    let cc = cache_creation as f64 * p.cache_creation / per;
    let long = LONG_CONTEXT.contains(&key.as_str()) && request_input.unwrap_or(input + cache_read + cache_creation) > 272_000;
    if long { (i + cr + cc) * 2.0 + o * 1.5 } else { i + o + cr + cc }
}

/// 价格表内容指纹（内置表 + 自定义价格，SHA-256）。表一变，扫描缓存自动失效并全量重建、重算历史费用。
pub fn fingerprint() -> String {
    fn describe<'a>(items: impl Iterator<Item = (&'a str, ModelPrice)>) -> String {
        let mut rows: Vec<String> = items
            .map(|(k, p)| format!("{k}:{}/{}/{}/{}", p.input, p.output, p.cache_read, p.cache_creation))
            .collect();
        rows.sort();
        rows.join(";")
    }
    let custom = custom_prices();
    let mut body = describe(TABLE.iter().map(|(k, p)| (*k, *p)));
    if !custom.is_empty() {
        body.push_str("|custom|");
        body.push_str(&describe(custom.iter().map(|(k, p)| (k.as_str(), *p))));
    }
    Sha256::digest(body.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes() {
        assert_eq!(normalize("openai/GPT-5.5"), "gpt-5.5");
        assert_eq!(normalize("claude-opus-4-1-20250805"), "claude-opus-4-1");
        assert_eq!(normalize("claude-sonnet-4@20250514"), "claude-sonnet-4");
        assert_eq!(normalize("gpt-5-2025-08-07"), "gpt-5");
        assert_eq!(normalize("gemini-3.1-pro"), "gemini-3.1-pro");
    }

    #[test]
    fn long_context() {
        let normal = cost("gpt-6-sol", 1_000_000, 0, 0, 0, Some(100));
        let long = cost("gpt-6-sol", 1_000_000, 0, 0, 0, Some(300_000));
        assert!((normal - 2.0).abs() < 1e-9);
        assert!((long - 4.0).abs() < 1e-9);
    }
}
