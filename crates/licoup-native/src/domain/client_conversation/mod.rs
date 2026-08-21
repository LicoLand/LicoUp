//! Canonical client-owned Conversation authority.
//!
//! A Conversation is the only durable owner for direct and group chat facts.
//! Human and Agent principals are peers; access, runtime availability, and
//! collaboration roles are intentionally represented by separate values.

mod migration;
mod service;
mod store;

pub use migration::{MigrationReport, migrate_legacy_state};
pub use service::ConversationService;
pub use store::{
    ConversationRuntimeScope, ConversationStore, DEFAULT_EVENT_PAGE_SIZE, MAX_EVENT_PAGE_SIZE,
    NewEventPart, StoreError, StoreResult,
};

use serde::{Deserialize, Serialize};

pub const CONVERSATION_SCHEMA_VERSION: &str = "lico.conversation.v1";
pub const DEFAULT_LOCAL_AGENT_GROUP_ID: &str = "lico-group-default";
pub const DEFAULT_LOCAL_AGENT_GROUP_TITLE: &str = "Local";

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
/// by strategy, delivery, and subagent effects.
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
