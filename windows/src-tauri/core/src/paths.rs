//! 各 CLI 在本机（以及正在运行的 WSL 发行版里）的数据目录，和 yybar 自己的数据目录。
//!
//! | Mac | Windows |
//! |---|---|
//! | `~/Library/Application Support/yybar` | `%APPDATA%\yybar` |
//! | `~/Library/Caches/yybar` | `%LOCALAPPDATA%\yybar` |

use std::path::{Path, PathBuf};

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

fn env_dir(key: &str) -> Option<PathBuf> {
    std::env::var_os(key).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// Claude Code 配置目录：`CLAUDE_CONFIG_DIR`，否则 `~/.claude`。
pub fn claude_dir() -> PathBuf {
    env_dir("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home().join(".claude"))
}

/// Codex 配置目录：`CODEX_HOME`，否则 `~/.codex`。
pub fn codex_dir() -> PathBuf {
    env_dir("CODEX_HOME").unwrap_or_else(|| home().join(".codex"))
}

/// Grok CLI 目录：`GROK_HOME`，否则 `~/.grok`。
pub fn grok_dir() -> PathBuf {
    env_dir("GROK_HOME").unwrap_or_else(|| home().join(".grok"))
}

/// agy（Antigravity CLI）用的 `~/.gemini`（`GEMINI_CLI_HOME` 可改）。
pub fn gemini_dir() -> PathBuf {
    env_dir("GEMINI_CLI_HOME").unwrap_or_else(|| home().join(".gemini"))
}

/// yybar 数据目录（对应 Mac 的 Application Support/yybar）。测试时可用 `YYBAR_DATA_DIR` 指到临时目录。
pub fn data_dir() -> PathBuf {
    env_dir("YYBAR_DATA_DIR")
        .unwrap_or_else(|| dirs::config_dir().unwrap_or_else(home).join("yybar"))
}

/// yybar 缓存目录（对应 Mac 的 Caches/yybar）。
pub fn cache_dir() -> PathBuf {
    env_dir("YYBAR_CACHE_DIR")
        .unwrap_or_else(|| dirs::cache_dir().unwrap_or_else(home).join("yybar"))
}

/// 先写临时文件再改名，避免写到一半崩溃留下坏文件（对应 Swift 的 `.atomic`）。
pub fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&tmp, data)?;
    match std::fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

/// 一个用户主目录（Windows 本机或某个 WSL 发行版里的 /home/xxx）。
#[derive(Debug, Clone, PartialEq)]
pub struct HomeRoot {
    pub path: PathBuf,
    /// 来自 WSL 时是发行版名
    pub wsl_distro: Option<String>,
}

/// 正在运行的 WSL 发行版里的用户主目录（有 .claude / .codex / .grok 的）。
/// 只看已经在运行的发行版：访问 `\\wsl.localhost\<distro>` 会把没开的发行版拉起来。
pub fn wsl_homes() -> Vec<HomeRoot> {
    wsl_homes_impl()
}

#[cfg(windows)]
fn wsl_homes_impl() -> Vec<HomeRoot> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let output = std::process::Command::new("wsl.exe")
        .args(["--list", "--quiet", "--running"])
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    let Ok(output) = output else { return vec![] };
    if !output.status.success() {
        return vec![];
    }
    let mut roots = Vec::new();
    for distro in parse_wsl_list(&output.stdout) {
        let base = PathBuf::from(format!(r"\\wsl.localhost\{distro}"));
        let mut candidates = vec![base.join("root")];
        if let Ok(entries) = std::fs::read_dir(base.join("home")) {
            candidates.extend(entries.flatten().map(|e| e.path()));
        }
        for path in candidates {
            if path.join(".claude").is_dir() || path.join(".codex").is_dir() || path.join(".grok").is_dir() {
                roots.push(HomeRoot { path, wsl_distro: Some(distro.clone()) });
            }
        }
    }
    roots
}

#[cfg(not(windows))]
fn wsl_homes_impl() -> Vec<HomeRoot> {
    vec![]
}

/// `wsl.exe --list` 输出 UTF-16LE，每行一个发行版名。
pub fn parse_wsl_list(bytes: &[u8]) -> Vec<String> {
    let text = if bytes.len() >= 2 && bytes.iter().skip(1).step_by(2).take(8).all(|b| *b == 0) {
        let units: Vec<u16> = bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    };
    text.lines()
        .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}' || c == '\0'))
        .filter(|l| !l.is_empty())
        .map(str::to_string)
        .collect()
}

/// 在 PATH 和给定的候选位置里找可执行文件（Windows 上自动补 `.exe` / `.cmd`）。
pub fn find_executable(name: &str, extra: &[PathBuf]) -> Option<PathBuf> {
    let exts: &[&str] = if cfg!(windows) { &[".exe", ".cmd", ".bat", ""] } else { &[""] };
    let mut dirs: Vec<PathBuf> = extra.to_vec();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    for dir in dirs {
        for ext in exts {
            let candidate = dir.join(format!("{name}{ext}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// 不弹黑色控制台窗口地启动子进程（Windows 的 CREATE_NO_WINDOW）。
pub fn hide_console(cmd: &mut tokio::process::Command) {
    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let _ = cmd;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_utf16_wsl_list() {
        let text = "Ubuntu\r\nDebian\r\n";
        let bytes: Vec<u8> = text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(parse_wsl_list(&bytes), vec!["Ubuntu", "Debian"]);
    }
}
