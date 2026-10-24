//! 从指定字节偏移开始流式按行读取 JSONL（对应 Mac `JSONLLineReader`）。
//! 一块可复用的缓冲（1 MB 起，单行超长时才扩大）循环读，内存与文件大小无关；
//! 只有含关键词的完整行才交给回调解析（日志里绝大多数字节是对话正文和工具输出，先按字节筛掉）。
//! 末尾没有换行的残行不消费，新偏移停在最后一个换行之后，等下次写完整再读。

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use chrono::{Local, NaiveDate};
use memchr::memmem::Finder;

const CHUNK: usize = 1 << 20;

/// 读 `path` 中 `offset` 之后的完整行。返回新偏移；打不开 / 读失败返回 None（调用方应丢弃本文件这次的结果）。
pub fn scan(path: &Path, offset: u64, keywords: &[&str], body: impl FnMut(&[u8])) -> Option<u64> {
    let mut file = File::open(path).ok()?;
    let end = file.metadata().ok()?.len();
    if offset >= end {
        return Some(end.max(offset.min(end)));
    }
    file.seek(SeekFrom::Start(offset)).ok()?;
    let (consumed, _) = read_lines(&mut file, 0, keywords, body)?;
    Some(offset + consumed)
}

/// 流式解压 `.jsonl.zst` 并按行读取 `offset`（解压后的偏移）之后的内容。返回 (新偏移, 解压后总长度)。
pub fn scan_zstd(path: &Path, offset: u64, keywords: &[&str], body: impl FnMut(&[u8])) -> Option<(u64, u64)> {
    let file = std::io::BufReader::new(File::open(path).ok()?);
    let mut decoder = ruzstd::StreamingDecoder::new(file).ok()?;
    read_lines(&mut decoder, offset, keywords, body)
}

/// 读到结尾。前 `skip` 字节丢弃，之后按 `\n` 切行，含关键词的行交给 `body`。
/// 返回最后一个换行之后在流中的位置（没有新行时为 `skip`）和流的总长度。
fn read_lines(reader: &mut impl Read, skip: u64, keywords: &[&str], mut body: impl FnMut(&[u8])) -> Option<(u64, u64)> {
    let finders: Vec<Finder> = keywords.iter().map(|k| Finder::new(k.as_bytes())).collect();
    let mut buf = vec![0u8; CHUNK];
    let mut filled = 0usize;
    let mut total: u64 = 0;
    let mut end = skip;
    loop {
        if filled == buf.len() {
            buf.resize(buf.len() * 2, 0);
        }
        let n = match reader.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        };
        let read_start = total;
        total += n as u64;
        if total <= skip {
            continue;
        }
        if read_start < skip {
            let drop = (skip - read_start) as usize;
            buf.copy_within(drop..n, 0);
            filled = n - drop;
        } else {
            filled += n;
        }
        let mut line_start = 0usize;
        while let Some(pos) = memchr::memchr(b'\n', &buf[line_start..filled]) {
            let line = &buf[line_start..line_start + pos];
            if !line.is_empty() && (finders.is_empty() || finders.iter().any(|f| f.find(line).is_some())) {
                body(line);
            }
            line_start += pos + 1;
        }
        if line_start > 0 {
            end += line_start as u64;
            buf.copy_within(line_start..filled, 0);
            filled -= line_start;
        }
    }
    Some((end, total))
}

/// 递归列出目录下的 `.jsonl`（`include_zstd` 时也包括 `.jsonl.zst`）。跳过点开头的隐藏项（和 Mac 的枚举一致）。
pub fn files(root: &Path, include_zstd: bool) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with('.') {
                continue;
            }
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path();
            if kind.is_dir() {
                stack.push(path);
            } else {
                let lower = name.to_lowercase();
                if lower.ends_with(".jsonl") || (include_zstd && lower.ends_with(".jsonl.zst")) {
                    out.push(path);
                }
            }
        }
    }
    out.sort();
    out
}

/// 文件的 (修改时间, 大小)。
pub fn signature(path: &Path) -> (f64, u64) {
    let Ok(meta) = std::fs::metadata(path) else { return (0.0, 0) };
    let mtime = meta
        .modified()
        .ok()
        .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    (mtime, meta.len())
}

/// 日志里的 ISO 8601 时间戳 → 本地日期。
pub fn local_day(timestamp: &str) -> Option<NaiveDate> {
    chrono::DateTime::parse_from_rfc3339(timestamp.trim()).ok().map(|d| d.with_timezone(&Local).date_naive())
}

/// Unix 秒 → 本地日期。
pub fn local_day_from_secs(secs: f64) -> Option<NaiveDate> {
    chrono::DateTime::from_timestamp(secs.floor() as i64, 0).map(|d| d.with_timezone(&Local).date_naive())
}

/// 路径转成扫描状态的键。
pub fn key(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn keeps_partial_line() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("a.jsonl");
        let mut f = File::create(&p).unwrap();
        f.write_all(b"{\"hit\":1}\n{\"miss\":2}\n{\"hit\":3").unwrap();
        let mut lines = Vec::new();
        let off = scan(&p, 0, &["hit"], |l| lines.push(String::from_utf8_lossy(l).into_owned())).unwrap();
        assert_eq!(lines, vec!["{\"hit\":1}"]);
        assert_eq!(off, 21);
        f.write_all(b"}\n").unwrap();
        let mut lines = Vec::new();
        let off2 = scan(&p, off, &["hit"], |l| lines.push(String::from_utf8_lossy(l).into_owned())).unwrap();
        assert_eq!(lines, vec!["{\"hit\":3}"]);
        assert_eq!(off2, 31);
    }
}
