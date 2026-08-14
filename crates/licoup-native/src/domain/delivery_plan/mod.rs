//! LicoUp's native Better Plan-derived delivery authority.
//!
//! The module deliberately has one semantic record (Plan.json) and one
//! mutable record (Checkpoints.json). Plan data is validated before it is
//! admitted, and checkpoint transitions are committed through the same
//! reducer used by callers and by reload. No agent is executed here; this
//! module only owns planning, authorization, eligibility, and recoverable
//! lifecycle state.

use serde::{Deserialize, Deserializer, Serialize, Serializer, de::DeserializeOwned};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const PLAN_SCHEMA: &str = "better-plan.plan/v3";
pub const CHECKPOINT_SCHEMA: &str = "better-plan.checkpoints/v3";
pub const MAX_TASKS: usize = 256;
pub const MAX_SEMANTIC_BYTES: usize = 2 * 1024 * 1024;
pub const PLAN_FILE: &str = "Plan.json";
pub const CHECKPOINT_FILE: &str = "Checkpoints.json";

const DESIGNER_ROLE: &str = "designer";
const REVIEWER_ROLE: &str = "reviewer";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Parse,
    Schema,
    Validation,
    Dossier,
    Designer,
    Readiness,
    Authorization,
    Continuation,
    Eligibility,
    Dispatch,
    Acceptance,
    Reviewer,
    Persistence,
    Recovery,
    Cancellation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PlanError {
    pub stage: Stage,
    pub code: String,
    #[serde(skip_serializing)]
    pub detail: String,
}

impl PlanError {
    fn new(stage: Stage, code: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            stage,
            code: code.into(),
            detail: detail.into(),
        }
    }

    pub fn code(&self) -> &str {
        &self.code
    }
}

impl fmt::Display for PlanError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.code, self.detail)
    }
}

impl std::error::Error for PlanError {}

impl From<io::Error> for PlanError {
    fn from(error: io::Error) -> Self {
        Self::new(
            Stage::Persistence,
            "private_write_failed",
            error.to_string(),
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PlanPhase {
    Draft,
    Designing,
    Ready,
    Authorized,
    Revising,
    Reviewing,
    Completed,
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TaskStatus {
    #[serde(rename = "pending")]
    Pending,
    #[serde(rename = "in-progress")]
    InProgress,
    #[serde(rename = "completed")]
    Completed,
    #[serde(rename = "blocked-by-authority")]
    BlockedByAuthority,
    #[serde(rename = "blocked-by-environment")]
    BlockedByEnvironment,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DispatchPhase {
    #[serde(rename = "worker_running")]
    WorkerRunning,
    #[serde(rename = "worker_correction")]
    WorkerCorrection,
    #[serde(rename = "awaiting_acceptance")]
    AwaitingAcceptance,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Role {
    #[serde(rename = "designer")]
    Designer,
    #[serde(rename = "worker")]
    Worker,
    #[serde(rename = "reviewer")]
    Reviewer,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scope {
    #[serde(default)]
    pub r#in: Vec<String>,
    #[serde(default)]
    pub out: Vec<String>,
}

impl Default for Scope {
    fn default() -> Self {
        Self {
            r#in: Vec::new(),
            out: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Intent {
    #[serde(default)]
    pub goal: String,
    #[serde(default)]
    pub risk_authority: Vec<String>,
    #[serde(default)]
    pub scope: Scope,
}

impl Default for Intent {
    fn default() -> Self {
        Self {
            goal: String::new(),
            risk_authority: Vec::new(),
            scope: Scope::default(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DecisionOption {
    pub id: String,
    #[serde(default)]
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DecisionQuestion {
    pub code: String,
    #[serde(default)]
    pub question: String,
    #[serde(default)]
    pub context: String,
    #[serde(default)]
    pub options: Vec<DecisionOption>,
    #[serde(default)]
    pub default: Option<String>,
    #[serde(default)]
    pub selected: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DossierStatus {
    Open,
    Resolved,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Dossier {
    #[serde(default = "default_dossier_status")]
    pub status: DossierStatus,
    #[serde(default)]
    pub questions: Vec<DecisionQuestion>,
}

fn default_dossier_status() -> DossierStatus {
    DossierStatus::Open
}

impl Default for Dossier {
    fn default() -> Self {
        Self {
            status: DossierStatus::Open,
            questions: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Requirement {
    pub code: String,
    #[serde(default)]
    pub statement: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RepositoryReference {
    pub path: String,
    #[serde(default)]
    pub purpose: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Output {
    pub code: String,
    #[serde(default)]
    pub title: String,
    pub produced_by: String,
    #[serde(default)]
    pub references: Vec<RepositoryReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AcceptanceCriterion {
    pub code: String,
    #[serde(default)]
    pub statement: String,
    #[serde(default)]
    pub task: Option<String>,
    #[serde(default)]
    pub requirement: Option<String>,
    #[serde(default)]
    pub output: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ExecutionPolicy {
    #[serde(default)]
    pub max_attempts: u32,
    #[serde(default)]
    pub allowed_effects: Vec<String>,
}

impl Default for ExecutionPolicy {
    fn default() -> Self {
        Self {
            max_attempts: 1,
            allowed_effects: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoleContract {
    pub role: Role,
    #[serde(default)]
    pub authority: String,
    #[serde(default)]
    pub execution_policy: ExecutionPolicy,
    #[serde(default)]
    pub references: Vec<RepositoryReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Prerequisite {
    pub from: String,
    pub output: String,
    pub guarantee_input: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Task {
    pub code: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub contract: String,
    #[serde(default)]
    pub requirements: Vec<String>,
    #[serde(default)]
    pub outputs: Vec<String>,
    #[serde(default)]
    pub acceptance_criteria: Vec<String>,
    #[serde(default)]
    pub prerequisites: Vec<Prerequisite>,
    #[serde(default)]
    pub owned_writes: Vec<String>,
    #[serde(default)]
    pub references: Vec<RepositoryReference>,
    #[serde(default)]
    pub execution_policy: ExecutionPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub schema: String,
    pub code: String,
    pub title: String,
    pub directory: String,
    pub intent: Intent,
    pub dossier: Dossier,
    pub requirements: Vec<Requirement>,
    pub outputs: Vec<Output>,
    pub acceptance_criteria: Vec<AcceptanceCriterion>,
    pub roles: Vec<RoleContract>,
    pub tasks: Vec<Task>,
    pub execution_policy: ExecutionPolicy,
    pub references: Vec<RepositoryReference>,
    current_document: Option<Value>,
    runtime_phase: PlanPhase,
}

impl Plan {
    pub fn new(code: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            schema: PLAN_SCHEMA.to_string(),
            code: code.into(),
            title: title.into(),
            directory: String::new(),
            intent: Intent::default(),
            dossier: Dossier::default(),
            requirements: Vec::new(),
            outputs: Vec::new(),
            acceptance_criteria: Vec::new(),
            roles: vec![
                RoleContract {
                    role: Role::Designer,
                    authority: DESIGNER_ROLE.to_string(),
                    execution_policy: ExecutionPolicy::default(),
                    references: Vec::new(),
                },
                RoleContract {
                    role: Role::Worker,
                    authority: "worker".to_string(),
                    execution_policy: ExecutionPolicy::default(),
                    references: Vec::new(),
                },
                RoleContract {
                    role: Role::Reviewer,
                    authority: REVIEWER_ROLE.to_string(),
                    execution_policy: ExecutionPolicy::default(),
                    references: Vec::new(),
                },
            ],
            tasks: Vec::new(),
            execution_policy: ExecutionPolicy::default(),
            references: Vec::new(),
            current_document: None,
            runtime_phase: PlanPhase::Draft,
        }
    }

    pub fn from_json_str(value: &str) -> Result<Self, PlanError> {
        let parsed: Value = serde_json::from_str(value)
            .map_err(|error| PlanError::new(Stage::Parse, "invalid_json", error.to_string()))?;
        let object = parsed.as_object().ok_or_else(|| {
            PlanError::new(
                Stage::Parse,
                "plan_not_object",
                "Plan.json must be an object",
            )
        })?;
        let schema = object
            .get("schema")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if schema != PLAN_SCHEMA {
            return Err(PlanError::new(
                Stage::Schema,
                "unsupported_schema",
                "only the current native Plan generation is accepted",
            ));
        }
        let plan = plan_from_current_value(parsed)?;
        plan.validate()?;
        Ok(plan)
    }

    pub fn to_json(&self) -> Result<String, PlanError> {
        serde_json::to_string_pretty(&self.current_value(None)?)
            .map(|text| format!("{text}\n"))
            .map_err(|error| PlanError::new(Stage::Parse, "plan_encode_failed", error.to_string()))
    }

    pub fn semantic_digest(&self) -> Result<String, PlanError> {
        let value = self.current_value(None)?;
        let object = value.as_object().ok_or_else(|| {
            PlanError::new(Stage::Parse, "plan_encode_failed", "Plan is not an object")
        })?;
        let semantic = json_object([
            (
                "schema",
                object.get("schema").cloned().unwrap_or(Value::Null),
            ),
            ("code", object.get("code").cloned().unwrap_or(Value::Null)),
            ("title", object.get("title").cloned().unwrap_or(Value::Null)),
            (
                "intent",
                object.get("intent").cloned().unwrap_or(Value::Null),
            ),
            (
                "ledger",
                object.get("ledger").cloned().unwrap_or(Value::Null),
            ),
            (
                "dossier",
                object.get("dossier").cloned().unwrap_or(Value::Null),
            ),
            ("spec", object.get("spec").cloned().unwrap_or(Value::Null)),
        ]);
        Ok(sha256_hex(canonical_json(&semantic).as_bytes()))
    }

    pub fn validate(&self) -> Result<(), PlanError> {
        validate_plan(self)
    }

    fn current_value(&self, checkpoints: Option<&Checkpoints>) -> Result<Value, PlanError> {
        let mut value = if let Some(document) = &self.current_document {
            document.clone()
        } else {
            current_value_from_projection(self)
        };
        let object = value.as_object_mut().ok_or_else(|| {
            PlanError::new(Stage::Parse, "plan_encode_failed", "Plan is not an object")
        })?;
        object.insert(
            "phase".to_owned(),
            Value::String(plan_phase_name(self.runtime_phase).to_owned()),
        );
        if let Some(checkpoints) = checkpoints {
            object.insert(
                "lifecycle".to_owned(),
                lifecycle_value(checkpoints, self.runtime_phase),
            );
        }
        Ok(value)
    }

    fn sync_current_dossier(&mut self) -> Result<(), PlanError> {
        let Some(document) = self.current_document.as_mut() else {
            return Ok(());
        };
        let dossier = document
            .get_mut("dossier")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Dossier,
                    "invalid_plan_shape",
                    "current dossier is missing",
                )
            })?;
        dossier.insert(
            "status".to_owned(),
            Value::String(
                match self.dossier.status {
                    DossierStatus::Open => "draft",
                    DossierStatus::Resolved => "resolved",
                }
                .to_owned(),
            ),
        );
        let questions = dossier
            .get_mut("questions")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Dossier,
                    "invalid_plan_shape",
                    "current dossier questions are missing",
                )
            })?;
        for projected in &self.dossier.questions {
            let question = questions
                .iter_mut()
                .find(|question| {
                    question.get("code").and_then(Value::as_str) == Some(projected.code.as_str())
                })
                .and_then(Value::as_object_mut)
                .ok_or_else(|| {
                    PlanError::new(Stage::Dossier, "invalid_plan_shape", projected.code.clone())
                })?;
            question.insert(
                "selected".to_owned(),
                projected
                    .selected
                    .as_ref()
                    .map_or(Value::Null, |selected| Value::String(selected.clone())),
            );
        }

        // Dossier selections are semantic Plan data. Keep the current ledger
        // projection in lockstep so the sealed digest cannot describe a
        // decision that the persisted Plan does not contain.
        let selected = self
            .dossier
            .questions
            .iter()
            .filter_map(|question| {
                let option_id = question.selected.as_ref()?;
                let raw_question = questions.iter().find(|raw| {
                    raw.get("code").and_then(Value::as_str) == Some(question.code.as_str())
                })?;
                let option = raw_question
                    .get("options")?
                    .as_array()?
                    .iter()
                    .find(|option| {
                        option.get("id").and_then(Value::as_str) == Some(option_id.as_str())
                    })?;
                Some(json!({
                    "source": question.code,
                    "option": option_id,
                    "resolves": raw_question.get("resolves").cloned().unwrap_or_else(|| json!([])),
                    "effects": option.get("effects").cloned().unwrap_or_else(|| json!([]))
                }))
            })
            .collect::<Vec<_>>();
        let ledger = document
            .get_mut("ledger")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Dossier,
                    "invalid_plan_shape",
                    "current decision ledger is missing",
                )
            })?;
        ledger.insert("user_decided".to_owned(), Value::Array(selected));
        Ok(())
    }

    fn sync_current_task(&mut self, task_code: &str) -> Result<(), PlanError> {
        let Some(document) = self.current_document.as_mut() else {
            return Ok(());
        };
        let projected = self
            .tasks
            .iter()
            .find(|task| task.code == task_code)
            .ok_or_else(|| PlanError::new(Stage::Continuation, "task_out_of_scope", task_code))?;
        let tasks = document
            .pointer_mut("/spec/tasks")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Continuation,
                    "invalid_plan_shape",
                    "current Task set is missing",
                )
            })?;
        let task = tasks
            .iter_mut()
            .find(|task| task.get("code").and_then(Value::as_str) == Some(task_code))
            .and_then(Value::as_object_mut)
            .ok_or_else(|| PlanError::new(Stage::Continuation, "task_out_of_scope", task_code))?;
        task.insert("title".to_owned(), Value::String(projected.title.clone()));
        task.insert(
            "outcome".to_owned(),
            Value::String(projected.contract.clone()),
        );
        task.insert("requirements".to_owned(), json!(projected.requirements));
        task.insert(
            "prerequisites".to_owned(),
            json!(
                projected
                    .prerequisites
                    .iter()
                    .map(|prerequisite| prerequisite.from.as_str())
                    .collect::<Vec<_>>()
            ),
        );
        task.insert(
            "inputs".to_owned(),
            Value::Array(
                projected
                    .prerequisites
                    .iter()
                    .map(|prerequisite| {
                        json!({
                            "from": prerequisite.from,
                            "output": prerequisite.output,
                            "guarantee": prerequisite.guarantee_input
                        })
                    })
                    .collect(),
            ),
        );
        reorder_current_objects(task, "outputs", &projected.outputs, Stage::Continuation)?;
        reorder_current_objects(
            task,
            "acceptance",
            &projected.acceptance_criteria,
            Stage::Continuation,
        )?;
        let ownership = task
            .get_mut("ownership")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Continuation,
                    "invalid_plan_shape",
                    "current Task ownership is missing",
                )
            })?;
        ownership.insert("write_paths".to_owned(), json!(projected.owned_writes));
        Ok(())
    }

    fn lifecycle_session(&self, key: &str, role: Role) -> Option<SessionCheckpoint> {
        let value = self.current_document.as_ref()?.get("lifecycle")?.get(key)?;
        if value.is_null() {
            return None;
        }
        let object = value.as_object()?;
        let status = object
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let completed = status == "completed"
            || object.get("agent_returned").and_then(Value::as_bool) == Some(true);
        Some(SessionCheckpoint {
            role,
            opened: true,
            completed,
            conversation_location: optional_string(
                object
                    .get("native_conversation_location")
                    .or_else(|| object.get("conversation_location")),
            ),
            receipt: optional_string(object.get("id")),
            opened_at: optional_string(object.get("opened_at")),
            completed_at: optional_string(
                object
                    .get("closed_at")
                    .or_else(|| object.get("completed_at")),
            ),
        })
    }
}

impl Serialize for Plan {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.current_value(None)
            .map_err(serde::ser::Error::custom)?
            .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Plan {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        plan_from_current_value(value).map_err(serde::de::Error::custom)
    }
}

fn plan_from_current_value(value: Value) -> Result<Plan, PlanError> {
    let object = value.as_object().ok_or_else(|| {
        PlanError::new(
            Stage::Parse,
            "plan_not_object",
            "Plan.json must be an object",
        )
    })?;
    require_exact_keys(
        object,
        &[
            "schema",
            "code",
            "title",
            "directory",
            "phase",
            "intent",
            "ledger",
            "dossier",
            "spec",
            "lifecycle",
        ],
        Stage::Parse,
    )?;
    let schema = required_string(object, "schema", Stage::Schema)?;
    if schema != PLAN_SCHEMA {
        return Err(PlanError::new(
            Stage::Schema,
            "unsupported_schema",
            "only the current Better Plan generation is accepted",
        ));
    }
    let code = required_string(object, "code", Stage::Validation)?;
    let title = required_string(object, "title", Stage::Validation)?;
    let directory = required_string(object, "directory", Stage::Validation)?;
    let runtime_phase = parse_plan_phase(required_string(object, "phase", Stage::Validation)?)?;

    let intent_value = required_object(object, "intent", Stage::Validation)?;
    let scope_value = required_object(intent_value, "scope", Stage::Validation)?;
    let intent = Intent {
        goal: required_string(intent_value, "goal", Stage::Validation)?.to_owned(),
        risk_authority: string_array(intent_value.get("risk_boundary"), Stage::Validation)?,
        scope: Scope {
            r#in: string_array(scope_value.get("in"), Stage::Validation)?,
            out: string_array(scope_value.get("out"), Stage::Validation)?,
        },
    };

    let dossier_value = required_object(object, "dossier", Stage::Dossier)?;
    let dossier_status = match required_string(dossier_value, "status", Stage::Dossier)? {
        "resolved" => DossierStatus::Resolved,
        "draft" => DossierStatus::Open,
        "not_required" => DossierStatus::Resolved,
        _ => {
            return Err(PlanError::new(
                Stage::Dossier,
                "invalid_dossier_status",
                "unsupported dossier status",
            ));
        }
    };
    let questions = required_array(dossier_value, "questions", Stage::Dossier)?
        .iter()
        .map(|question| {
            let question = question.as_object().ok_or_else(|| {
                PlanError::new(
                    Stage::Dossier,
                    "invalid_plan_shape",
                    "question must be an object",
                )
            })?;
            let options = required_array(question, "options", Stage::Dossier)?
                .iter()
                .map(|option| {
                    let option = option.as_object().ok_or_else(|| {
                        PlanError::new(
                            Stage::Dossier,
                            "invalid_plan_shape",
                            "option must be an object",
                        )
                    })?;
                    Ok(DecisionOption {
                        id: required_string(option, "id", Stage::Dossier)?.to_owned(),
                        label: required_string(option, "label", Stage::Dossier)?.to_owned(),
                    })
                })
                .collect::<Result<Vec<_>, PlanError>>()?;
            Ok(DecisionQuestion {
                code: required_string(question, "code", Stage::Dossier)?.to_owned(),
                question: required_string(question, "question", Stage::Dossier)?.to_owned(),
                context: required_string(question, "context", Stage::Dossier)?.to_owned(),
                options,
                default: optional_string(question.get("default")),
                selected: optional_string(question.get("selected")),
            })
        })
        .collect::<Result<Vec<_>, PlanError>>()?;

    let spec = required_object(object, "spec", Stage::Validation)?;
    require_exact_keys(
        spec,
        &["requirements", "architecture", "tasks", "full_regression"],
        Stage::Validation,
    )?;
    validate_regression(
        required_object(spec, "full_regression", Stage::Validation)?,
        "missing_full_regression",
    )?;
    let requirements = required_array(spec, "requirements", Stage::Validation)?
        .iter()
        .map(|requirement| {
            let requirement = requirement.as_object().ok_or_else(|| {
                PlanError::new(
                    Stage::Validation,
                    "invalid_plan_shape",
                    "requirement must be an object",
                )
            })?;
            Ok(Requirement {
                code: required_string(requirement, "code", Stage::Validation)?.to_owned(),
                statement: required_string(requirement, "statement", Stage::Validation)?.to_owned(),
            })
        })
        .collect::<Result<Vec<_>, PlanError>>()?;

    let mut outputs = Vec::new();
    let mut acceptance_criteria = Vec::new();
    let mut tasks = Vec::new();
    for task_value in required_array(spec, "tasks", Stage::Validation)? {
        let task = task_value.as_object().ok_or_else(|| {
            PlanError::new(
                Stage::Validation,
                "invalid_plan_shape",
                "Task must be an object",
            )
        })?;
        let task_code = required_string(task, "code", Stage::Validation)?.to_owned();
        let focused = required_object(task, "focused_regression", Stage::Validation)?;
        validate_regression(focused, "missing_focused_regression")?;
        let _focused_paths = string_array(focused.get("paths"), Stage::Validation)?;
        let task_outputs = required_array(task, "outputs", Stage::Validation)?;
        let mut task_output_codes = Vec::new();
        for output in task_outputs {
            let output = output.as_object().ok_or_else(|| {
                PlanError::new(
                    Stage::Validation,
                    "invalid_plan_shape",
                    "output must be an object",
                )
            })?;
            let output_code = required_string(output, "code", Stage::Validation)?.to_owned();
            let artifact = required_string(output, "artifact", Stage::Validation)?.to_owned();
            task_output_codes.push(output_code.clone());
            outputs.push(Output {
                code: output_code,
                title: required_string(output, "title", Stage::Validation)?.to_owned(),
                produced_by: task_code.clone(),
                references: vec![RepositoryReference {
                    path: artifact,
                    purpose: "artifact".to_owned(),
                }],
            });
        }
        let task_acceptance = required_array(task, "acceptance", Stage::Validation)?;
        let mut task_acceptance_codes = Vec::new();
        for criterion in task_acceptance {
            let criterion = criterion.as_object().ok_or_else(|| {
                PlanError::new(
                    Stage::Validation,
                    "invalid_plan_shape",
                    "acceptance must be an object",
                )
            })?;
            let criterion_code = required_string(criterion, "code", Stage::Validation)?.to_owned();
            let covers = string_array(criterion.get("covers"), Stage::Validation)?;
            task_acceptance_codes.push(criterion_code.clone());
            acceptance_criteria.push(AcceptanceCriterion {
                code: criterion_code,
                statement: required_string(criterion, "then", Stage::Validation)?.to_owned(),
                task: Some(task_code.clone()),
                requirement: covers.iter().find(|code| code.starts_with("REQ-")).cloned(),
                output: covers.iter().find(|code| code.starts_with("OUT-")).cloned(),
            });
        }
        let prerequisite_codes = string_array(task.get("prerequisites"), Stage::Validation)?;
        let inputs = required_array(task, "inputs", Stage::Validation)?;
        let mut prerequisites = Vec::new();
        for prerequisite in prerequisite_codes {
            let matches = inputs
                .iter()
                .filter_map(Value::as_object)
                .filter(|input| {
                    input.get("from").and_then(Value::as_str) == Some(prerequisite.as_str())
                })
                .collect::<Vec<_>>();
            if matches.len() != 1 {
                return Err(PlanError::new(
                    Stage::Validation,
                    "missing_or_duplicate_edge_input",
                    prerequisite,
                ));
            }
            prerequisites.push(Prerequisite {
                from: prerequisite,
                output: required_string(matches[0], "output", Stage::Validation)?.to_owned(),
                guarantee_input: required_string(matches[0], "guarantee", Stage::Validation)?
                    .to_owned(),
            });
        }
        if inputs.len() != prerequisites.len() {
            return Err(PlanError::new(
                Stage::Validation,
                "orphan_edge_input",
                task_code,
            ));
        }
        let ownership = required_object(task, "ownership", Stage::Validation)?;
        tasks.push(Task {
            code: task_code,
            title: required_string(task, "title", Stage::Validation)?.to_owned(),
            contract: required_string(task, "outcome", Stage::Validation)?.to_owned(),
            requirements: string_array(task.get("requirements"), Stage::Validation)?,
            outputs: task_output_codes,
            acceptance_criteria: task_acceptance_codes,
            prerequisites,
            owned_writes: string_array(ownership.get("write_paths"), Stage::Validation)?,
            references: Vec::new(),
            execution_policy: ExecutionPolicy::default(),
        });
    }
    let full_regression = required_object(spec, "full_regression", Stage::Validation)?;
    let references = string_array(full_regression.get("paths"), Stage::Validation)?
        .into_iter()
        .map(|path| RepositoryReference {
            path,
            purpose: "full-regression".to_owned(),
        })
        .collect();
    let plan = Plan {
        schema: schema.to_owned(),
        code: code.to_owned(),
        title: title.to_owned(),
        directory: directory.to_owned(),
        intent,
        dossier: Dossier {
            status: dossier_status,
            questions,
        },
        requirements,
        outputs,
        acceptance_criteria,
        roles: default_role_contracts(),
        tasks,
        execution_policy: ExecutionPolicy::default(),
        references,
        current_document: Some(value),
        runtime_phase,
    };
    Ok(plan)
}

fn current_value_from_projection(plan: &Plan) -> Value {
    let selected = plan
        .dossier
        .questions
        .iter()
        .filter_map(|question| {
            question
                .selected
                .as_ref()
                .map(|selected| (question, selected))
        })
        .map(|(question, selected)| {
            json!({
                "source": question.code,
                "option": selected,
                "resolves": [],
                "effects": []
            })
        })
        .collect::<Vec<_>>();
    let questions = plan
        .dossier
        .questions
        .iter()
        .map(|question| {
            json!({
                "code": question.code,
                "question": question.question,
            "context": if question.context.trim().is_empty() {
                question.question.as_str()
            } else {
                question.context.as_str()
            },
                "resolves": [],
                "options": question.options.iter().map(|option| json!({
                    "id": option.id,
                    "label": option.label,
                    "effects": []
                })).collect::<Vec<_>>(),
                "recommended": question.default,
                "default": question.default,
                "selected": question.selected
            })
        })
        .collect::<Vec<_>>();
    let tasks = plan
        .tasks
        .iter()
        .map(|task| {
            let outputs = task
                .outputs
                .iter()
                .filter_map(|code| plan.outputs.iter().find(|output| &output.code == code))
                .map(|output| json!({
                    "code": output.code,
                    "title": output.title,
                    "artifact": output.references.first().map(|reference| reference.path.clone()).unwrap_or_else(|| "crates/licoup-native".to_owned()),
                    "guarantee": task.contract
                }))
                .collect::<Vec<_>>();
            let acceptance = task
                .acceptance_criteria
                .iter()
                .filter_map(|code| plan.acceptance_criteria.iter().find(|criterion| &criterion.code == code))
                .map(|criterion| {
                    let covers = [criterion.requirement.clone(), criterion.output.clone()]
                        .into_iter()
                        .flatten()
                        .collect::<Vec<_>>();
                    json!({
                        "code": criterion.code,
                        "covers": covers,
                        "given": "A validated native delivery",
                        "when": "The focused transition runs",
                        "then": criterion.statement,
                        "oracle": criterion.statement,
                        "evidence": {"type": "command", "source": "native focused regression"}
                    })
                })
                .collect::<Vec<_>>();
            let paths = if task.references.is_empty() {
                task.owned_writes.clone()
            } else {
                task.references.iter().map(|reference| reference.path.clone()).collect()
            };
            json!({
                "code": task.code,
                "title": task.title,
                "outcome": task.contract,
                "scope": {"in": task.owned_writes, "out": []},
                "prerequisites": task.prerequisites.iter().map(|edge| edge.from.clone()).collect::<Vec<_>>(),
                "inputs": task.prerequisites.iter().map(|edge| json!({"from": edge.from, "output": edge.output, "guarantee": edge.guarantee_input})).collect::<Vec<_>>(),
                "outputs": outputs,
                "ownership": {"write_paths": task.owned_writes, "shared_exclusive": []},
                "difficulty": "standard",
                "verification": "code",
                "requirements": task.requirements,
                "risks": [],
                "design": {"interfaces": [task.contract]},
                "acceptance": acceptance,
                "focused_regression": {"commands": ["cargo test -p licoup-native"], "paths": paths}
            })
        })
        .collect::<Vec<_>>();
    let full_paths = if plan.references.is_empty() {
        vec!["crates/licoup-native".to_owned()]
    } else {
        plan.references
            .iter()
            .map(|reference| reference.path.clone())
            .collect()
    };
    json!({
        "schema": PLAN_SCHEMA,
        "code": plan.code,
        "title": plan.title,
        "directory": if plan.directory.is_empty() { "delivery" } else { &plan.directory },
        "phase": plan_phase_name(plan.runtime_phase),
        "intent": {
            "goal": if plan.intent.goal.trim().is_empty() { &plan.title } else { &plan.intent.goal },
            "scope": {"in": plan.intent.scope.r#in, "out": plan.intent.scope.out},
            "success": [plan.title],
            "risk_boundary": plan.intent.risk_authority,
            "autonomy": {
                "allow_in_scope_revision": true,
                "allow_reviewer_repairs": true,
                "blocked_branch_policy": "continue_independent_work",
                "forbid_mid_execution_questions": true
            }
        },
        "ledger": {"observed": [], "user_decided": selected, "defaulted": [], "unresolved": []},
        "dossier": {
            "status": if plan.dossier.status == DossierStatus::Resolved { "resolved" } else { "draft" },
            "questions": questions
        },
        "spec": {
            "requirements": plan.requirements.iter().map(|requirement| json!({"code": requirement.code, "statement": requirement.statement, "source_refs": ["native"]})).collect::<Vec<_>>(),
            "architecture": {"summary": plan.title, "notes": ["LicoUp native delivery authority"]},
            "tasks": tasks,
            "full_regression": {"commands": ["cargo test -p licoup-native"], "paths": full_paths}
        },
        "lifecycle": {"authorization": null, "continuation_receipts": [], "designer_session": null, "reviewer_session": null, "sealed": null}
    })
}

fn reorder_current_objects(
    object: &mut serde_json::Map<String, Value>,
    field: &str,
    codes: &[String],
    stage: Stage,
) -> Result<(), PlanError> {
    let values = object.get(field).and_then(Value::as_array).ok_or_else(|| {
        PlanError::new(stage, "invalid_plan_shape", format!("{field} is missing"))
    })?;
    let mut by_code = values
        .iter()
        .filter_map(|value| {
            value
                .get("code")
                .and_then(Value::as_str)
                .map(|code| (code.to_owned(), value.clone()))
        })
        .collect::<BTreeMap<_, _>>();
    if by_code.len() != values.len()
        || by_code.len() != codes.len()
        || codes.iter().any(|code| !by_code.contains_key(code))
    {
        return Err(PlanError::new(
            stage,
            "continuation_rich_contract_required",
            format!("{field} codes must remain exact in the current Plan generation"),
        ));
    }
    object.insert(
        field.to_owned(),
        Value::Array(
            codes
                .iter()
                .map(|code| by_code.remove(code).expect("exact set checked"))
                .collect(),
        ),
    );
    Ok(())
}

fn default_role_contracts() -> Vec<RoleContract> {
    vec![
        RoleContract {
            role: Role::Designer,
            authority: DESIGNER_ROLE.to_owned(),
            execution_policy: ExecutionPolicy::default(),
            references: Vec::new(),
        },
        RoleContract {
            role: Role::Worker,
            authority: "worker".to_owned(),
            execution_policy: ExecutionPolicy::default(),
            references: Vec::new(),
        },
        RoleContract {
            role: Role::Reviewer,
            authority: REVIEWER_ROLE.to_owned(),
            execution_policy: ExecutionPolicy::default(),
            references: Vec::new(),
        },
    ]
}

fn validate_regression(value: &Map<String, Value>, code: &'static str) -> Result<(), PlanError> {
    let commands = string_array(value.get("commands"), Stage::Validation)?;
    let paths = string_array(value.get("paths"), Stage::Validation)?;
    if commands.is_empty()
        || paths.is_empty()
        || commands.iter().any(|value| value.trim().is_empty())
    {
        return Err(PlanError::new(
            Stage::Validation,
            code,
            "regression contract is empty",
        ));
    }
    for path in paths {
        validate_relative_reference(&path, Stage::Validation)?;
    }
    Ok(())
}

fn require_exact_keys(
    object: &Map<String, Value>,
    keys: &[&str],
    stage: Stage,
) -> Result<(), PlanError> {
    let expected = keys.iter().copied().collect::<BTreeSet<_>>();
    if object.keys().any(|key| !expected.contains(key.as_str())) {
        return Err(PlanError::new(
            stage,
            "unknown_field",
            "unknown current-generation field",
        ));
    }
    if keys.iter().any(|key| !object.contains_key(*key)) {
        return Err(PlanError::new(
            stage,
            "invalid_plan_shape",
            "required field missing",
        ));
    }
    Ok(())
}

fn required_object<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    stage: Stage,
) -> Result<&'a Map<String, Value>, PlanError> {
    object.get(key).and_then(Value::as_object).ok_or_else(|| {
        PlanError::new(
            stage,
            "invalid_plan_shape",
            format!("{key} must be an object"),
        )
    })
}

fn required_array<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    stage: Stage,
) -> Result<&'a Vec<Value>, PlanError> {
    object.get(key).and_then(Value::as_array).ok_or_else(|| {
        PlanError::new(
            stage,
            "invalid_plan_shape",
            format!("{key} must be an array"),
        )
    })
}

fn required_string<'a>(
    object: &'a Map<String, Value>,
    key: &str,
    stage: Stage,
) -> Result<&'a str, PlanError> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| PlanError::new(stage, "invalid_plan_shape", format!("{key} must be text")))
}

fn optional_string(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn string_array(value: Option<&Value>, stage: Stage) -> Result<Vec<String>, PlanError> {
    value
        .and_then(Value::as_array)
        .ok_or_else(|| PlanError::new(stage, "invalid_plan_shape", "expected string array"))?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| {
                    PlanError::new(stage, "invalid_plan_shape", "array item must be text")
                })
        })
        .collect()
}

fn parse_plan_phase(value: &str) -> Result<PlanPhase, PlanError> {
    match value {
        "draft" => Ok(PlanPhase::Draft),
        "designing" => Ok(PlanPhase::Designing),
        "ready" => Ok(PlanPhase::Ready),
        "authorized" => Ok(PlanPhase::Authorized),
        "revising" => Ok(PlanPhase::Revising),
        "reviewing" => Ok(PlanPhase::Reviewing),
        "completed" => Ok(PlanPhase::Completed),
        "blocked" => Ok(PlanPhase::Blocked),
        _ => Err(PlanError::new(
            Stage::Validation,
            "invalid_phase",
            "unsupported Plan phase",
        )),
    }
}

fn plan_phase_name(phase: PlanPhase) -> &'static str {
    match phase {
        PlanPhase::Draft => "draft",
        PlanPhase::Designing => "designing",
        PlanPhase::Ready => "ready",
        PlanPhase::Authorized => "authorized",
        PlanPhase::Revising => "revising",
        PlanPhase::Reviewing => "reviewing",
        PlanPhase::Completed => "completed",
        PlanPhase::Blocked => "blocked",
    }
}

fn json_object<const N: usize>(entries: [(&str, Value); N]) -> Value {
    Value::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Checkpoints {
    pub schema: String,
    pub plan_code: String,
    pub revision: u64,
    pub phase: PlanPhase,
    pub dossier_resolved: bool,
    pub semantic_digest: Option<String>,
    pub designer: Option<SessionCheckpoint>,
    pub reviewer: Option<SessionCheckpoint>,
    pub tasks: BTreeMap<String, TaskCheckpoint>,
    pub dispatches: BTreeMap<String, DispatchCheckpoint>,
    pub next_dispatch_sequence: u64,
    pub cancellation_requested: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionCheckpoint {
    pub role: Role,
    pub opened: bool,
    pub completed: bool,
    #[serde(default)]
    pub conversation_location: Option<String>,
    #[serde(default)]
    pub receipt: Option<String>,
    #[serde(default)]
    pub opened_at: Option<String>,
    #[serde(default)]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskCheckpoint {
    pub status: TaskStatus,
    pub contract_digest: String,
    #[serde(default)]
    pub started_contract_digest: Option<String>,
    #[serde(default)]
    pub completion_receipt: Option<String>,
    #[serde(default)]
    pub blocked_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DispatchCheckpoint {
    pub id: String,
    pub role: Role,
    #[serde(default)]
    pub task_code: Option<String>,
    pub attempt: u32,
    pub phase: DispatchPhase,
    #[serde(default)]
    pub conversation_location: Option<String>,
    #[serde(default)]
    pub receipt: Option<String>,
    pub task_contract_digest: String,
    #[serde(default)]
    pub evidence: Vec<String>,
    #[serde(default)]
    pub failure_code: Option<String>,
}

impl Serialize for Checkpoints {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        checkpoints_current_value(self).serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for Checkpoints {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Value::deserialize(deserializer)?;
        checkpoints_from_current_value(value).map_err(serde::de::Error::custom)
    }
}

fn checkpoints_current_value(checkpoints: &Checkpoints) -> Value {
    let tasks = checkpoints
        .tasks
        .iter()
        .map(|(code, task)| {
            let latest = checkpoints
                .dispatches
                .values()
                .filter(|dispatch| dispatch.task_code.as_deref() == Some(code.as_str()))
                .max_by_key(|dispatch| dispatch.attempt);
            let evidence = latest
                .map(|dispatch| {
                    dispatch
                        .evidence
                        .iter()
                        .cloned()
                        .map(Value::String)
                        .collect()
                })
                .unwrap_or_else(Vec::new);
            json!({
                "code": code,
                "status": task_status_current_name(task.status),
                "dispatch": latest,
                "evidence": evidence,
                "status_reason": task.blocked_reason
            })
        })
        .collect::<Vec<_>>();
    json!({
        "schema": CHECKPOINT_SCHEMA,
        "plan": checkpoints.plan_code,
        "revision": checkpoints.revision,
        "semantic_digest": checkpoints.semantic_digest,
        "delivery_status": checkpoint_delivery_status(checkpoints),
        "tasks": tasks
    })
}

fn checkpoints_from_current_value(value: Value) -> Result<Checkpoints, PlanError> {
    let object = value.as_object().ok_or_else(|| {
        PlanError::new(
            Stage::Recovery,
            "corrupt_checkpoint",
            "checkpoint must be an object",
        )
    })?;
    require_exact_keys(
        object,
        &[
            "schema",
            "plan",
            "revision",
            "semantic_digest",
            "delivery_status",
            "tasks",
        ],
        Stage::Recovery,
    )?;
    if required_string(object, "schema", Stage::Recovery)? != CHECKPOINT_SCHEMA {
        return Err(PlanError::new(
            Stage::Recovery,
            "corrupt_checkpoint",
            "unsupported checkpoint generation",
        ));
    }
    let plan_code = required_string(object, "plan", Stage::Recovery)?.to_owned();
    let revision = object
        .get("revision")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            PlanError::new(Stage::Recovery, "corrupt_checkpoint", "revision is invalid")
        })?;
    let semantic_digest = optional_string(object.get("semantic_digest"));
    let delivery_status = required_string(object, "delivery_status", Stage::Recovery)?;
    let (phase, mut cancellation_requested) = match delivery_status {
        "pending" => (PlanPhase::Draft, false),
        "in_progress" => (PlanPhase::Authorized, false),
        "completed" => (PlanPhase::Completed, false),
        "blocked" => (PlanPhase::Blocked, false),
        // Cancellation is runtime checkpoint state. It deliberately reuses
        // the current v3 shape instead of mutating semantic Plan fields or
        // introducing a compatibility generation.
        "cancelled" => (PlanPhase::Blocked, true),
        _ => {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "delivery status is invalid",
            ));
        }
    };
    let mut tasks = BTreeMap::new();
    let mut dispatches = BTreeMap::new();
    for task_value in required_array(object, "tasks", Stage::Recovery)? {
        let task = task_value.as_object().ok_or_else(|| {
            PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "Task checkpoint must be an object",
            )
        })?;
        let allowed = ["code", "status", "dispatch", "evidence", "status_reason"];
        if task.keys().any(|key| !allowed.contains(&key.as_str()))
            || !["code", "status", "dispatch", "evidence"]
                .iter()
                .all(|key| task.contains_key(*key))
        {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "Task checkpoint shape is invalid",
            ));
        }
        let code = required_string(task, "code", Stage::Recovery)?.to_owned();
        let status = parse_current_task_status(required_string(task, "status", Stage::Recovery)?)?;
        let blocked_reason = optional_string(task.get("status_reason"));
        cancellation_requested |= blocked_reason.as_deref() == Some("cancelled");
        let evidence = task
            .get("evidence")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Recovery,
                    "corrupt_checkpoint",
                    "Task evidence must be an array",
                )
            })?;
        let evidence_strings = evidence
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect::<Vec<_>>();
        let dispatch = task
            .get("dispatch")
            .filter(|value| !value.is_null())
            .map(|value| decode_current_dispatch(value, &code, &evidence_strings))
            .transpose()?;
        let started =
            matches!(status, TaskStatus::InProgress | TaskStatus::Completed).then(String::new);
        if let Some(dispatch) = dispatch {
            dispatches.insert(dispatch.id.clone(), dispatch);
        }
        if tasks
            .insert(
                code,
                TaskCheckpoint {
                    status,
                    contract_digest: String::new(),
                    started_contract_digest: started,
                    completion_receipt: None,
                    blocked_reason,
                },
            )
            .is_some()
        {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "duplicate Task checkpoint",
            ));
        }
    }
    let next_dispatch_sequence = dispatches.len() as u64;
    Ok(Checkpoints {
        schema: CHECKPOINT_SCHEMA.to_owned(),
        plan_code,
        revision,
        phase,
        dossier_resolved: false,
        semantic_digest,
        designer: None,
        reviewer: None,
        tasks,
        dispatches,
        next_dispatch_sequence,
        cancellation_requested,
    })
}

fn decode_current_dispatch(
    value: &Value,
    task_code: &str,
    evidence: &[String],
) -> Result<DispatchCheckpoint, PlanError> {
    if let Ok(dispatch) = serde_json::from_value::<DispatchCheckpoint>(value.clone()) {
        return Ok(dispatch);
    }
    let object = value.as_object().ok_or_else(|| {
        PlanError::new(
            Stage::Recovery,
            "corrupt_checkpoint",
            "dispatch must be an object",
        )
    })?;
    let id = required_string(object, "id", Stage::Recovery)?.to_owned();
    let attempt = object
        .get("attempts")
        .or_else(|| object.get("attempt"))
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(1) as u32;
    Ok(DispatchCheckpoint {
        id,
        role: Role::Worker,
        task_code: Some(task_code.to_owned()),
        attempt,
        phase: DispatchPhase::AwaitingAcceptance,
        conversation_location: None,
        receipt: None,
        task_contract_digest: String::new(),
        evidence: evidence.to_vec(),
        failure_code: optional_string(object.get("last_failure")),
    })
}

fn checkpoint_delivery_status(checkpoints: &Checkpoints) -> &'static str {
    if checkpoints.cancellation_requested {
        "cancelled"
    } else if checkpoints.phase == PlanPhase::Blocked {
        "blocked"
    } else if checkpoints.phase == PlanPhase::Completed {
        "completed"
    } else if checkpoints.phase == PlanPhase::Draft {
        "pending"
    } else {
        "in_progress"
    }
}

fn task_status_current_name(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Pending => "pending",
        TaskStatus::InProgress => "in_progress",
        TaskStatus::Completed => "completed",
        TaskStatus::BlockedByAuthority => "blocked_by_authority",
        TaskStatus::BlockedByEnvironment => "blocked_by_environment",
    }
}

fn parse_current_task_status(value: &str) -> Result<TaskStatus, PlanError> {
    match value {
        "pending" => Ok(TaskStatus::Pending),
        "in_progress" => Ok(TaskStatus::InProgress),
        "completed" => Ok(TaskStatus::Completed),
        "blocked_by_authority" => Ok(TaskStatus::BlockedByAuthority),
        "blocked_by_environment" => Ok(TaskStatus::BlockedByEnvironment),
        _ => Err(PlanError::new(
            Stage::Recovery,
            "corrupt_checkpoint",
            "Task status is invalid",
        )),
    }
}

fn lifecycle_value(checkpoints: &Checkpoints, phase: PlanPhase) -> Value {
    fn session_value(session: Option<&SessionCheckpoint>) -> Value {
        session.map_or(Value::Null, |session| {
            json!({
                "id": session.receipt,
                "count": 1,
                "attempts": 1,
                "status": if session.completed { "completed" } else { "active" },
                "opened_at": session.opened_at,
                "closed_at": session.completed_at,
                "agent_returned": session.completed,
                "native_conversation_location": session.conversation_location
            })
        })
    }
    let sealed = checkpoints.semantic_digest.as_ref().map_or(
        Value::Null,
        |digest| json!({"revision": checkpoints.revision, "semantic_digest": digest}),
    );
    let authorization = matches!(
        phase,
        PlanPhase::Authorized
            | PlanPhase::Revising
            | PlanPhase::Reviewing
            | PlanPhase::Completed
            | PlanPhase::Blocked
    )
    .then(|| {
        json!({
            "source": "licoup-native",
            "semantic_digest": checkpoints.semantic_digest,
            "autonomy": {
                "allow_in_scope_revision": true,
                "allow_reviewer_repairs": true,
                "blocked_branch_policy": "continue_independent_work",
                "forbid_mid_execution_questions": true
            }
        })
    })
    .unwrap_or(Value::Null);
    json!({
        "authorization": authorization,
        "continuation_receipts": [],
        "designer_session": session_value(checkpoints.designer.as_ref()),
        "reviewer_session": session_value(checkpoints.reviewer.as_ref()),
        "sealed": sealed
    })
}

impl Checkpoints {
    /// Validate an externally supplied current-generation Better Plan
    /// checkpoint document against the exact semantic Plan. The native engine
    /// does not translate this document into an older or flatter generation.
    pub fn validate_current_json(plan: &Plan, text: &str) -> Result<(), PlanError> {
        let value: Value = serde_json::from_str(text).map_err(|error| {
            PlanError::new(Stage::Recovery, "corrupt_checkpoint", error.to_string())
        })?;
        let object = value.as_object().ok_or_else(|| {
            PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "checkpoint must be an object",
            )
        })?;
        require_exact_keys(
            object,
            &[
                "schema",
                "plan",
                "revision",
                "semantic_digest",
                "delivery_status",
                "tasks",
            ],
            Stage::Recovery,
        )?;
        if required_string(object, "schema", Stage::Recovery)? != CHECKPOINT_SCHEMA {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "unsupported checkpoint generation",
            ));
        }
        if required_string(object, "plan", Stage::Recovery)? != plan.code {
            return Err(PlanError::new(
                Stage::Recovery,
                "checkpoint_plan_mismatch",
                "checkpoint is for another Plan",
            ));
        }
        let revision = object
            .get("revision")
            .and_then(Value::as_u64)
            .filter(|revision| *revision > 0)
            .ok_or_else(|| {
                PlanError::new(Stage::Recovery, "corrupt_checkpoint", "revision is invalid")
            })?;
        let _ = revision;
        let digest = required_string(object, "semantic_digest", Stage::Recovery)?;
        if digest != plan.semantic_digest()? {
            return Err(PlanError::new(
                Stage::Recovery,
                "stale_authorization_digest",
                "checkpoint digest does not match Plan",
            ));
        }
        match required_string(object, "delivery_status", Stage::Recovery)? {
            "pending" | "in_progress" | "completed" | "blocked" | "cancelled" => {}
            _ => {
                return Err(PlanError::new(
                    Stage::Recovery,
                    "corrupt_checkpoint",
                    "delivery status is invalid",
                ));
            }
        }
        let mut codes = BTreeSet::new();
        for task in required_array(object, "tasks", Stage::Recovery)? {
            let task = task.as_object().ok_or_else(|| {
                PlanError::new(
                    Stage::Recovery,
                    "corrupt_checkpoint",
                    "Task checkpoint must be an object",
                )
            })?;
            let allowed = ["code", "status", "dispatch", "evidence", "status_reason"];
            if task.keys().any(|key| !allowed.contains(&key.as_str()))
                || !["code", "status", "dispatch", "evidence"]
                    .iter()
                    .all(|key| task.contains_key(*key))
            {
                return Err(PlanError::new(
                    Stage::Recovery,
                    "corrupt_checkpoint",
                    "Task checkpoint shape is invalid",
                ));
            }
            let code = required_string(task, "code", Stage::Recovery)?.to_owned();
            if !codes.insert(code) {
                return Err(PlanError::new(
                    Stage::Recovery,
                    "corrupt_checkpoint",
                    "duplicate Task checkpoint",
                ));
            }
            match required_string(task, "status", Stage::Recovery)? {
                "pending"
                | "in_progress"
                | "completed"
                | "blocked_by_authority"
                | "blocked_by_environment" => {}
                _ => {
                    return Err(PlanError::new(
                        Stage::Recovery,
                        "corrupt_checkpoint",
                        "Task status is invalid",
                    ));
                }
            }
            if !task.get("evidence").is_some_and(Value::is_array) {
                return Err(PlanError::new(
                    Stage::Recovery,
                    "corrupt_checkpoint",
                    "Task evidence must be an array",
                ));
            }
        }
        let expected = plan
            .tasks
            .iter()
            .map(|task| task.code.clone())
            .collect::<BTreeSet<_>>();
        if codes != expected {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "Task checkpoint set is not exact",
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContinuationRequest {
    pub task: Task,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DispatchBinding {
    pub id: String,
    pub task_code: String,
    pub attempt: u32,
    pub conversation_location: Option<String>,
    pub receipt: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DirectInput {
    pub from_task: String,
    pub output: Output,
    pub guarantee_input: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DecisionSelection {
    pub code: String,
    pub selected: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TaskBrief {
    pub code: String,
    pub title: String,
    pub contract: String,
    pub requirements: Vec<String>,
    pub outputs: Vec<String>,
    pub acceptance_criteria: Vec<String>,
    pub owned_writes: Vec<String>,
    pub references: Vec<RepositoryReference>,
    pub execution_policy: ExecutionPolicy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReviewBrief {
    pub plan_code: String,
    pub requirement_codes: Vec<String>,
    pub output_codes: Vec<String>,
    pub task_codes: Vec<String>,
    pub acceptance_codes: Vec<String>,
    pub references: Vec<RepositoryReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoleBrief {
    pub role: Role,
    pub authority: String,
    pub selected_decisions: Vec<DecisionSelection>,
    pub direct_inputs: Vec<DirectInput>,
    #[serde(default)]
    pub task: Option<TaskBrief>,
    #[serde(default)]
    pub review: Option<ReviewBrief>,
    pub execution_policy: ExecutionPolicy,
    pub repository_references: Vec<RepositoryReference>,
    #[serde(default)]
    pub native_conversation_location: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub enum NextAction {
    #[serde(rename = "designer")]
    Designer,
    #[serde(rename = "worker")]
    Worker { tasks: Vec<String> },
    #[serde(rename = "awaiting_acceptance")]
    AwaitingAcceptance {
        task_code: String,
        dispatch_id: String,
    },
    #[serde(rename = "reviewer")]
    Reviewer,
    #[serde(rename = "completed")]
    Completed,
    #[serde(rename = "blocked")]
    Blocked,
    #[serde(rename = "cancelled")]
    Cancelled,
    #[serde(rename = "none")]
    None,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Readiness {
    pub ready: bool,
    pub phase: PlanPhase,
    pub issues: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeliveryStatus {
    pub plan_code: String,
    pub revision: u64,
    pub phase: PlanPhase,
    pub semantic_digest: Option<String>,
    pub tasks: BTreeMap<String, TaskStatus>,
    pub next_action: NextAction,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct GraphIndex {
    adjacency: BTreeMap<String, Vec<String>>,
    indegree: BTreeMap<String, usize>,
}

impl GraphIndex {
    fn build(plan: &Plan) -> Result<Self, PlanError> {
        let mut adjacency: BTreeMap<String, Vec<String>> = plan
            .tasks
            .iter()
            .map(|task| (task.code.clone(), Vec::new()))
            .collect();
        let mut indegree: BTreeMap<String, usize> = plan
            .tasks
            .iter()
            .map(|task| (task.code.clone(), 0))
            .collect();
        for task in &plan.tasks {
            for edge in &task.prerequisites {
                adjacency
                    .get_mut(&edge.from)
                    .ok_or_else(|| {
                        PlanError::new(Stage::Validation, "unknown_prerequisite", edge.from.clone())
                    })?
                    .push(task.code.clone());
                *indegree.get_mut(&task.code).ok_or_else(|| {
                    PlanError::new(Stage::Validation, "unknown_task", task.code.clone())
                })? += 1;
            }
        }
        for children in adjacency.values_mut() {
            children.sort();
        }
        let mut ready: BTreeSet<String> = indegree
            .iter()
            .filter_map(|(code, degree)| (*degree == 0).then_some(code.clone()))
            .collect();
        let mut seen = 0usize;
        while let Some(code) = ready.pop_first() {
            seen += 1;
            if let Some(children) = adjacency.get(&code) {
                for child in children {
                    let degree = indegree
                        .get_mut(child)
                        .expect("graph child was initialized");
                    *degree -= 1;
                    if *degree == 0 {
                        ready.insert(child.clone());
                    }
                }
            }
        }
        if seen != plan.tasks.len() {
            return Err(PlanError::new(
                Stage::Validation,
                "cycle",
                "prerequisite graph is cyclic",
            ));
        }
        let original_indegree = plan
            .tasks
            .iter()
            .map(|task| (task.code.clone(), task.prerequisites.len()))
            .collect();
        Ok(Self {
            adjacency,
            indegree: original_indegree,
        })
    }

    fn reachable(&self, from: &str, target: &str) -> bool {
        let mut queue = VecDeque::from([from.to_string()]);
        let mut seen = BTreeSet::new();
        while let Some(current) = queue.pop_front() {
            if !seen.insert(current.clone()) {
                continue;
            }
            if current == target {
                return true;
            }
            if let Some(children) = self.adjacency.get(&current) {
                queue.extend(children.iter().cloned());
            }
        }
        false
    }
}

pub struct DeliveryPlanEngine {
    root: PathBuf,
    plan: Plan,
    checkpoints: Checkpoints,
    graph: GraphIndex,
}

impl DeliveryPlanEngine {
    pub fn create(root: impl Into<PathBuf>, mut plan: Plan) -> Result<Self, PlanError> {
        let root = root.into();
        ensure_private_directory(&root)?;
        plan.runtime_phase = PlanPhase::Draft;
        plan.validate()?;
        let graph = GraphIndex::build(&plan)?;
        let tasks = plan
            .tasks
            .iter()
            .map(|task| {
                Ok((
                    task.code.clone(),
                    TaskCheckpoint {
                        status: TaskStatus::Pending,
                        contract_digest: task_digest(task)?,
                        started_contract_digest: None,
                        completion_receipt: None,
                        blocked_reason: None,
                    },
                ))
            })
            .collect::<Result<BTreeMap<_, _>, PlanError>>()?;
        let checkpoints = Checkpoints {
            schema: CHECKPOINT_SCHEMA.to_string(),
            plan_code: plan.code.clone(),
            revision: 0,
            phase: PlanPhase::Draft,
            dossier_resolved: plan.dossier.status == DossierStatus::Resolved,
            semantic_digest: None,
            designer: None,
            reviewer: None,
            tasks,
            dispatches: BTreeMap::new(),
            next_dispatch_sequence: 0,
            cancellation_requested: false,
        };
        let engine = Self {
            root,
            plan,
            checkpoints,
            graph,
        };
        engine.persist_records()?;
        Ok(engine)
    }

    pub fn load(root: impl Into<PathBuf>) -> Result<Self, PlanError> {
        let root = root.into();
        ensure_private_directory(&root)?;
        let plan_value = read_json_value(&root.join(PLAN_FILE), Stage::Recovery)?;
        let plan_schema = plan_value
            .as_object()
            .and_then(|object| object.get("schema"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        if plan_schema != PLAN_SCHEMA {
            return Err(PlanError::new(
                Stage::Schema,
                "unsupported_schema",
                "current Plan generation required",
            ));
        }
        let mut plan: Plan = decode_strict(plan_value, Stage::Parse)?;
        plan.validate()?;
        let persisted_phase = plan.runtime_phase;
        let checkpoint_value = read_json_value(&root.join(CHECKPOINT_FILE), Stage::Recovery)?;
        let mut checkpoints: Checkpoints = decode_strict(checkpoint_value, Stage::Recovery)
            .map_err(|error| PlanError::new(Stage::Recovery, "corrupt_checkpoint", error.detail))?;
        hydrate_current_checkpoints(&plan, persisted_phase, &mut checkpoints)?;
        // Checkpoints are the sole runtime cancellation authority. Plan.phase
        // remains a non-semantic lifecycle mirror and is never required to
        // encode a cancellation write.
        plan.runtime_phase = checkpoints.phase;
        validate_checkpoints(&plan, &checkpoints)?;
        let graph = GraphIndex::build(&plan)?;
        Ok(Self {
            root,
            plan,
            checkpoints,
            graph,
        })
    }

    pub fn plan(&self) -> &Plan {
        &self.plan
    }

    pub fn checkpoints(&self) -> &Checkpoints {
        &self.checkpoints
    }

    pub fn semantic_digest(&self) -> Result<String, PlanError> {
        self.plan.semantic_digest()
    }

    pub fn resolve_dossier(
        &mut self,
        selections: BTreeMap<String, String>,
    ) -> Result<(), PlanError> {
        self.transaction(Stage::Dossier, |plan, checkpoints| {
            if checkpoints.phase != PlanPhase::Draft || checkpoints.dossier_resolved {
                return Err(PlanError::new(
                    Stage::Dossier,
                    "dossier_already_resolved",
                    "dossier resolution is one-time",
                ));
            }
            let expected: BTreeSet<String> = plan
                .dossier
                .questions
                .iter()
                .map(|question| question.code.clone())
                .collect();
            if selections.len() != expected.len()
                || selections.keys().any(|code| !expected.contains(code))
            {
                return Err(PlanError::new(
                    Stage::Dossier,
                    "decision_resolution_incomplete",
                    "all dossier questions must be selected exactly once",
                ));
            }
            for question in &mut plan.dossier.questions {
                let selected = selections.get(&question.code).ok_or_else(|| {
                    PlanError::new(
                        Stage::Dossier,
                        "decision_resolution_incomplete",
                        question.code.clone(),
                    )
                })?;
                if !question.options.is_empty()
                    && !question.options.iter().any(|option| option.id == *selected)
                {
                    return Err(PlanError::new(
                        Stage::Dossier,
                        "decision_option_unknown",
                        question.code.clone(),
                    ));
                }
                question.selected = Some(selected.clone());
            }
            plan.dossier.status = DossierStatus::Resolved;
            plan.sync_current_dossier()?;
            checkpoints.dossier_resolved = true;
            Ok(())
        })
    }

    pub fn open_designer(
        &mut self,
        conversation_location: impl Into<String>,
    ) -> Result<(), PlanError> {
        let location = conversation_location.into();
        self.transaction(Stage::Designer, |plan, checkpoints| {
            if checkpoints.phase != PlanPhase::Draft || !checkpoints.dossier_resolved {
                return Err(PlanError::new(
                    Stage::Designer,
                    "designer_not_admissible",
                    "dossier must be resolved from draft",
                ));
            }
            if checkpoints.designer.is_some() {
                return Err(PlanError::new(
                    Stage::Designer,
                    "designer_already_open",
                    "exactly one Designer session is allowed",
                ));
            }
            checkpoints.phase = PlanPhase::Designing;
            checkpoints.designer = Some(SessionCheckpoint {
                role: Role::Designer,
                opened: true,
                completed: false,
                conversation_location: Some(location),
                receipt: None,
                opened_at: Some(runtime_stamp()),
                completed_at: None,
            });
            let _ = plan;
            Ok(())
        })
    }

    pub fn complete_designer(&mut self, receipt: Option<String>) -> Result<(), PlanError> {
        self.transaction(Stage::Designer, |plan, checkpoints| {
            let designer = checkpoints.designer.as_mut().ok_or_else(|| {
                PlanError::new(
                    Stage::Designer,
                    "designer_not_open",
                    "Designer must be opened before completion",
                )
            })?;
            if designer.completed {
                return Err(PlanError::new(
                    Stage::Designer,
                    "designer_already_completed",
                    "Designer completion is one-time",
                ));
            }
            if !designer.opened {
                return Err(PlanError::new(
                    Stage::Designer,
                    "designer_not_open",
                    "Designer session is not open",
                ));
            }
            designer.completed = true;
            designer.receipt = receipt;
            designer.completed_at = Some(runtime_stamp());
            checkpoints.phase = PlanPhase::Designing;
            plan.validate()?;
            Ok(())
        })
    }

    pub fn bind_role_dispatch(&mut self, role: Role, dispatch_id: &str) -> Result<(), PlanError> {
        if role == Role::Worker {
            return Err(PlanError::new(
                Stage::Dispatch,
                "role_dispatch_invalid",
                "worker dispatches bind through Task state",
            ));
        }
        let dispatch_id = dispatch_id.to_owned();
        self.transaction(Stage::Dispatch, |_plan, checkpoints| {
            let session = match role {
                Role::Designer => checkpoints.designer.as_mut(),
                Role::Reviewer => checkpoints.reviewer.as_mut(),
                Role::Worker => None,
            }
            .ok_or_else(|| {
                PlanError::new(
                    Stage::Dispatch,
                    "role_session_not_open",
                    "role session is not open",
                )
            })?;
            if session.completed {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "role_session_completed",
                    "completed role cannot be rebound",
                ));
            }
            if let Some(existing) = session.receipt.as_deref() {
                if existing == dispatch_id {
                    return Ok(());
                }
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "role_dispatch_already_bound",
                    "one role session already owns a dispatch",
                ));
            }
            session.receipt = Some(dispatch_id.clone());
            Ok(())
        })
    }

    pub fn readiness(&self) -> Readiness {
        let mut issues = Vec::new();
        if !self.checkpoints.dossier_resolved {
            issues.push("unresolved_decision".to_string());
        }
        if !self
            .checkpoints
            .designer
            .as_ref()
            .is_some_and(|session| session.completed)
        {
            issues.push("designer_incomplete".to_string());
        }
        if let Err(error) = self.plan.validate() {
            issues.push(error.code);
        }
        Readiness {
            ready: issues.is_empty(),
            phase: self.checkpoints.phase,
            issues,
        }
    }

    pub fn mark_ready(&mut self) -> Result<Readiness, PlanError> {
        self.transaction(Stage::Readiness, |plan, checkpoints| {
            if !checkpoints.dossier_resolved {
                return Err(PlanError::new(
                    Stage::Readiness,
                    "unresolved_decision",
                    "dossier is not resolved",
                ));
            }
            if !checkpoints
                .designer
                .as_ref()
                .is_some_and(|session| session.completed)
            {
                return Err(PlanError::new(
                    Stage::Readiness,
                    "designer_incomplete",
                    "Designer has not completed",
                ));
            }
            plan.validate()?;
            checkpoints.phase = PlanPhase::Ready;
            Ok(())
        })?;
        Ok(self.readiness())
    }

    pub fn authorize(&mut self) -> Result<String, PlanError> {
        self.transaction(Stage::Authorization, |plan, checkpoints| {
            if checkpoints.phase != PlanPhase::Ready {
                return Err(PlanError::new(
                    Stage::Authorization,
                    "not_ready",
                    "Plan is not ready for authorization",
                ));
            }
            let digest = plan.semantic_digest()?;
            checkpoints.revision = checkpoints.revision.saturating_add(1);
            checkpoints.semantic_digest = Some(digest);
            checkpoints.phase = PlanPhase::Authorized;
            for task in &plan.tasks {
                let task_checkpoint = checkpoints.tasks.get_mut(&task.code).ok_or_else(|| {
                    PlanError::new(
                        Stage::Authorization,
                        "corrupt_checkpoint",
                        task.code.clone(),
                    )
                })?;
                if task_checkpoint.status == TaskStatus::Pending {
                    task_checkpoint.contract_digest = task_digest(task)?;
                }
            }
            Ok(())
        })?;
        self.checkpoints.semantic_digest.clone().ok_or_else(|| {
            PlanError::new(
                Stage::Authorization,
                "authorization_not_sealed",
                "digest was not persisted",
            )
        })
    }

    pub fn next_action(&self) -> Result<NextAction, PlanError> {
        if self.checkpoints.cancellation_requested {
            return Ok(NextAction::Cancelled);
        }
        match self.checkpoints.phase {
            PlanPhase::Draft => Ok(NextAction::Designer),
            PlanPhase::Designing => {
                if self
                    .checkpoints
                    .designer
                    .as_ref()
                    .is_some_and(|session| !session.completed)
                {
                    return Ok(NextAction::Designer);
                }
                Ok(NextAction::None)
            }
            PlanPhase::Ready => Ok(NextAction::None),
            PlanPhase::Authorized | PlanPhase::Revising => self.next_authorized_action(),
            PlanPhase::Reviewing => Ok(NextAction::Reviewer),
            PlanPhase::Completed => Ok(NextAction::Completed),
            PlanPhase::Blocked => Ok(NextAction::Blocked),
        }
    }

    fn next_authorized_action(&self) -> Result<NextAction, PlanError> {
        for dispatch in self.checkpoints.dispatches.values() {
            if dispatch.phase == DispatchPhase::AwaitingAcceptance {
                if let Some(task_code) = &dispatch.task_code {
                    if self
                        .checkpoints
                        .tasks
                        .get(task_code)
                        .is_some_and(|task| task.status != TaskStatus::InProgress)
                    {
                        continue;
                    }
                    return Ok(NextAction::AwaitingAcceptance {
                        task_code: task_code.clone(),
                        dispatch_id: dispatch.id.clone(),
                    });
                }
            }
        }
        let eligible = self.eligible_tasks()?;
        if !eligible.is_empty() {
            return Ok(NextAction::Worker { tasks: eligible });
        }
        let all_settled = self.checkpoints.tasks.values().all(|task| {
            matches!(
                task.status,
                TaskStatus::Completed
                    | TaskStatus::BlockedByAuthority
                    | TaskStatus::BlockedByEnvironment
            )
        });
        if all_settled
            && self
                .checkpoints
                .tasks
                .values()
                .all(|task| task.status == TaskStatus::Completed)
        {
            return Ok(NextAction::Reviewer);
        }
        if all_settled {
            return Ok(NextAction::Blocked);
        }
        Ok(NextAction::None)
    }

    pub fn eligible_tasks(&self) -> Result<Vec<String>, PlanError> {
        eligible_tasks_for(&self.plan, &self.checkpoints)
    }

    pub fn compile_task_brief(
        &self,
        task_code: &str,
        native_conversation_location: Option<String>,
    ) -> Result<RoleBrief, PlanError> {
        if !matches!(
            self.checkpoints.phase,
            PlanPhase::Authorized | PlanPhase::Revising
        ) {
            return Err(PlanError::new(
                Stage::Eligibility,
                "brief_not_admissible",
                "Task Brief requires an authorized Plan",
            ));
        }
        let task = self
            .plan
            .tasks
            .iter()
            .find(|task| task.code == task_code)
            .ok_or_else(|| {
                PlanError::new(Stage::Eligibility, "unknown_task", task_code.to_string())
            })?;
        let authority = role_authority(&self.plan, Role::Worker)?;
        let direct_inputs = task
            .prerequisites
            .iter()
            .map(|edge| {
                let output = self
                    .plan
                    .outputs
                    .iter()
                    .find(|output| output.code == edge.output)
                    .ok_or_else(|| {
                        PlanError::new(
                            Stage::Validation,
                            "unknown_upstream_output",
                            edge.output.clone(),
                        )
                    })?;
                Ok(DirectInput {
                    from_task: edge.from.clone(),
                    output: output.clone(),
                    guarantee_input: edge.guarantee_input.clone(),
                })
            })
            .collect::<Result<Vec<_>, PlanError>>()?;
        Ok(RoleBrief {
            role: Role::Worker,
            authority,
            selected_decisions: selected_decisions(&self.plan),
            direct_inputs,
            task: Some(TaskBrief {
                code: task.code.clone(),
                title: task.title.clone(),
                contract: task.contract.clone(),
                requirements: task.requirements.clone(),
                outputs: task.outputs.clone(),
                acceptance_criteria: task.acceptance_criteria.clone(),
                owned_writes: task.owned_writes.clone(),
                references: task.references.clone(),
                execution_policy: task.execution_policy.clone(),
            }),
            review: None,
            execution_policy: task.execution_policy.clone(),
            repository_references: task.references.clone(),
            native_conversation_location,
        })
    }

    pub fn compile_reviewer_brief(
        &self,
        native_conversation_location: Option<String>,
    ) -> Result<RoleBrief, PlanError> {
        if !matches!(
            self.checkpoints.phase,
            PlanPhase::Authorized | PlanPhase::Reviewing
        ) {
            return Err(PlanError::new(
                Stage::Reviewer,
                "review_not_admissible",
                "review requires an authorized Plan",
            ));
        }
        let authority = role_authority(&self.plan, Role::Reviewer)?;
        Ok(RoleBrief {
            role: Role::Reviewer,
            authority,
            selected_decisions: selected_decisions(&self.plan),
            direct_inputs: Vec::new(),
            task: None,
            review: Some(ReviewBrief {
                plan_code: self.plan.code.clone(),
                requirement_codes: self
                    .plan
                    .requirements
                    .iter()
                    .map(|item| item.code.clone())
                    .collect(),
                output_codes: self
                    .plan
                    .outputs
                    .iter()
                    .map(|item| item.code.clone())
                    .collect(),
                task_codes: self
                    .plan
                    .tasks
                    .iter()
                    .map(|item| item.code.clone())
                    .collect(),
                acceptance_codes: self
                    .plan
                    .acceptance_criteria
                    .iter()
                    .map(|item| item.code.clone())
                    .collect(),
                references: self.plan.references.clone(),
            }),
            execution_policy: self.plan.execution_policy.clone(),
            repository_references: self.plan.references.clone(),
            native_conversation_location,
        })
    }

    pub fn bind_dispatch(&mut self, binding: DispatchBinding) -> Result<(), PlanError> {
        self.transaction(Stage::Dispatch, |plan, checkpoints| {
            if checkpoints.phase != PlanPhase::Authorized {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "dispatch_not_admissible",
                    "dispatch requires an authorized Plan",
                ));
            }
            if checkpoints.dispatches.contains_key(&binding.id) {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "duplicate_dispatch",
                    binding.id.clone(),
                ));
            }
            let task = plan
                .tasks
                .iter()
                .find(|task| task.code == binding.task_code)
                .ok_or_else(|| {
                    PlanError::new(Stage::Dispatch, "unknown_task", binding.task_code.clone())
                })?;
            let eligible = eligible_tasks_for(plan, checkpoints)?;
            if !eligible.contains(&binding.task_code) {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "task_not_eligible",
                    binding.task_code.clone(),
                ));
            }
            let task_checkpoint =
                checkpoints
                    .tasks
                    .get_mut(&binding.task_code)
                    .ok_or_else(|| {
                        PlanError::new(
                            Stage::Dispatch,
                            "corrupt_checkpoint",
                            binding.task_code.clone(),
                        )
                    })?;
            if task_checkpoint.started_contract_digest.is_some() {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "task_already_started",
                    binding.task_code.clone(),
                ));
            }
            let digest = task_digest(task)?;
            if digest != task_checkpoint.contract_digest {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "task_contract_digest_mismatch",
                    binding.task_code.clone(),
                ));
            }
            task_checkpoint.status = TaskStatus::InProgress;
            task_checkpoint.started_contract_digest = Some(digest.clone());
            checkpoints.next_dispatch_sequence =
                checkpoints.next_dispatch_sequence.saturating_add(1);
            checkpoints.dispatches.insert(
                binding.id.clone(),
                DispatchCheckpoint {
                    id: binding.id,
                    role: Role::Worker,
                    task_code: Some(binding.task_code),
                    attempt: binding.attempt.max(1),
                    phase: DispatchPhase::WorkerRunning,
                    conversation_location: binding.conversation_location,
                    receipt: binding.receipt,
                    task_contract_digest: digest,
                    evidence: Vec::new(),
                    failure_code: None,
                },
            );
            Ok(())
        })
    }

    pub fn complete_dispatch(
        &mut self,
        dispatch_id: &str,
        evidence: Vec<String>,
    ) -> Result<(), PlanError> {
        self.transaction(Stage::Dispatch, |_plan, checkpoints| {
            let dispatch = checkpoints.dispatches.get_mut(dispatch_id).ok_or_else(|| {
                PlanError::new(Stage::Dispatch, "unknown_dispatch", dispatch_id.to_string())
            })?;
            if dispatch.phase != DispatchPhase::WorkerRunning
                && dispatch.phase != DispatchPhase::WorkerCorrection
            {
                return Err(PlanError::new(
                    Stage::Dispatch,
                    "dispatch_not_running",
                    dispatch_id.to_string(),
                ));
            }
            dispatch.phase = DispatchPhase::AwaitingAcceptance;
            dispatch.evidence = evidence;
            Ok(())
        })
    }

    pub fn fail_dispatch(
        &mut self,
        dispatch_id: &str,
        failure_code: impl Into<String>,
        retryable: bool,
    ) -> Result<(), PlanError> {
        let failure_code = failure_code.into();
        self.transaction(Stage::Dispatch, |plan, checkpoints| {
            let dispatch = checkpoints.dispatches.get_mut(dispatch_id).ok_or_else(|| {
                PlanError::new(Stage::Dispatch, "unknown_dispatch", dispatch_id.to_string())
            })?;
            let task_code = dispatch.task_code.clone().ok_or_else(|| {
                PlanError::new(
                    Stage::Dispatch,
                    "dispatch_task_missing",
                    dispatch_id.to_string(),
                )
            })?;
            let task_limit = plan
                .tasks
                .iter()
                .find(|candidate| candidate.code == task_code)
                .map(|candidate| candidate.execution_policy.max_attempts.max(1))
                .unwrap_or(1);
            let task = checkpoints.tasks.get_mut(&task_code).ok_or_else(|| {
                PlanError::new(Stage::Dispatch, "corrupt_checkpoint", task_code.clone())
            })?;
            dispatch.failure_code = Some(failure_code.clone());
            if retryable && dispatch.attempt < task_limit {
                dispatch.phase = DispatchPhase::WorkerCorrection;
                task.status = TaskStatus::Pending;
                task.started_contract_digest = None;
            } else {
                dispatch.phase = DispatchPhase::WorkerCorrection;
                task.status = TaskStatus::BlockedByEnvironment;
                task.blocked_reason = Some(failure_code);
            }
            Ok(())
        })
    }

    pub fn accept_task(
        &mut self,
        task_code: &str,
        dispatch_id: &str,
        receipt: Option<String>,
    ) -> Result<(), PlanError> {
        self.transaction(Stage::Acceptance, |_plan, checkpoints| {
            let dispatch = checkpoints.dispatches.get(dispatch_id).ok_or_else(|| {
                PlanError::new(
                    Stage::Acceptance,
                    "unknown_dispatch",
                    dispatch_id.to_string(),
                )
            })?;
            if dispatch.phase != DispatchPhase::AwaitingAcceptance
                || dispatch.task_code.as_deref() != Some(task_code)
            {
                return Err(PlanError::new(
                    Stage::Acceptance,
                    "dispatch_not_awaiting_acceptance",
                    dispatch_id.to_string(),
                ));
            }
            let task = checkpoints.tasks.get_mut(task_code).ok_or_else(|| {
                PlanError::new(
                    Stage::Acceptance,
                    "corrupt_checkpoint",
                    task_code.to_string(),
                )
            })?;
            if task.status != TaskStatus::InProgress {
                return Err(PlanError::new(
                    Stage::Acceptance,
                    "task_not_in_progress",
                    task_code.to_string(),
                ));
            }
            task.status = TaskStatus::Completed;
            task.completion_receipt = receipt;
            Ok(())
        })
    }

    pub fn block_branch(
        &mut self,
        task_code: &str,
        authority: bool,
        reason: impl Into<String>,
    ) -> Result<(), PlanError> {
        let reason = reason.into();
        self.transaction(Stage::Acceptance, |plan, checkpoints| {
            if !plan.tasks.iter().any(|task| task.code == task_code) {
                return Err(PlanError::new(
                    Stage::Acceptance,
                    "unknown_task",
                    task_code.to_string(),
                ));
            }
            let mut blocked = BTreeSet::from([task_code.to_string()]);
            let mut queue = VecDeque::from([task_code.to_string()]);
            while let Some(parent) = queue.pop_front() {
                for child in self_children(plan, &parent) {
                    if blocked.insert(child.clone()) {
                        queue.push_back(child);
                    }
                }
            }
            for code in blocked {
                if let Some(task) = checkpoints.tasks.get_mut(&code) {
                    if task.status == TaskStatus::Pending || task.status == TaskStatus::InProgress {
                        task.status = if authority {
                            TaskStatus::BlockedByAuthority
                        } else {
                            TaskStatus::BlockedByEnvironment
                        };
                        task.blocked_reason = Some(reason.clone());
                    }
                }
            }
            let all_settled = checkpoints.tasks.values().all(|task| {
                matches!(
                    task.status,
                    TaskStatus::Completed
                        | TaskStatus::BlockedByAuthority
                        | TaskStatus::BlockedByEnvironment
                )
            });
            checkpoints.phase = if all_settled {
                PlanPhase::Blocked
            } else {
                PlanPhase::Authorized
            };
            Ok(())
        })
    }

    pub fn open_reviewer(
        &mut self,
        conversation_location: impl Into<String>,
    ) -> Result<(), PlanError> {
        let location = conversation_location.into();
        self.transaction(Stage::Reviewer, |plan, checkpoints| {
            if checkpoints.phase != PlanPhase::Authorized {
                return Err(PlanError::new(
                    Stage::Reviewer,
                    "review_not_admissible",
                    "Reviewer requires an authorized Plan",
                ));
            }
            if checkpoints.reviewer.is_some() {
                return Err(PlanError::new(
                    Stage::Reviewer,
                    "reviewer_already_open",
                    "exactly one Reviewer session is allowed",
                ));
            }
            if checkpoints
                .tasks
                .values()
                .any(|task| task.status != TaskStatus::Completed)
            {
                return Err(PlanError::new(
                    Stage::Reviewer,
                    "tasks_incomplete",
                    "all Tasks must be accepted before review",
                ));
            }
            checkpoints.reviewer = Some(SessionCheckpoint {
                role: Role::Reviewer,
                opened: true,
                completed: false,
                conversation_location: Some(location),
                receipt: None,
                opened_at: Some(runtime_stamp()),
                completed_at: None,
            });
            checkpoints.phase = PlanPhase::Reviewing;
            let _ = plan;
            Ok(())
        })
    }

    pub fn complete_reviewer(&mut self, receipt: Option<String>) -> Result<(), PlanError> {
        self.transaction(Stage::Reviewer, |_plan, checkpoints| {
            let reviewer = checkpoints.reviewer.as_mut().ok_or_else(|| {
                PlanError::new(
                    Stage::Reviewer,
                    "reviewer_not_open",
                    "Reviewer must be opened before completion",
                )
            })?;
            if reviewer.completed {
                return Err(PlanError::new(
                    Stage::Reviewer,
                    "reviewer_already_completed",
                    "Reviewer completion is one-time",
                ));
            }
            reviewer.completed = true;
            reviewer.receipt = receipt;
            reviewer.completed_at = Some(runtime_stamp());
            checkpoints.phase = PlanPhase::Completed;
            Ok(())
        })
    }

    pub fn continue_unstarted(
        &mut self,
        request: ContinuationRequest,
    ) -> Result<String, PlanError> {
        self.transaction(Stage::Continuation, |plan, checkpoints| {
            if checkpoints.phase != PlanPhase::Authorized {
                return Err(PlanError::new(
                    Stage::Continuation,
                    "continuation_not_admissible",
                    "only an authorized revision can continue",
                ));
            }
            let task_code = request.task.code.clone();
            let existing = plan
                .tasks
                .iter()
                .position(|task| task.code == task_code)
                .ok_or_else(|| {
                    PlanError::new(Stage::Continuation, "task_out_of_scope", task_code.clone())
                })?;
            let checkpoint = checkpoints.tasks.get(&task_code).ok_or_else(|| {
                PlanError::new(Stage::Continuation, "corrupt_checkpoint", task_code.clone())
            })?;
            if checkpoint.status != TaskStatus::Pending
                || checkpoint.started_contract_digest.is_some()
            {
                return Err(PlanError::new(
                    Stage::Continuation,
                    "started_task_edit",
                    task_code,
                ));
            }
            request.task.validate_shape()?;
            if plan.current_document.is_some()
                && (request.task.references != plan.tasks[existing].references
                    || request.task.execution_policy != plan.tasks[existing].execution_policy)
            {
                return Err(PlanError::new(
                    Stage::Continuation,
                    "continuation_rich_contract_required",
                    "current Plan continuation cannot add fields absent from its Task schema",
                ));
            }
            plan.tasks[existing] = request.task.clone();
            plan.sync_current_task(&task_code)?;
            plan.validate()?;
            let digest = plan.semantic_digest()?;
            checkpoints.revision = checkpoints.revision.saturating_add(1);
            checkpoints.semantic_digest = Some(digest.clone());
            checkpoints.phase = PlanPhase::Authorized;
            checkpoints
                .tasks
                .get_mut(&request.task.code)
                .expect("task existed")
                .contract_digest = task_digest(&request.task)?;
            Ok(())
        })?;
        self.graph = GraphIndex::build(&self.plan)?;
        self.checkpoints.semantic_digest.clone().ok_or_else(|| {
            PlanError::new(
                Stage::Continuation,
                "authorization_not_sealed",
                "continuation digest was not persisted",
            )
        })
    }

    pub fn status(&self) -> Result<DeliveryStatus, PlanError> {
        Ok(DeliveryStatus {
            plan_code: self.plan.code.clone(),
            revision: self.checkpoints.revision,
            phase: self.checkpoints.phase,
            semantic_digest: self.checkpoints.semantic_digest.clone(),
            tasks: self
                .checkpoints
                .tasks
                .iter()
                .map(|(code, checkpoint)| (code.clone(), checkpoint.status))
                .collect(),
            next_action: self.next_action()?,
        })
    }

    pub fn cancel(&mut self) -> Result<(), PlanError> {
        if self.checkpoints.phase == PlanPhase::Completed {
            return Err(PlanError::new(
                Stage::Cancellation,
                "already_completed",
                "completed delivery cannot be cancelled",
            ));
        }
        if self.checkpoints.cancellation_requested {
            return Ok(());
        }
        let mut checkpoints = self.checkpoints.clone();
        checkpoints.cancellation_requested = true;
        checkpoints.phase = PlanPhase::Blocked;
        validate_checkpoints(&self.plan, &checkpoints)?;
        // Cancellation changes one current-generation runtime record only.
        // A crash observes the old or new Checkpoints.json, never a partial
        // cancellation split across semantic Plan and checkpoint files.
        persist_checkpoint_at(&self.root, &checkpoints)?;
        self.plan.runtime_phase = PlanPhase::Blocked;
        self.checkpoints = checkpoints;
        Ok(())
    }

    fn transaction<F>(&mut self, stage: Stage, operation: F) -> Result<(), PlanError>
    where
        F: FnOnce(&mut Plan, &mut Checkpoints) -> Result<(), PlanError>,
    {
        if self.checkpoints.cancellation_requested && stage != Stage::Cancellation {
            return Err(PlanError::new(
                stage,
                "delivery_cancelled",
                "cancelled delivery state is terminal",
            ));
        }
        let mut plan = self.plan.clone();
        let mut checkpoints = self.checkpoints.clone();
        operation(&mut plan, &mut checkpoints).map_err(|error| {
            if error.stage == stage {
                error
            } else {
                PlanError::new(stage, error.code, error.detail)
            }
        })?;
        plan.runtime_phase = checkpoints.phase;
        plan.validate()?;
        validate_checkpoints(&plan, &checkpoints)?;
        let graph = GraphIndex::build(&plan)?;
        persist_records_at(&self.root, &plan, &checkpoints)?;
        self.plan = plan;
        self.checkpoints = checkpoints;
        self.graph = graph;
        Ok(())
    }

    fn persist_records(&self) -> Result<(), PlanError> {
        persist_records_at(&self.root, &self.plan, &self.checkpoints)
    }
}

impl Task {
    fn validate_shape(&self) -> Result<(), PlanError> {
        validate_code(&self.code, "TASK", Stage::Continuation)?;
        for reference in &self.references {
            validate_relative_reference(&reference.path, Stage::Continuation)?;
        }
        Ok(())
    }
}

fn validate_plan(plan: &Plan) -> Result<(), PlanError> {
    if plan.schema != PLAN_SCHEMA {
        return Err(PlanError::new(
            Stage::Schema,
            "unsupported_schema",
            "current native Plan generation required",
        ));
    }
    validate_code(&plan.code, "PLAN", Stage::Validation)?;
    if plan.tasks.len() > MAX_TASKS {
        return Err(PlanError::new(
            Stage::Validation,
            "task_limit_exceeded",
            "Plan exceeds the 256 Task bound",
        ));
    }
    let semantic_size = serde_json::to_vec(plan)
        .map_err(|error| PlanError::new(Stage::Parse, "plan_encode_failed", error.to_string()))?
        .len();
    if semantic_size > MAX_SEMANTIC_BYTES {
        return Err(PlanError::new(
            Stage::Validation,
            "semantic_document_too_large",
            "Plan exceeds the 2 MiB semantic bound",
        ));
    }
    validate_relative_reference(&plan.directory, Stage::Validation)?;
    for reference in &plan.references {
        validate_relative_reference(&reference.path, Stage::Validation)?;
    }
    let mut requirement_codes = BTreeSet::new();
    for requirement in &plan.requirements {
        validate_code(&requirement.code, "REQ", Stage::Validation)?;
        if !requirement_codes.insert(requirement.code.clone()) {
            return Err(PlanError::new(
                Stage::Validation,
                "duplicate_requirement",
                requirement.code.clone(),
            ));
        }
    }
    let mut output_codes = BTreeSet::new();
    for output in &plan.outputs {
        validate_code(&output.code, "OUT", Stage::Validation)?;
        if !output_codes.insert(output.code.clone()) {
            return Err(PlanError::new(
                Stage::Validation,
                "duplicate_output",
                output.code.clone(),
            ));
        }
        if !plan
            .tasks
            .iter()
            .any(|task| task.code == output.produced_by)
        {
            return Err(PlanError::new(
                Stage::Validation,
                "unknown_output_owner",
                output.code.clone(),
            ));
        }
        for reference in &output.references {
            validate_relative_reference(&reference.path, Stage::Validation)?;
        }
    }
    let mut task_codes = BTreeSet::new();
    for task in &plan.tasks {
        validate_code(&task.code, "TASK", Stage::Validation)?;
        if !task_codes.insert(task.code.clone()) {
            return Err(PlanError::new(
                Stage::Validation,
                "duplicate_task",
                task.code.clone(),
            ));
        }
        for requirement in &task.requirements {
            if !requirement_codes.contains(requirement) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_requirement",
                    requirement.clone(),
                ));
            }
        }
        for output in &task.outputs {
            if !output_codes.contains(output) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_output",
                    output.clone(),
                ));
            }
        }
        for reference in &task.references {
            validate_relative_reference(&reference.path, Stage::Validation)?;
        }
        for write in &task.owned_writes {
            validate_relative_reference(write, Stage::Validation)?;
        }
        let mut from_codes = BTreeSet::new();
        for edge in &task.prerequisites {
            if !from_codes.insert(edge.from.clone()) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "duplicate_edge_input",
                    task.code.clone(),
                ));
            }
            if edge.guarantee_input.trim().is_empty() {
                return Err(PlanError::new(
                    Stage::Validation,
                    "missing_edge_input",
                    task.code.clone(),
                ));
            }
            if !plan
                .tasks
                .iter()
                .any(|candidate| candidate.code == edge.from)
            {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_prerequisite",
                    edge.from.clone(),
                ));
            }
            let output = plan
                .outputs
                .iter()
                .find(|output| output.code == edge.output)
                .ok_or_else(|| {
                    PlanError::new(
                        Stage::Validation,
                        "unknown_upstream_output",
                        edge.output.clone(),
                    )
                })?;
            if output.produced_by != edge.from {
                return Err(PlanError::new(
                    Stage::Validation,
                    "upstream_output_owner_mismatch",
                    edge.output.clone(),
                ));
            }
        }
    }
    for requirement in &plan.requirements {
        if !plan
            .tasks
            .iter()
            .any(|task| task.requirements.contains(&requirement.code))
        {
            return Err(PlanError::new(
                Stage::Validation,
                "uncovered_requirement",
                requirement.code.clone(),
            ));
        }
    }
    for output in &plan.outputs {
        if !plan
            .tasks
            .iter()
            .any(|task| task.outputs.contains(&output.code))
        {
            return Err(PlanError::new(
                Stage::Validation,
                "uncovered_output",
                output.code.clone(),
            ));
        }
    }
    let acceptance_codes: BTreeSet<String> = plan
        .acceptance_criteria
        .iter()
        .map(|item| item.code.clone())
        .collect();
    for criterion in &plan.acceptance_criteria {
        validate_code(&criterion.code, "AC", Stage::Validation)?;
        if let Some(task) = &criterion.task {
            if !task_codes.contains(task) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_acceptance_task",
                    task.clone(),
                ));
            }
        }
        if let Some(requirement) = &criterion.requirement {
            if !requirement_codes.contains(requirement) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_acceptance_requirement",
                    requirement.clone(),
                ));
            }
        }
        if let Some(output) = &criterion.output {
            if !output_codes.contains(output) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_acceptance_output",
                    output.clone(),
                ));
            }
        }
    }
    for task in &plan.tasks {
        for criterion in &task.acceptance_criteria {
            if !acceptance_codes.contains(criterion) {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unknown_task_acceptance",
                    criterion.clone(),
                ));
            }
        }
        if !plan
            .acceptance_criteria
            .iter()
            .any(|criterion| criterion.task.as_deref() == Some(task.code.as_str()))
        {
            return Err(PlanError::new(
                Stage::Validation,
                "uncovered_task_acceptance",
                task.code.clone(),
            ));
        }
    }
    let designers = plan
        .roles
        .iter()
        .filter(|role| role.role == Role::Designer)
        .count();
    let reviewers = plan
        .roles
        .iter()
        .filter(|role| role.role == Role::Reviewer)
        .count();
    if designers != 1 || reviewers != 1 {
        return Err(PlanError::new(
            Stage::Validation,
            "role_cardinality",
            "exactly one Designer and one Reviewer are required",
        ));
    }
    for question in &plan.dossier.questions {
        validate_code(&question.code, "Q", Stage::Validation)?;
        if let Some(selected) = &question.selected {
            if !question.options.is_empty()
                && !question.options.iter().any(|option| option.id == *selected)
            {
                return Err(PlanError::new(
                    Stage::Validation,
                    "decision_option_unknown",
                    question.code.clone(),
                ));
            }
        }
        if plan.dossier.status == DossierStatus::Resolved && question.selected.is_none() {
            return Err(PlanError::new(
                Stage::Validation,
                "unresolved_decision",
                question.code.clone(),
            ));
        }
    }
    let graph = GraphIndex::build(plan)?;
    validate_parallel_ownership(plan, &graph)?;
    Ok(())
}

fn validate_parallel_ownership(plan: &Plan, graph: &GraphIndex) -> Result<(), PlanError> {
    for left_index in 0..plan.tasks.len() {
        for right_index in left_index + 1..plan.tasks.len() {
            let left = &plan.tasks[left_index];
            let right = &plan.tasks[right_index];
            if !writes_overlap(&left.owned_writes, &right.owned_writes) {
                continue;
            }
            if !graph.reachable(&left.code, &right.code)
                && !graph.reachable(&right.code, &left.code)
            {
                return Err(PlanError::new(
                    Stage::Validation,
                    "unsafe_parallel_write_overlap",
                    format!("{} and {}", left.code, right.code),
                ));
            }
        }
    }
    Ok(())
}

fn hydrate_current_checkpoints(
    plan: &Plan,
    persisted_phase: PlanPhase,
    checkpoints: &mut Checkpoints,
) -> Result<(), PlanError> {
    checkpoints.phase = if checkpoints.cancellation_requested {
        PlanPhase::Blocked
    } else {
        persisted_phase
    };
    checkpoints.dossier_resolved = plan.dossier.status == DossierStatus::Resolved;
    checkpoints.designer = plan.lifecycle_session("designer_session", Role::Designer);
    checkpoints.reviewer = plan.lifecycle_session("reviewer_session", Role::Reviewer);
    for task in &plan.tasks {
        let checkpoint = checkpoints.tasks.get_mut(&task.code).ok_or_else(|| {
            PlanError::new(Stage::Recovery, "corrupt_checkpoint", task.code.clone())
        })?;
        let digest = task_digest(task)?;
        checkpoint.contract_digest = digest.clone();
        if checkpoint.started_contract_digest.is_some() {
            checkpoint.started_contract_digest = Some(digest.clone());
        }
        for dispatch in checkpoints
            .dispatches
            .values_mut()
            .filter(|dispatch| dispatch.task_code.as_deref() == Some(task.code.as_str()))
        {
            dispatch.task_contract_digest = digest.clone();
        }
    }
    checkpoints.next_dispatch_sequence = checkpoints.dispatches.len() as u64;
    Ok(())
}

fn validate_checkpoints(plan: &Plan, checkpoints: &Checkpoints) -> Result<(), PlanError> {
    if checkpoints.schema != CHECKPOINT_SCHEMA {
        return Err(PlanError::new(
            Stage::Recovery,
            "corrupt_checkpoint",
            "unsupported checkpoint generation",
        ));
    }
    if checkpoints.plan_code != plan.code {
        return Err(PlanError::new(
            Stage::Recovery,
            "checkpoint_plan_mismatch",
            "checkpoint is for another Plan",
        ));
    }
    if checkpoints.tasks.len() != plan.tasks.len()
        || plan
            .tasks
            .iter()
            .any(|task| !checkpoints.tasks.contains_key(&task.code))
    {
        return Err(PlanError::new(
            Stage::Recovery,
            "corrupt_checkpoint",
            "Task checkpoint set is not exact",
        ));
    }
    for task in &plan.tasks {
        let checkpoint = checkpoints.tasks.get(&task.code).expect("checked above");
        let current = task_digest(task)?;
        if checkpoint.started_contract_digest.is_some()
            && checkpoint.started_contract_digest.as_deref() != Some(current.as_str())
        {
            return Err(PlanError::new(
                Stage::Recovery,
                "started_task_edit",
                task.code.clone(),
            ));
        }
        if checkpoint.started_contract_digest.is_none()
            && checkpoint.contract_digest != current
            && matches!(
                checkpoints.phase,
                PlanPhase::Authorized
                    | PlanPhase::Revising
                    | PlanPhase::Reviewing
                    | PlanPhase::Completed
                    | PlanPhase::Blocked
            )
        {
            return Err(PlanError::new(
                Stage::Recovery,
                "task_contract_digest_mismatch",
                task.code.clone(),
            ));
        }
    }
    let digest = plan.semantic_digest()?;
    if matches!(
        checkpoints.phase,
        PlanPhase::Authorized
            | PlanPhase::Revising
            | PlanPhase::Reviewing
            | PlanPhase::Completed
            | PlanPhase::Blocked
    ) && (!checkpoints.cancellation_requested || checkpoints.semantic_digest.is_some())
        && checkpoints.semantic_digest.as_deref() != Some(digest.as_str())
    {
        return Err(PlanError::new(
            Stage::Recovery,
            "stale_authorization_digest",
            "sealed digest does not match Plan",
        ));
    }
    if let Some(designer) = &checkpoints.designer {
        if designer.role != Role::Designer {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "Designer role mismatch",
            ));
        }
    }
    if let Some(reviewer) = &checkpoints.reviewer {
        if reviewer.role != Role::Reviewer {
            return Err(PlanError::new(
                Stage::Recovery,
                "corrupt_checkpoint",
                "Reviewer role mismatch",
            ));
        }
    }
    Ok(())
}

fn eligible_tasks_for(plan: &Plan, checkpoints: &Checkpoints) -> Result<Vec<String>, PlanError> {
    let mut eligible = Vec::new();
    for task in &plan.tasks {
        let state = checkpoints.tasks.get(&task.code).ok_or_else(|| {
            PlanError::new(Stage::Eligibility, "corrupt_checkpoint", task.code.clone())
        })?;
        if state.status == TaskStatus::Pending
            && task.prerequisites.iter().all(|edge| {
                checkpoints
                    .tasks
                    .get(&edge.from)
                    .is_some_and(|state| state.status == TaskStatus::Completed)
            })
        {
            eligible.push(task.code.clone());
        }
    }
    eligible.sort();
    Ok(eligible)
}

fn role_authority(plan: &Plan, role: Role) -> Result<String, PlanError> {
    plan.roles
        .iter()
        .find(|contract| contract.role == role)
        .map(|contract| contract.authority.clone())
        .ok_or_else(|| {
            PlanError::new(
                Stage::Validation,
                "role_cardinality",
                "requested role is not declared",
            )
        })
}

fn selected_decisions(plan: &Plan) -> Vec<DecisionSelection> {
    plan.dossier
        .questions
        .iter()
        .filter_map(|question| {
            question
                .selected
                .as_ref()
                .map(|selected| DecisionSelection {
                    code: question.code.clone(),
                    selected: selected.clone(),
                })
        })
        .collect()
}

fn self_children(plan: &Plan, parent: &str) -> Vec<String> {
    let mut children = plan
        .tasks
        .iter()
        .filter(|task| task.prerequisites.iter().any(|edge| edge.from == parent))
        .map(|task| task.code.clone())
        .collect::<Vec<_>>();
    children.sort();
    children
}

fn task_digest(task: &Task) -> Result<String, PlanError> {
    let value = serde_json::to_value(task)
        .map_err(|error| PlanError::new(Stage::Parse, "task_encode_failed", error.to_string()))?;
    Ok(sha256_hex(canonical_json(&value).as_bytes()))
}

fn validate_code(value: &str, prefix: &str, stage: Stage) -> Result<(), PlanError> {
    let expected = format!("{prefix}-");
    if !value.starts_with(&expected)
        || value.len() <= expected.len()
        || value.chars().any(|character| {
            !(character.is_ascii_uppercase() || character.is_ascii_digit() || character == '-')
        })
    {
        return Err(PlanError::new(
            stage,
            "invalid_code",
            format!("{prefix} code is not canonical"),
        ));
    }
    Ok(())
}

fn validate_relative_reference(reference: &str, stage: Stage) -> Result<(), PlanError> {
    if reference.is_empty() {
        return Ok(());
    }
    let path = Path::new(reference);
    if path.is_absolute()
        || reference.contains('\\')
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(PlanError::new(
            stage,
            "non_relative_reference",
            "declared artifact/reference must be repository-relative",
        ));
    }
    Ok(())
}

fn writes_overlap(left: &[String], right: &[String]) -> bool {
    left.iter().any(|left_path| {
        right.iter().any(|right_path| {
            left_path == right_path
                || left_path.starts_with(&format!("{right_path}/"))
                || right_path.starts_with(&format!("{left_path}/"))
        })
    })
}

fn ensure_private_directory(root: &Path) -> Result<(), PlanError> {
    if root.exists() {
        let metadata = fs::symlink_metadata(root)?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(PlanError::new(
                Stage::Persistence,
                "symlink_state",
                "delivery directory is not a private directory",
            ));
        }
    } else {
        fs::create_dir_all(root)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
    }
    for name in [PLAN_FILE, CHECKPOINT_FILE] {
        let path = root.join(name);
        if path.exists() && fs::symlink_metadata(&path)?.file_type().is_symlink() {
            return Err(PlanError::new(
                Stage::Persistence,
                "symlink_state",
                "delivery state entry is symlinked",
            ));
        }
    }
    Ok(())
}

fn persist_records_at(
    root: &Path,
    plan: &Plan,
    checkpoints: &Checkpoints,
) -> Result<(), PlanError> {
    ensure_private_directory(root)?;
    let plan_text = serde_json::to_string_pretty(&plan.current_value(Some(checkpoints))?)
        .map(|text| format!("{text}\n"))
        .map_err(|error| {
            PlanError::new(Stage::Persistence, "plan_encode_failed", error.to_string())
        })?;
    atomic_private_write(&root.join(PLAN_FILE), plan_text.as_bytes())?;
    persist_checkpoint_at(root, checkpoints)
}

fn persist_checkpoint_at(root: &Path, checkpoints: &Checkpoints) -> Result<(), PlanError> {
    ensure_private_directory(root)?;
    let checkpoint_text = serde_json::to_string_pretty(checkpoints)
        .map(|text| format!("{text}\n"))
        .map_err(|error| {
            PlanError::new(
                Stage::Persistence,
                "checkpoint_encode_failed",
                error.to_string(),
            )
        })?;
    atomic_private_write(&root.join(CHECKPOINT_FILE), checkpoint_text.as_bytes())
}

fn atomic_private_write(path: &Path, bytes: &[u8]) -> Result<(), PlanError> {
    if path.exists() && fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(PlanError::new(
            Stage::Persistence,
            "symlink_state",
            "cannot replace a symlinked state entry",
        ));
    }
    let parent = path.parent().ok_or_else(|| {
        PlanError::new(
            Stage::Persistence,
            "private_write_failed",
            "state has no parent",
        )
    })?;
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temp = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("state"),
        stamp
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    file.write_all(bytes)?;
    file.sync_all()?;
    drop(file);
    if path.exists() && fs::symlink_metadata(path)?.file_type().is_symlink() {
        let _ = fs::remove_file(&temp);
        return Err(PlanError::new(
            Stage::Persistence,
            "symlink_state",
            "state entry changed to symlink",
        ));
    }
    fs::rename(&temp, path).map_err(|error| {
        let _ = fs::remove_file(&temp);
        PlanError::from(error)
    })?;
    Ok(())
}

fn read_json_value(path: &Path, stage: Stage) -> Result<Value, PlanError> {
    if fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
    {
        return Err(PlanError::new(
            stage,
            "symlink_state",
            "state entry is symlinked",
        ));
    }
    let text = fs::read_to_string(path)
        .map_err(|error| PlanError::new(stage, "corrupt_checkpoint", error.to_string()))?;
    serde_json::from_str(&text)
        .map_err(|error| PlanError::new(stage, "corrupt_checkpoint", error.to_string()))
}

fn decode_strict<T: DeserializeOwned>(value: Value, stage: Stage) -> Result<T, PlanError> {
    serde_json::from_value(value).map_err(|error| {
        let code = if error.to_string().contains("unknown field") {
            "unknown_field"
        } else {
            "invalid_record_shape"
        };
        PlanError::new(stage, code, error.to_string())
    })
}

fn canonical_json(value: &Value) -> String {
    match value {
        Value::Object(object) => {
            let mut entries: Vec<(&String, &Value)> = object.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            let rendered = entries
                .into_iter()
                .map(|(key, value)| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(key).expect("key encoding"),
                        canonical_json(value)
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            format!("{{{rendered}}}")
        }
        Value::Array(items) => format!(
            "[{}]",
            items
                .iter()
                .map(canonical_json)
                .collect::<Vec<_>>()
                .join(",")
        ),
        _ => serde_json::to_string(value).expect("scalar encoding"),
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn runtime_stamp() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    format!("runtime-{millis}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    fn root(name: &str) -> PathBuf {
        let sequence = TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "lico-delivery-plan-{name}-{}-{sequence}",
            std::process::id()
        ))
    }

    fn task(code: &str, requirement: &str, output: &str, writes: &[&str]) -> Task {
        Task {
            code: code.to_string(),
            title: code.to_string(),
            contract: format!("contract-{code}"),
            requirements: vec![requirement.to_string()],
            outputs: vec![output.to_string()],
            acceptance_criteria: vec![format!("AC-{code}")],
            prerequisites: Vec::new(),
            owned_writes: writes.iter().map(|value| (*value).to_string()).collect(),
            references: Vec::new(),
            execution_policy: ExecutionPolicy {
                max_attempts: 1,
                allowed_effects: vec!["write".to_string()],
            },
        }
    }

    fn synthetic_plan() -> Plan {
        let mut plan = Plan::new("PLAN-SYNTHETIC-001", "Synthetic delivery");
        plan.dossier.questions.push(DecisionQuestion {
            code: "Q-001".to_string(),
            question: "Boundary?".to_string(),
            context: String::new(),
            options: vec![DecisionOption {
                id: "native".to_string(),
                label: "Native".to_string(),
            }],
            default: None,
            selected: None,
        });
        plan.requirements = vec![Requirement {
            code: "REQ-001".to_string(),
            statement: "Synthetic".to_string(),
        }];
        plan.tasks = vec![
            task("TASK-001", "REQ-001", "OUT-001", &["src/a.rs"]),
            task("TASK-002", "REQ-001", "OUT-002", &["src/b.rs"]),
        ];
        plan.outputs = vec![
            Output {
                code: "OUT-001".to_string(),
                title: "A".to_string(),
                produced_by: "TASK-001".to_string(),
                references: Vec::new(),
            },
            Output {
                code: "OUT-002".to_string(),
                title: "B".to_string(),
                produced_by: "TASK-002".to_string(),
                references: Vec::new(),
            },
        ];
        plan.acceptance_criteria = vec![
            AcceptanceCriterion {
                code: "AC-TASK-001".to_string(),
                statement: "A".to_string(),
                task: Some("TASK-001".to_string()),
                requirement: Some("REQ-001".to_string()),
                output: Some("OUT-001".to_string()),
            },
            AcceptanceCriterion {
                code: "AC-TASK-002".to_string(),
                statement: "B".to_string(),
                task: Some("TASK-002".to_string()),
                requirement: None,
                output: Some("OUT-002".to_string()),
            },
        ];
        plan
    }

    #[test]
    fn resolved_plan_authorizes_and_reloads_stably() {
        let root = root("lifecycle");
        let mut engine = DeliveryPlanEngine::create(&root, synthetic_plan()).unwrap();
        engine
            .resolve_dossier(BTreeMap::from([(
                "Q-001".to_string(),
                "native".to_string(),
            )]))
            .unwrap();
        engine.open_designer("native/design/one").unwrap();
        engine.complete_designer(None).unwrap();
        engine.mark_ready().unwrap();
        let digest = engine.authorize().unwrap();
        assert_eq!(digest.len(), 64);
        assert_eq!(
            engine.next_action().unwrap(),
            NextAction::Worker {
                tasks: vec!["TASK-001".to_string(), "TASK-002".to_string()]
            }
        );
        let loaded = DeliveryPlanEngine::load(&root).unwrap();
        assert_eq!(loaded.next_action().unwrap(), engine.next_action().unwrap());
        assert_eq!(loaded.checkpoints().revision, engine.checkpoints().revision);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn downstream_waits_for_both_independent_tasks() {
        let mut plan = synthetic_plan();
        plan.tasks.push(Task {
            code: "TASK-003".to_string(),
            title: "Downstream".to_string(),
            contract: "contract-TASK-003".to_string(),
            requirements: vec!["REQ-001".to_string()],
            outputs: vec!["OUT-003".to_string()],
            acceptance_criteria: vec!["AC-TASK-003".to_string()],
            prerequisites: vec![
                Prerequisite {
                    from: "TASK-001".to_string(),
                    output: "OUT-001".to_string(),
                    guarantee_input: "input-a".to_string(),
                },
                Prerequisite {
                    from: "TASK-002".to_string(),
                    output: "OUT-002".to_string(),
                    guarantee_input: "input-b".to_string(),
                },
            ],
            owned_writes: vec!["src/c.rs".to_string()],
            references: Vec::new(),
            execution_policy: ExecutionPolicy::default(),
        });
        plan.outputs.push(Output {
            code: "OUT-003".to_string(),
            title: "C".to_string(),
            produced_by: "TASK-003".to_string(),
            references: Vec::new(),
        });
        plan.acceptance_criteria.push(AcceptanceCriterion {
            code: "AC-TASK-003".to_string(),
            statement: "C".to_string(),
            task: Some("TASK-003".to_string()),
            requirement: None,
            output: Some("OUT-003".to_string()),
        });
        let root = root("graph");
        let mut engine = DeliveryPlanEngine::create(&root, plan).unwrap();
        engine
            .resolve_dossier(BTreeMap::from([(
                "Q-001".to_string(),
                "native".to_string(),
            )]))
            .unwrap();
        engine.open_designer("native/design/graph").unwrap();
        engine.complete_designer(None).unwrap();
        engine.mark_ready().unwrap();
        engine.authorize().unwrap();
        for code in ["TASK-001", "TASK-002"] {
            let dispatch = format!("dispatch-{code}");
            engine
                .bind_dispatch(DispatchBinding {
                    id: dispatch.clone(),
                    task_code: code.to_string(),
                    attempt: 1,
                    conversation_location: None,
                    receipt: None,
                })
                .unwrap();
            engine.complete_dispatch(&dispatch, Vec::new()).unwrap();
            engine.accept_task(code, &dispatch, None).unwrap();
        }
        assert_eq!(
            engine.next_action().unwrap(),
            NextAction::Worker {
                tasks: vec!["TASK-003".to_string()]
            }
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn semantic_digest_excludes_runtime_checkpoint_fields() {
        let root = root("digest");
        let mut engine = DeliveryPlanEngine::create(&root, synthetic_plan()).unwrap();
        let before = engine.semantic_digest().unwrap();
        engine
            .resolve_dossier(BTreeMap::from([(
                "Q-001".to_string(),
                "native".to_string(),
            )]))
            .unwrap();
        let after_resolution = engine.semantic_digest().unwrap();
        assert_ne!(before, after_resolution);
        engine.open_designer("native/design/digest").unwrap();
        engine.complete_designer(None).unwrap();
        engine.mark_ready().unwrap();
        let sealed = engine.authorize().unwrap();
        assert_eq!(sealed, engine.semantic_digest().unwrap());
        let dispatch_before = engine.semantic_digest().unwrap();
        engine
            .bind_dispatch(DispatchBinding {
                id: "dispatch-1".to_string(),
                task_code: "TASK-001".to_string(),
                attempt: 1,
                conversation_location: Some("opaque/location".to_string()),
                receipt: Some("receipt".to_string()),
            })
            .unwrap();
        assert_eq!(dispatch_before, engine.semantic_digest().unwrap());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn continuation_freezes_started_task_and_seals_revision() {
        let root = root("continuation");
        let mut engine = DeliveryPlanEngine::create(&root, synthetic_plan()).unwrap();
        engine
            .resolve_dossier(BTreeMap::from([(
                "Q-001".to_string(),
                "native".to_string(),
            )]))
            .unwrap();
        engine.open_designer("native/design/continuation").unwrap();
        engine.complete_designer(None).unwrap();
        engine.mark_ready().unwrap();
        engine.authorize().unwrap();
        let digest_before = engine.checkpoints().tasks["TASK-001"]
            .contract_digest
            .clone();
        engine
            .bind_dispatch(DispatchBinding {
                id: "dispatch-1".to_string(),
                task_code: "TASK-001".to_string(),
                attempt: 1,
                conversation_location: None,
                receipt: None,
            })
            .unwrap();
        let revision_before = engine.checkpoints().revision;
        let mut replacement = engine
            .plan()
            .tasks
            .iter()
            .find(|task| task.code == "TASK-002")
            .unwrap()
            .clone();
        replacement.contract = "revised".to_string();
        let digest = engine
            .continue_unstarted(ContinuationRequest { task: replacement })
            .unwrap();
        assert_eq!(engine.checkpoints().revision, revision_before + 1);
        assert_eq!(
            engine.checkpoints().tasks["TASK-001"]
                .started_contract_digest
                .as_deref(),
            Some(digest_before.as_str())
        );
        assert_eq!(engine.semantic_digest().unwrap(), digest);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn cancellation_is_atomic_checkpoint_state_and_preserves_semantic_plan() {
        let root = root("cancel-checkpoint");
        let mut engine = DeliveryPlanEngine::create(&root, synthetic_plan()).unwrap();
        engine
            .resolve_dossier(BTreeMap::from([(
                "Q-001".to_string(),
                "native".to_string(),
            )]))
            .unwrap();
        engine.open_designer("native/design/cancel").unwrap();
        engine.complete_designer(None).unwrap();
        engine.mark_ready().unwrap();
        engine.authorize().unwrap();
        let digest_before = engine.semantic_digest().unwrap();
        let plan_before = fs::read(root.join(PLAN_FILE)).unwrap();

        engine.cancel().unwrap();
        engine.cancel().unwrap();
        assert!(engine.checkpoints().cancellation_requested);
        assert_eq!(engine.checkpoints().phase, PlanPhase::Blocked);
        assert_eq!(engine.next_action().unwrap(), NextAction::Cancelled);
        assert_eq!(engine.semantic_digest().unwrap(), digest_before);
        assert_eq!(fs::read(root.join(PLAN_FILE)).unwrap(), plan_before);
        let checkpoint: Value =
            serde_json::from_slice(&fs::read(root.join(CHECKPOINT_FILE)).unwrap()).unwrap();
        assert_eq!(checkpoint["delivery_status"], "cancelled");
        assert_eq!(checkpoint.as_object().unwrap().len(), 6);

        let mut reloaded = DeliveryPlanEngine::load(&root).unwrap();
        assert!(reloaded.checkpoints().cancellation_requested);
        assert_eq!(reloaded.checkpoints().phase, PlanPhase::Blocked);
        assert_eq!(reloaded.next_action().unwrap(), NextAction::Cancelled);
        assert_eq!(reloaded.semantic_digest().unwrap(), digest_before);
        let error = reloaded
            .continue_unstarted(ContinuationRequest {
                task: reloaded.plan().tasks[1].clone(),
            })
            .unwrap_err();
        assert_eq!(error.code(), "delivery_cancelled");
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn invalid_generation_and_unknown_fields_fail_closed() {
        let mut value = serde_json::to_value(synthetic_plan()).unwrap();
        value["schema"] = Value::String("better-plan.plan/v2".to_string());
        let error = Plan::from_json_str(&serde_json::to_string(&value).unwrap()).unwrap_err();
        assert_eq!(error.code(), "unsupported_schema");
        value["schema"] = Value::String(PLAN_SCHEMA.to_string());
        value["unknown"] = Value::Bool(true);
        let error = Plan::from_json_str(&serde_json::to_string(&value).unwrap()).unwrap_err();
        assert_eq!(error.code(), "unknown_field");
    }
}
