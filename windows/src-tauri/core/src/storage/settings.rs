//! 设置（`%APPDATA%\yybar\settings.json`），字段与 Mac `SettingsStore`（`yybar.settings.*`）一一对应。
//! Mac 的「菜单栏」列在 Windows 上是「任务栏托盘图标」。

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::save_json;
use crate::paths;
use crate::UsageApp;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MenuBarWindow {
    FiveHour,
    Weekly,
    Both,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ResetTimeDisplay {
    Relative,
    Absolute,
}

/// 悬浮窗收起时贴着的屏幕边（对应 Mac `FloatingDockEdge`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockEdge {
    Left,
    Right,
}

/// 悬浮窗样式（对应 Mac `FloatingStyle`）：简略 = 每行一个进度条和剩余百分比；详细 = 和弹出窗口一样（名字、套餐、5H / WK 带重置倒计时）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum FloatingStyle {
    #[default]
    Compact,
    Detailed,
}

/// 主窗口字号（对应 Mac `TextSize`）：Windows 上按倍数缩放主窗口网页。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum TextSize {
    Small,
    #[default]
    Standard,
    Large,
    ExtraLarge,
}

impl TextSize {
    pub fn scale(self) -> f64 {
        match self {
            TextSize::Small => 0.9,
            TextSize::Standard => 1.0,
            TextSize::Large => 1.1,
            TextSize::ExtraLarge => 1.2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AppLanguage {
    System,
    Zh,
    En,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    // 服务
    pub show_codex: bool,
    pub show_claude: bool,
    pub show_grok: bool,
    pub show_agy: bool,
    /// 用户在设置里「删除」的本机账号：服务 → 账号身份。CLI 换成别的账号后身份不同，自动重新出现。
    pub removed_local_accounts: BTreeMap<String, String>,
    // 托盘（Mac 菜单栏）
    pub menu_bar_show_codex: bool,
    pub menu_bar_show_claude: bool,
    pub menu_bar_show_grok: bool,
    pub menu_bar_show_agy: bool,
    pub menu_bar_window: MenuBarWindow,
    pub menu_bar_breathe_when_active: bool,
    pub menu_bar_hold_color_while_waiting: bool,
    // 悬浮窗
    pub floating_enabled: bool,
    pub floating_show_codex: bool,
    pub floating_show_claude: bool,
    pub floating_show_grok: bool,
    pub floating_show_agy: bool,
    /// 悬浮窗左上角（物理像素），None 表示还没拖动过
    pub floating_position: Option<(i32, i32)>,
    /// 悬浮窗拖出屏幕左 / 右边缘后收起成贴边窄条，记住贴的哪一边；None 为展开
    pub floating_dock: Option<DockEdge>,
    pub floating_style: FloatingStyle,
    // 刷新
    /// "m1" / "m2" / "m3" / "m5" / "m10"
    pub quota_interval: String,
    pub usage_interval: String,
    /// 也统计 / 读取正在运行的 WSL 发行版里的 CLI（Windows 独有）
    pub scan_wsl: bool,
    /// 手动添加的其他 Codex 目录（第二个账号用 CODEX_HOME 放在别处时；自动找到的不存这里，见 paths::extra_codex_dirs）
    pub extra_codex_dirs: Vec<String>,
    /// 自动找到、但用户移除了的 Codex 目录（不再统计、不再显示它登录的账号）
    pub ignored_codex_homes: Vec<String>,
    // 统计
    pub reset_time_display: ResetTimeDisplay,
    pub show_service_status: bool,
    /// 主窗口字号
    pub text_size: TextSize,
    // 通用
    pub app_language: AppLanguage,
    pub did_complete_onboarding: bool,
    // bar
    /// 每天 0:30 自动把今天以前的用量传到 yybar 网站（默认关，对应 Mac `yybar.settings.webAutoUpload`）
    pub web_auto_upload: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            show_codex: true,
            show_claude: true,
            show_grok: true,
            show_agy: false,
            removed_local_accounts: BTreeMap::new(),
            // 任务栏 / 悬浮窗默认都不显示，由用户在引导或「服务」页勾选
            menu_bar_show_codex: false,
            menu_bar_show_claude: false,
            menu_bar_show_grok: false,
            menu_bar_show_agy: false,
            menu_bar_window: MenuBarWindow::FiveHour,
            menu_bar_breathe_when_active: true,
            menu_bar_hold_color_while_waiting: true,
            floating_enabled: false,
            floating_show_codex: false,
            floating_show_claude: false,
            floating_show_grok: false,
            floating_show_agy: false,
            floating_position: None,
            floating_dock: None,
            floating_style: FloatingStyle::Compact,
            quota_interval: "m2".into(),
            usage_interval: "m2".into(),
            scan_wsl: false,
            extra_codex_dirs: Vec::new(),
            ignored_codex_homes: Vec::new(),
            reset_time_display: ResetTimeDisplay::Relative,
            show_service_status: true,
            text_size: TextSize::Standard,
            app_language: AppLanguage::System,
            did_complete_onboarding: false,
            web_auto_upload: false,
        }
    }
}

pub fn interval_seconds(choice: &str) -> u64 {
    match choice {
        "m1" => 60,
        "m3" => 180,
        "m5" => 300,
        "m10" => 600,
        _ => 120,
    }
}

impl Settings {
    fn file() -> std::path::PathBuf {
        paths::data_dir().join("settings.json")
    }

    /// 读设置。没设置过 showAgy 时按本机是否装了 agy 决定（和 Mac 一致）。
    pub fn load() -> Settings {
        let raw: Option<serde_json::Value> = std::fs::read(Self::file()).ok().and_then(|d| serde_json::from_slice(&d).ok());
        let mut settings: Settings = raw.clone().and_then(|v| serde_json::from_value(v).ok()).unwrap_or_default();
        if raw.as_ref().and_then(|v| v.get("showAgy")).is_none() {
            settings.show_agy = crate::quota::google::is_installed();
        }
        settings
    }

    pub fn save(&self) {
        if let Err(e) = save_json(&Self::file(), self, true) {
            log::warn!("[Settings 设置] 写盘失败: {e}");
        }
    }

    pub fn quota_interval_secs(&self) -> u64 {
        interval_seconds(&self.quota_interval)
    }

    pub fn usage_interval_secs(&self) -> u64 {
        interval_seconds(&self.usage_interval)
    }

    pub fn is_enabled(&self, app: UsageApp) -> bool {
        match app {
            UsageApp::Codex => self.show_codex,
            UsageApp::Claude => self.show_claude,
            UsageApp::Grok => self.show_grok,
            UsageApp::Agy => self.show_agy,
        }
    }

    /// 托盘上显示这个服务（叠加启用开关）。
    pub fn tray_shows(&self, app: UsageApp) -> bool {
        self.is_enabled(app)
            && match app {
                UsageApp::Codex => self.menu_bar_show_codex,
                UsageApp::Claude => self.menu_bar_show_claude,
                UsageApp::Grok => self.menu_bar_show_grok,
                UsageApp::Agy => self.menu_bar_show_agy,
            }
    }

    /// 悬浮窗显示这个服务（叠加启用开关）。
    pub fn floating_shows(&self, app: UsageApp) -> bool {
        self.is_enabled(app)
            && match app {
                UsageApp::Codex => self.floating_show_codex,
                UsageApp::Claude => self.floating_show_claude,
                UsageApp::Grok => self.floating_show_grok,
                UsageApp::Agy => self.floating_show_agy,
            }
    }

    pub fn resolved_chinese(&self) -> bool {
        match self.app_language {
            AppLanguage::Zh => true,
            AppLanguage::En => false,
            AppLanguage::System => crate::l10n::system_prefers_chinese(),
        }
    }
}
