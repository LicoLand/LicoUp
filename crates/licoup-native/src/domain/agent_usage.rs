//! Local-only agent token usage facade.

mod agent_usage_codex;
mod agent_usage_native;
mod attribution;
mod command;
mod contract;
mod incremental;
mod model_identity;
mod persistence;
mod variant;
mod window;
pub(crate) mod workflow_ledger;

pub use command::{report, scan};
pub use incremental::{UsageIncrementalAuthority, UsageWindowProjection};
pub(crate) use variant::{model_label as recorded_usage_model, prefer_recorded_model};

#[cfg(test)]
mod tests;
