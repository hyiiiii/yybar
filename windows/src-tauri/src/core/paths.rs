//! 各 CLI 在本机（以及正在运行的 WSL 发行版里）的数据目录。

use std::path::PathBuf;

pub fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

fn env_dir(key: &str) -> Option<PathBuf> {
    std::env::var_os(key)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

/// Claude Code 配置目录：`CLAUDE_CONFIG_DIR`，否则 `~/.claude`。
pub fn claude_dir() -> PathBuf {
    env_dir("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home().join(".claude"))
}

/// Codex 配置目录：`CODEX_HOME`，否则 `~/.codex`。
pub fn codex_dir() -> PathBuf {
    env_dir("CODEX_HOME").unwrap_or_else(|| home().join(".codex"))
}

pub fn grok_dir() -> PathBuf {
    home().join(".grok")
}

/// 一个用户主目录（Windows 本机或某个 WSL 发行版里的 /home/xxx）。
#[derive(Debug, Clone)]
pub struct HomeRoot {
    pub path: PathBuf,
    /// 来自 WSL 时是发行版名
    pub wsl_distro: Option<String>,
}

/// Windows 本机主目录 + （可选）正在运行的 WSL 发行版里的用户主目录。
/// 只看已经在运行的发行版：访问 `\\wsl.localhost\<distro>` 会把没开的发行版拉起来。
pub fn home_roots(include_wsl: bool) -> Vec<HomeRoot> {
    let mut roots = vec![HomeRoot { path: home(), wsl_distro: None }];
    if include_wsl {
        roots.extend(wsl_homes());
    }
    roots
}

#[cfg(windows)]
fn wsl_homes() -> Vec<HomeRoot> {
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
fn wsl_homes() -> Vec<HomeRoot> {
    vec![]
}

/// `wsl.exe --list` 输出 UTF-16LE，每行一个发行版名。
#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_wsl_list(bytes: &[u8]) -> Vec<String> {
    let text = if bytes.len() >= 2 && bytes.iter().skip(1).step_by(2).take(8).all(|b| *b == 0) {
        let units: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
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
