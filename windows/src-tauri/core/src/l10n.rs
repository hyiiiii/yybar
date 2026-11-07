//! 对应 Mac 版 `Core/L10n.swift`：界面只显示一种语言，`tr(en, zh)` 按设置选词。
//! 后台产生的文案（错误提示、托盘提示）也走这里；界面文案在前端 `src/shared/l10n.ts`。

use std::sync::atomic::{AtomicBool, Ordering};

static ZH: AtomicBool = AtomicBool::new(true);

/// 设置解析后的语言（跟随系统时由调用方先解析好）。
pub fn set_chinese(zh: bool) {
    ZH.store(zh, Ordering::Relaxed);
}

pub fn is_chinese() -> bool {
    ZH.load(Ordering::Relaxed)
}

pub fn tr(en: &str, zh: &str) -> String {
    if is_chinese() { zh.to_string() } else { en.to_string() }
}

/// 跟随系统：系统首选语言以 zh 开头视为中文（兼容简繁）。
pub fn system_prefers_chinese() -> bool {
    #[cfg(windows)]
    {
        if let Some(lang) = windows_ui_language() {
            return lang.to_lowercase().starts_with("zh");
        }
    }
    ["LC_ALL", "LC_MESSAGES", "LANG", "LANGUAGE"]
        .iter()
        .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .map(|v| v.to_lowercase().starts_with("zh"))
        .unwrap_or(true)
}

/// Windows 的用户界面语言（如 `zh-CN`），通过 PowerShell 以外的方式读取：注册表里的首选语言列表。
#[cfg(windows)]
fn windows_ui_language() -> Option<String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let out = std::process::Command::new("reg")
        .args(["query", r"HKCU\Control Panel\International\User Profile", "/v", "Languages"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.lines().find(|l| l.contains("Languages"))?;
    let value = line.split("REG_MULTI_SZ").nth(1)?.trim();
    value.split("\\0").next().map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}
