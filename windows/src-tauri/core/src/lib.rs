//! yybar for Windows 的核心逻辑，和 Mac 版 `Core/` 一一对应：
//! - `credentials`：读各 CLI 的登录（Codex / Claude Code / Grok），对应 `Core/Credentials`
//! - `quota`：额度接口、token 续期、官方服务状态，对应 `Core/Quota`
//! - `usage`：本地会话日志扫描、价格、聚合，对应 `Core/Usage`
//! - `storage`：设置、额度缓存、今日额度变化、扫描进度，对应 `Core/Storage`
//! - `web`：yybar 网站账号（连接 GitHub、上传用量换筹码），对应 `YYBarWebAccount`
//! - `accounts`：其他账号（添加 / 登录 / 粘贴 / 切换本机 CLI 账号），对应 `ExtraAccount` / `CLILoginSession` / `CLIAccountSwitch`
//!
//! 这一层不依赖 Tauri，`cargo test` 在 Linux / macOS 上也能跑。

pub mod accounts;
pub mod credentials;
pub mod l10n;
pub mod models;
pub mod paths;
pub mod proxy;
pub mod quota;
pub mod storage;
pub mod usage;
pub mod web;

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
