//! yybar for Windows 的核心逻辑，和 Mac 版 `Core/` 一一对应：
//! - `credentials`：读各 CLI 的登录（Codex / Claude Code / Grok），对应 `Core/Credentials`
//! - `quota`：额度接口、token 续期、官方服务状态，对应 `Core/Quota`
//! - `usage`：本地会话日志扫描、价格、聚合，对应 `Core/Usage`
//! - `storage`：设置、额度缓存、今日额度变化、扫描进度，对应 `Core/Storage`
//!
//! 这一层不依赖 Tauri，`cargo test` 在 Linux / macOS 上也能跑。

pub mod credentials;
pub mod l10n;
pub mod models;
pub mod paths;
pub mod quota;
pub mod storage;
pub mod usage;

pub use l10n::tr;
pub use models::UsageApp;

/// 当前 Unix 时间（秒）。
pub fn now_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

/// 当前 Unix 时间（秒，带小数）。
pub fn now_f64() -> f64 {
    chrono::Utc::now().timestamp_millis() as f64 / 1000.0
}
