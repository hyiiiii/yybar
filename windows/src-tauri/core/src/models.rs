//! 服务枚举。声明顺序即托盘 / 弹出窗口 / 悬浮窗 / 统计页的排列顺序：Codex → Claude → Grok → Antigravity。
//! Mac 版另有 Grok Bot、Gemini App，这两个在 Windows 上读不到（见 docs/Windows版.md「和 Mac 版的差别」）。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UsageApp {
    Codex,
    Claude,
    Grok,
    Agy,
}

impl UsageApp {
    pub const ALL: [UsageApp; 4] = [UsageApp::Codex, UsageApp::Claude, UsageApp::Grok, UsageApp::Agy];

    pub fn key(self) -> &'static str {
        match self {
            UsageApp::Codex => "codex",
            UsageApp::Claude => "claude",
            UsageApp::Grok => "grok",
            UsageApp::Agy => "agy",
        }
    }

    pub fn from_key(key: &str) -> Option<UsageApp> {
        UsageApp::ALL.into_iter().find(|a| a.key() == key)
    }

    /// 界面上的服务名。
    pub fn display_name(self) -> &'static str {
        match self {
            UsageApp::Codex => "Codex",
            UsageApp::Claude => "Claude Code",
            UsageApp::Grok => "Grok",
            UsageApp::Agy => "Antigravity",
        }
    }

    /// 只有一个（周期）额度窗口的服务。
    pub fn has_single_period(self) -> bool {
        self == UsageApp::Grok
    }
}
