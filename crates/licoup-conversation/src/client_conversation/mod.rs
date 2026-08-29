//! Canonical client-owned Conversation records.

use serde::{Deserialize, Deserializer, Serialize, Serializer, de};

pub use crate::state_machine::TurnState;

pub const CONVERSATION_SCHEMA_VERSION: &str = "lico.conversation.v1";
pub const DEFAULT_LOCAL_AGENT_GROUP_ID: &str = "lico-group-default";
pub const DEFAULT_LOCAL_AGENT_GROUP_TITLE: &str = "Local";
pub const MAX_PROFILE_CAPABILITIES: usize = 32;
pub const MAX_PROFILE_SKILLS: usize = 32;
pub const MAX_PROFILE_FIELD_BYTES: usize = 128;
pub const ASSISTANT_WORKFLOW_AUTHORING_SKILL_ID: &str = "assistant-workflow-authoring";
const ASSISTANT_WORKFLOW_AUTHORING_PROMPT: &str = "Respond directly to the user's request. Use tools only when the current request requires them. Do not start, resume, or invent unrelated work. Finish the requested response and return it.";

pub(crate) fn assistant_workflow_authoring_prompt() -> &'static str {
    ASSISTANT_WORKFLOW_AUTHORING_PROMPT
}

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
    pub preferred_reasoning_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
    #[serde(default)]
    pub responsibility: ProfileResponsibility,
    pub updated_at_unix_ms: i64,
}

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
    pub preferred_reasoning_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_environment: Option<String>,
}

impl ProfileIntentUpdate {
    pub fn validate(&self) -> Result<(), String> {
        for (field, values, maximum) in [
            (
                "required_capabilities",
                &self.required_capabilities,
                MAX_PROFILE_CAPABILITIES,
            ),
            (
                "preferred_capabilities",
                &self.preferred_capabilities,
                MAX_PROFILE_CAPABILITIES,
            ),
            (
                "skill_references",
                &self.skill_references,
                MAX_PROFILE_SKILLS,
            ),
        ] {
            if values.len() > maximum {
                return Err(format!("profile_{field}_limit"));
            }
            if values
                .iter()
                .any(|value| value.is_empty() || value.len() > MAX_PROFILE_FIELD_BYTES)
            {
                return Err(format!("profile_{field}_invalid"));
            }
        }
        for (field, value) in [
            ("preferred_model", self.preferred_model.as_deref()),
            (
                "preferred_reasoning_effort",
                self.preferred_reasoning_effort.as_deref(),
            ),
            (
                "preferred_environment",
                self.preferred_environment.as_deref(),
            ),
        ] {
            if value.is_some_and(|value| value.is_empty() || value.len() > MAX_PROFILE_FIELD_BYTES)
            {
                return Err(format!("profile_{field}_invalid"));
            }
        }
        Ok(())
    }
}

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
    pub preferred_reasoning_effort: Option<String>,
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
    Image,
}

/// Attachment metadata carried by one image Event Part. The part content is
/// this value's JSON encoding, exactly like Metadata and Diagnostic parts
/// carry structured JSON in their content; the byte size is recorded from the
/// local file at admission time, never from a caller declaration.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImageAttachment {
    pub path: String,
    pub name: String,
    pub media_type: String,
    pub byte_size: u64,
}

impl ImageAttachment {
    /// Canonical content encoding for one image Event Part.
    pub fn part_content(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_owned())
    }

    /// Decode the attachment metadata from one image part's content. Returns
    /// None for malformed content so readers tolerate a part they cannot
    /// interpret instead of failing the whole event read.
    pub fn from_part_content(content: &str) -> Option<Self> {
        serde_json::from_str(content).ok()
    }
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

impl EventPart {
    /// The decoded attachment metadata when this part is an image part with a
    /// well-formed content encoding; None for every other part.
    pub fn image_attachment(&self) -> Option<ImageAttachment> {
        (self.kind == EventPartKind::Image)
            .then(|| ImageAttachment::from_part_content(&self.content))
            .flatten()
    }
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

impl Serialize for TurnState {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(match self {
            Self::Pending => "pending",
            Self::Claimed => "claimed",
            Self::Running => "running",
            Self::WaitingForHuman => "waiting-for-human",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Interrupted => "interrupted",
            Self::Cancelled => "cancelled",
        })
    }
}

impl<'de> Deserialize<'de> for TurnState {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        match String::deserialize(deserializer)?.as_str() {
            "pending" => Ok(Self::Pending),
            "claimed" => Ok(Self::Claimed),
            "running" => Ok(Self::Running),
            "waiting-for-human" => Ok(Self::WaitingForHuman),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "interrupted" => Ok(Self::Interrupted),
            "cancelled" => Ok(Self::Cancelled),
            _ => Err(de::Error::custom("invalid turn state")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image_part(content: String) -> EventPart {
        EventPart {
            id: "part:1".to_owned(),
            event_id: "event:1".to_owned(),
            ordinal: 1,
            kind: EventPartKind::Image,
            content,
            created_at_unix_ms: 1,
        }
    }

    #[test]
    fn image_part_content_round_trips_attachment_metadata() {
        let attachment = ImageAttachment {
            path: "fixtures/mockup.png".to_owned(),
            name: "mockup.png".to_owned(),
            media_type: "image/png".to_owned(),
            byte_size: 12,
        };
        let content = attachment.part_content();
        assert_eq!(
            ImageAttachment::from_part_content(&content).as_ref(),
            Some(&attachment)
        );
        let part = image_part(content);
        assert_eq!(part.image_attachment().as_ref(), Some(&attachment));
    }

    #[test]
    fn image_part_wire_kind_is_kebab_case_image() {
        assert_eq!(
            serde_json::to_value(EventPartKind::Image).unwrap(),
            serde_json::json!("image")
        );
        assert_eq!(
            serde_json::from_value::<EventPartKind>(serde_json::json!("image")).unwrap(),
            EventPartKind::Image
        );
    }

    #[test]
    fn image_part_attachment_decodes_only_for_well_formed_image_parts() {
        let mut text_part = image_part(
            ImageAttachment {
                path: "fixtures/a.png".to_owned(),
                name: "a.png".to_owned(),
                media_type: "image/png".to_owned(),
                byte_size: 1,
            }
            .part_content(),
        );
        text_part.kind = EventPartKind::Text;
        assert_eq!(text_part.image_attachment(), None);

        let malformed = image_part("not json".to_owned());
        assert_eq!(malformed.image_attachment(), None);

        let missing_fields = image_part(r#"{"path":"fixtures/a.png"}"#.to_owned());
        assert_eq!(missing_fields.image_attachment(), None);
    }
}
