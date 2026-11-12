//! 额度数据结构（对应 Mac `QuotaModels.swift`）。字段名按 camelCase 序列化给前端和缓存文件。

use serde::{Deserialize, Serialize};

use crate::l10n::tr;
use crate::UsageApp;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    /// 0~100，已用百分比
    pub used_percent: f64,
    /// 窗口重置时间（Unix 秒）
    #[serde(default)]
    pub resets_at: Option<i64>,
    /// 窗口长度（秒）
    #[serde(default)]
    pub window_seconds: Option<i64>,
}

impl QuotaWindow {
    pub fn remaining_percent(&self) -> f64 {
        (100.0 - self.used_percent).clamp(0.0, 100.0)
    }

    /// 剩余 0 且还没到重置时间。
    pub fn is_exhausted(&self, now: i64) -> bool {
        self.remaining_percent() <= 0.0 && self.resets_at.map_or(true, |r| r > now)
    }
}

/// 一个格子包含多个额度池时（Antigravity = agy 的 Gemini 池 + Claude·GPT 池）逐池列出。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaPool {
    /// 行首短标签，如 "Gemini"、"Claude·GPT"。
    pub label: String,
    #[serde(default)]
    pub five_hour: Option<QuotaWindow>,
    #[serde(default)]
    pub weekly: Option<QuotaWindow>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub app: UsageApp,
    #[serde(default)]
    pub five_hour: Option<QuotaWindow>,
    #[serde(default)]
    pub weekly: Option<QuotaWindow>,
    #[serde(default)]
    pub weekly_opus: Option<QuotaWindow>,
    #[serde(default)]
    pub weekly_sonnet: Option<QuotaWindow>,
    #[serde(default)]
    pub plan_type: Option<String>,
    pub fetched_at: i64,
    /// 不是 5 小时周期的主额度（Grok 的周 / 月额度）。
    #[serde(default)]
    pub primary: Option<QuotaWindow>,
    /// 形如 "WEEK · 本周"，前端按语言取一半。
    #[serde(default)]
    pub primary_label: Option<String>,
    /// 多个池子时逐池列出；此时 fiveHour / weekly 是各池里剩余最少的那个。
    #[serde(default)]
    pub pools: Option<Vec<QuotaPool>>,
}

impl QuotaSnapshot {
    pub fn empty(app: UsageApp, fetched_at: i64) -> QuotaSnapshot {
        QuotaSnapshot {
            app,
            five_hour: None,
            weekly: None,
            weekly_opus: None,
            weekly_sonnet: None,
            plan_type: None,
            fetched_at,
            primary: None,
            primary_label: None,
            pools: None,
        }
    }

    /// Antigravity 的展示快照：agy 两个池子合在一起。两个都没有时返回 None。
    pub fn antigravity(gemini: Option<&QuotaSnapshot>, third_party: Option<&QuotaSnapshot>) -> Option<QuotaSnapshot> {
        if gemini.is_none() && third_party.is_none() {
            return None;
        }
        let pools = vec![
            QuotaPool {
                label: "Gemini".into(),
                five_hour: gemini.and_then(|s| s.five_hour.clone()),
                weekly: gemini.and_then(|s| s.weekly.clone()),
            },
            QuotaPool {
                label: "Claude·GPT".into(),
                five_hour: third_party.and_then(|s| s.five_hour.clone()),
                weekly: third_party.and_then(|s| s.weekly.clone()),
            },
        ];
        let tightest = |ws: Vec<Option<QuotaWindow>>| {
            ws.into_iter().flatten().max_by(|a, b| a.used_percent.total_cmp(&b.used_percent))
        };
        let fetched = [gemini.map(|s| s.fetched_at), third_party.map(|s| s.fetched_at)]
            .into_iter()
            .flatten()
            .max()
            .unwrap_or_else(crate::now_secs);
        let mut snap = QuotaSnapshot::empty(UsageApp::Agy, fetched);
        snap.five_hour = tightest(pools.iter().map(|p| p.five_hour.clone()).collect());
        snap.weekly = tightest(pools.iter().map(|p| p.weekly.clone()).collect());
        snap.pools = Some(pools);
        Some(snap)
    }

    /// 托盘 / 悬浮窗只有一个数字时：Grok 取周期额度，其余按 5H（没有时 WK）。
    pub fn headline(&self) -> Option<&QuotaWindow> {
        if self.app.has_single_period() {
            return self.primary.as_ref().or(self.weekly.as_ref());
        }
        self.five_hour.as_ref().or(self.weekly.as_ref())
    }

    /// 额度用完(5H / WK / 主窗口任一剩 0 且还没到重置时间)。有 pools 的 Antigravity 不算(两个池互不影响)。
    pub fn is_exhausted(&self, now: i64) -> bool {
        if self.pools.is_some() {
            return false;
        }
        [&self.five_hour, &self.weekly, &self.primary]
            .into_iter()
            .flatten()
            .any(|w| w.is_exhausted(now))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum QuotaSource {
    Api,
    Cache,
    /// `agy -p /usage`
    AgyCli,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshReason {
    Periodic,
    UserInitiated,
}

/// 每个服务的刷新状态（对应 Mac `QuotaRefreshState`）。
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefreshState {
    pub last_success_at: Option<i64>,
    pub last_attempt_at: Option<i64>,
    pub backoff_until: Option<i64>,
    pub last_error: Option<String>,
    pub in_flight: bool,
    pub source: Option<QuotaSource>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum QuotaError {
    MissingToken,
    Http(u16, String),
    Transport(String),
    Decode(String),
    TokenRefreshFailed(String),
    /// OAuth 服务端拒绝了 refresh_token（invalid_grant），只能重新登录。
    TokenRevoked,
}

impl QuotaError {
    pub fn http_status(&self) -> Option<u16> {
        match self {
            QuotaError::Http(code, _) => Some(*code),
            _ => None,
        }
    }

    pub fn is_rate_limited(&self) -> bool {
        self.http_status() == Some(429)
    }

    pub fn is_auth_failure(&self) -> bool {
        matches!(self.http_status(), Some(401 | 403))
    }

    /// 给用户看的一行说明（按当前语言）。
    pub fn message(&self, app: UsageApp) -> String {
        let one_line = |s: &str| -> String {
            let first = s.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("");
            let mut out: String = first.chars().take(110).collect();
            if first.chars().count() > 110 {
                out.push('…');
            }
            out
        };
        match self {
            QuotaError::MissingToken => match app {
                UsageApp::Codex => tr("Not signed in. Run codex login in a terminal.", "未登录，请在终端运行 codex login"),
                UsageApp::Claude => tr("Not signed in. Run claude in a terminal and log in.", "未登录，请在终端运行 claude 登录"),
                UsageApp::Grok => tr("Grok isn't signed in. Run grok login.", "Grok 未登录，请运行 grok login"),
                UsageApp::Agy => tr("agy isn't signed in, or it couldn't renew its sign-in. If your network is fine, run agy in a terminal and sign in again.", "agy 未登录或登录刷新失败。网络正常时请在终端运行 agy 重新登录"),
            },
            QuotaError::Http(401 | 403, _) => match app {
                UsageApp::Codex => tr("Codex sign-in expired. Run codex login again.", "Codex 登录已失效，请在终端运行 codex login 重新登录"),
                UsageApp::Claude => tr("Claude sign-in expired. Run claude in a terminal to sign in again.", "Claude 登录已失效，请在终端运行 claude 重新登录"),
                _ => tr("Sign-in expired. Sign in again in the CLI.", "登录已失效，请在 CLI 里重新登录"),
            },
            QuotaError::Http(429, _) => tr("Rate limited; paused for 10 minutes", "请求太频繁，已暂停 10 分钟"),
            QuotaError::Http(code, body) => format!("HTTP {code} {}", one_line(body)).trim().to_string(),
            QuotaError::Transport(m) => format!("{}{}", tr("Network error: ", "网络错误："), one_line(m)),
            QuotaError::Decode(m) => format!("{}{}", tr("Couldn't read the response: ", "解析失败："), one_line(m)),
            QuotaError::TokenRefreshFailed(m) => format!("{}{}", tr("Token renewal failed: ", "token 续期失败："), one_line(m)),
            QuotaError::TokenRevoked => tr(
                "Claude sign-in is no longer valid. Run claude in a terminal to sign in again, then refresh.",
                "Claude 登录已失效，请在终端运行 claude 重新登录后再回来刷新",
            ),
        }
    }
}

impl std::fmt::Display for QuotaError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            QuotaError::MissingToken => write!(f, "missing access token"),
            QuotaError::Http(c, m) => write!(f, "http {c}: {m}"),
            QuotaError::Transport(m) => write!(f, "transport: {m}"),
            QuotaError::Decode(m) => write!(f, "decode: {m}"),
            QuotaError::TokenRefreshFailed(m) => write!(f, "token refresh failed: {m}"),
            QuotaError::TokenRevoked => write!(f, "token revoked"),
        }
    }
}
