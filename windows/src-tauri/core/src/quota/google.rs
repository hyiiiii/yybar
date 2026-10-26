//! Antigravity / agy 的额度：本机 agy CLI 的只读命令 `agy -p /usage --output-format json`（对应 Mac `GoogleQuotaClient`）。
//! 额度挂在 Google 账号上，有两个池子：「Gemini Models」和「Claude and GPT models」，各有 5 小时和每周两层限制，
//! 全部显示在 Antigravity 下。命令用 agy 自己的登录，不发模型请求、不消耗额度，yybar 不碰任何凭据。
//! 在私有临时目录里运行，日志也写到这个临时目录（--log-file），不在 ~/.gemini 留文件。一次约 10~15 秒。

use std::path::PathBuf;
use std::time::Duration;

use serde_json::Value;
use tokio::io::AsyncReadExt;

use super::{num, QuotaError, QuotaSnapshot, QuotaWindow};
use crate::credentials::parse_iso;
use crate::paths;
use crate::{now_secs, UsageApp};

#[derive(Debug, Clone, Default, PartialEq)]
pub struct UsageResult {
    /// Gemini 模型池
    pub gemini: Option<QuotaSnapshot>,
    /// Claude·GPT 池
    pub third_party: Option<QuotaSnapshot>,
    pub plan: Option<String>,
}

/// agy CLI 位置：PATH 或 `~/.local/bin`。
pub fn binary() -> Option<PathBuf> {
    let home = paths::home();
    paths::find_executable("agy", &[home.join(".local").join("bin")])
}

pub fn is_installed() -> bool {
    binary().is_some()
}

pub async fn fetch() -> Result<UsageResult, QuotaError> {
    fetch_in(None).await
}

/// `home` 为 None 时用本机 agy 的登录；否则用其他 Google 账号自己的 agy 目录（GEMINI_CLI_HOME）。
pub async fn fetch_in(home: Option<&std::path::Path>) -> Result<UsageResult, QuotaError> {
    let Some(binary) = binary() else { return Err(QuotaError::MissingToken) };
    let work = std::env::temp_dir().join(format!("yybar-agy-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&work).map_err(|e| QuotaError::Transport(format!("agy temp dir: {e}")))?;
    let result = run(&binary, &work, home).await;
    let _ = std::fs::remove_dir_all(&work);
    result
}

/// 其他 Google 账号的 agy 环境：GEMINI_CLI_HOME 指到账号目录（agy 用它替代 ~/.gemini）；
/// SSH_TTY 让 agy 把登录存成该目录里的文件，不碰本机 agy 的登录（和 Mac 版一样）。
fn isolated_env(cmd: &mut tokio::process::Command, home: &std::path::Path) {
    cmd.env("GEMINI_CLI_HOME", home).env("SSH_TTY", "yybar");
}

async fn run(binary: &PathBuf, work: &PathBuf, home: Option<&std::path::Path>) -> Result<UsageResult, QuotaError> {
    let mut cmd = tokio::process::Command::new(binary);
    if let Some(home) = home {
        isolated_env(&mut cmd, home);
    }
    cmd.args(["-p", "/usage", "--output-format", "json", "--log-file"])
        .arg(work.join("agy.log"))
        .current_dir(work)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    paths::hide_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| QuotaError::Transport(format!("agy launch failed: {e}")))?;
    let stdout = child.stdout.take();
    let finished = tokio::time::timeout(Duration::from_secs(90), async {
        let mut data = Vec::new();
        if let Some(mut out) = stdout {
            out.read_to_end(&mut data).await?;
        }
        child.wait().await.map(|_| data)
    })
    .await;
    let mut data = match finished {
        Ok(result) => result.map_err(|e| QuotaError::Transport(e.to_string()))?,
        Err(_) => {
            paths::kill_tree(&mut child).await;
            return Err(QuotaError::Transport("agy /usage timed out".into()));
        }
    };
    data.truncate(1 << 20);
    parse(&data, now_secs())
}

/// 在新的控制台窗口里给其他 Google 账号登录：在账号目录里运行交互式 agy（按提示在浏览器登录，
/// 把授权码粘贴回控制台，登录成功后输入 /exit），回到 yybar 点「完成添加」。只在 Windows 上可用。
pub fn open_login_console(home: &std::path::Path) -> std::io::Result<()> {
    let Some(binary) = binary() else {
        return Err(std::io::Error::new(std::io::ErrorKind::NotFound, "agy"));
    };
    #[cfg(windows)]
    {
        let banner = crate::tr(
            "yybar: sign in to Antigravity (agy) with the Google account to add. Paste the code back here; after signing in, type /exit and click Finish adding in yybar.",
            "yybar：为新的 Google 账号登录 Antigravity（agy）。按提示在浏览器登录，把授权码粘贴回这里；登录成功后输入 /exit，再回到 yybar 点「完成添加」。",
        );
        let mut cmd = std::process::Command::new("cmd.exe");
        cmd.env("GEMINI_CLI_HOME", home)
            .env("SSH_TTY", "yybar")
            .current_dir(home)
            .args(["/C", "start", "agy", "cmd.exe", "/K"])
            .arg(format!("echo {banner} && \"{}\"", binary.display()));
        cmd.spawn().map(|_| ())
    }
    #[cfg(not(windows))]
    {
        let _ = (home, binary);
        Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "Windows only"))
    }
}

/// agy 日志里记录的登录邮箱（`applyAuthResult: email=…`），只用来给账号起名字。
pub fn signed_in_email() -> Option<String> {
    signed_in_email_in(&paths::gemini_dir())
}

/// 同上，读指定 agy 目录（其他 Google 账号的 GEMINI_CLI_HOME）。
pub fn signed_in_email_in(gemini: &std::path::Path) -> Option<String> {
    let mut logs: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
    for dir in ["antigravity-cli/log", "antigravity/log"] {
        let Ok(entries) = std::fs::read_dir(gemini.join(dir)) else { continue };
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().is_some_and(|x| x == "log") {
                let m = e.metadata().and_then(|m| m.modified()).unwrap_or(std::time::UNIX_EPOCH);
                logs.push((m, p));
            }
        }
    }
    logs.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, log) in logs.into_iter().take(5) {
        let Ok(text) = std::fs::read_to_string(&log) else { continue };
        for line in text.lines().rev() {
            if let Some(idx) = line.find("applyAuthResult: email=") {
                let rest = &line[idx + "applyAuthResult: email=".len()..];
                let email: String = rest.chars().take_while(|c| *c != ',' && *c != ' ').collect();
                if email.contains('@') {
                    return Some(email);
                }
            }
        }
    }
    None
}

/// 解析 `agy -p /usage --output-format json` 的输出。没登录时 agy 会先打印几行提示，最后一行才是 JSON。
pub fn parse(data: &[u8], now: i64) -> Result<UsageResult, QuotaError> {
    let text = String::from_utf8_lossy(data);
    let root: Value = serde_json::from_str(text.trim())
        .ok()
        .or_else(|| {
            text.lines()
                .rev()
                .map(str::trim)
                .find(|l| l.starts_with('{'))
                .and_then(|l| serde_json::from_str(l).ok())
        })
        .ok_or_else(|| QuotaError::Decode("agy /usage output is not JSON".into()))?;
    let status = root.get("status").and_then(Value::as_str).unwrap_or("");
    if status != "SUCCESS" {
        let message = root
            .get("error")
            .and_then(Value::as_str)
            .or_else(|| root.get("response").and_then(Value::as_str))
            .unwrap_or(status);
        let lower = message.to_lowercase();
        // 限流按 429 处理，走统一的 10 分钟退避。
        if message.contains("429") || lower.contains("resource_exhausted") {
            return Err(QuotaError::Http(429, "agy usage rate limited".into()));
        }
        if lower.contains("login") || lower.contains("auth") {
            return Err(QuotaError::MissingToken);
        }
        return Err(QuotaError::Decode(format!("agy /usage status {}", if status.is_empty() { "unknown" } else { status })));
    }
    let payload = root.get("command").and_then(|c| c.get("data"));
    let groups = payload
        .and_then(|d| d.get("groups"))
        .and_then(Value::as_array)
        .ok_or_else(|| QuotaError::Decode("agy /usage has no quota groups".into()))?;
    let mut result = UsageResult::default();
    result.plan = ["plan", "plan_name", "planName", "tier", "subscription"]
        .iter()
        .find_map(|k| {
            payload
                .and_then(|p| p.get(*k))
                .or_else(|| root.get(*k))
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
        });
    for group in groups {
        let name = group.get("name").and_then(Value::as_str).unwrap_or("").to_lowercase();
        let is_gemini = name.contains("gemini");
        let is_third = name.contains("claude") || name.contains("gpt");
        if !is_gemini && !is_third {
            continue;
        }
        let mut five: Option<QuotaWindow> = None;
        let mut weekly: Option<QuotaWindow> = None;
        for bucket in group.get("buckets").and_then(Value::as_array).into_iter().flatten() {
            // 没有 remaining_fraction 的档位算「未知」，不当成用完。
            let Some(fraction) = num(bucket.get("remaining_fraction")).filter(|f| f.is_finite()) else { continue };
            let window = bucket.get("window").and_then(Value::as_str).unwrap_or("").to_lowercase();
            let id = bucket.get("id").and_then(Value::as_str).unwrap_or("").to_lowercase();
            let used = ((1.0 - fraction) * 100.0).clamp(0.0, 100.0);
            let resets = parse_iso(bucket.get("reset_time"));
            // 同一窗口有多档时取剩余最少的。
            if window == "5h" || id.ends_with("5h") {
                if five.as_ref().map_or(-1.0, |w| w.used_percent) < used {
                    five = Some(QuotaWindow { used_percent: used, resets_at: resets, window_seconds: Some(5 * 3600) });
                }
            } else if (window == "weekly" || id.ends_with("weekly")) && weekly.as_ref().map_or(-1.0, |w| w.used_percent) < used {
                weekly = Some(QuotaWindow { used_percent: used, resets_at: resets, window_seconds: Some(7 * 86400) });
            }
        }
        if five.is_none() && weekly.is_none() {
            continue;
        }
        let mut snap = QuotaSnapshot::empty(UsageApp::Agy, now);
        snap.five_hour = five;
        snap.weekly = weekly;
        if is_gemini {
            result.gemini = Some(snap);
        } else {
            result.third_party = Some(snap);
        }
    }
    if result.gemini.is_none() && result.third_party.is_none() {
        return Err(QuotaError::Decode("agy /usage has no known quota buckets".into()));
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_pools() {
        let out = br#"Signing in...
{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":1,"reset_time":"2026-10-20T00:00:00Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.25}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.5},{"id":"3p-5h","window":"5h"}]}]}}}"#;
        let r = parse(out, 0).unwrap();
        assert_eq!(r.gemini.as_ref().unwrap().five_hour.as_ref().unwrap().used_percent, 75.0);
        assert!(r.third_party.as_ref().unwrap().five_hour.is_none());
        let merged = QuotaSnapshot::antigravity(r.gemini.as_ref(), r.third_party.as_ref()).unwrap();
        assert_eq!(merged.weekly.unwrap().used_percent, 50.0);
        assert_eq!(merged.pools.unwrap().len(), 2);
        assert_eq!(parse(br#"{"status":"FAILED","error":"429 RESOURCE_EXHAUSTED"}"#, 0), Err(QuotaError::Http(429, "agy usage rate limited".into())));
    }
}
