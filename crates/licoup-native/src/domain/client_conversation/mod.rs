//! Native host composition for the independent Canonical Conversation crate.
//!
//! Durable records and SQLite state are owned by `licoup-conversation`; this
//! module retains only host-specific migration, snapshot authorities, runtime
//! closures, and the stable FFI-facing re-export.

mod migration;
pub mod peer_ingress;
mod profile_admission;
mod profile_snapshot;
pub(crate) mod projection_delta;
mod service;
#[allow(hidden_glob_reexports)]
mod store;

pub use licoup_conversation::*;
pub use migration::{MigrationReport, migrate_legacy_state};
pub use profile_admission::{
    CandidateFilters, ProfileAdmission, ProfileAdmissionRefusal, ProfileChoiceOrigin,
    ProfileRequirementOutcome, RequirementOutcome, ResolvedProfileChoice, admit_profile_candidates,
    rank_candidates,
};
pub use profile_snapshot::{
    PriceFacts, ProfileSnapshotAuthority, SharedSnapshotAuthority, TargetFacts,
    production_snapshot_authority, project_profile_snapshot, project_profile_snapshots,
};
pub(crate) use service::route_receipt;
pub use service::{ConversationService, PersistentRuntimePorts, dispatch_attachments_param};

// The bundled usage Skill's identity — its published name and the source one MCP
// registration delivers under it — is owned by `licoup-mcp::guide_skill`, which
// owns that registration. The host reads it downward; it keeps no second copy.
