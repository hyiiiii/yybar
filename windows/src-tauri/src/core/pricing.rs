//! 模型价格（USD / 百万 token），由 Mac 版 `Core/Usage/Pricing.swift` 同步而来。
//! 命中不到的模型花费计 0，token 照常统计。

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ModelPrice {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    pub cache_creation: f64,
}

/// 和 Mac 版价格表保持一致；改价时两边一起改。
pub const TABLE: &[(&str, ModelPrice)] = &[
    ("claude-fable-5-1", ModelPrice { input: 10.0, output: 50.0, cache_read: 0.25, cache_creation: 12.50 }),
    ("claude-fable-5", ModelPrice { input: 10.0, output: 50.0, cache_read: 1.00, cache_creation: 12.50 }),
    ("claude-opus-5-5", ModelPrice { input: 4.0, output: 20.0, cache_read: 0.20, cache_creation: 5.0 }),
    ("claude-opus-5", ModelPrice { input: 5.0, output: 25.0, cache_read: 0.50, cache_creation: 6.25 }),
    ("claude-opus-4-8", ModelPrice { input: 5.0, output: 25.0, cache_read: 0.50, cache_creation: 6.25 }),
    ("claude-opus-4-7", ModelPrice { input: 5.0, output: 25.0, cache_read: 0.50, cache_creation: 6.25 }),
    ("claude-opus-4-6", ModelPrice { input: 5.0, output: 25.0, cache_read: 0.50, cache_creation: 6.25 }),
    ("claude-opus-4-5", ModelPrice { input: 5.0, output: 25.0, cache_read: 0.50, cache_creation: 6.25 }),
    ("claude-opus-4-1", ModelPrice { input: 15.0, output: 75.0, cache_read: 1.50, cache_creation: 18.75 }),
    ("claude-opus-4", ModelPrice { input: 15.0, output: 75.0, cache_read: 1.50, cache_creation: 18.75 }),
    ("claude-sonnet-5-5", ModelPrice { input: 2.0, output: 10.0, cache_read: 0.10, cache_creation: 2.50 }),
    ("claude-sonnet-5", ModelPrice { input: 2.0, output: 10.0, cache_read: 0.20, cache_creation: 2.50 }),
    ("claude-sonnet-4-7", ModelPrice { input: 3.0, output: 15.0, cache_read: 0.30, cache_creation: 3.75 }),
    ("claude-sonnet-4-6", ModelPrice { input: 3.0, output: 15.0, cache_read: 0.30, cache_creation: 3.75 }),
    ("claude-sonnet-4-5", ModelPrice { input: 3.0, output: 15.0, cache_read: 0.30, cache_creation: 3.75 }),
    ("claude-sonnet-4", ModelPrice { input: 3.0, output: 15.0, cache_read: 0.30, cache_creation: 3.75 }),
    ("claude-haiku-4-5", ModelPrice { input: 1.0, output: 5.0, cache_read: 0.10, cache_creation: 1.25 }),
    ("claude-haiku-4", ModelPrice { input: 0.8, output: 4.0, cache_read: 0.08, cache_creation: 1.0 }),
    ("gpt-5", ModelPrice { input: 1.25, output: 10.0, cache_read: 0.125, cache_creation: 0.0 }),
    ("gpt-5-mini", ModelPrice { input: 0.25, output: 2.0, cache_read: 0.025, cache_creation: 0.0 }),
    ("gpt-5-nano", ModelPrice { input: 0.05, output: 0.40, cache_read: 0.005, cache_creation: 0.0 }),
    ("gpt-5-codex", ModelPrice { input: 1.25, output: 10.0, cache_read: 0.125, cache_creation: 0.0 }),
    ("gpt-5.1", ModelPrice { input: 1.25, output: 10.0, cache_read: 0.125, cache_creation: 0.0 }),
    ("gpt-5.1-codex", ModelPrice { input: 1.25, output: 10.0, cache_read: 0.125, cache_creation: 0.0 }),
    ("gpt-5.2", ModelPrice { input: 1.25, output: 10.0, cache_read: 0.125, cache_creation: 0.0 }),
    ("gpt-5.3", ModelPrice { input: 1.25, output: 10.0, cache_read: 0.125, cache_creation: 0.0 }),
    ("gpt-5.4", ModelPrice { input: 2.50, output: 15.0, cache_read: 0.25, cache_creation: 0.0 }),
    ("gpt-5.4-codex", ModelPrice { input: 2.50, output: 15.0, cache_read: 0.25, cache_creation: 0.0 }),
    ("gpt-5.5", ModelPrice { input: 5.0, output: 30.0, cache_read: 0.50, cache_creation: 0.0 }),
    ("gpt-5.5-codex", ModelPrice { input: 5.0, output: 30.0, cache_read: 0.50, cache_creation: 0.0 }),
    ("gpt-5.5-pro", ModelPrice { input: 5.0, output: 30.0, cache_read: 0.50, cache_creation: 0.0 }),
    ("gpt-5.6", ModelPrice { input: 4.0, output: 20.0, cache_read: 0.40, cache_creation: 5.0 }),
    ("gpt-5.6-sol", ModelPrice { input: 4.0, output: 20.0, cache_read: 0.40, cache_creation: 5.0 }),
    ("gpt-5.6-terra", ModelPrice { input: 2.0, output: 12.0, cache_read: 0.20, cache_creation: 2.5 }),
    ("gpt-5.6-luna", ModelPrice { input: 0.2, output: 1.2, cache_read: 0.02, cache_creation: 0.25 }),
    ("gpt-6-astra", ModelPrice { input: 10.0, output: 50.0, cache_read: 1.0, cache_creation: 12.5 }),
    ("gpt-6.1-sol", ModelPrice { input: 2.0, output: 10.0, cache_read: 0.10, cache_creation: 2.5 }),
    ("gpt-6-sol", ModelPrice { input: 2.0, output: 10.0, cache_read: 0.20, cache_creation: 2.5 }),
    ("gpt-6-luna", ModelPrice { input: 0.10, output: 0.50, cache_read: 0.01, cache_creation: 0.125 }),
    ("codex-mini-latest", ModelPrice { input: 1.50, output: 6.0, cache_read: 0.375, cache_creation: 0.0 }),
];

/// 超过 272K 输入时输入与缓存 2 倍、输出 1.5 倍的模型。
const LONG_CONTEXT: &[&str] = &[
    "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
    "gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna",
];

/// 归一化模型名：去 `openai/` 前缀、`@日期`，剥末尾 `-YYYY-MM-DD` / `-YYYYMMDD`。
pub fn normalize(model: &str) -> String {
    let mut m = model.strip_prefix("openai/").unwrap_or(model);
    if let Some(at) = m.find('@') {
        m = &m[..at];
    }
    let b = m.as_bytes();
    let is_digits = |s: &[u8]| s.iter().all(u8::is_ascii_digit);
    let n = b.len();
    if n > 11 && b[n - 11] == b'-' && b[n - 6] == b'-' && b[n - 3] == b'-'
        && is_digits(&b[n - 10..n - 6]) && is_digits(&b[n - 5..n - 3]) && is_digits(&b[n - 2..])
    {
        m = &m[..n - 11];
    } else if n > 9 && b[n - 9] == b'-' && is_digits(&b[n - 8..]) {
        m = &m[..n - 9];
    }
    m.to_lowercase()
}

pub fn price(model: &str) -> Option<ModelPrice> {
    let key = normalize(model);
    TABLE.iter().find(|(k, _)| *k == key).map(|(_, p)| *p)
}

pub fn cost(model: &str, input: u64, output: u64, cache_read: u64, cache_creation: u64, request_input: Option<u64>) -> f64 {
    let key = normalize(model);
    let Some(p) = price(&key) else { return 0.0 };
    let per = 1_000_000.0;
    let i = input as f64 * p.input / per;
    let o = output as f64 * p.output / per;
    let cr = cache_read as f64 * p.cache_read / per;
    let cc = cache_creation as f64 * p.cache_creation / per;
    let long = LONG_CONTEXT.contains(&key.as_str())
        && request_input.unwrap_or(input + cache_read + cache_creation) > 272_000;
    if long { (i + cr + cc) * 2.0 + o * 1.5 } else { i + o + cr + cc }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_dates() {
        assert_eq!(normalize("claude-sonnet-4-5-20250929"), "claude-sonnet-4-5");
        assert_eq!(normalize("openai/gpt-5-2025-08-07"), "gpt-5");
        assert_eq!(normalize("claude-opus-4-1@20250805"), "claude-opus-4-1");
    }

    #[test]
    fn prices_known_model() {
        let c = cost("claude-sonnet-4-5-20250929", 1_000_000, 0, 0, 0, None);
        assert!((c - 3.0).abs() < 1e-9);
        assert_eq!(cost("mystery", 1000, 1000, 0, 0, None), 0.0);
    }
}
