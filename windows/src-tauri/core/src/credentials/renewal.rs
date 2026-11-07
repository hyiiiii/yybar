//! 下次续费日（对应 Mac `SubscriptionRenewal`）。
//! - Codex：id_token 的 `chatgpt_subscription_active_until` 就是当前付费周期结束日；已过期时按月往后推，标为推算。
//! - Claude：只有订阅开始日，按每月同一天推算。
//! - Grok：接口没有续费信息，不显示。

use chrono::{Months, TimeZone};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionRenewal {
    pub date: i64,
    pub estimated: bool,
    /// 推算依据：Codex 为周期结束日，Claude 为订阅开始日。
    pub basis: i64,
}

impl SubscriptionRenewal {
    pub fn codex(active_until: Option<i64>, now: i64) -> Option<SubscriptionRenewal> {
        let until = active_until?;
        if until > now {
            return Some(SubscriptionRenewal { date: until, estimated: false, basis: until });
        }
        Some(SubscriptionRenewal { date: next_monthly(until, now), estimated: true, basis: until })
    }

    pub fn monthly(start: Option<i64>, now: i64) -> Option<SubscriptionRenewal> {
        let start = start?;
        Some(SubscriptionRenewal { date: next_monthly(start, now), estimated: true, basis: start })
    }
}

/// anchor 之后每月同一天里第一个晚于 now 的日子（31 号等月末日顺延到当月最后一天）。
pub fn next_monthly(anchor: i64, now: i64) -> i64 {
    let Some(base) = chrono::Local.timestamp_opt(anchor, 0).single() else { return anchor };
    for months in 1..=1200u32 {
        if let Some(date) = base.checked_add_months(Months::new(months)) {
            if date.timestamp() > now {
                return date.timestamp();
            }
        }
    }
    anchor
}
