//! 按 (day, app, model) 聚合的内存表（对应 Mac `UsageAggregator`）。

use std::collections::HashMap;

use chrono::NaiveDate;

use super::models::{UsageBucket, UsageEntry};
use crate::UsageApp;

#[derive(Debug, Default, Clone)]
pub struct Aggregator {
    buckets: HashMap<(NaiveDate, UsageApp, String), UsageBucket>,
}

impl Aggregator {
    pub fn from_buckets(list: Vec<UsageBucket>) -> Aggregator {
        let mut a = Aggregator::default();
        a.load(list);
        a
    }

    pub fn load(&mut self, list: Vec<UsageBucket>) {
        self.buckets.clear();
        for b in list {
            self.buckets.insert((b.day, b.app, b.model.clone()), b);
        }
    }

    pub fn ingest(&mut self, entries: &[UsageEntry]) {
        for e in entries {
            let b = self.buckets.entry((e.day, e.app, e.model.clone())).or_insert_with(|| UsageBucket {
                app: e.app,
                model: e.model.clone(),
                day: e.day,
                input_tokens: 0,
                output_tokens: 0,
                cache_read_tokens: 0,
                cache_creation_tokens: 0,
                cost_usd: 0.0,
            });
            b.input_tokens += e.input_tokens;
            b.output_tokens += e.output_tokens;
            b.cache_read_tokens += e.cache_read_tokens;
            b.cache_creation_tokens += e.cache_creation_tokens;
            b.cost_usd += e.cost_usd;
        }
    }

    pub fn is_empty(&self) -> bool {
        self.buckets.is_empty()
    }

    /// 按 天 → 服务 → 模型 排好序的全部桶。
    pub fn snapshot(&self) -> Vec<UsageBucket> {
        let mut list: Vec<UsageBucket> = self.buckets.values().cloned().collect();
        list.sort_by(|a, b| (a.day, a.app, &a.model).cmp(&(b.day, b.app, &b.model)));
        list
    }
}
