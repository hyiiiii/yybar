//! 在浏览器中登录（对应 Mac `CLILoginSession`）：用官方 CLI 在新账号自己的目录里登录，不影响本机 CLI 已登录的账号。
//! - Codex：`CODEX_HOME=<目录> codex login`（本地回调，浏览器里授权后自动结束）
//! - Claude Code：`CLAUDE_CONFIG_DIR=<目录> claude auth login --claudeai`（浏览器页面给出授权码，要粘贴回 CLI）
//! - Grok：`GROK_HOME=<目录> grok login --oauth`（本地回调，自动结束）
//! CLI 退出码 0 视为登录成功，凭据已经在账号目录里；没成功或取消时删掉目录。
//! 输出里第一个像登录页的链接（含 authorize / oauth）记下来，界面上可以「重新打开登录页」。

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::ChildStdin;
use tokio::sync::oneshot;

use super::{new_dir, remove_dir, AccountError, Provider};
use crate::paths;
use crate::tr;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Phase {
    Starting,
    WaitingForBrowser,
    /// Claude：浏览器页面给了授权码，等用户粘贴回来
    NeedsCode,
    Exited {
        succeeded: bool,
    },
    Failed {
        message: String,
    },
}

/// 给界面的登录进度。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginView {
    pub id: String,
    pub provider: Provider,
    pub phase: Phase,
    pub login_url: Option<String>,
    /// CLI 最近的输出（失败时显示最后几行）
    pub output_tail: String,
}

pub type OnChange = Arc<dyn Fn(LoginView) + Send + Sync>;

pub struct LoginSession {
    pub id: String,
    pub provider: Provider,
    /// 账号目录（凭据直接登录进这里）
    pub folder: String,
    pub dir: PathBuf,
    inner: Mutex<Inner>,
    on_change: OnChange,
}

struct Inner {
    phase: Phase,
    login_url: Option<String>,
    output: String,
    stdin: Option<ChildStdin>,
    cancel: Option<oneshot::Sender<()>>,
}

/// 浏览器登录调用的官方命令（界面上展示用）。
pub fn login_command(provider: Provider) -> &'static str {
    match provider {
        Provider::Codex => "codex login",
        Provider::Claude => "claude auth login",
        Provider::Grok => "grok login --oauth",
        Provider::Google => "agy",
    }
}

/// 粘贴方式对应的凭据文件（界面上展示用）。
pub fn credentials_file(provider: Provider) -> &'static str {
    match provider {
        Provider::Codex => r"%USERPROFILE%\.codex\auth.json",
        Provider::Claude => r"%USERPROFILE%\.claude\.credentials.json",
        Provider::Grok => r"%USERPROFILE%\.grok\auth.json",
        Provider::Google => "",
    }
}

/// 本机的官方 CLI：PATH，再加 npm 全局目录、`~/.local/bin` 等常见安装位置。
pub fn binary(provider: Provider) -> Option<PathBuf> {
    let home = paths::home();
    let npm = std::env::var_os("APPDATA").map(|d| PathBuf::from(d).join("npm"));
    let mut extra: Vec<PathBuf> = npm.into_iter().collect();
    extra.push(home.join(".local").join("bin"));
    match provider {
        Provider::Codex => {
            extra.push(home.join(".bun").join("bin"));
            paths::find_executable("codex", &extra)
        }
        Provider::Claude => {
            extra.push(home.join(".claude").join("local"));
            paths::find_executable("claude", &extra)
        }
        Provider::Grok => crate::quota::grok::binary(),
        Provider::Google => crate::quota::google::binary(),
    }
}

impl LoginSession {
    /// 新建账号目录并启动 CLI。找不到 CLI 时返回错误（界面提示改用粘贴凭据）。
    pub fn start(provider: Provider, on_change: OnChange) -> Result<Arc<LoginSession>, AccountError> {
        let command = login_command(provider);
        let name = command.split(' ').next().unwrap_or(command);
        let binary = binary(provider).ok_or_else(|| {
            AccountError::msg(tr(
                &format!("Couldn't find the {name} command on this PC. Install the CLI first, or paste credentials instead."),
                &format!("本机没有找到 {name} 命令。请先安装对应 CLI，或改用粘贴凭据。"),
            ))
        })?;
        let (folder, dir) = new_dir(provider)?;
        let mut cmd = tokio::process::Command::new(&binary);
        match provider {
            Provider::Codex => {
                cmd.env("CODEX_HOME", &dir).arg("login");
            }
            Provider::Claude => {
                cmd.env("CLAUDE_CONFIG_DIR", &dir).args(["auth", "login", "--claudeai"]);
            }
            Provider::Grok => {
                cmd.env("GROK_HOME", &dir).args(["login", "--oauth"]);
            }
            Provider::Google => {
                remove_dir(provider, &folder);
                return Err(AccountError::msg("Google accounts sign in through agy in a console window"));
            }
        }
        cmd.current_dir(&dir)
            .env("NO_COLOR", "1")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        paths::hide_console(&mut cmd);
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                remove_dir(provider, &folder);
                return Err(AccountError::msg(e.to_string()));
            }
        };
        let (cancel_tx, cancel_rx) = oneshot::channel();
        let session = Arc::new(LoginSession {
            id: uuid::Uuid::new_v4().simple().to_string(),
            provider,
            folder,
            dir,
            inner: Mutex::new(Inner {
                phase: Phase::Starting,
                login_url: None,
                output: String::new(),
                stdin: child.stdin.take(),
                cancel: Some(cancel_tx),
            }),
            on_change,
        });
        if let Some(out) = child.stdout.take() {
            tokio::spawn(read_output(session.clone(), out));
        }
        if let Some(err) = child.stderr.take() {
            tokio::spawn(read_output(session.clone(), err));
        }
        let s = session.clone();
        tokio::spawn(async move {
            let status = tokio::select! {
                status = child.wait() => status.ok(),
                _ = cancel_rx => {
                    paths::kill_tree(&mut child).await;
                    // CLI 退出前目录还被占着，删不干净，结束后再删一次
                    remove_dir(s.provider, &s.folder);
                    None
                }
            };
            s.finish(status.map(|st| st.success()));
        });
        session.notify();
        Ok(session)
    }

    pub fn view(&self) -> LoginView {
        let g = self.inner.lock().unwrap();
        let tail: String = {
            let chars: Vec<char> = g.output.chars().collect();
            chars[chars.len().saturating_sub(600)..].iter().collect()
        };
        LoginView { id: self.id.clone(), provider: self.provider, phase: g.phase.clone(), login_url: g.login_url.clone(), output_tail: tail }
    }

    fn notify(&self) {
        (self.on_change)(self.view());
    }

    /// Claude：把浏览器页面上的授权码交给 CLI。
    pub async fn submit_code(&self, code: &str) {
        let code = code.trim();
        if code.is_empty() {
            return;
        }
        let stdin = self.inner.lock().unwrap().stdin.take();
        if let Some(mut stdin) = stdin {
            let line = if cfg!(windows) { format!("{code}\r\n") } else { format!("{code}\n") };
            let _ = stdin.write_all(line.as_bytes()).await;
            let _ = stdin.flush().await;
            let mut g = self.inner.lock().unwrap();
            g.stdin = Some(stdin);
            if g.phase == Phase::NeedsCode {
                g.phase = Phase::WaitingForBrowser;
            }
        }
        self.notify();
    }

    /// 取消：结束 CLI，删掉账号目录。
    pub fn cancel(&self) {
        if let Some(tx) = self.inner.lock().unwrap().cancel.take() {
            let _ = tx.send(());
        }
        remove_dir(self.provider, &self.folder);
    }

    /// 登录成功后添加账号失败（比如就是本机账号）时也要删掉目录。
    pub fn discard(&self) {
        remove_dir(self.provider, &self.folder);
    }

    fn consume(&self, text: &str) {
        {
            let mut g = self.inner.lock().unwrap();
            g.output.push_str(&strip_ansi(text));
            if g.output.len() > 64 * 1024 {
                let cut = g.output.len() - 32 * 1024;
                let cut = (cut..g.output.len()).find(|i| g.output.is_char_boundary(*i)).unwrap_or(cut);
                g.output.drain(..cut);
            }
            if g.login_url.is_none() {
                if let Some(url) = first_login_url(text) {
                    g.login_url = Some(url);
                    if g.phase == Phase::Starting {
                        g.phase = Phase::WaitingForBrowser;
                    }
                }
            }
            if self.provider == Provider::Claude
                && g.output.to_lowercase().contains("paste code")
                && matches!(g.phase, Phase::Starting | Phase::WaitingForBrowser)
            {
                g.phase = Phase::NeedsCode;
            }
        }
        self.notify();
    }

    fn finish(&self, succeeded: Option<bool>) {
        {
            let mut g = self.inner.lock().unwrap();
            g.stdin = None;
            if matches!(g.phase, Phase::Failed { .. }) {
                return;
            }
            g.phase = Phase::Exited { succeeded: succeeded.unwrap_or(false) };
        }
        self.notify();
    }
}

async fn read_output(session: Arc<LoginSession>, mut stream: impl AsyncRead + Unpin) {
    let mut buf = [0u8; 4096];
    let mut pending: Vec<u8> = Vec::new();
    loop {
        match stream.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                pending.extend_from_slice(&buf[..n]);
                // 只交出完整的 UTF-8，半个字符留到下一次
                let valid = match std::str::from_utf8(&pending) {
                    Ok(_) => pending.len(),
                    Err(e) => e.valid_up_to(),
                };
                if valid > 0 {
                    let text = String::from_utf8_lossy(&pending[..valid]).into_owned();
                    pending.drain(..valid);
                    session.consume(&text);
                }
            }
        }
    }
}

/// 去掉终端颜色 / 光标控制序列（CSI `ESC [ … 字母`、OSC `ESC ] … BEL/ST`）。
pub fn strip_ansi(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            if c != '\r' {
                out.push(c);
            }
            continue;
        }
        match chars.next() {
            Some('[') => {
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(c) = chars.next() {
                    if c == '\u{7}' {
                        break;
                    }
                    if c == '\u{1b}' && chars.peek() == Some(&'\\') {
                        chars.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// 输出里第一个像登录页的 https 链接（含 authorize / oauth）。也认终端超链接（OSC 8）里的地址。
pub fn first_login_url(text: &str) -> Option<String> {
    let mut rest = text;
    while let Some(idx) = rest.find("https://") {
        let tail = &rest[idx..];
        let end = tail
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | '<' | '>' | '\u{7}' | '\u{1b}'))
            .unwrap_or(tail.len());
        let url = tail[..end].trim_end_matches(['.', ',', ')', ';']);
        if url.contains("authorize") || url.contains("oauth") {
            return Some(url.to_string());
        }
        rest = &tail[end..];
    }
    None
}

/// 同一个登录链接加上 OIDC 标准参数 `prompt=login`，要求重新显示登录表单，而不是直接沿用浏览器里已登录的账号。
/// state / PKCE 不变，CLI 仍能接住回调；服务商不支持时会忽略它。
pub fn switch_account_url(url: &str) -> String {
    let (base, fragment) = match url.split_once('#') {
        Some((b, f)) => (b, Some(f)),
        None => (url, None),
    };
    let (path, query) = base.split_once('?').unwrap_or((base, ""));
    let mut params: Vec<&str> = query.split('&').filter(|p| !p.is_empty() && !p.starts_with("prompt=")).collect();
    params.push("prompt=login");
    let mut out = format!("{path}?{}", params.join("&"));
    if let Some(f) = fragment {
        out.push('#');
        out.push_str(f);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_login_links() {
        let text = "Starting local login server on http://localhost:1455.\nIf your browser did not open, navigate to this URL to authenticate:\n\n\u{1b}[1mhttps://auth.openai.com/oauth/authorize?response_type=code&client_id=x&state=s\u{1b}[0m\n";
        assert_eq!(first_login_url(text).as_deref(), Some("https://auth.openai.com/oauth/authorize?response_type=code&client_id=x&state=s"));
        let osc = "\u{1b}]8;;https://claude.ai/oauth/authorize?code=true&state=z\u{7}Open\u{1b}]8;;\u{7}";
        assert_eq!(first_login_url(osc).as_deref(), Some("https://claude.ai/oauth/authorize?code=true&state=z"));
        assert_eq!(first_login_url("see https://docs.example.com/help."), None);
    }

    #[test]
    fn strips_terminal_sequences() {
        assert_eq!(strip_ansi("\u{1b}[32mok\u{1b}[0m\r\n\u{1b}]8;;https://x\u{7}link\u{1b}]8;;\u{1b}\\"), "ok\nlink");
    }

    #[test]
    fn adds_prompt_login() {
        assert_eq!(switch_account_url("https://a/authorize?x=1&prompt=none"), "https://a/authorize?x=1&prompt=login");
        assert_eq!(switch_account_url("https://a/authorize"), "https://a/authorize?prompt=login");
        assert_eq!(switch_account_url("https://a/authorize?x=1#frag"), "https://a/authorize?x=1&prompt=login#frag");
    }
}
