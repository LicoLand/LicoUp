use crate::WORKFLOW_SCHEMA_VERSION;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowDefinition {
    pub schema: String,
    pub metadata: WorkflowMetadata,
    #[serde(default)]
    pub limits: WorkflowLimits,
    #[serde(default)]
    pub actor_slots: Vec<ActorSlot>,
    #[serde(default)]
    pub runtimes: Vec<RuntimeRequirement>,
    #[serde(default)]
    pub worksets: Vec<WorksetTemplate>,
    pub initial: String,
    pub states: Vec<GraphState>,
    pub transitions: Vec<Transition>,
}

impl WorkflowDefinition {
    pub fn has_supported_schema(&self) -> bool {
        self.schema == WORKFLOW_SCHEMA_VERSION
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowMetadata {
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkflowLimits {
    pub max_parallelism: u8,
    pub max_workset_items: u16,
    pub max_attempts: u8,
}

impl Default for WorkflowLimits {
    fn default() -> Self {
        Self {
            max_parallelism: 8,
            max_workset_items: 256,
            max_attempts: 3,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum BindingKind {
    Actor,
    Runtime,
    Workspace,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ActorSlot {
    pub id: String,
    pub kind: BindingKind,
    pub label: String,
    #[serde(default = "default_true")]
    pub required: bool,
    #[serde(default)]
    pub session_policy: SessionPolicy,
    #[serde(default)]
    pub entry: bool,
    #[serde(default)]
    pub fallback: SlotFallbackPolicy,
}

impl ActorSlot {
    pub fn required_actor(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            kind: BindingKind::Actor,
            label: label.into(),
            required: true,
            session_policy: SessionPolicy::New,
            entry: true,
            fallback: SlotFallbackPolicy::default(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct SlotFallbackPolicy {
    pub after_transient_attempts: u8,
    pub on_quota: bool,
}

impl Default for SlotFallbackPolicy {
    fn default() -> Self {
        Self {
            after_transient_attempts: 2,
            on_quota: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum SessionPolicy {
    #[default]
    New,
    Resume,
    Sticky,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RuntimeKind {
    Python,
    Node,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeRequirement {
    pub id: String,
    pub kind: RuntimeKind,
    #[serde(default)]
    pub version_requirement: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorksetTemplate {
    pub id: String,
    pub item_binding: String,
    #[serde(default)]
    pub predecessor_field: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum GraphStateKind {
    Pass,
    Choice,
    Fork,
    Join,
    Authorization,
    Actor,
    Script,
    Workset,
    Succeed,
    Fail,
    Blocked,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GraphState {
    pub id: String,
    pub kind: GraphStateKind,
    pub label: String,
    #[serde(default)]
    pub instruction: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub binding: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workset: Option<String>,
    #[serde(default)]
    pub retry: RetryPolicy,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct RetryPolicy {
    pub max_attempts: u8,
    pub transient_only: bool,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 1,
            transient_only: true,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Transition {
    pub id: String,
    pub from: String,
    pub to: String,
    pub event: TransitionEvent,
    /// Declared handoff mode. `flow` (the default when the field is absent)
    /// enters the target as soon as the edge is selected; `callback` first
    /// parks the run and waits for the master agent's decision.
    #[serde(default, skip_serializing_if = "TransitionMode::is_flow")]
    pub mode: TransitionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guard: Option<GuardExpression>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransitionMode {
    #[default]
    Flow,
    Callback,
}

impl TransitionMode {
    pub const fn is_flow(&self) -> bool {
        matches!(self, Self::Flow)
    }
}

/// One durable callback wait: the edge was selected but the declared target is
/// not entered until the master agent's decision arrives as a run input.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingCallback {
    pub state_id: String,
    pub state_visit: u64,
    pub transition_id: String,
    pub event: TransitionEvent,
    pub target: String,
}

/// The master agent's decision for one pending callback: enter the declared
/// next node, return to the completed node, or terminate the run.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum CallbackDecisionKind {
    Advance,
    Return,
    Terminate,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum TransitionEvent {
    Complete,
    Success,
    Failure,
}

impl TransitionEvent {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Complete => "complete",
            Self::Success => "success",
            Self::Failure => "failure",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GuardExpression {
    pub path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub equals: Option<Value>,
    #[serde(default)]
    pub exists: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum StrategyRunStatus {
    Pending,
    AuthorizationRequired,
    RuntimeMissing,
    Running,
    Waiting,
    Retryable,
    CancelRequested,
    CancelInDoubt,
    Blocked,
    Cancelled,
    Failed,
    Completed,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum FailureClass {
    Transient,
    Permanent,
    Authority,
    Runtime,
    Sandbox,
    InDoubt,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FallbackReceipt {
    pub fallback_from: String,
    pub fallback_to: String,
    pub reason: String,
    pub attempts: u8,
}

const fn default_true() -> bool {
    true
}
