//! 扫描 → 聚合 → 持久化（对应 Mac `UsageService`）。
//! 扫描本身（`run_scan`）是纯函数，在后台线程跑；`UsageService` 持有聚合结果，扫描前后各短暂加锁。

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use chrono::NaiveDate;

use super::aggregator::Aggregator;
use super::models::{ScanResult, UsageBucket};
use super::{agy, claude, codex, grok, pricing};
use crate::paths::{self, HomeRoot};
use crate::storage::scan_cache::{ScanState, UsageRollup};
use crate::UsageApp;

/// 全量重建时，日志已不在磁盘上、只剩在汇总里的历史桶要不要按新价格重算费用。
#[derive(Debug, Clone, PartialEq)]
pub enum Reprice {
    None,
    Keys(HashSet<String>),
    All,
}

impl Reprice {
    pub fn merged(self, other: Reprice) -> Reprice {
        match (self, other) {
            (Reprice::All, _) | (_, Reprice::All) => Reprice::All,
            (Reprice::Keys(mut a), Reprice::Keys(b)) => {
                a.extend(b);
                Reprice::Keys(a)
            }
            (Reprice::None, x) | (x, Reprice::None) => x,
        }
    }
}

/// 各服务的日志根目录。
#[derive(Debug, Clone, Default)]
pub struct ScanRoots {
    pub codex: Vec<PathBuf>,
    pub claude: Vec<PathBuf>,
    pub grok: Vec<PathBuf>,
    pub agy: Vec<PathBuf>,
}

impl ScanRoots {
    /// 本机目录，加上（可选）正在运行的 WSL 发行版里的同名目录。
    pub fn build(wsl: &[HomeRoot]) -> ScanRoots {
        let codex_dir = paths::codex_dir();
        let mut roots = ScanRoots {
            codex: vec![codex_dir.join("sessions"), codex_dir.join("archived_sessions")],
            claude: claude::roots(&paths::claude_dir(), true),
            grok: vec![paths::grok_dir().join("sessions")],
            agy: agy::default_roots(),
        };
        for home in wsl {
            let p = &home.path;
            roots.codex.push(p.join(".codex").join("sessions"));
            roots.codex.push(p.join(".codex").join("archived_sessions"));
            roots.claude.extend(claude::roots(&p.join(".claude"), false));
            roots.grok.push(p.join(".grok").join("sessions"));
        }
        roots
    }
}

#[derive(Debug, Default)]
pub struct ScanOutput {
    pub codex: ScanResult,
    pub claude: ScanResult,
    pub claude_seen: Vec<String>,
    pub grok: ScanResult,
    pub agy: ScanResult,
    pub elapsed_ms: u128,
}

/// 扫一遍所有日志（四个服务并行）。
pub fn run_scan(prev: &ScanState, roots: &ScanRoots) -> ScanOutput {
    let started = std::time::Instant::now();
    let (codex, (claude_scan, (grok, agy))) = std::thread::scope(|s| {
        let c = s.spawn(|| codex::scan(&prev.codex, &roots.codex));
        let k = s.spawn(|| claude::scan(&prev.claude, &prev.claude_seen_message_ids, &roots.claude));
        let g = s.spawn(|| grok::scan(&prev.grok, &roots.grok));
        let a = agy::scan(&prev.agy, &roots.agy);
        (c.join().unwrap_or_default(), (k.join().unwrap_or_else(|_| claude::ClaudeScan { result: ScanResult::default(), seen: vec![] }), (g.join().unwrap_or_default(), a)))
    });
    ScanOutput {
        codex,
        claude: claude_scan.result,
        claude_seen: claude_scan.seen,
        grok,
        agy,
        elapsed_ms: started.elapsed().as_millis(),
    }
}

pub struct UsageService {
    aggregator: Aggregator,
    /// 每次数据变化 +1，前端据此判断要不要重新拉取。
    pub version: u64,
    pub last_scan_at: Option<i64>,
    pub scanning: bool,
    pending_rebuild: Option<Reprice>,
}

impl UsageService {
    /// 启动：先把汇总灌进内存。价格表在上次退出后变了：第一次扫描全量重建，保留的历史按新价格重算。
    pub fn bootstrap() -> UsageService {
        let rollup = UsageRollup::load();
        let pending = if !rollup.buckets.is_empty() && rollup.pricing_fingerprint != pricing::fingerprint() {
            Some(Reprice::All)
        } else {
            None
        };
        UsageService {
            aggregator: Aggregator::from_buckets(rollup.buckets),
            version: 1,
            last_scan_at: None,
            scanning: false,
            pending_rebuild: pending,
        }
    }

    pub fn buckets(&self) -> Vec<UsageBucket> {
        self.aggregator.snapshot()
    }

    /// 改了自定义价格后排队一次全量重建。
    pub fn request_rebuild(&mut self, reprice: Reprice) {
        self.pending_rebuild = Some(match self.pending_rebuild.take() {
            Some(p) => p.merged(reprice),
            None => reprice,
        });
    }

    pub fn has_pending_rebuild(&self) -> bool {
        self.pending_rebuild.is_some()
    }

    /// 开始一次扫描：返回扫描进度和是否全量重建。扫描进度丢了但汇总还在时也全量重建（避免在旧汇总上重复叠加）。
    pub fn begin_scan(&mut self) -> (ScanState, Option<Reprice>) {
        self.scanning = true;
        let mut rebuild = self.pending_rebuild.take();
        let prev = if rebuild.is_some() { ScanState::default() } else { ScanState::load(&pricing::fingerprint()) };
        if rebuild.is_none() && prev.is_empty() && !self.aggregator.is_empty() {
            rebuild = Some(Reprice::None);
        }
        (prev, rebuild)
    }

    /// 并入扫描结果并写盘。
    pub fn finish_scan(&mut self, output: ScanOutput, rebuild: Option<Reprice>, now: i64) {
        let all_entries = [&output.claude.entries, &output.codex.entries, &output.grok.entries, &output.agy.entries];
        let changed = rebuild.is_some() || all_entries.iter().any(|e| !e.is_empty());
        match rebuild {
            Some(reprice) => {
                let mut fresh = Aggregator::default();
                for e in all_entries {
                    fresh.ingest(e);
                }
                let merged = merge_preserving_history(self.aggregator.snapshot(), fresh.snapshot(), &reprice);
                self.aggregator.load(merged);
            }
            None => {
                for e in all_entries {
                    self.aggregator.ingest(e);
                }
            }
        }
        let fingerprint = pricing::fingerprint();
        let state = ScanState {
            version: ScanState::VERSION,
            pricing_fingerprint: fingerprint.clone(),
            claude: output.claude.new_state,
            codex: output.codex.new_state,
            grok: output.grok.new_state,
            agy: output.agy.new_state,
            claude_seen_message_ids: output.claude_seen,
        };
        if let Err(e) = state.save() {
            log::warn!("[UsageScan 用量扫描] 扫描状态写盘失败: {e}");
        }
        let rollup = UsageRollup { version: UsageRollup::VERSION, pricing_fingerprint: fingerprint, buckets: self.aggregator.snapshot(), updated_at: now };
        if let Err(e) = rollup.save() {
            log::warn!("[UsageScan 用量扫描] 汇总写盘失败: {e}");
        }
        if changed {
            self.version += 1;
        }
        self.last_scan_at = Some(now);
        self.scanning = false;
        log::info!(
            "[UsageScan 用量扫描] claude files={} lines={} new={}; codex files={} lines={} new={}; grok files={} new={}; agy dbs={} new={}; {}ms",
            output.claude.files_scanned, output.claude.lines_parsed, output.claude.entries.len(),
            output.codex.files_scanned, output.codex.lines_parsed, output.codex.entries.len(),
            output.grok.files_scanned, output.grok.entries.len(),
            output.agy.files_scanned, output.agy.entries.len(), output.elapsed_ms
        );
    }
}

/// 全量重建时合并新旧数据。CLI 或清理工具会删掉旧日志，那部分用量只剩在旧汇总里：
/// 按「天 + 服务」比较 token 合计，旧的更多（说明那天有日志被删）就保留旧桶，否则用重扫结果。
/// 保留的旧桶按需用新价格重算费用（按 token 合计平价计算）；Grok 费用来自日志，不重算。
pub fn merge_preserving_history(old: Vec<UsageBucket>, fresh: Vec<UsageBucket>, reprice: &Reprice) -> Vec<UsageBucket> {
    let mut old_by: HashMap<(NaiveDate, UsageApp), Vec<UsageBucket>> = HashMap::new();
    for b in old {
        old_by.entry((b.day, b.app)).or_default().push(b);
    }
    let mut fresh_by: HashMap<(NaiveDate, UsageApp), Vec<UsageBucket>> = HashMap::new();
    for b in fresh {
        fresh_by.entry((b.day, b.app)).or_default().push(b);
    }
    let tokens = |list: &[UsageBucket]| list.iter().map(UsageBucket::total_tokens).sum::<i64>();
    let keys: HashSet<(NaiveDate, UsageApp)> = old_by.keys().chain(fresh_by.keys()).copied().collect();
    let mut result = Vec::new();
    for k in keys {
        let kept = old_by.remove(&k).unwrap_or_default();
        let rescanned = fresh_by.remove(&k).unwrap_or_default();
        if tokens(&kept) > tokens(&rescanned) {
            result.extend(kept.into_iter().map(|b| repriced(b, reprice)));
        } else {
            result.extend(rescanned);
        }
    }
    result
}

fn repriced(mut bucket: UsageBucket, reprice: &Reprice) -> UsageBucket {
    if bucket.app == UsageApp::Grok {
        return bucket;
    }
    match reprice {
        Reprice::None => return bucket,
        Reprice::Keys(keys) if !keys.contains(&pricing::normalize(&bucket.model)) => return bucket,
        _ => {}
    }
    bucket.cost_usd = pricing::cost(
        &bucket.model,
        bucket.input_tokens,
        bucket.output_tokens,
        bucket.cache_read_tokens,
        bucket.cache_creation_tokens,
        Some(0),
    );
    bucket
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bucket(day: u32, tokens: i64, cost: f64) -> UsageBucket {
        UsageBucket {
            app: UsageApp::Claude,
            model: "claude-sonnet-4-5".into(),
            day: NaiveDate::from_ymd_opt(2026, 10, day).unwrap(),
            input_tokens: tokens,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            cost_usd: cost,
        }
    }

    #[test]
    fn keeps_deleted_history_and_reprices() {
        let old = vec![bucket(1, 1_000_000, 0.0), bucket(2, 10, 0.0)];
        let fresh = vec![bucket(2, 20, 1.0)];
        let mut merged = merge_preserving_history(old, fresh, &Reprice::All);
        merged.sort_by_key(|b| b.day);
        assert_eq!(merged.len(), 2);
        assert!((merged[0].cost_usd - 3.0).abs() < 1e-9);
        assert_eq!(merged[1].input_tokens, 20);
    }
}
