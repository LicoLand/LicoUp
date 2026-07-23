//! Durable policy types and deterministic workflow reduction.

pub mod engine;
pub mod reducer;
pub mod store;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

pub const MAX_POLICY_STEPS: usize = 4096;
pub const MAX_AGENT_MODEL_BYTES: usize = 256;
pub const MAX_STEP_TIMEOUT_MS: u64 = 86_400_000;
pub const MAX_STEP_ATTEMPTS: u32 = 16;
pub const MAX_JSON_POINTER_SEGMENTS: usize = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReasoningLevel {
    Low,
    Medium,
    High,
    Max,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ModelAssignment {
    pub agent_id: String,
    pub model_id: String,
    pub reasoning_level: Option<ReasoningLevel>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AgentDefinition {
    pub id: String,
    pub roles: Vec<String>,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PolicyDocument {
    pub schema_version: u32,
    pub id: String,
    pub label: String,
    pub commander: Option<ModelAssignment>,
    pub model_library: Vec<ModelAssignment>,
    pub agents: Vec<AgentDefinition>,
    pub workflow: PolicyWorkflow,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PolicyWorkflow {
    pub steps: Vec<PolicyStep>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StepPurpose {
    Action,
    Validation,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum OutputMode {
    Text,
    Json,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FailureAction {
    Stop,
    Continue,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApprovalRule {
    NotRequired,
    Required,
}
impl Serialize for ApprovalRule {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Wire {
            required: bool,
        }
        Wire {
            required: matches!(self, Self::Required),
        }
        .serialize(s)
    }
}
impl<'de> Deserialize<'de> for ApprovalRule {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Wire {
            required: bool,
        }
        Ok(if Wire::deserialize(d)?.required {
            Self::Required
        } else {
            Self::NotRequired
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Condition {
    Always,
    Exists {
        source_step_id: String,
        pointer: String,
    },
    JsonPointerEquals {
        source_step_id: String,
        pointer: String,
        expected: Value,
    },
    Contains {
        source_step_id: String,
        pointer: String,
        expected: Value,
    },
}
impl Serialize for Condition {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self{Self::Always=>Option::<Value>::None.serialize(s),Self::Exists{source_step_id,pointer}=>serde_json::json!({"sourceStepId":source_step_id,"pointer":pointer,"operator":"exists","value":null}).serialize(s),Self::JsonPointerEquals{source_step_id,pointer,expected}=>serde_json::json!({"sourceStepId":source_step_id,"pointer":pointer,"operator":"equals","value":expected}).serialize(s),Self::Contains{source_step_id,pointer,expected}=>serde_json::json!({"sourceStepId":source_step_id,"pointer":pointer,"operator":"contains","value":expected}).serialize(s)}
    }
}
impl<'de> Deserialize<'de> for Condition {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Wire {
            source_step_id: String,
            pointer: String,
            operator: String,
            value: Value,
        }
        let value = Option::<Wire>::deserialize(d)?;
        match value {
            None => Ok(Self::Always),
            Some(w) => match w.operator.as_str() {
                "exists" => Ok(Self::Exists {
                    source_step_id: w.source_step_id,
                    pointer: w.pointer,
                }),
                "equals" => Ok(Self::JsonPointerEquals {
                    source_step_id: w.source_step_id,
                    pointer: w.pointer,
                    expected: w.value,
                }),
                "contains" => Ok(Self::Contains {
                    source_step_id: w.source_step_id,
                    pointer: w.pointer,
                    expected: w.value,
                }),
                _ => Err(serde::de::Error::custom("invalid condition operator")),
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "mode",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum ValidationRule {
    RequiredPass { evidence_kinds: Vec<String> },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PolicyStep {
    pub id: String,
    pub predecessor_id: Option<String>,
    pub purpose: StepPurpose,
    pub role_id: Option<String>,
    pub agent_id: Option<String>,
    pub model_id: Option<String>,
    pub reasoning_level: Option<ReasoningLevel>,
    pub context_step_ids: Vec<String>,
    pub max_context_bytes: usize,
    pub output_mode: OutputMode,
    pub timeout_ms: u64,
    pub max_attempts: u32,
    pub failure_action: FailureAction,
    pub approval: ApprovalRule,
    pub condition: Condition,
    pub validation: Option<ValidationRule>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompileErrorCode {
    DuplicateStepId,
    MissingPredecessor,
    Cycle,
    LimitExceeded,
    InvalidCondition,
    PrivacyViolation,
    InvalidPolicy,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompileError(CompileErrorCode);
impl CompileError {
    pub fn code(&self) -> CompileErrorCode {
        self.0
    }
}

#[derive(Clone, Debug)]
pub struct CompileMetrics {
    pub visited_steps: usize,
    pub indexed_steps: usize,
}
#[derive(Clone, Debug)]
pub struct CompiledPolicy {
    source: PolicyDocument,
    ordered: Vec<PolicyStep>,
    index: HashMap<String, usize>,
    revision: String,
    metrics: CompileMetrics,
}
impl CompiledPolicy {
    pub fn compile(source: PolicyDocument) -> Result<Self, CompileError> {
        if source.schema_version != 3 || source.workflow.steps.len() > MAX_POLICY_STEPS {
            return Err(CompileError(CompileErrorCode::LimitExceeded));
        }
        let mut index = HashMap::with_capacity(source.workflow.steps.len());
        for (position, step) in source.workflow.steps.iter().enumerate() {
            validate_step(step)?;
            if index.insert(step.id.clone(), position).is_some() {
                return Err(CompileError(CompileErrorCode::DuplicateStepId));
            }
        }
        for (position, step) in source.workflow.steps.iter().enumerate() {
            if let Some(predecessor) = &step.predecessor_id {
                let Some(&before) = index.get(predecessor) else {
                    return Err(CompileError(CompileErrorCode::MissingPredecessor));
                };
                if before >= position {
                    return Err(CompileError(CompileErrorCode::Cycle));
                }
            }
            for context in &step.context_step_ids {
                let Some(&before) = index.get(context) else {
                    return Err(CompileError(CompileErrorCode::MissingPredecessor));
                };
                if before >= position {
                    return Err(CompileError(CompileErrorCode::Cycle));
                }
            }
            match &step.condition {
                Condition::Always => {}
                Condition::Exists {
                    source_step_id,
                    pointer,
                }
                | Condition::JsonPointerEquals {
                    source_step_id,
                    pointer,
                    ..
                }
                | Condition::Contains {
                    source_step_id,
                    pointer,
                    ..
                } => {
                    let Some(&before) = index.get(source_step_id) else {
                        return Err(CompileError(CompileErrorCode::InvalidCondition));
                    };
                    if before >= position || !valid_pointer(pointer) {
                        return Err(CompileError(CompileErrorCode::InvalidCondition));
                    }
                }
            }
        }
        let encoded = serde_json::to_vec(&source)
            .map_err(|_| CompileError(CompileErrorCode::InvalidPolicy))?;
        let revision = format!("{:x}", Sha256::digest(encoded));
        let metrics = CompileMetrics {
            visited_steps: source.workflow.steps.len(),
            indexed_steps: index.len(),
        };
        Ok(Self {
            ordered: source.workflow.steps.clone(),
            source,
            index,
            revision,
            metrics,
        })
    }
    pub fn ordered_steps(&self) -> &[PolicyStep] {
        &self.ordered
    }
    pub fn step_index(&self) -> &HashMap<String, usize> {
        &self.index
    }
    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.index.get(id).copied()
    }
    pub fn revision_digest(&self) -> &str {
        &self.revision
    }
    pub fn source_policy(&self) -> &PolicyDocument {
        &self.source
    }
    pub fn compile_metrics(&self) -> &CompileMetrics {
        &self.metrics
    }
}

fn bounded(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && !privacy_unsafe(s)
}
fn privacy_unsafe(s: &str) -> bool {
    let v = s.to_ascii_lowercase();
    [
        "credential=",
        "password=",
        "secret=",
        "nativesessionid",
        "prompt:",
        "reasoning:",
    ]
    .iter()
    .any(|x| v.contains(x))
        || s.starts_with('/')
}
fn valid_pointer(p: &str) -> bool {
    p.len() <= 2048
        && (p.is_empty() || p.starts_with('/'))
        && p.split('/').skip(1).count() <= MAX_JSON_POINTER_SEGMENTS
}
fn validate_step(s: &PolicyStep) -> Result<(), CompileError> {
    let strings = s
        .role_id
        .iter()
        .map(|x| (x.as_str(), 128))
        .chain(s.agent_id.iter().map(|x| (x.as_str(), 256)))
        .chain(s.model_id.iter().map(|x| (x.as_str(), 256)));
    if s.role_id
        .iter()
        .chain(s.agent_id.iter())
        .chain(s.model_id.iter())
        .any(|x| privacy_unsafe(x))
    {
        return Err(CompileError(CompileErrorCode::PrivacyViolation));
    }
    if !bounded(&s.id, 128)
        || strings.clone().any(|(x, m)| !bounded(x, m))
        || s.timeout_ms == 0
        || s.timeout_ms > MAX_STEP_TIMEOUT_MS
        || s.max_attempts == 0
        || s.max_attempts > MAX_STEP_ATTEMPTS
        || s.max_context_bytes == 0
        || s.max_context_bytes > 262_144
        || s.context_step_ids.len() > 256
    {
        return Err(CompileError(CompileErrorCode::LimitExceeded));
    }
    let mut seen = HashSet::new();
    if s.context_step_ids
        .iter()
        .any(|x| !bounded(x, 128) || !seen.insert(x))
    {
        return Err(CompileError(CompileErrorCode::LimitExceeded));
    }
    if s.purpose == StepPurpose::Validation && s.validation.is_none() {
        return Err(CompileError(CompileErrorCode::InvalidPolicy));
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkflowState {
    Created,
    Admitted,
    Running,
    AwaitingApproval,
    Validating,
    Completed,
    Failed,
    Cancelled,
    Unknown,
}
impl WorkflowState {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::Failed | Self::Cancelled | Self::Unknown
        )
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StepState {
    Pending,
    AwaitingApproval,
    Dispatching,
    Running,
    Validating,
    Succeeded,
    Failed,
    Cancelled,
    Unknown,
    Skipped,
}
impl StepState {
    pub fn is_active(self) -> bool {
        matches!(
            self,
            Self::AwaitingApproval | Self::Dispatching | Self::Running | Self::Validating
        )
    }
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Succeeded | Self::Failed | Self::Cancelled | Self::Unknown | Self::Skipped
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ArtifactRef {
    pub opaque_handle: String,
    pub digest: String,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StepSnapshot {
    pub id: String,
    pub state: StepState,
    pub attempts: u32,
    pub deadline_ms: Option<u64>,
    pub approved: bool,
    pub artifact: Option<ArtifactRef>,
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowSnapshot {
    pub workflow_id: String,
    pub policy_revision: String,
    pub state: WorkflowState,
    pub active_step_id: Option<String>,
    pub steps: Vec<StepSnapshot>,
    pub reason_code: Option<String>,
    #[serde(default)]
    pub submit_input: Option<ArtifactRef>,
}
impl WorkflowSnapshot {
    pub fn initial(id: &str, policy: &CompiledPolicy) -> Self {
        Self {
            workflow_id: id.into(),
            policy_revision: policy.revision.clone(),
            state: WorkflowState::Created,
            active_step_id: None,
            steps: policy
                .ordered
                .iter()
                .map(|s| StepSnapshot {
                    id: s.id.clone(),
                    state: StepState::Pending,
                    attempts: 0,
                    deadline_ms: None,
                    approved: false,
                    artifact: None,
                })
                .collect(),
            reason_code: None,
            submit_input: None,
        }
    }
    pub fn step(&self, id: &str) -> Option<&StepSnapshot> {
        self.steps.iter().find(|s| s.id == id)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkflowEvent {
    Admitted {
        input_artifact: ArtifactRef,
    },
    ApprovalRequested {
        step_id: String,
    },
    StepApproved {
        step_id: String,
    },
    ConditionEvaluated {
        step_id: String,
        matched: bool,
    },
    DispatchStarted {
        step_id: String,
        attempt: u32,
        owner_fence: u64,
        absolute_deadline_ms: u64,
    },
    DispatchProvenSucceeded {
        step_id: String,
        artifact_handle: String,
        digest: String,
    },
    StepFailed {
        step_id: String,
        reason_code: String,
    },
    StepCancelled {
        step_id: String,
    },
    StepUnknown {
        step_id: String,
        reason_code: String,
    },
    WorkflowCompleted,
    WorkflowFailed {
        reason_code: String,
    },
    WorkflowCancelled {
        reason_code: String,
    },
    WorkflowUnknown {
        reason_code: String,
    },
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum WorkflowCommand {
    Submit {
        idempotency_key: String,
        workflow_id: String,
        policy: PolicyDocument,
        input_artifact: ArtifactRef,
    },
    Approve {
        idempotency_key: String,
        workflow_id: String,
        step_id: String,
    },
    Cancel {
        idempotency_key: String,
        workflow_id: String,
    },
    Tick {
        idempotency_key: String,
        workflow_id: String,
    },
}
impl WorkflowCommand {
    pub fn key(&self) -> &str {
        match self {
            Self::Submit {
                idempotency_key, ..
            }
            | Self::Approve {
                idempotency_key, ..
            }
            | Self::Cancel {
                idempotency_key, ..
            }
            | Self::Tick {
                idempotency_key, ..
            } => idempotency_key,
        }
    }
    pub fn workflow_id(&self) -> &str {
        match self {
            Self::Submit { workflow_id, .. }
            | Self::Approve { workflow_id, .. }
            | Self::Cancel { workflow_id, .. }
            | Self::Tick { workflow_id, .. } => workflow_id,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkflowReceipt {
    pub workflow_id: String,
    pub state: WorkflowState,
    pub active_step_id: Option<String>,
    pub reason_code: Option<String>,
}
impl From<&WorkflowSnapshot> for WorkflowReceipt {
    fn from(s: &WorkflowSnapshot) -> Self {
        Self {
            workflow_id: s.workflow_id.clone(),
            state: s.state,
            active_step_id: s.active_step_id.clone(),
            reason_code: s.reason_code.clone(),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DispatchRequest {
    pub workflow_id: String,
    pub step_id: String,
    pub role_id: Option<String>,
    pub agent_id: Option<String>,
    pub model_id: Option<String>,
    pub reasoning_level: Option<ReasoningLevel>,
    pub purpose: StepPurpose,
    pub validation: Option<ValidationRule>,
    pub input_artifact: Option<ArtifactRef>,
    pub predecessor_artifacts: Vec<ArtifactRef>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreparedExternalDispatch {
    pub request: DispatchRequest,
    pub step_id: String,
    pub owner_fence: u64,
    pub max_attempts: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ExternalDriveStep {
    Quiescent(WorkflowReceipt),
    Progressed(WorkflowReceipt),
    Ready(PreparedExternalDispatch),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DispatchOutcome {
    Succeeded {
        summary: String,
        digest: String,
    },
    ValidationPassed {
        summary: String,
        digest: String,
    },
    ValidationFailed {
        reason_code: String,
    },
    KnownFailure {
        reason_code: String,
        retryable: bool,
    },
    Unknown {
        reason_code: String,
    },
}
pub trait DispatchPort: Send + Sync {
    fn dispatch(&self, request: DispatchRequest) -> DispatchOutcome;
}
pub trait Clock: Send + Sync {
    fn now_ms(&self) -> u64;
}
#[derive(Clone)]
pub struct ManualClock(Arc<AtomicU64>);
impl ManualClock {
    pub fn new(v: u64) -> Self {
        Self(Arc::new(AtomicU64::new(v)))
    }
    pub fn advance_ms(&self, v: u64) {
        self.0.fetch_add(v, Ordering::SeqCst);
    }
}
impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CrashBoundary {
    BeforeJournalAppend,
    AfterJournalAppend,
    BeforeSnapshotReplace,
    AfterSnapshotReplace,
    BeforeExternalDispatch,
    AfterExternalDispatchBeforeProof,
}
impl CrashBoundary {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BeforeJournalAppend => "before-journal",
            Self::AfterJournalAppend => "after-journal",
            Self::BeforeSnapshotReplace => "before-snapshot",
            Self::AfterSnapshotReplace => "after-snapshot",
            Self::BeforeExternalDispatch => "before-dispatch",
            Self::AfterExternalDispatchBeforeProof => "after-dispatch",
        }
    }
}
pub trait CrashBoundaryInjector: Send + Sync {
    fn should_crash(&self, boundary: CrashBoundary) -> bool;
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineErrorCode {
    NotFound,
    InvalidCommand,
    TerminalState,
    LeaseHeld,
    StaleFence,
    CapacityExceeded,
    Storage,
    CrashInjected,
    Compile,
}
impl From<rusqlite::Error> for EngineErrorCode {
    fn from(_: rusqlite::Error) -> Self {
        Self::Storage
    }
}
impl From<serde_json::Error> for EngineErrorCode {
    fn from(_: serde_json::Error) -> Self {
        Self::Storage
    }
}
#[derive(Clone, Debug)]
pub struct EngineLimits {
    pub max_events_per_page: usize,
    pub max_receipt_summary_bytes: usize,
    pub max_predecessor_context_bytes: usize,
    pub max_receipt_bytes: usize,
    pub lease_duration_ms: u64,
}
impl Default for EngineLimits {
    fn default() -> Self {
        Self {
            max_events_per_page: 64,
            max_receipt_summary_bytes: 256,
            max_predecessor_context_bytes: 262144,
            max_receipt_bytes: 1024,
            lease_duration_ms: 30_000,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventRecord {
    pub cursor: u64,
    pub event: WorkflowEvent,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventPage {
    pub events: Vec<EventRecord>,
    pub next_cursor: u64,
}

pub use engine::PersistentWorkflowEngine;
#[cfg(test)]
mod tests;
