//! Local-only agent token usage facade.

mod agent_usage_codex;
mod agent_usage_native;
mod attribution;
mod command;
mod contract;
mod incremental;
mod persistence;
mod window;
pub mod workflow_ledger;

pub use command::{report, scan};
pub use incremental::{UsageIncrementalAuthority, UsageWindowProjection};

#[cfg(test)]
mod tests;
