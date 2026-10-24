//! Claude Code 会话日志：`~/.claude/projects/**/*.jsonl`，加上 Claude 桌面 App Cowork 会话自己的 `.claude/projects`
//! （对应 Mac `ClaudeJSONLScanner`）。解析 `type=assistant` 行；同一 `message.id` 跨文件全局去重
//! （sidechain / subagent 会重复引用同一条），seen 集合上限 20000。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::jsonl::{self, key};
use super::models::{ScanFileState, ScanResult, UsageEntry};
use super::pricing;
use crate::UsageApp;

const SEEN_LIMIT: usize = 20_000;

/// 一个主目录下的日志根：`.claude/projects`；本机再加上 Claude 桌面 App 的 Cowork 会话。
pub fn roots(claude_dir: &Path, include_cowork: bool) -> Vec<PathBuf> {
    let mut roots = vec![claude_dir.join("projects")];
    if include_cowork {
        let cowork = dirs::config_dir().unwrap_or_default().join("Claude").join("local-agent-mode-sessions");
        for account in subdirs(&cowork) {
            for org in subdirs(&account) {
                for session in subdirs(&org) {
                    if session.file_name().is_some_and(|n| n.to_string_lossy().starts_with("local_")) {
                        roots.push(session.join(".claude").join("projects"));
                    }
                }
            }
        }
    }
    roots
}

fn subdirs(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|it| it.flatten().filter(|e| e.file_type().is_ok_and(|t| t.is_dir())).map(|e| e.path()).collect())
        .unwrap_or_default()
}

pub struct ClaudeScan {
    pub result: ScanResult,
    pub seen: Vec<String>,
}

struct Parsed {
    id: String,
    model: String,
    day: chrono::NaiveDate,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_creation: i64,
    stop_reason: Option<String>,
}

pub fn scan(previous: &HashMap<String, ScanFileState>, seen_ids: &[String], roots: &[PathBuf]) -> ClaudeScan {
    let files: Vec<PathBuf> = roots.iter().flat_map(|r| jsonl::files(r, false)).collect();
    let mut new_state = previous.clone();
    let mut entries = Vec::new();
    let mut lines_parsed = 0;
    let mut seen_order: Vec<String> = seen_ids.to_vec();
    let mut seen: HashSet<String> = seen_ids.iter().cloned().collect();

    for path in &files {
        let k = key(path);
        let (mtime, size) = jsonl::signature(path);
        let mut state = previous.get(&k).cloned().unwrap_or_default();
        if state.mtime == mtime && state.offset == size {
            new_state.insert(k, state);
            continue;
        }
        if state.offset > size {
            state.offset = 0;
        }
        // 本批次内按 id 收集，优先有 stop_reason 的一条；最后再与全局 seen 比对。
        let mut candidates: HashMap<String, Parsed> = HashMap::new();
        let mut order: Vec<String> = Vec::new();
        let mut lines = 0;
        let new_offset = jsonl::scan(path, state.offset, &["output_tokens"], |line| {
            lines += 1;
            let Some(p) = parse_line(line) else { return };
            if seen.contains(&p.id) {
                return;
            }
            match candidates.get(&p.id) {
                Some(existing) => {
                    let prefer = (p.stop_reason.is_some() && existing.stop_reason.is_none())
                        || (p.output > existing.output && existing.stop_reason.is_none());
                    if prefer {
                        candidates.insert(p.id.clone(), p);
                    }
                }
                None => {
                    order.push(p.id.clone());
                    candidates.insert(p.id.clone(), p);
                }
            }
        });
        let Some(new_offset) = new_offset else {
            new_state.insert(k, state);
            continue;
        };
        lines_parsed += lines;
        for id in order {
            let Some(p) = candidates.remove(&id) else { continue };
            seen.insert(id.clone());
            seen_order.push(id);
            entries.push(UsageEntry {
                app: UsageApp::Claude,
                cost_usd: pricing::cost(&p.model, p.input, p.output, p.cache_read, p.cache_creation, None),
                model: pricing::normalize(&p.model),
                day: p.day,
                input_tokens: p.input,
                output_tokens: p.output,
                cache_read_tokens: p.cache_read,
                cache_creation_tokens: p.cache_creation,
            });
        }
        state.mtime = mtime;
        state.offset = new_offset;
        new_state.insert(k, state);
    }
    let alive: HashSet<String> = files.iter().map(|p| key(p)).collect();
    new_state.retain(|k, _| alive.contains(k));
    if seen_order.len() > SEEN_LIMIT {
        seen_order.drain(..seen_order.len() - SEEN_LIMIT);
    }
    ClaudeScan { result: ScanResult { entries, new_state, files_scanned: files.len(), lines_parsed }, seen: seen_order }
}

fn parse_line(line: &[u8]) -> Option<Parsed> {
    let root: Value = serde_json::from_slice(line).ok()?;
    if root.get("type")?.as_str()? != "assistant" {
        return None;
    }
    let message = root.get("message")?;
    let id = message.get("id")?.as_str()?.to_string();
    let usage = message.get("usage")?;
    let int = |k: &str| usage.get(k).and_then(Value::as_i64).unwrap_or(0).max(0);
    let output = int("output_tokens");
    if output == 0 {
        return None;
    }
    let day = root
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(jsonl::local_day)
        .unwrap_or_else(|| chrono::Local::now().date_naive());
    Some(Parsed {
        id,
        model: message.get("model").and_then(Value::as_str).unwrap_or("unknown").to_string(),
        day,
        input: int("input_tokens"),
        output,
        cache_read: int("cache_read_input_tokens"),
        cache_creation: int("cache_creation_input_tokens"),
        stop_reason: message.get("stop_reason").and_then(Value::as_str).map(str::to_string),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn dedupes_across_files() {
        let dir = tempfile::tempdir().unwrap();
        let projects = dir.path().join("projects").join("p");
        std::fs::create_dir_all(&projects).unwrap();
        let line = r#"{"type":"assistant","timestamp":"2026-10-20T08:00:00Z","message":{"id":"m1","model":"claude-opus-4-1-20250805","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100}}}"#;
        for name in ["a.jsonl", "b.jsonl"] {
            let mut f = std::fs::File::create(projects.join(name)).unwrap();
            writeln!(f, "{line}").unwrap();
        }
        let r = scan(&HashMap::new(), &[], &[dir.path().join("projects")]);
        assert_eq!(r.result.entries.len(), 1);
        assert_eq!(r.result.entries[0].model, "claude-opus-4-1");
        assert_eq!(r.seen, vec!["m1"]);
    }
}
