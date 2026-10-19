//! 设置存在 `%APPDATA%\yybar\settings.json`。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub show_codex: bool,
    pub show_claude: bool,
    pub show_grok: bool,
    /// 悬浮条
    pub show_pill: bool,
    /// 悬浮条位置（物理像素），None 时放在任务栏右上方
    pub pill_position: Option<(i32, i32)>,
    /// 额度刷新间隔（秒）
    pub quota_interval_secs: u64,
    /// 同时扫描正在运行的 WSL 发行版
    pub scan_wsl: bool,
    /// 重置时间显示为具体时刻而不是倒计时
    pub reset_as_clock: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            show_codex: true,
            show_claude: true,
            show_grok: true,
            show_pill: true,
            pill_position: None,
            quota_interval_secs: 120,
            scan_wsl: true,
            reset_as_clock: false,
        }
    }
}

fn path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("yybar")
        .join("settings.json")
}

impl Settings {
    pub fn load() -> Settings {
        std::fs::read(path())
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let p = path();
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(p, data);
        }
    }

    /// 限制在 Mac 版提供的 1 / 2 / 3 / 5 / 10 分钟几档之内。
    pub fn quota_interval(&self) -> u64 {
        self.quota_interval_secs.clamp(60, 600)
    }
}
