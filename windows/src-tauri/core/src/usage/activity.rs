//! 「使用中」判断（对应 Mac `UsageActivityMonitor`，不含 hook 驱动那一套）。
//!
//! 额度接口 2 分钟才刷新一次，太慢；CLI 对话进行中会持续往会话日志里追加，监听写入即可近实时感知。
//! 最近 30 秒内有写入的服务视为使用中（托盘图标呼吸），写入停止后自动回落。
//! agy 没有 `.jsonl`，看会话库（`conversations/*.db` 和 `-wal`）的修改事件，不打开库。
//! 等待审批：日志最后一条相关记录是「还没有结果的工具调用」且 3 秒没有新写入时视为在等待审批（图标保持识别色），
//! 最多 30 分钟。没有本地日志可看的情况（Antigravity 两池），额度刷新发现剩余减少时也算使用中（`mark_quota_activity`）。

use std::collections::{BTreeSet, HashMap};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use notify::{RecursiveMode, Watcher};
use serde_json::Value;

use crate::UsageApp;

pub const ACTIVE_WINDOW: Duration = Duration::from_secs(30);
pub const PENDING_DELAY: Duration = Duration::from_secs(3);
pub const PENDING_LIMIT: Duration = Duration::from_secs(30 * 60);

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ActivitySnapshot {
    pub active: BTreeSet<UsageApp>,
    pub waiting: BTreeSet<UsageApp>,
}

#[derive(Default)]
struct Inner {
    last_write: HashMap<UsageApp, Instant>,
    pending_tool: HashMap<UsageApp, bool>,
    quota_active_until: HashMap<UsageApp, Instant>,
}

#[derive(Clone)]
pub struct ActivityMonitor {
    inner: Arc<Mutex<Inner>>,
    watcher: Arc<Mutex<Option<notify::RecommendedWatcher>>>,
}

impl Default for ActivityMonitor {
    fn default() -> Self {
        Self::new()
    }
}

impl ActivityMonitor {
    pub fn new() -> ActivityMonitor {
        ActivityMonitor { inner: Arc::new(Mutex::new(Inner::default())), watcher: Arc::new(Mutex::new(None)) }
    }

    /// 开始监听（重复调用会换成新的目录列表）。`changed` 在有写入时被调用（在监听线程上）。
    pub fn start(&self, roots: Vec<(UsageApp, PathBuf)>, changed: impl Fn() + Send + 'static) {
        let roots: Vec<(UsageApp, PathBuf)> = roots.into_iter().filter(|(_, p)| p.is_dir()).collect();
        let inner = self.inner.clone();
        let handler_roots = roots.clone();
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            let Ok(event) = res else { return };
            if matches!(event.kind, notify::EventKind::Access(_)) {
                return;
            }
            let now = Instant::now();
            let mut touched = false;
            for path in &event.paths {
                let Some((app, _)) = handler_roots.iter().find(|(_, r)| path.starts_with(r)) else { continue };
                let name = path.to_string_lossy().to_lowercase();
                if *app == UsageApp::Agy {
                    if !(name.ends_with(".db") || name.ends_with(".db-wal")) {
                        continue;
                    }
                    inner.lock().unwrap().last_write.insert(*app, now);
                    touched = true;
                    continue;
                }
                if !name.ends_with(".jsonl") {
                    continue;
                }
                let pending = ends_with_pending_tool_call(path, *app);
                let mut g = inner.lock().unwrap();
                g.last_write.insert(*app, now);
                if let Some(p) = pending {
                    g.pending_tool.insert(*app, p);
                }
                touched = true;
            }
            if touched {
                changed();
            }
        });
        let Ok(mut watcher) = watcher else { return };
        for (_, root) in &roots {
            let _ = watcher.watch(root, RecursiveMode::Recursive);
        }
        *self.watcher.lock().unwrap() = Some(watcher);
    }

    /// 额度刷新发现剩余减少：呼吸到 `until` 之后。
    pub fn mark_quota_activity(&self, app: UsageApp, hold: Duration) {
        let until = Instant::now() + hold;
        let mut g = self.inner.lock().unwrap();
        let entry = g.quota_active_until.entry(app).or_insert(until);
        if *entry < until {
            *entry = until;
        }
    }

    pub fn snapshot(&self) -> ActivitySnapshot {
        let now = Instant::now();
        let mut g = self.inner.lock().unwrap();
        g.quota_active_until.retain(|_, until| *until > now);
        let mut snap = ActivitySnapshot::default();
        snap.active.extend(g.quota_active_until.keys().copied());
        for (app, at) in &g.last_write {
            let quiet = now.duration_since(*at);
            if g.pending_tool.get(app) == Some(&true) && quiet >= PENDING_DELAY && quiet < PENDING_LIMIT {
                snap.waiting.insert(*app);
            } else if quiet < ACTIVE_WINDOW {
                snap.active.insert(*app);
            }
        }
        for app in snap.active.clone() {
            snap.waiting.remove(&app);
        }
        snap
    }

    /// 还有东西会随时间变化（使用中 / 等待中 / 将转入等待），调用方据此决定要不要每秒复查。
    pub fn needs_ticking(&self) -> bool {
        let now = Instant::now();
        let g = self.inner.lock().unwrap();
        g.quota_active_until.values().any(|u| *u > now)
            || g.last_write.iter().any(|(app, at)| {
                let quiet = now.duration_since(*at);
                quiet < ACTIVE_WINDOW || (g.pending_tool.get(app) == Some(&true) && quiet < PENDING_LIMIT)
            })
    }
}

fn tail(path: &Path) -> Option<String> {
    let mut f = std::fs::File::open(path).ok()?;
    let size = f.metadata().ok()?.len();
    f.seek(SeekFrom::Start(size.saturating_sub(65_536))).ok()?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf).ok()?;
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// 读日志末尾，判断最后一条相关记录是否为还没有结果的工具调用。None 表示这个文件判断不了。
pub fn ends_with_pending_tool_call(path: &Path, app: UsageApp) -> Option<bool> {
    if app == UsageApp::Agy {
        return None;
    }
    if app == UsageApp::Grok && !path.to_string_lossy().ends_with("updates.jsonl") {
        return None;
    }
    let text = tail(path)?;
    for line in text.lines().rev() {
        let Ok(record) = serde_json::from_str::<Value>(line) else { continue };
        match app {
            UsageApp::Claude => {
                let kind = record.get("type").and_then(Value::as_str);
                if kind != Some("assistant") && kind != Some("user") {
                    continue;
                }
                if kind != Some("assistant") {
                    return Some(false);
                }
                let Some(message) = record.get("message") else { return Some(false) };
                if message.get("stop_reason").and_then(Value::as_str) == Some("tool_use") {
                    return Some(true);
                }
                let has_tool = message
                    .get("content")
                    .and_then(Value::as_array)
                    .is_some_and(|c| c.iter().any(|i| i.get("type").and_then(Value::as_str) == Some("tool_use")));
                return Some(has_tool);
            }
            UsageApp::Codex => {
                let kind = record.get("type").and_then(Value::as_str);
                let payload = record.get("payload").and_then(|p| p.get("type")).and_then(Value::as_str);
                if kind == Some("event_msg") && matches!(payload, Some("task_complete" | "turn_aborted")) {
                    return Some(false);
                }
                if kind != Some("response_item") {
                    continue;
                }
                let Some(payload) = payload else { continue };
                return Some(payload == "function_call" || payload == "custom_tool_call");
            }
            UsageApp::Grok => {
                let Some(update) = record.get("params").and_then(|p| p.get("update")) else { continue };
                match update.get("sessionUpdate").and_then(Value::as_str) {
                    Some("tool_call" | "tool_call_update") => {
                        let status = update.get("status").and_then(Value::as_str);
                        return Some(status != Some("completed") && status != Some("failed"));
                    }
                    Some("agent_message_chunk" | "agent_thought_chunk" | "user_message_chunk" | "turn_completed") => return Some(false),
                    _ => continue,
                }
            }
            UsageApp::Agy => return None,
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn detects_pending_claude_tool() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("s.jsonl");
        let mut f = std::fs::File::create(&p).unwrap();
        writeln!(f, r#"{{"type":"assistant","message":{{"stop_reason":"tool_use","content":[]}}}}"#).unwrap();
        writeln!(f, r#"{{"type":"attachment"}}"#).unwrap();
        assert_eq!(ends_with_pending_tool_call(&p, UsageApp::Claude), Some(true));
        writeln!(f, r#"{{"type":"user","message":{{"content":"ok"}}}}"#).unwrap();
        assert_eq!(ends_with_pending_tool_call(&p, UsageApp::Claude), Some(false));
    }
}
