//! Canonical client-owned Conversation authority.
//!
//! A Conversation is the only durable owner for direct and group chat facts.
//! Human and Agent principals are peers; access, runtime availability, and
//! collaboration roles are intentionally represented by separate values.

mod migration;
mod profile_snapshot;
mod service;
mod store;

pub use migration::{MigrationReport, migrate_legacy_state};
pub use profile_snapshot::{
    CandidateFilters, PriceFacts, ProfileSnapshotAuthority, SharedSnapshotAuthority, TargetFacts,
    production_snapshot_authority, project_profile_snapshot, project_profile_snapshots,
    rank_candidates,
};
pub use service::ConversationService;
pub(crate) use service::route_receipt;
pub use store::{
    ConversationRuntimeScope, ConversationStore, DEFAULT_EVENT_PAGE_SIZE, MAX_EVENT_PAGE_SIZE,
    NewEventPart, StoreError, StoreResult,
};

use serde::{Deserialize, Serialize};

pub const CONVERSATION_SCHEMA_VERSION: &str = "lico.conversation.v1";
pub const DEFAULT_LOCAL_AGENT_GROUP_ID: &str = "lico-group-default";
pub const DEFAULT_LOCAL_AGENT_GROUP_TITLE: &str = "Local";
/// Bounded Profile intent limits. Each field is a bounded allowlist; unknown
/// optional facts stay unknown instead of being guessed.
pub const MAX_PROFILE_CAPABILITIES: usize = 32;
pub const MAX_PROFILE_SKILLS: usize = 32;
pub const MAX_PROFILE_FIELD_BYTES: usize = 128;
/// Product-owned, bundle-embedded Assistant workflow-authoring Skill. The
/// designated Assistant Profile references this bounded local resource by
/// default; it is never installed into a third-party Agent skill root.
pub const ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID: &str = "assistant-workflow-authoring";
pub(crate) const ASSISTANT_WORKFLOW_AUTHORING_SKILL_SOURCE: &str =
    include_str!("../../../resources/assistant-workflow-authoring/SKILL.md");

/// Typed rejection for dispatch-type work on a service constructed without
/// the persistent host runtime. One-shot transports route through the
/// conversation host instead of opening unattached turns or orphaning runs.
pub const PERSISTENT_TRANSPORT_REQUIRED: &str = "persistent_conversation_transport_required";

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum PrincipalKind {
    Human,
    Agent,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MembershipAccess {
    Owner,
    Member,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum MembershipStatus {
    Active,
    Left,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Principal {
    pub id: String,
    pub kind: PrincipalKind,
    pub display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub created_at_unix_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub title: String,
    pub archived: bool,
    pub pinned: bool,
    pub is_group: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strategy_revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assistant_membership_id: Option<String>,
    pub revision: i64,
    pub created_at_unix_ms: i64,
    pub updated_at_unix_ms: i64,
    pub memberships: Vec<Membership>,
    pub event_count: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationSummary {
    pub id: String,
    pub title: String,
    pub archived: bool,
    pub pinned: bool,
    pub is_group: bool,
    pub revision: i64,
    pub updated_at_unix_ms: i64,
    pub membership_count: i64,
    pub event_count: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Membership {
    pub id: String,
    pub conversation_id: String,
    pub principal: Principal,
    pub access: MembershipAccess,
    pub status: MembershipStatus,
    pub joined_at_unix_ms: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub left_at_unix_ms: Option<i64>,
}

/// Persistent, endpoint-local Profile intent for one active Agent
/// Membership. The intent is bounded and revisioned; derived facts (price,
/// score, model availability, readiness) are never stored here and come only
/// from their existing owners through [`ProfileSnapshotAuthority`].
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProfileResponsibility {
    Assistant,
    #[default]
    Member,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProfileIntent {
    pub revision: i64,
    #[serde(default)]
    pub required_capabilities: Vec<String>,
    #[serde(default)]
    pub preferred_capabilities: Vec<String>,
    #[serde(default)]
    pub skill_references: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
    #[serde(default)]
    pub responsibility: ProfileResponsibility,
    pub updated_at_unix_ms: i64,
}

/// Mutable Profile fields. Revision, responsibility, and timestamps are
/// store-owned and therefore cannot be asserted by a bridge or MCP caller.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProfileIntentUpdate {
    #[serde(default)]
    pub required_capabilities: Vec<String>,
    #[serde(default)]
    pub preferred_capabilities: Vec<String>,
    #[serde(default)]
    pub skill_references: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
}

impl ProfileIntentUpdate {
    /// Validate the bounded intent fields. Bounds are enforced at the store
    /// boundary so a Profile can never grow without a typed rejection.
    pub fn validate(&self) -> Result<(), String> {
        for field in [
            "required_capabilities",
            "preferred_capabilities",
            "skill_references",
        ] {
            let values = match field {
                "required_capabilities" => &self.required_capabilities,
                "preferred_capabilities" => &self.preferred_capabilities,
                _ => &self.skill_references,
            };
            let maximum = match field {
                "skill_references" => MAX_PROFILE_SKILLS,
                _ => MAX_PROFILE_CAPABILITIES,
            };
            if values.len() > maximum {
                return Err(format!("profile_{field}_limit"));
            }
            for value in values {
                if value.is_empty() || value.len() > MAX_PROFILE_FIELD_BYTES {
                    return Err(format!("profile_{field}_invalid"));
                }
            }
        }
        for (field, value) in [
            ("preferred_model", self.preferred_model.as_deref()),
            (
                "preferred_environment",
                self.preferred_environment.as_deref(),
            ),
        ] {
            if let Some(value) = value {
                if value.is_empty() || value.len() > MAX_PROFILE_FIELD_BYTES {
                    return Err(format!("profile_{field}_invalid"));
                }
            }
        }
        Ok(())
    }
}

/// One derived, privacy-safe Membership Profile projection. Facts come only
/// from the persistent intent and the named existing authorities; the
/// projection contains no prompt, credential, absolute path, machine
/// identity or runtime endpoint.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MembershipProfileSnapshot {
    pub conversation_id: String,
    pub membership_id: String,
    pub agent_id: String,
    pub intent_revision: i64,
    pub responsibility: ProfileResponsibility,
    #[serde(default)]
    pub required_capabilities: Vec<String>,
    #[serde(default)]
    pub preferred_capabilities: Vec<String>,
    #[serde(default)]
    pub skill_references: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readiness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub price_input_usd_per_million_tokens: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub price_output_usd_per_million_tokens: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intelligence_score: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reliability_class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latency_class: Option<u8>,
    #[serde(default)]
    pub authority: Vec<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EventKind {
    Message,
    MembershipChanged,
    Availability,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EventPartKind {
    Text,
    Reasoning,
    ToolCall,
    ToolResult,
    Artifact,
    Diagnostic,
    Metadata,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationEvent {
    pub id: String,
    pub conversation_id: String,
    pub sequence: i64,
    pub author_membership_id: Option<String>,
    pub kind: EventKind,
    pub causation_id: Option<String>,
    pub correlation_id: Option<String>,
    pub created_at_unix_ms: i64,
    pub finalized: bool,
    pub parts: Vec<EventPart>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventPart {
    pub id: String,
    pub event_id: String,
    pub ordinal: i64,
    pub kind: EventPartKind,
    pub content: String,
    pub created_at_unix_ms: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EventPage {
    pub events: Vec<ConversationEvent>,
    pub next_cursor: Option<String>,
    pub total_count: i64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceLink {
    pub id: String,
    pub conversation_id: String,
    pub source_kind: String,
    pub native_identity: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeBinding {
    pub id: String,
    pub conversation_id: String,
    pub membership_id: String,
    pub lane: String,
    pub availability: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub safe_reason: Option<String>,
}

/// Private execution state for one membership-scoped Agent dispatch. Runtime
/// locations stay inside the native Conversation database and are never part
/// of the client-facing Conversation contract.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationDispatch {
    pub id: String,
    pub conversation_id: String,
    pub membership_id: String,
    pub operation: String,
    pub state: DispatchState,
    pub session_mode: DispatchSessionMode,
    pub runtime_conversation_path: Option<String>,
    pub error_code: Option<String>,
    pub created_at_unix_ms: i64,
    pub updated_at_unix_ms: i64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum DispatchState {
    Accepted,
    Running,
    Completed,
    Failed,
    CancelRequested,
    Cancelled,
}

impl DispatchState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::CancelRequested => "cancel-requested",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum DispatchSessionMode {
    New,
    Resume,
}

impl DispatchSessionMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::New => "new",
            Self::Resume => "resume",
        }
    }
}

/// One structured mention dispatch record. Addressing still selects a
/// Membership; execution is the same Membership-scoped PersistentTurn used
/// by direct, Assistant-Graph, strategy, and subagent effects.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectTurn {
    pub id: String,
    pub conversation_id: String,
    pub source_event_id: String,
    pub membership_id: String,
    pub state: TurnState,
    pub ordinal: i64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TurnState {
    Pending,
    Claimed,
    Running,
    WaitingForHuman,
    Succeeded,
    Failed,
    Interrupted,
    Cancelled,
}
