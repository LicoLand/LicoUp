use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

use super::WORKFLOW_SCHEMA_VERSION;

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guard: Option<GuardExpression>,
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BindingCandidate {
    pub value_id: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub reasoning_effort: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BindingValue {
    pub slot_id: String,
    #[serde(default)]
    pub ordinal: u8,
    pub value_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub model: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reasoning_effort: String,
    #[serde(default)]
    pub revision: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StrategyAuthorization {
    pub definition_digest: String,
    pub semantics_digest: String,
    pub binding_digest: String,
    pub authorization_digest: String,
    pub revision: u64,
    pub active: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StrategyDefinitionSummary {
    pub definition_id: String,
    pub revision_digest: String,
    pub semantics_digest: String,
    pub name: String,
    pub version: String,
    pub imported_at_unix_ms: i64,
    #[serde(default)]
    pub authorized: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StrategyDefinition {
    #[serde(flatten)]
    pub summary: StrategyDefinitionSummary,
    pub workflow: WorkflowDefinition,
    pub asset_count: usize,
    pub bindings: Vec<BindingValue>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authorization: Option<StrategyAuthorization>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StrategyDiagnostic {
    pub code: String,
    pub component: String,
    pub retryable: bool,
    pub recovery: String,
    #[serde(default)]
    pub arguments: BTreeMap<String, String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StrategyProjection {
    pub schema: String,
    pub definition: StrategyDefinitionSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_id: Option<String>,
    pub status: StrategyRunStatus,
    pub current_states: BTreeSet<String>,
    pub neighbor_states: BTreeSet<String>,
    pub allowed_operations: BTreeSet<String>,
    pub bindings: Vec<BindingValue>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diagnostic: Option<StrategyDiagnostic>,
    pub history_count: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fallbacks: Vec<FallbackReceipt>,
    #[serde(default)]
    pub needs_human_input: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entry_session_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FallbackReceipt {
    pub fallback_from: String,
    pub fallback_to: String,
    pub reason: String,
    pub attempts: u8,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StrategyErrorCode {
    InvalidRequest,
    PackageUnavailable,
    PackageTooLarge,
    PackageEntryInvalid,
    PackageLayoutInvalid,
    PackageDuplicateEntry,
    PackageResourceLimit,
    WorkflowInvalid,
    DefinitionNotFound,
    PreparationNotFound,
    RevisionConflict,
    BindingIncomplete,
    AuthorizationRequired,
    AuthorizationStale,
    RuntimeUnavailable,
    RuntimeDrifted,
    SandboxUnavailable,
    PermitDenied,
    RunNotFound,
    RunNotRetryable,
    CallbackStale,
    CallbackConflict,
    EffectInDoubt,
    UnsupportedAction,
}

impl StrategyErrorCode {
    pub const fn wire(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::PackageUnavailable => "package_unavailable",
            Self::PackageTooLarge => "package_too_large",
            Self::PackageEntryInvalid => "package_entry_invalid",
            Self::PackageLayoutInvalid => "package_layout_invalid",
            Self::PackageDuplicateEntry => "package_duplicate_entry",
            Self::PackageResourceLimit => "package_resource_limit",
            Self::WorkflowInvalid => "workflow_invalid",
            Self::DefinitionNotFound => "definition_not_found",
            Self::PreparationNotFound => "preparation_not_found",
            Self::RevisionConflict => "revision_conflict",
            Self::BindingIncomplete => "binding_incomplete",
            Self::AuthorizationRequired => "authorization_required",
            Self::AuthorizationStale => "authorization_stale",
            Self::RuntimeUnavailable => "runtime_unavailable",
            Self::RuntimeDrifted => "runtime_drifted",
            Self::SandboxUnavailable => "sandbox_unavailable",
            Self::PermitDenied => "permit_denied",
            Self::RunNotFound => "run_not_found",
            Self::RunNotRetryable => "run_not_retryable",
            Self::CallbackStale => "callback_stale",
            Self::CallbackConflict => "callback_conflict",
            Self::EffectInDoubt => "effect_in_doubt",
            Self::UnsupportedAction => "unsupported_action",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StrategyError {
    pub code: StrategyErrorCode,
    pub stage: &'static str,
    pub component: &'static str,
    pub retryable: bool,
    pub recovery: &'static str,
}

impl StrategyError {
    pub const fn new(
        code: StrategyErrorCode,
        stage: &'static str,
        component: &'static str,
        retryable: bool,
        recovery: &'static str,
    ) -> Self {
        Self {
            code,
            stage,
            component,
            retryable,
            recovery,
        }
    }
}

impl std::fmt::Display for StrategyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code.wire())
    }
}

impl std::error::Error for StrategyError {}

const fn default_true() -> bool {
    true
}
