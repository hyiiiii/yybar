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

/// 共用的 HTTP 客户端。reqwest 会读取 Windows 的系统代理（Internet 选项）和 HTTPS_PROXY 环境变量。
pub fn client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("http client")
    })
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
