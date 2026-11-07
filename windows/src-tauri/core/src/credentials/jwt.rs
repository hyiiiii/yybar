//! base64url 解 JWT 的 payload（不验签，只取 claims）。

use base64::Engine;
use serde_json::Value;

pub fn decode_payload(token: &str) -> Option<Value> {
    let part = token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(part.trim_end_matches('='))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// JWT 的 `exp`（Unix 秒）。
pub fn expiry(token: &str) -> Option<i64> {
    decode_payload(token)?.get("exp")?.as_f64().map(|n| n as i64)
}
