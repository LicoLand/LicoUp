//! Native host composition for the independent Canonical Conversation crate.
//!
//! Durable records and SQLite state are owned by `licoup-conversation`; this
//! module retains only host-specific migration, snapshot authorities, runtime
//! closures, and the stable FFI-facing re-export.

mod migration;
mod profile_snapshot;
mod service;
#[allow(hidden_glob_reexports)]
mod store;

pub use licoup_conversation::*;
pub use migration::{MigrationReport, migrate_legacy_state};
pub use profile_snapshot::{
    CandidateFilters, PriceFacts, ProfileSnapshotAuthority, SharedSnapshotAuthority, TargetFacts,
    production_snapshot_authority, project_profile_snapshot, project_profile_snapshots,
    rank_candidates,
};
pub use service::ConversationService;
pub(crate) use service::route_receipt;

/// Product-owned private dispatch guidance remains composed by the native host
/// and is never written into Conversation Event text.
pub(crate) const ASSISTANT_WORKFLOW_AUTHORING_SKILL_SOURCE: &str =
    include_str!("../../../resources/assistant-workflow-authoring/SKILL.md");

#[cfg(test)]
pub(crate) fn assistant_workflow_authoring_prompt() -> &'static str {
    let source = ASSISTANT_WORKFLOW_AUTHORING_SKILL_SOURCE.trim();
    source
        .strip_prefix("---\n")
        .and_then(|rest| rest.split_once("\n---\n"))
        .map(|(_, prompt)| prompt.trim())
        .filter(|prompt| !prompt.is_empty())
        .unwrap_or(source)
}
