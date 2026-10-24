//! Grok 会话日志：`~/.grok/sessions/**/updates.jsonl`，只读 `_x.ai/session/update` → `turn_completed` 的
//! `usage.modelUsage`（对应 Mac `GrokJSONLScanner`）。以 prompt_id 跨文件去重；输入扣掉缓存读写；
//! `costUsdTicks` 按 10^10 ticks/USD 换算。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use serde_json::Value;

use super::jsonl::{self, key};
use super::models::{ScanFileState, ScanResult, UsageEntry};
use crate::UsageApp;

pub fn scan(previous: &HashMap<String, ScanFileState>, roots: &[PathBuf]) -> ScanResult {
    let files: Vec<PathBuf> = roots
        .iter()
        .flat_map(|r| jsonl::files(r, false))
        .filter(|p| p.file_name().is_some_and(|n| n == "updates.jsonl"))
        .collect();
    let mut states = HashMap::new();
    let mut entries = Vec::new();
    let mut lines_parsed = 0;
    let mut all_seen: HashSet<String> = previous.values().flat_map(|s| s.seen_turn_ids.clone().unwrap_or_default()).collect();

    for path in &files {
        let k = key(path);
        let (mtime, size) = jsonl::signature(path);
        let mut state = previous.get(&k).cloned().unwrap_or_default();
        if state.mtime == mtime && state.offset == size {
            states.insert(k, state);
            continue;
        }
        // 截断时保留 prompt id，重放的轮次不会算两次。
        if state.offset > size {
            state.offset = 0;
        }
        let mut file_entries = Vec::new();
        let mut file_seen: HashSet<String> = HashSet::new();
        let mut lines = 0;
        let new_offset = jsonl::scan(path, state.offset, &["turn_completed"], |line| {
            lines += 1;
            let Ok(event) = serde_json::from_slice::<Value>(line) else { return };
            if event.get("method").and_then(Value::as_str) != Some("_x.ai/session/update") {
                return;
            }
            let Some(update) = event.get("params").and_then(|p| p.get("update")) else { return };
            if update.get("sessionUpdate").and_then(Value::as_str) != Some("turn_completed") {
                return;
            }
            let (Some(usage), Some(ts), Some(prompt)) = (
                update.get("usage"),
                event.get("timestamp").and_then(Value::as_f64),
                update.get("prompt_id").and_then(Value::as_str),
            ) else {
                return;
            };
            if all_seen.contains(prompt) || file_seen.contains(prompt) {
                return;
            }
            let Some(day) = jsonl::local_day_from_secs(ts) else { return };
            let models = usage.get("modelUsage").and_then(Value::as_object).filter(|m| !m.is_empty());
            let breakdown: Vec<(String, &Value)> = match models {
                Some(m) => m.iter().map(|(k, v)| (k.clone(), v)).collect(),
                None => vec![("grok-unknown".to_string(), usage)],
            };
            for (model, v) in breakdown {
                let int = |k: &str| v.get(k).and_then(Value::as_i64).unwrap_or(0).max(0);
                let input = int("inputTokens");
                let cached = int("cachedReadTokens").min(input);
                let creation = int("cacheCreationTokens").min(input - cached);
                let output = int("outputTokens");
                if input + output <= 0 {
                    continue;
                }
                let ticks = v.get("costUsdTicks").and_then(Value::as_i64).unwrap_or(0);
                file_entries.push(UsageEntry {
                    app: UsageApp::Grok,
                    model,
                    day,
                    input_tokens: input - cached - creation,
                    output_tokens: output,
                    cache_read_tokens: cached,
                    cache_creation_tokens: creation,
                    cost_usd: ticks as f64 / 10_000_000_000.0,
                });
            }
            file_seen.insert(prompt.to_string());
        });
        let Some(new_offset) = new_offset else {
            states.insert(k, state);
            continue;
        };
        entries.extend(file_entries);
        lines_parsed += lines;
        let mut seen: Vec<String> = state.seen_turn_ids.take().unwrap_or_default();
        seen.extend(file_seen.iter().cloned());
        seen.sort();
        seen.dedup();
        all_seen.extend(file_seen);
        state.mtime = mtime;
        state.offset = new_offset;
        state.seen_turn_ids = Some(seen);
        states.insert(k, state);
    }
    ScanResult { entries, new_state: states, files_scanned: files.len(), lines_parsed }
}
