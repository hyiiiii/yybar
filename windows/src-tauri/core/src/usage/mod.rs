//! 本地用量统计（对应 Mac 版 `Core/Usage`）：扫描各 CLI 的会话日志 → 按 (天, 服务, 模型) 聚合 → 持久化。

pub mod activity;
pub mod agy;
pub mod aggregator;
pub mod claude;
pub mod codex;
pub mod grok;
pub mod jsonl;
pub mod models;
pub mod pricing;
pub mod service;
pub mod sqlite;

pub use aggregator::Aggregator;
pub use models::*;
