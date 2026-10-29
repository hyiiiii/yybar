//! 额度接口、token 续期、官方服务状态（对应 Mac 版 `Core/Quota`）。

pub mod claude;
pub mod claude_refresh;
pub mod codex;
pub mod codex_refresh;
pub mod google;
pub mod grok;
pub mod models;
pub mod status;

use std::sync::OnceLock;
use std::time::Duration;

use serde_json::Value;

pub use models::*;

/// 共用的 HTTP 客户端。reqwest 会读取 Windows 的系统代理（Internet 选项里手动设置的代理服务器）和 HTTPS_PROXY
/// 环境变量；设置了代理脚本（PAC）时改按脚本选代理（见 crate::proxy）。
pub fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        let mut builder = reqwest::Client::builder().timeout(Duration::from_secs(30));
        if let Some(pac) = crate::proxy::pac_proxy() {
            builder = builder.proxy(pac);
        }
        builder.build().expect("http client")
    })
}

/// reqwest 的错误本身只说「发请求出错」，把底下的原因（DNS / 连不上 / 超时 / 证书）接上，一看就知道是不是网络或代理的问题。
pub fn describe_error(e: &reqwest::Error) -> String {
    let mut text = e.to_string();
    let mut source = std::error::Error::source(e);
    while let Some(s) = source {
        let part = s.to_string();
        if !part.is_empty() && !text.contains(&part) {
            text.push_str(": ");
            text.push_str(&part);
        }
        source = s.source();
    }
    text
}

/// 发请求并按 JSON 解析；非 2xx 返回 `QuotaError::Http`。
pub(crate) async fn get_json(req: reqwest::RequestBuilder) -> Result<Value, QuotaError> {
    let resp = req.send().await.map_err(|e| QuotaError::Transport(e.to_string()))?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| QuotaError::Transport(e.to_string()))?;
    if !status.is_success() {
        return Err(QuotaError::Http(status.as_u16(), body));
    }
    serde_json::from_str(&body).map_err(|e| QuotaError::Decode(e.to_string()))
}

pub(crate) fn num(v: Option<&Value>) -> Option<f64> {
    let v = v?;
    if v.is_boolean() {
        return None;
    }
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
}
