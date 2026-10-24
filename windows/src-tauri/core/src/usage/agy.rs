//! agy（Antigravity CLI）本机会话库的用量（对应 Mac `AgyConversationScanner`）。
//! 每个会话一个 SQLite 库：`~/.gemini/antigravity-cli/conversations/<uuid>.db`（旧版 `antigravity/conversations`）。
//! 只读两张表里的 protobuf 数字字段和模型名，不解析对话内容：
//! - `steps.metadata`：field 1 = 创建时间（1 = 秒）、field 9 = 用量（2 = 输入，3 = 输出，5 = 缓存读取）、field 11 = 模型枚举；
//! - `gen_metadata.data`：field 1 → 3 = 模型枚举、19 = 模型名。
//! agy 里的所有调用（包括 Gemini 模型）都记到 Antigravity。
//! agy 运行中持有库并写 WAL，所以先把 `.db` / `-wal` 复制到临时目录再打开副本，不锁原库。
//! 用系统自带的 SQLite（Windows 的 winsqlite3.dll）读库，见 `sqlite.rs`。

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use super::jsonl::{self, key};
use super::models::{ScanFileState, ScanResult, UsageEntry};
use super::pricing;
use super::sqlite;
use crate::paths;
use crate::UsageApp;

pub fn default_roots() -> Vec<PathBuf> {
    let gemini = paths::gemini_dir();
    vec![gemini.join("antigravity-cli").join("conversations"), gemini.join("antigravity").join("conversations")]
}

#[derive(Debug, Clone, PartialEq)]
pub struct Call {
    pub id: String,
    pub timestamp: i64,
    pub model: String,
    /// 已扣掉缓存读取
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
}

pub fn scan(previous: &HashMap<String, ScanFileState>, roots: &[PathBuf]) -> ScanResult {
    let files: Vec<PathBuf> = roots
        .iter()
        .flat_map(|r| std::fs::read_dir(r).map(|it| it.flatten().map(|e| e.path()).collect::<Vec<_>>()).unwrap_or_default())
        .filter(|p| p.extension().is_some_and(|e| e == "db"))
        .collect();
    let mut states = HashMap::new();
    let mut entries = Vec::new();
    let mut steps = 0;
    for path in &files {
        let k = key(path);
        let (mtime, size) = signature(path);
        let mut state = previous.get(&k).cloned().unwrap_or_default();
        if state.mtime == mtime && state.offset == size {
            states.insert(k, state);
            continue;
        }
        let Some(calls) = read_calls(path) else {
            // 读失败（正在被重写等）：保留旧进度，下次再试。
            if previous.contains_key(&k) {
                states.insert(k, state);
            }
            continue;
        };
        let mut seen: HashSet<String> = state.seen_turn_ids.take().unwrap_or_default().into_iter().collect();
        for call in &calls {
            if !seen.insert(call.id.clone()) || call.input + call.output + call.cache_read <= 0 {
                continue;
            }
            let Some(day) = jsonl::local_day_from_secs(call.timestamp as f64) else { continue };
            entries.push(UsageEntry {
                app: UsageApp::Agy,
                model: call.model.clone(),
                day,
                input_tokens: call.input,
                output_tokens: call.output,
                cache_read_tokens: call.cache_read,
                cache_creation_tokens: 0,
                cost_usd: pricing::cost(&call.model, call.input, call.output, call.cache_read, 0, None),
            });
        }
        steps += calls.len();
        let mut seen: Vec<String> = seen.into_iter().collect();
        seen.sort();
        state.mtime = mtime;
        state.offset = size;
        state.seen_turn_ids = Some(seen);
        states.insert(k, state);
    }
    ScanResult { entries, new_state: states, files_scanned: files.len(), lines_parsed: steps }
}

/// 库 + WAL 的合并签名（修改时间取较新者，大小相加）。
fn signature(path: &Path) -> (f64, u64) {
    let (m1, s1) = jsonl::signature(path);
    let wal = PathBuf::from(format!("{}-wal", path.to_string_lossy()));
    let (m2, s2) = jsonl::signature(&wal);
    (m1.max(m2), s1 + s2)
}

/// agy 的模型名带变体后缀（`-thinking`、`-n` 等），去掉后才能对上价格表。
pub fn canonical_model(raw: &str) -> String {
    let mut name = raw.to_lowercase();
    for suffix in ["-thinking", "-n", "-high", "-low", "-medium"] {
        if let Some(s) = name.strip_suffix(suffix) {
            name = s.to_string();
        }
    }
    name
}

pub fn read_calls(path: &Path) -> Option<Vec<Call>> {
    let dir = std::env::temp_dir().join(format!("yybar-agy-scan-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).ok()?;
    let copy = dir.join("conversation.db");
    let result = (|| {
        std::fs::copy(path, &copy).ok()?;
        let wal = PathBuf::from(format!("{}-wal", path.to_string_lossy()));
        if wal.is_file() {
            let _ = std::fs::copy(&wal, dir.join("conversation.db-wal"));
        }
        read_calls_from(&copy)
    })();
    let _ = std::fs::remove_dir_all(&dir);
    result
}

/// 直接读一个（已复制出来的）会话库。
pub fn read_calls_from(db: &Path) -> Option<Vec<Call>> {
    let conn = sqlite::Connection::open(db, false)?;
    let mut names: HashMap<u64, String> = HashMap::new();
    conn.for_each_blob("SELECT data FROM gen_metadata", |_, blob| {
        let Some(info) = proto::message(blob, 1) else { return };
        let Some(model) = proto::string(&info, 19).filter(|m| !m.is_empty()) else { return };
        if let Some(e) = proto::varint(&info, 3) {
            names.insert(e, model);
        }
    });
    let mut calls = Vec::new();
    let ok = conn.for_each_blob("SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL", |idx, blob| {
        let (Some(usage), Some(created)) = (proto::message(blob, 9), proto::message(blob, 1)) else { return };
        let Some(seconds) = proto::varint(&created, 1) else { return };
        let prompt = proto::varint(&usage, 2).unwrap_or(0) as i64;
        let cached = (proto::varint(&usage, 5).unwrap_or(0) as i64).min(prompt);
        let output = proto::varint(&usage, 3).unwrap_or(0) as i64;
        let enum_value = proto::varint(blob, 11).or_else(|| proto::varint(&usage, 1));
        let raw = enum_value
            .and_then(|e| names.get(&e).cloned())
            .unwrap_or_else(|| format!("agy-model-{}", enum_value.map(|e| e.to_string()).unwrap_or_else(|| "unknown".into())));
        calls.push(Call {
            id: idx.to_string(),
            timestamp: seconds as i64,
            model: canonical_model(&raw),
            input: prompt - cached,
            output,
            cache_read: cached,
        });
    });
    ok.then_some(calls)
}

/// 极简 protobuf 读取：只按字段号取第一个 varint / 子消息 / 字符串。
pub mod proto {
    fn fields(bytes: &[u8], mut visit: impl FnMut(u64, u64, u64, &[u8]) -> bool) {
        let mut i = 0usize;
        let read_varint = |i: &mut usize| -> Option<u64> {
            let mut result = 0u64;
            let mut shift = 0u32;
            while *i < bytes.len() && shift < 64 {
                let b = bytes[*i];
                *i += 1;
                result |= u64::from(b & 0x7f) << shift;
                if b < 0x80 {
                    return Some(result);
                }
                shift += 7;
            }
            None
        };
        while i < bytes.len() {
            let Some(key) = read_varint(&mut i) else { return };
            let (field, wire) = (key >> 3, key & 7);
            match wire {
                0 => {
                    let Some(v) = read_varint(&mut i) else { return };
                    if !visit(field, wire, v, &[]) {
                        return;
                    }
                }
                1 => i += 8,
                2 => {
                    let Some(len) = read_varint(&mut i) else { return };
                    if len > (bytes.len() - i) as u64 {
                        return;
                    }
                    let slice = &bytes[i..i + len as usize];
                    i += len as usize;
                    if !visit(field, wire, 0, slice) {
                        return;
                    }
                }
                5 => i += 4,
                _ => return,
            }
        }
    }

    pub fn varint(bytes: &[u8], field: u64) -> Option<u64> {
        let mut found = None;
        fields(bytes, |f, w, v, _| {
            if f == field && w == 0 {
                found = Some(v);
                return false;
            }
            true
        });
        found
    }

    pub fn message(bytes: &[u8], field: u64) -> Option<Vec<u8>> {
        let mut found = None;
        fields(bytes, |f, w, _, s| {
            if f == field && w == 2 {
                found = Some(s.to_vec());
                return false;
            }
            true
        });
        found
    }

    pub fn string(bytes: &[u8], field: u64) -> Option<String> {
        message(bytes, field).and_then(|b| String::from_utf8(b).ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn varint(mut v: u64, out: &mut Vec<u8>) {
        loop {
            let b = (v & 0x7f) as u8;
            v >>= 7;
            if v == 0 {
                out.push(b);
                return;
            }
            out.push(b | 0x80);
        }
    }
    fn field_varint(f: u64, v: u64, out: &mut Vec<u8>) {
        varint(f << 3, out);
        varint(v, out);
    }
    fn field_bytes(f: u64, b: &[u8], out: &mut Vec<u8>) {
        varint((f << 3) | 2, out);
        varint(b.len() as u64, out);
        out.extend_from_slice(b);
    }

    #[test]
    fn reads_conversation_db() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("c.db");
        let conn = sqlite::Connection::open(&db, true).unwrap();
        assert!(conn.exec("CREATE TABLE gen_metadata (data BLOB); CREATE TABLE steps (idx INTEGER, metadata BLOB);"));
        let hex = |b: &[u8]| b.iter().map(|x| format!("{x:02x}")).collect::<String>();
        let mut info = Vec::new();
        field_varint(3, 7, &mut info);
        field_bytes(19, b"gemini-3.8-flash-n", &mut info);
        let mut gen = Vec::new();
        field_bytes(1, &info, &mut gen);
        assert!(conn.exec(&format!("INSERT INTO gen_metadata VALUES (x'{}')", hex(&gen))));
        let mut created = Vec::new();
        field_varint(1, 1_792_400_000, &mut created);
        let mut usage = Vec::new();
        field_varint(2, 1000, &mut usage);
        field_varint(3, 200, &mut usage);
        field_varint(5, 300, &mut usage);
        let mut step = Vec::new();
        field_bytes(1, &created, &mut step);
        field_bytes(9, &usage, &mut step);
        field_varint(11, 7, &mut step);
        assert!(conn.exec(&format!("INSERT INTO steps VALUES (1, x'{}')", hex(&step))));
        drop(conn);
        let calls = read_calls_from(&db).unwrap();
        assert_eq!(calls, vec![Call { id: "1".into(), timestamp: 1_792_400_000, model: "gemini-3.8-flash".into(), input: 700, output: 200, cache_read: 300 }]);
    }
}
