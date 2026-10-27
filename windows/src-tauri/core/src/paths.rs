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

/// 在 PATH、常见安装目录（见 `cli_dirs`）和给定的候选位置里找可执行文件（Windows 上自动补 `.exe` / `.cmd`）。
/// 结果缓存 30 秒：状态快照每次发布都要问几遍，PATH 里有断开的网络盘时每次查找都可能卡住好几秒。
pub fn find_executable(name: &str, extra: &[PathBuf]) -> Option<PathBuf> {
    use std::collections::HashMap;
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    static CACHE: Mutex<Option<HashMap<String, (Instant, Option<PathBuf>)>>> = Mutex::new(None);
    let key = format!("{name}|{}", extra.iter().map(|p| p.to_string_lossy()).collect::<Vec<_>>().join("|"));
    if let Some((at, found)) = CACHE.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).get(&key) {
        if at.elapsed() < Duration::from_secs(30) {
            return found.clone();
        }
    }
    let found = search_executable(name, extra);
    CACHE.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).insert(key, (Instant::now(), found.clone()));
    found
}

fn search_executable(name: &str, extra: &[PathBuf]) -> Option<PathBuf> {
    let exts: &[&str] = if cfg!(windows) { &[".exe", ".cmd", ".bat", ""] } else { &[""] };
    let mut dirs: Vec<PathBuf> = extra.to_vec();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.extend(cli_dirs());
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

/// CLI 常见的安装目录（结果缓存一分钟）。yybar 是图形程序，PATH 是登录时从资源管理器继承的：
/// 之后才装的工具、用 nvm / fnm / Volta 管理的 Node 装的 npm 包往往不在里面，所以另外找注册表里的
/// 用户 / 系统 PATH 和这些包管理器的目录。只在 Windows 上有内容。
pub fn cli_dirs() -> Vec<PathBuf> {
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    static CACHE: Mutex<Option<(Instant, Vec<PathBuf>)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, dirs)) = cache.as_ref() {
        if at.elapsed() < Duration::from_secs(60) {
            return dirs.clone();
        }
    }
    let dirs = scan_cli_dirs();
    *cache = Some((Instant::now(), dirs.clone()));
    dirs
}

#[cfg(not(windows))]
fn scan_cli_dirs() -> Vec<PathBuf> {
    Vec::new()
}

#[cfg(windows)]
fn scan_cli_dirs() -> Vec<PathBuf> {
    let mut dirs = registry_path_dirs();
    let home = home();
    let appdata = env_dir("APPDATA");
    let local = env_dir("LOCALAPPDATA");
    if let Some(d) = &appdata {
        dirs.push(d.join("npm"));
    }
    if let Some(d) = &local {
        dirs.push(d.join("pnpm"));
        dirs.push(d.join("Volta").join("bin"));
        dirs.push(d.join("Microsoft").join("WinGet").join("Links"));
        dirs.push(d.join("Microsoft").join("WindowsApps"));
    }
    if let Some(d) = env_dir("ProgramFiles") {
        dirs.push(d.join("nodejs"));
    }
    dirs.extend(env_dir("NVM_SYMLINK"));
    dirs.push(PathBuf::from(r"C:\nvm4w\nodejs"));
    dirs.push(home.join("scoop").join("shims"));
    dirs.push(home.join(".bun").join("bin"));
    dirs.push(home.join(".local").join("bin"));
    dirs.push(home.join(".cargo").join("bin"));
    // nvm-windows：每个 Node 版本一个目录，全局 npm 包的命令就在里面
    for base in [env_dir("NVM_HOME"), appdata.as_ref().map(|d| d.join("nvm"))].into_iter().flatten() {
        dirs.extend(subdirs(&base).into_iter().filter(|d| d.file_name().is_some_and(|n| n.to_string_lossy().starts_with('v'))));
    }
    // fnm：<FNM_DIR>/node-versions/<版本>/installation
    for base in [env_dir("FNM_DIR"), appdata.as_ref().map(|d| d.join("fnm")), local.as_ref().map(|d| d.join("fnm"))].into_iter().flatten() {
        dirs.extend(subdirs(&base.join("node-versions")).into_iter().map(|d| d.join("installation")));
    }
    dirs.retain(|d| d.is_dir());
    let mut seen = std::collections::HashSet::new();
    dirs.retain(|d| seen.insert(d.to_string_lossy().to_lowercase()));
    dirs
}

/// 注册表里的用户 PATH 和系统 PATH（展开其中的 %变量%）。
#[cfg(windows)]
fn registry_path_dirs() -> Vec<PathBuf> {
    use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE};
    use winreg::RegKey;
    let read = |root: winreg::HKEY, key: &str| -> Option<String> { RegKey::predef(root).open_subkey(key).ok()?.get_value::<String, _>("Path").ok() };
    [
        read(HKEY_CURRENT_USER, "Environment"),
        read(HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
    ]
    .into_iter()
    .flatten()
    .flat_map(|value| value.split(';').map(expand_env).collect::<Vec<_>>())
    .filter(|s| !s.trim().is_empty())
    .map(|s| PathBuf::from(s.trim()))
    .collect()
}

/// 展开 `%NAME%`；找不到的变量原样保留。
#[cfg(any(windows, test))]
fn expand_env(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find('%') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        match after.find('%') {
            Some(end) => {
                let name = &after[..end];
                match std::env::var(name) {
                    Ok(v) if !name.is_empty() => out.push_str(&v),
                    _ => {
                        out.push('%');
                        out.push_str(name);
                        out.push('%');
                    }
                }
                rest = &after[end + 1..];
            }
            None => {
                out.push_str(&rest[start..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(windows)]
fn subdirs(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir).map(|it| it.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect()).unwrap_or_default()
}

/// 给子进程用的 PATH：CLI 自己所在的目录 + 当前 PATH + 常见安装目录。npm 装的 `.cmd` 要找得到 node。
pub fn child_path(binary: &Path) -> std::ffi::OsString {
    let mut dirs: Vec<PathBuf> = binary.parent().map(Path::to_path_buf).into_iter().collect();
    if let Some(path) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&path));
    }
    dirs.extend(cli_dirs());
    std::env::join_paths(dirs).unwrap_or_else(|_| std::env::var_os("PATH").unwrap_or_default())
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

/// 结束子进程连同它启动的进程。Windows 上 npm 装的 CLI 是 `.cmd`，真正的 CLI 跑在 cmd.exe 的子进程里，
/// 只结束 cmd.exe 会把它留在后台，所以先用 `taskkill /T` 结束整棵进程树。
pub async fn kill_tree(child: &mut tokio::process::Child) {
    #[cfg(windows)]
    if let Some(pid) = child.id() {
        let mut cmd = tokio::process::Command::new("taskkill");
        cmd.args(["/T", "/F", "/PID", &pid.to_string()])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        hide_console(&mut cmd);
        let _ = cmd.status().await;
    }
    let _ = child.kill().await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_env_vars() {
        std::env::set_var("YYBAR_TEST_DIR", r"C:\Users\me");
        assert_eq!(expand_env(r"%YYBAR_TEST_DIR%\npm"), r"C:\Users\me\npm");
        assert_eq!(expand_env(r"%YYBAR_NO_SUCH_VAR%\x"), r"%YYBAR_NO_SUCH_VAR%\x");
        assert_eq!(expand_env("plain;100%"), "plain;100%");
    }

    #[test]
    fn parses_utf16_wsl_list() {
        let text = "Ubuntu\r\nDebian\r\n";
        let bytes: Vec<u8> = text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(parse_wsl_list(&bytes), vec!["Ubuntu", "Debian"]);
    }
}
