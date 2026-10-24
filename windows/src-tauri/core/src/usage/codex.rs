//! Codex 会话日志：`~/.codex/sessions/**/*.jsonl` + `archived_sessions`，以及压缩后的旧会话 `*.jsonl.zst`
//! （对应 Mac `CodexJSONLScanner`；Windows 版用内置的纯 Rust zstd 解码，不需要另装 zstd 命令）。
//! - `turn_context` 的 `payload.model` 给后续 token_count 打标签；
//! - `event_msg` / `token_count` 的 `info.last_token_usage` 是这次调用的 token；用 `total_token_usage` 的增量去掉重复通知，
//!   累计值重置时退回 last_token_usage；
//! - Codex 的 `input_tokens` 含 cache_read，计费时扣掉。
//! 压缩内容与原 `.jsonl` 逐字节相同：`.zst` 没有自己的进度时沿用原文件的进度（偏移按解压后计），不会重复计数。

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::jsonl::{self, key};
use super::models::{ScanFileState, ScanResult, UsageEntry};
use super::pricing;
use crate::UsageApp;

const KEYWORDS: &[&str] = &["turn_context", "token_count"];
const USAGE_KEYS: [&str; 4] = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"];

pub fn scan(previous: &HashMap<String, ScanFileState>, roots: &[PathBuf]) -> ScanResult {
    let files: Vec<PathBuf> = roots.iter().flat_map(|r| jsonl::files(r, true)).collect();
    let mut new_state = previous.clone();
    let mut entries = Vec::new();
    let mut lines_parsed = 0;

    let base_name = |p: &str| -> String {
        let name = Path::new(p).file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
        name.strip_suffix(".zst").map(str::to_string).unwrap_or(name)
    };

    for path in &files {
        let k = key(path);
        let (mtime, size) = jsonl::signature(path);
        let is_zstd = k.to_lowercase().ends_with(".jsonl.zst");
        let own = previous.get(&k);
        // 同名文件（移到 archived_sessions、或被压缩成 .zst）沿用原来的进度。
        let mut state = own
            .cloned()
            .or_else(|| if is_zstd { previous.get(&k[..k.len() - 4]).cloned() } else { None })
            .or_else(|| {
                let b = base_name(&k);
                previous.iter().find(|(pk, _)| base_name(pk) == b).map(|(_, v)| v.clone())
            })
            .unwrap_or_default();

        if is_zstd {
            if own.is_some() && state.mtime == mtime {
                new_state.insert(k, state);
                continue;
            }
        } else {
            if state.mtime == mtime && state.offset == size {
                new_state.insert(k, state);
                continue;
            }
            if state.offset > size {
                state.offset = 0;
                state.last_model = None;
                state.last_total_usage = None;
            }
        }

        let mut parser = FileParser { model: state.last_model.clone(), last_total: state.last_total_usage.clone(), entries: Vec::new(), lines: 0 };
        let new_offset = if is_zstd {
            let Some(mut result) = jsonl::scan_zstd(path, state.offset, KEYWORDS, |l| parser.handle(l)) else {
                // 解压失败：保留（可能继承来的）进度，mtime 记 0 以便下次重试。
                state.mtime = 0.0;
                new_state.insert(k, state);
                continue;
            };
            if result.1 < state.offset {
                // 继承来的偏移超出解压后的长度（内容对不上）：从头重扫。
                parser = FileParser { model: None, last_total: None, entries: Vec::new(), lines: 0 };
                match jsonl::scan_zstd(path, 0, KEYWORDS, |l| parser.handle(l)) {
                    Some(again) => result = again,
                    None => {
                        state.mtime = 0.0;
                        new_state.insert(k, state);
                        continue;
                    }
                }
            }
            result.0
        } else {
            match jsonl::scan(path, state.offset, KEYWORDS, |l| parser.handle(l)) {
                Some(o) => o,
                None => {
                    new_state.insert(k, state);
                    continue;
                }
            }
        };
        entries.extend(parser.entries);
        lines_parsed += parser.lines;
        state.mtime = mtime;
        state.offset = new_offset;
        state.last_model = parser.model;
        state.last_total_usage = parser.last_total;
        new_state.insert(k, state);
    }

    let alive: std::collections::HashSet<String> = files.iter().map(|p| key(p)).collect();
    new_state.retain(|k, _| alive.contains(k));
    ScanResult { entries, new_state, files_scanned: files.len(), lines_parsed }
}

struct FileParser {
    model: Option<String>,
    last_total: Option<BTreeMap<String, i64>>,
    entries: Vec<UsageEntry>,
    lines: usize,
}

impl FileParser {
    fn handle(&mut self, line: &[u8]) {
        self.lines += 1;
        let Ok(root) = serde_json::from_slice::<Value>(line) else { return };
        let kind = root.get("type").and_then(Value::as_str);
        if kind == Some("turn_context") {
            if let Some(m) = root.get("payload").and_then(|p| p.get("model")).and_then(Value::as_str) {
                self.model = Some(m.to_string());
            }
            return;
        }
        let Some(payload) = root.get("payload") else { return };
        if kind != Some("event_msg") || payload.get("type").and_then(Value::as_str) != Some("token_count") {
            return;
        }
        let Some(info) = payload.get("info").filter(|v| v.is_object()) else { return };
        let Some(last) = info.get("last_token_usage").and_then(Value::as_object) else { return };
        let as_map = |o: &serde_json::Map<String, Value>| -> BTreeMap<String, i64> {
            o.iter().filter_map(|(k, v)| v.as_i64().map(|n| (k.clone(), n))).collect()
        };
        let mut usage = as_map(last);
        if let Some(total) = info.get("total_token_usage").and_then(Value::as_object).map(as_map) {
            if let Some(prior) = &self.last_total {
                if &total == prior {
                    return;
                }
                let get = |m: &BTreeMap<String, i64>, k: &str| m.get(k).copied().unwrap_or(0);
                if USAGE_KEYS.iter().all(|k| get(&total, k) >= get(prior, k)) {
                    usage = USAGE_KEYS.iter().map(|k| (k.to_string(), get(&total, k) - get(prior, k))).collect();
                }
            }
            self.last_total = Some(total);
        }
        let get = |k: &str| usage.get(k).copied().unwrap_or(0).max(0);
        let input_total = get("input_tokens");
        let cached = get("cached_input_tokens").min(input_total);
        let output = get("output_tokens");
        let cache_write = get("cache_write_input_tokens").min(input_total - cached);
        let billable = (input_total - cached - cache_write).max(0);
        if output == 0 && billable == 0 && cached == 0 && cache_write == 0 {
            return;
        }
        let Some(day) = root.get("timestamp").and_then(Value::as_str).and_then(jsonl::local_day) else { return };
        let model = self.model.clone().unwrap_or_else(|| "unknown".into());
        let request_input = last.get("input_tokens").and_then(Value::as_i64);
        self.entries.push(UsageEntry {
            app: UsageApp::Codex,
            cost_usd: pricing::cost(&model, billable, output, cached, cache_write, request_input),
            model: pricing::normalize(&model),
            day,
            input_tokens: billable,
            output_tokens: output,
            cache_read_tokens: cached,
            cache_creation_tokens: cache_write,
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn line(total_in: i64, total_out: i64, last_in: i64, last_out: i64) -> String {
        format!(
            r#"{{"timestamp":"2026-10-20T08:00:00Z","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{total_in},"cached_input_tokens":0,"output_tokens":{total_out}}},"last_token_usage":{{"input_tokens":{last_in},"cached_input_tokens":0,"output_tokens":{last_out}}}}}}}}}"#
        )
    }

    #[test]
    fn dedupes_repeated_notifications() {
        let dir = tempfile::tempdir().unwrap();
        let sessions = dir.path().join("sessions");
        std::fs::create_dir_all(&sessions).unwrap();
        let mut f = std::fs::File::create(sessions.join("rollout-a.jsonl")).unwrap();
        writeln!(f, r#"{{"type":"turn_context","payload":{{"model":"gpt-5.5"}}}}"#).unwrap();
        writeln!(f, "{}", line(100, 10, 100, 10)).unwrap();
        writeln!(f, "{}", line(100, 10, 100, 10)).unwrap();
        writeln!(f, "{}", line(150, 30, 50, 20)).unwrap();
        drop(f);
        let r = scan(&HashMap::new(), &[sessions.clone()]);
        assert_eq!(r.entries.len(), 2);
        assert_eq!(r.entries.iter().map(|e| e.input_tokens).sum::<i64>(), 150);
        assert_eq!(r.entries[0].model, "gpt-5.5");
        // 再扫不重复
        let r2 = scan(&r.new_state, &[sessions]);
        assert!(r2.entries.is_empty());
    }
}
