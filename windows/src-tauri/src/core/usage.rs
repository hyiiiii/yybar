//! 扫本地 JSONL 日志算 token 和花费，规则和 Mac 版三个 `*JSONLScanner.swift` 一致：
//! - Claude：`~/.claude/projects/**/*.jsonl` 的 assistant 行，同一 message.id 全局只计一次；
//! - Codex：`~/.codex/{sessions,archived_sessions}/**/*.jsonl` 的 token_count 事件，用累计值做差去重；
//! - Grok：`~/.grok/sessions/**/updates.jsonl` 的 turn_completed，按 prompt_id 去重。
//!
//! 增量：每个文件记字节偏移，只读新增的完整行；进度持久化在本地缓存目录。

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use chrono::{DateTime, Datelike, Local, NaiveDate, TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::model::{App, AppUsage, DailyPoint, PeriodSummary, UsageSummary, UsageTotals};
use super::paths::{self, HomeRoot};
use super::pricing;

const STATE_VERSION: u32 = 1;
const SEEN_CAP: usize = 40_000;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct FileState {
    mtime: u64,
    size: u64,
    offset: u64,
    /// Codex：当前模型（turn_context 给出）
    last_model: Option<String>,
    /// Codex：上一条 total_token_usage（input, cached, cache_write, output）
    last_total: Option<[u64; 4]>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Scanner {
    version: u32,
    pricing_fingerprint: u64,
    files: HashMap<String, FileState>,
    /// Claude message.id / Grok prompt_id，跨文件去重；按插入顺序截断
    seen: VecDeque<String>,
    #[serde(skip)]
    seen_set: HashSet<String>,
    /// 日期 → [codex, claude, grok]
    buckets: BTreeMap<NaiveDate, [UsageTotals; 3]>,
    #[serde(skip)]
    pub files_scanned: usize,
}

fn app_index(app: App) -> usize {
    match app {
        App::Codex => 0,
        App::Claude => 1,
        App::Grok => 2,
    }
}

fn pricing_fingerprint() -> u64 {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for (k, p) in pricing::TABLE {
        k.hash(&mut h);
        for v in [p.input, p.output, p.cache_read, p.cache_creation] {
            v.to_bits().hash(&mut h);
        }
    }
    h.finish()
}

fn state_path() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join("yybar")
        .join("scan-state.json")
}

impl Scanner {
    /// 读上次的进度；版本或价格表变了就从头扫。
    pub fn load() -> Scanner {
        let fresh = Scanner { version: STATE_VERSION, pricing_fingerprint: pricing_fingerprint(), ..Default::default() };
        let Ok(data) = std::fs::read(state_path()) else { return fresh };
        match serde_json::from_slice::<Scanner>(&data) {
            Ok(mut s) if s.version == STATE_VERSION && s.pricing_fingerprint == fresh.pricing_fingerprint => {
                s.seen_set = s.seen.iter().cloned().collect();
                s
            }
            _ => fresh,
        }
    }

    pub fn save(&self) {
        let path = state_path();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(data) = serde_json::to_vec(self) {
            let tmp = path.with_extension("json.tmp");
            if std::fs::write(&tmp, data).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }

    fn mark_seen(&mut self, id: String) {
        if self.seen_set.insert(id.clone()) {
            self.seen.push_back(id);
            while self.seen.len() > SEEN_CAP {
                if let Some(old) = self.seen.pop_front() {
                    self.seen_set.remove(&old);
                }
            }
        }
    }

    fn add(&mut self, app: App, ts: DateTime<Local>, totals: UsageTotals) {
        let day = ts.date_naive();
        self.buckets.entry(day).or_default()[app_index(app)].add(&totals);
    }

    pub fn scan(&mut self, roots: &[HomeRoot]) {
        let mut jobs: Vec<(App, PathBuf, String)> = Vec::new();
        let mut claude_roots: Vec<PathBuf> = Vec::new();
        let mut codex_roots: Vec<PathBuf> = Vec::new();
        let mut grok_roots: Vec<PathBuf> = Vec::new();
        for root in roots {
            if root.wsl_distro.is_none() {
                claude_roots.push(paths::claude_dir().join("projects"));
                let codex = paths::codex_dir();
                codex_roots.push(codex.join("sessions"));
                codex_roots.push(codex.join("archived_sessions"));
                grok_roots.push(paths::grok_dir().join("sessions"));
            } else {
                claude_roots.push(root.path.join(".claude").join("projects"));
                codex_roots.push(root.path.join(".codex").join("sessions"));
                codex_roots.push(root.path.join(".codex").join("archived_sessions"));
                grok_roots.push(root.path.join(".grok").join("sessions"));
            }
            claude_roots.push(root.path.join(".config").join("claude").join("projects"));
        }
        claude_roots.dedup();
        for dir in &claude_roots {
            for f in jsonl_files(dir) {
                let key = format!("claude:{}", f.display());
                jobs.push((App::Claude, f, key));
            }
        }
        for dir in &codex_roots {
            for f in jsonl_files(dir) {
                // 会话从 sessions 挪到 archived_sessions 时文件名不变，按文件名记进度防重复计数
                let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                jobs.push((App::Codex, f, format!("codex:{name}")));
            }
        }
        for dir in &grok_roots {
            for f in jsonl_files(dir).into_iter().filter(|f| f.file_name().is_some_and(|n| n == "updates.jsonl")) {
                let key = format!("grok:{}", f.display());
                jobs.push((App::Grok, f, key));
            }
        }
        self.files_scanned = jobs.len();
        for (app, path, key) in jobs {
            self.scan_file(app, &path, &key);
        }
    }

    fn scan_file(&mut self, app: App, path: &Path, key: &str) {
        let Ok(meta) = std::fs::metadata(path) else { return };
        let size = meta.len();
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let mut state = self.files.get(key).cloned().unwrap_or_default();
        if state.mtime == mtime && state.offset == size {
            return;
        }
        if state.offset > size {
            // 文件被截断：从头再读，全局去重兜底
            state = FileState::default();
        }
        let keywords: &[&str] = match app {
            App::Claude => &["output_tokens"],
            App::Codex => &["turn_context", "token_count"],
            App::Grok => &["turn_completed"],
        };
        let mut claude_candidates: HashMap<String, ClaudeLine> = HashMap::new();
        let mut entries: Vec<(DateTime<Local>, UsageTotals)> = Vec::new();
        let mut grok_ids: Vec<String> = Vec::new();
        let new_offset = read_lines(path, state.offset, keywords, |line| match app {
            App::Claude => {
                if let Some(p) = parse_claude_line(line) {
                    if self.seen_set.contains(&p.id) {
                        return;
                    }
                    let replace = match claude_candidates.get(&p.id) {
                        None => true,
                        Some(old) => old.stop_reason.is_none() && (p.stop_reason.is_some() || p.totals.output_tokens > old.totals.output_tokens),
                    };
                    if replace {
                        claude_candidates.insert(p.id.clone(), p);
                    }
                }
            }
            App::Codex => {
                if let Some(e) = parse_codex_line(line, &mut state) {
                    entries.push(e);
                }
            }
            App::Grok => {
                for (id, ts, totals) in parse_grok_line(line) {
                    if self.seen_set.contains(&id) || grok_ids.contains(&id) {
                        continue;
                    }
                    entries.push((ts, totals));
                    if !grok_ids.contains(&id) {
                        grok_ids.push(id);
                    }
                }
            }
        });
        let Some(new_offset) = new_offset else { return };
        for (id, p) in claude_candidates {
            self.mark_seen(id);
            entries.push((p.ts, p.totals));
        }
        for id in grok_ids {
            self.mark_seen(id);
        }
        for (ts, totals) in entries {
            self.add(app, ts, totals);
        }
        state.mtime = mtime;
        state.size = size;
        state.offset = new_offset;
        self.files.insert(key.to_string(), state);
    }

    pub fn summary(&self, today: NaiveDate) -> UsageSummary {
        let week_start = today - chrono::Duration::days(today.weekday().num_days_from_monday() as i64);
        let month_start = today.with_day(1).unwrap_or(today);
        let mut per_app: Vec<AppUsage> = App::ALL.iter().map(|a| AppUsage { app: Some(*a), ..Default::default() }).collect();
        let mut summary = UsageSummary::default();
        let add = |p: &mut PeriodSummary, t: &UsageTotals| {
            p.cost_usd += t.cost_usd;
            p.tokens += t.total_tokens();
        };
        for (day, totals) in self.buckets.range(month_start.min(week_start)..=today) {
            for (i, t) in totals.iter().enumerate() {
                if *day == today {
                    add(&mut per_app[i].today, t);
                    add(&mut summary.today, t);
                }
                if *day >= week_start {
                    add(&mut per_app[i].week, t);
                    add(&mut summary.week, t);
                }
                if *day >= month_start {
                    add(&mut per_app[i].month, t);
                    add(&mut summary.month, t);
                }
            }
        }
        summary.per_app = per_app;
        summary.daily = (0..30)
            .rev()
            .map(|back| {
                let day = today - chrono::Duration::days(back);
                let t = self.buckets.get(&day).copied().unwrap_or_default();
                DailyPoint { day: day.format("%Y-%m-%d").to_string(), codex: t[0].cost_usd, claude: t[1].cost_usd, grok: t[2].cost_usd }
            })
            .collect();
        summary.files_scanned = self.files_scanned;
        summary
    }
}

fn jsonl_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else { continue };
        for e in entries.flatten() {
            let Ok(ft) = e.file_type() else { continue };
            let p = e.path();
            if ft.is_dir() {
                stack.push(p);
            } else if ft.is_file() && p.extension().is_some_and(|x| x.eq_ignore_ascii_case("jsonl")) {
                out.push(p);
            }
        }
    }
    out
}

/// 从 offset 读到最后一个完整行；只把含关键字的行交给 handle。返回新偏移。
fn read_lines(path: &Path, offset: u64, keywords: &[&str], mut handle: impl FnMut(&[u8])) -> Option<u64> {
    let mut file = File::open(path).ok()?;
    file.seek(SeekFrom::Start(offset)).ok()?;
    let finders: Vec<memchr::memmem::Finder> = keywords.iter().map(|k| memchr::memmem::Finder::new(k.as_bytes())).collect();
    let mut reader = BufReader::with_capacity(256 * 1024, file);
    let mut pos = offset;
    let mut buf = Vec::with_capacity(64 * 1024);
    loop {
        buf.clear();
        let n = reader.read_until(b'\n', &mut buf).ok()?;
        if n == 0 || buf.last() != Some(&b'\n') {
            // 末尾半行（CLI 还在写）留到下次
            break;
        }
        pos += n as u64;
        if finders.iter().any(|f| f.find(&buf).is_some()) {
            handle(&buf);
        }
    }
    Some(pos)
}

fn u(v: Option<&Value>) -> u64 {
    v.and_then(Value::as_i64).map(|n| n.max(0) as u64).unwrap_or(0)
}

fn parse_ts(v: Option<&Value>) -> Option<DateTime<Local>> {
    let s = v?.as_str()?;
    DateTime::parse_from_rfc3339(s).ok().map(|d| d.with_timezone(&Local))
}

struct ClaudeLine {
    id: String,
    ts: DateTime<Local>,
    stop_reason: Option<String>,
    totals: UsageTotals,
}

fn parse_claude_line(line: &[u8]) -> Option<ClaudeLine> {
    let root: Value = serde_json::from_slice(line).ok()?;
    if root.get("type")?.as_str()? != "assistant" {
        return None;
    }
    let message = root.get("message")?;
    let id = message.get("id")?.as_str()?.to_string();
    let usage = message.get("usage")?;
    let output = u(usage.get("output_tokens"));
    if output == 0 {
        return None;
    }
    let input = u(usage.get("input_tokens"));
    let cache_read = u(usage.get("cache_read_input_tokens"));
    let cache_creation = u(usage.get("cache_creation_input_tokens"));
    let model = message.get("model").and_then(Value::as_str).unwrap_or("unknown");
    Some(ClaudeLine {
        id,
        ts: parse_ts(root.get("timestamp")).unwrap_or_else(Local::now),
        stop_reason: message.get("stop_reason").and_then(Value::as_str).map(str::to_string),
        totals: UsageTotals {
            input_tokens: input,
            output_tokens: output,
            cache_read_tokens: cache_read,
            cache_creation_tokens: cache_creation,
            cost_usd: pricing::cost(model, input, output, cache_read, cache_creation, None),
        },
    })
}

/// Codex 的 input_tokens 含缓存读取，计费时扣掉。
fn parse_codex_line(line: &[u8], state: &mut FileState) -> Option<(DateTime<Local>, UsageTotals)> {
    let root: Value = serde_json::from_slice(line).ok()?;
    let kind = root.get("type").and_then(Value::as_str);
    let payload = root.get("payload")?;
    if kind == Some("turn_context") {
        if let Some(m) = payload.get("model").and_then(Value::as_str) {
            state.last_model = Some(m.to_string());
        }
        return None;
    }
    if kind != Some("event_msg") || payload.get("type").and_then(Value::as_str) != Some("token_count") {
        return None;
    }
    let info = payload.get("info")?;
    let last = info.get("last_token_usage")?;
    let fields = |v: &Value| -> [u64; 4] {
        [u(v.get("input_tokens")), u(v.get("cached_input_tokens")), u(v.get("cache_write_input_tokens")), u(v.get("output_tokens"))]
    };
    let mut usage = fields(last);
    if let Some(total) = info.get("total_token_usage").map(fields) {
        if let Some(prior) = state.last_total {
            if total == prior {
                return None;
            }
            if total.iter().zip(prior.iter()).all(|(t, p)| t >= p) {
                usage = [total[0] - prior[0], total[1] - prior[1], total[2] - prior[2], total[3] - prior[3]];
            }
        }
        state.last_total = Some(total);
    }
    let input_total = usage[0];
    let cached = usage[1].min(input_total);
    let cache_write = usage[2].min(input_total - cached);
    let output = usage[3];
    let billable = input_total - cached - cache_write;
    if output == 0 && billable == 0 && cached == 0 && cache_write == 0 {
        return None;
    }
    let ts = parse_ts(root.get("timestamp"))?;
    let model = state.last_model.clone().unwrap_or_else(|| "unknown".into());
    let request_input = last.get("input_tokens").and_then(Value::as_u64);
    Some((
        ts,
        UsageTotals {
            input_tokens: billable,
            output_tokens: output,
            cache_read_tokens: cached,
            cache_creation_tokens: cache_write,
            cost_usd: pricing::cost(&model, billable, output, cached, cache_write, request_input),
        },
    ))
}

/// Grok 的花费直接用日志里的 costUsdTicks（10^10 ticks = $1）。
fn parse_grok_line(line: &[u8]) -> Vec<(String, DateTime<Local>, UsageTotals)> {
    let mut out = Vec::new();
    let Ok(event) = serde_json::from_slice::<Value>(line) else { return out };
    if event.get("method").and_then(Value::as_str) != Some("_x.ai/session/update") {
        return out;
    }
    let Some(update) = event.get("params").and_then(|p| p.get("update")) else { return out };
    if update.get("sessionUpdate").and_then(Value::as_str) != Some("turn_completed") {
        return out;
    }
    let (Some(usage), Some(prompt), Some(ts)) = (
        update.get("usage"),
        update.get("prompt_id").and_then(Value::as_str),
        event.get("timestamp").and_then(Value::as_f64),
    ) else {
        return out;
    };
    let Some(ts) = Local.timestamp_opt(ts as i64, 0).single() else { return out };
    let breakdown: Vec<&Value> = match usage.get("modelUsage").and_then(Value::as_object) {
        Some(m) if !m.is_empty() => m.values().collect(),
        _ => vec![usage],
    };
    let mut totals = UsageTotals::default();
    for v in breakdown {
        let input = u(v.get("inputTokens"));
        let cached = u(v.get("cachedReadTokens")).min(input);
        let creation = u(v.get("cacheCreationTokens")).min(input - cached);
        let output = u(v.get("outputTokens"));
        if input + output == 0 {
            continue;
        }
        totals.add(&UsageTotals {
            input_tokens: input - cached - creation,
            output_tokens: output,
            cache_read_tokens: cached,
            cache_creation_tokens: creation,
            cost_usd: u(v.get("costUsdTicks")) as f64 / 10_000_000_000.0,
        });
    }
    if totals.total_tokens() > 0 {
        out.push((prompt.to_string(), ts, totals));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("yybar-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn claude_dedupes_and_is_incremental() {
        let dir = temp_dir("claude");
        let file = dir.join("a.jsonl");
        let line = |id: &str, out: u64, stop: &str| {
            format!(r#"{{"type":"assistant","timestamp":"2026-10-19T03:00:00Z","message":{{"id":"{id}","model":"claude-sonnet-4-5-20250929","stop_reason":{stop},"usage":{{"input_tokens":1000000,"output_tokens":{out}}}}}}}"#)
        };
        let mut f = File::create(&file).unwrap();
        writeln!(f, "{}", line("m1", 10, "null")).unwrap();
        writeln!(f, "{}", line("m1", 20, "\"end_turn\"")).unwrap();
        drop(f);
        let mut s = Scanner::default();
        s.scan_file(App::Claude, &file, "k");
        let day = parse_ts(Some(&Value::String("2026-10-19T03:00:00Z".into()))).unwrap().date_naive();
        let t = s.buckets[&day][1];
        assert_eq!(t.output_tokens, 20);
        assert!((t.cost_usd - (3.0 + 20.0 * 15.0 / 1e6)).abs() < 1e-9);

        // 追加：重复的 m1 不再计，m2 计一次；半行不读
        let mut f = std::fs::OpenOptions::new().append(true).open(&file).unwrap();
        writeln!(f, "{}", line("m1", 30, "\"end_turn\"")).unwrap();
        writeln!(f, "{}", line("m2", 5, "\"end_turn\"")).unwrap();
        write!(f, "{{\"type\":\"assistant\"").unwrap();
        drop(f);
        s.scan_file(App::Claude, &file, "k");
        assert_eq!(s.buckets[&day][1].output_tokens, 25);
    }

    #[test]
    fn codex_uses_total_deltas() {
        let mut st = FileState::default();
        let ctx = br#"{"type":"turn_context","payload":{"model":"gpt-5"}}"#;
        assert!(parse_codex_line(ctx, &mut st).is_none());
        let ev = |total_in: u64, total_out: u64| {
            format!(r#"{{"type":"event_msg","timestamp":"2026-10-19T03:00:00Z","payload":{{"type":"token_count","info":{{"last_token_usage":{{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}},"total_token_usage":{{"input_tokens":{total_in},"cached_input_tokens":0,"output_tokens":{total_out}}}}}}}}}"#)
        };
        let (_, a) = parse_codex_line(ev(100, 10).as_bytes(), &mut st).unwrap();
        assert_eq!(a.input_tokens, 100);
        // 同一累计值重复通知：忽略
        assert!(parse_codex_line(ev(100, 10).as_bytes(), &mut st).is_none());
        let (_, b) = parse_codex_line(ev(250, 30).as_bytes(), &mut st).unwrap();
        assert_eq!((b.input_tokens, b.output_tokens), (150, 20));
    }

    #[test]
    fn grok_turn_completed() {
        let line = br#"{"method":"_x.ai/session/update","timestamp":1760850000,"params":{"update":{"sessionUpdate":"turn_completed","prompt_id":"p1","usage":{"modelUsage":{"grok-4":{"inputTokens":100,"cachedReadTokens":40,"outputTokens":10,"costUsdTicks":126890500}}}}}}"#;
        let v = parse_grok_line(line);
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].2.input_tokens, 60);
        assert!((v[0].2.cost_usd - 0.01268905).abs() < 1e-12);
    }
}
