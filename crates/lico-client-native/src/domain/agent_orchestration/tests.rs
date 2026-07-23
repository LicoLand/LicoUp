//! Focused tests for the durable orchestration authority.
//!
//! These tests intentionally exercise the concrete compiler, reducer, file store, lease,
//! idempotency index, and dispatch boundary. Test-only seams may control time, dispatch results,
//! and crash points, but they must not substitute an in-memory reducer or store.

use super::{
    ApprovalRule, ArtifactRef, CompileErrorCode, CompiledPolicy, Condition, CrashBoundary,
    CrashBoundaryInjector, DispatchOutcome, DispatchPort, DispatchRequest, EngineErrorCode,
    EngineLimits, FailureAction, ManualClock, OutputMode, PersistentWorkflowEngine, PolicyDocument,
    PolicyStep, PolicyWorkflow, ReasoningLevel, StepPurpose, StepState, ValidationRule,
    WorkflowCommand, WorkflowEvent, WorkflowReceipt, WorkflowSnapshot, WorkflowState,
    reducer::reduce_workflow_event,
    store::{DurableWorkflowStore, StoreLimits},
};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{
    collections::{HashSet, VecDeque},
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Barrier, Mutex},
};

const POLICY_SCHEMA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../packages/contracts/client/agent-orchestration-policy.schema.json"
));
const MODULE_SOURCE: &str = concat!(
    include_str!("mod.rs"),
    include_str!("engine.rs"),
    include_str!("reducer.rs"),
    include_str!("store/mod.rs")
);

#[derive(Clone, Default)]
struct ScriptedDispatch {
    inner: Arc<Mutex<ScriptedDispatchState>>,
}

type ScriptedDispatchPort = ScriptedDispatch;

#[derive(Default)]
struct ScriptedDispatchState {
    outcomes: VecDeque<DispatchOutcome>,
    requests: Vec<DispatchRequest>,
}

impl ScriptedDispatch {
    fn with_outcomes(outcomes: impl IntoIterator<Item = DispatchOutcome>) -> Self {
        Self {
            inner: Arc::new(Mutex::new(ScriptedDispatchState {
                outcomes: outcomes.into_iter().collect(),
                requests: Vec::new(),
            })),
        }
    }

    fn requests(&self) -> Vec<DispatchRequest> {
        self.inner.lock().unwrap().requests.clone()
    }
}

impl DispatchPort for ScriptedDispatch {
    fn dispatch(&self, request: DispatchRequest) -> DispatchOutcome {
        let mut state = self.inner.lock().unwrap();
        state.requests.push(request);
        state
            .outcomes
            .pop_front()
            .unwrap_or(DispatchOutcome::KnownFailure {
                reason_code: "synthetic_dispatch_exhausted".into(),
                retryable: false,
            })
    }
}

#[derive(Clone, Default)]
struct OneShotCrash {
    target: Arc<Mutex<Option<CrashBoundary>>>,
}

impl OneShotCrash {
    fn at(boundary: CrashBoundary) -> Self {
        Self {
            target: Arc::new(Mutex::new(Some(boundary))),
        }
    }
}

impl CrashBoundaryInjector for OneShotCrash {
    fn should_crash(&self, boundary: CrashBoundary) -> bool {
        let mut target = self.target.lock().unwrap();
        if target.as_ref() == Some(&boundary) {
            target.take();
            true
        } else {
            false
        }
    }
}

struct TempState(PathBuf);

impl TempState {
    fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "lico-arc-orchestration-{label}-{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempState {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn step(id: &str, predecessor_id: Option<&str>) -> PolicyStep {
    PolicyStep {
        id: id.into(),
        predecessor_id: predecessor_id.map(str::to_owned),
        purpose: StepPurpose::Action,
        role_id: Some(format!("role-{id}")),
        agent_id: Some(format!("agent-{id}")),
        model_id: Some(format!("model-{id}")),
        reasoning_level: Some(ReasoningLevel::Max),
        context_step_ids: predecessor_id.into_iter().map(str::to_owned).collect(),
        max_context_bytes: 4_096,
        output_mode: OutputMode::Text,
        timeout_ms: 5_000,
        max_attempts: 2,
        failure_action: FailureAction::Stop,
        approval: ApprovalRule::NotRequired,
        condition: Condition::Always,
        validation: None,
    }
}

fn policy(steps: Vec<PolicyStep>) -> PolicyDocument {
    PolicyDocument {
        schema_version: 3,
        id: "policy-synthetic".into(),
        label: "Synthetic policy".into(),
        commander: None,
        model_library: Vec::new(),
        agents: Vec::new(),
        workflow: PolicyWorkflow { steps },
    }
}

fn engine_limits() -> EngineLimits {
    EngineLimits {
        max_events_per_page: 3,
        max_receipt_summary_bytes: 96,
        max_predecessor_context_bytes: 256,
        ..EngineLimits::default()
    }
}

fn store_limits() -> StoreLimits {
    StoreLimits {
        max_journal_entries: 128,
        max_journal_bytes: 64 * 1024,
        max_snapshot_bytes: 32 * 1024,
        max_idempotency_entries: 64,
        max_events: 64,
        max_database_bytes: 2 * 1024 * 1024,
    }
}

fn open_engine(
    root: &Path,
    dispatch: ScriptedDispatch,
    clock: ManualClock,
    crash: Arc<dyn CrashBoundaryInjector>,
) -> Result<PersistentWorkflowEngine, EngineErrorCode> {
    open_engine_with_store_limits(root, dispatch, clock, crash, store_limits())
}

fn open_engine_with_store_limits(
    root: &Path,
    dispatch: ScriptedDispatch,
    clock: ManualClock,
    crash: Arc<dyn CrashBoundaryInjector>,
    limits: StoreLimits,
) -> Result<PersistentWorkflowEngine, EngineErrorCode> {
    let store = DurableWorkflowStore::open(root, limits)?;
    PersistentWorkflowEngine::open_active(
        store,
        Arc::new(dispatch),
        Arc::new(clock),
        crash,
        engine_limits(),
    )
}

fn submit_command(
    idempotency_key: &str,
    workflow_id: &str,
    policy: PolicyDocument,
) -> WorkflowCommand {
    WorkflowCommand::Submit {
        idempotency_key: idempotency_key.into(),
        workflow_id: workflow_id.into(),
        policy,
        input_artifact: ArtifactRef {
            opaque_handle: format!("artifact-input-{workflow_id}"),
            digest: "a".repeat(64),
        },
    }
}

fn reduce_all(
    initial: WorkflowSnapshot,
    events: impl IntoIterator<Item = WorkflowEvent>,
) -> Result<WorkflowSnapshot, EngineErrorCode> {
    events.into_iter().try_fold(initial, |state, event| {
        reduce_workflow_event(&state, &event)
    })
}

fn database_path(root: &Path) -> PathBuf {
    DurableWorkflowStore::database_path(root)
}

fn query_count(connection: &Connection, table: &str) -> i64 {
    connection
        .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
            row.get(0)
        })
        .unwrap()
}

fn latest_generation(connection: &Connection, table: &str) -> i64 {
    connection
        .query_row(
            &format!("SELECT COALESCE(MAX(generation), 0) FROM {table}"),
            [],
            |row| row.get(0),
        )
        .unwrap()
}

fn persisted_text_columns(connection: &Connection) -> String {
    let queries = [
        "SELECT event_json FROM workflow_journal",
        "SELECT snapshot_json FROM workflow_snapshots",
        "SELECT event_json FROM workflow_events",
        "SELECT receipt_json FROM workflow_idempotency",
        "SELECT receipt_json FROM workflow_receipts",
    ];
    let mut combined = String::new();
    for query in queries {
        let mut statement = connection.prepare(query).unwrap();
        let rows = statement
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap();
        for row in rows {
            combined.push_str(&row.unwrap());
            combined.push('\n');
        }
    }
    combined
}

fn database_bytes(path: &Path) -> u64 {
    let wal = PathBuf::from(format!("{}-wal", path.to_string_lossy()));
    let shm = PathBuf::from(format!("{}-shm", path.to_string_lossy()));
    fs::metadata(path).map(|meta| meta.len()).unwrap_or(0)
        + fs::metadata(wal).map(|meta| meta.len()).unwrap_or(0)
        + fs::metadata(shm).map(|meta| meta.len()).unwrap_or(0)
}

#[test]
fn agent_orchestration_policy_schema_is_closed_canonical_and_empty_means_empty() {
    let schema: Value = serde_json::from_str(POLICY_SCHEMA).unwrap();
    assert_eq!(
        schema["$schema"],
        "https://json-schema.org/draft/2020-12/schema"
    );
    assert_eq!(schema["type"], "object");
    assert_eq!(schema["additionalProperties"], false);
    assert_eq!(
        schema["required"],
        json!([
            "schemaVersion",
            "id",
            "label",
            "commander",
            "modelLibrary",
            "agents",
            "workflow"
        ])
    );
    assert_eq!(schema["properties"]["schemaVersion"]["const"], 3);
    assert_eq!(schema["$defs"]["workflow"]["additionalProperties"], false);
    assert_eq!(
        schema["$defs"]["workflow"]["properties"]["steps"]["maxItems"],
        super::MAX_POLICY_STEPS
    );
    assert_eq!(
        schema["$defs"]["workflowStep"]["additionalProperties"],
        false
    );
    assert_eq!(
        schema["$defs"]["workflowStep"]["required"],
        json!([
            "id",
            "predecessorId",
            "purpose",
            "roleId",
            "agentId",
            "modelId",
            "reasoningLevel",
            "contextStepIds",
            "maxContextBytes",
            "outputMode",
            "timeoutMs",
            "maxAttempts",
            "failureAction",
            "approval",
            "condition",
            "validation"
        ])
    );
    assert!(
        POLICY_SCHEMA.find("\"default\"").is_none(),
        "canonical policy must not infer defaults"
    );

    let empty_json = json!({
        "schemaVersion": 3,
        "id": "policy-empty",
        "label": "",
        "commander": null,
        "modelLibrary": [],
        "agents": [],
        "workflow": { "steps": [] }
    });
    let empty: PolicyDocument = serde_json::from_value(empty_json).unwrap();
    let compiled = CompiledPolicy::compile(empty).unwrap();
    assert!(compiled.ordered_steps().is_empty());
    assert!(compiled.step_index().is_empty());

    let unknown = json!({
        "schemaVersion": 3,
        "id": "policy-empty",
        "label": "",
        "commander": null,
        "modelLibrary": [],
        "agents": [],
        "workflow": { "steps": [] },
        "fallbackAgent": "must-not-be-accepted"
    });
    assert!(serde_json::from_value::<PolicyDocument>(unknown).is_err());
}

#[test]
fn agent_orchestration_compiler_preserves_assignments_as_data_and_rejects_invalid_graphs() {
    let mut first = step("intent", None);
    first.role_id = Some("configured-role-a".into());
    first.agent_id = Some("configured-agent-a".into());
    first.model_id = Some("configured-model-a".into());
    first.reasoning_level = Some(ReasoningLevel::Max);
    first.approval = ApprovalRule::Required;
    let mut second = step("verify", Some("intent"));
    second.role_id = Some("configured-role-b".into());
    second.agent_id = Some("configured-agent-b".into());
    second.model_id = Some("configured-model-b".into());
    second.reasoning_level = Some(ReasoningLevel::Low);
    second.purpose = StepPurpose::Validation;
    second.validation = Some(ValidationRule::RequiredPass {
        evidence_kinds: vec!["tests".into(), "review".into()],
    });
    let compiled = CompiledPolicy::compile(policy(vec![first, second])).unwrap();
    assert_eq!(compiled.ordered_steps().len(), 2);
    assert_eq!(compiled.step_index().len(), 2);
    assert_eq!(compiled.index_of("intent"), Some(0));
    assert_eq!(compiled.index_of("verify"), Some(1));
    let configured = &compiled.ordered_steps()[0];
    assert_eq!(configured.role_id.as_deref(), Some("configured-role-a"));
    assert_eq!(configured.agent_id.as_deref(), Some("configured-agent-a"));
    assert_eq!(configured.model_id.as_deref(), Some("configured-model-a"));
    assert_eq!(configured.reasoning_level, Some(ReasoningLevel::Max));
    let pinned_revision = compiled.revision_digest().to_owned();
    let mut changed = compiled.source_policy().clone();
    changed.workflow.steps[0].model_id = Some("configured-model-c".into());
    assert_ne!(
        CompiledPolicy::compile(changed).unwrap().revision_digest(),
        pinned_revision
    );

    let mut duplicate = step("same", None);
    duplicate.predecessor_id = Some("same".into());
    let error = CompiledPolicy::compile(policy(vec![step("same", None), duplicate])).unwrap_err();
    assert_eq!(error.code(), CompileErrorCode::DuplicateStepId);

    let error = CompiledPolicy::compile(policy(vec![step("orphan", Some("missing"))])).unwrap_err();
    assert_eq!(error.code(), CompileErrorCode::MissingPredecessor);

    let error = CompiledPolicy::compile(policy(vec![
        step("cycle-a", Some("cycle-b")),
        step("cycle-b", Some("cycle-a")),
    ]))
    .unwrap_err();
    assert_eq!(error.code(), CompileErrorCode::Cycle);

    let oversized = (0..=super::MAX_POLICY_STEPS)
        .map(|index| {
            step(
                &format!("step-{index}"),
                index.checked_sub(1).map(|p| format!("step-{p}")).as_deref(),
            )
        })
        .collect();
    let error = CompiledPolicy::compile(policy(oversized)).unwrap_err();
    assert_eq!(error.code(), CompileErrorCode::LimitExceeded);

    let mut unbounded_id = step("bounded", None);
    unbounded_id.agent_id = Some("x".repeat(super::MAX_AGENT_MODEL_BYTES + 1));
    assert_eq!(
        CompiledPolicy::compile(policy(vec![unbounded_id]))
            .unwrap_err()
            .code(),
        CompileErrorCode::LimitExceeded
    );
    let mut unbounded_timeout = step("bounded", None);
    unbounded_timeout.timeout_ms = super::MAX_STEP_TIMEOUT_MS + 1;
    assert_eq!(
        CompiledPolicy::compile(policy(vec![unbounded_timeout]))
            .unwrap_err()
            .code(),
        CompileErrorCode::LimitExceeded
    );
    let mut unbounded_attempts = step("bounded", None);
    unbounded_attempts.max_attempts = super::MAX_STEP_ATTEMPTS + 1;
    assert_eq!(
        CompiledPolicy::compile(policy(vec![unbounded_attempts]))
            .unwrap_err()
            .code(),
        CompileErrorCode::LimitExceeded
    );
    let mut invalid_pointer = step("pointer", None);
    invalid_pointer.predecessor_id = Some("source".into());
    invalid_pointer.context_step_ids = vec!["source".into()];
    invalid_pointer.condition = Condition::JsonPointerEquals {
        source_step_id: "source".into(),
        pointer: format!("/{}", "x/".repeat(super::MAX_JSON_POINTER_SEGMENTS + 1)),
        expected: json!(true),
    };
    assert_eq!(
        CompiledPolicy::compile(policy(vec![step("source", None), invalid_pointer]))
            .unwrap_err()
            .code(),
        CompileErrorCode::InvalidCondition
    );

    let metrics = compiled.compile_metrics();
    assert_eq!(metrics.visited_steps, compiled.ordered_steps().len());
    assert_eq!(metrics.indexed_steps, compiled.step_index().len());

    let lower = MODULE_SOURCE.to_ascii_lowercase();
    for forbidden in ["kimi", "claude", "deepseek", "gpt-5"] {
        assert!(
            !lower.contains(forbidden),
            "production orchestration source hardcodes {forbidden}"
        );
    }
    for forbidden_branch in [
        "if role_id",
        "match role_id",
        "\"frontend\" =>",
        "\"backend\" =>",
        "\"planner\" =>",
        "\"verifier\" =>",
    ] {
        assert!(
            !lower.contains(forbidden_branch),
            "production orchestration source contains a role branch: {forbidden_branch}"
        );
    }
}

#[test]
fn agent_orchestration_engine_dispatches_exact_configured_assignments_and_changes_with_policy_data()
{
    fn configured_policy(variant: &str) -> PolicyDocument {
        let mut plan = step("planner", None);
        plan.role_id = Some(format!("role-planner-{variant}"));
        plan.agent_id = Some(format!("agent-planner-{variant}"));
        plan.model_id = Some(format!("model-planner-{variant}"));
        plan.reasoning_level = Some(if variant == "a" {
            ReasoningLevel::Max
        } else {
            ReasoningLevel::High
        });

        let mut implement = step("implementation", Some("planner"));
        implement.role_id = Some(format!("role-implementation-{variant}"));
        implement.agent_id = Some(format!("agent-implementation-{variant}"));
        implement.model_id = Some(format!("model-implementation-{variant}"));
        implement.reasoning_level = Some(if variant == "a" {
            ReasoningLevel::High
        } else {
            ReasoningLevel::Medium
        });

        let mut validate = step("validation", Some("implementation"));
        validate.role_id = Some(format!("role-validate-{variant}"));
        validate.agent_id = Some(format!("agent-validate-{variant}"));
        validate.model_id = Some(format!("model-validate-{variant}"));
        validate.reasoning_level = Some(if variant == "a" {
            ReasoningLevel::Low
        } else {
            ReasoningLevel::Max
        });
        validate.purpose = StepPurpose::Validation;
        validate.validation = Some(ValidationRule::RequiredPass {
            evidence_kinds: vec!["tests".into(), "review".into()],
        });
        policy(vec![plan, implement, validate])
    }

    fn run_configured_policy(
        root: &Path,
        policy: PolicyDocument,
        workflow_id: &str,
    ) -> Vec<DispatchRequest> {
        let port = ScriptedDispatchPort::with_outcomes([
            DispatchOutcome::Succeeded {
                summary: "synthetic-planner-output".into(),
                digest: "1".repeat(64),
            },
            DispatchOutcome::Succeeded {
                summary: "synthetic-implementation-output".into(),
                digest: "2".repeat(64),
            },
            DispatchOutcome::ValidationPassed {
                summary: "synthetic-validation-output".into(),
                digest: "3".repeat(64),
            },
        ]);
        let engine = open_engine(
            root,
            port.clone(),
            ManualClock::new(1_000),
            Arc::new(OneShotCrash::default()),
        )
        .unwrap();
        engine
            .handle(submit_command(
                &format!("submit-{workflow_id}"),
                workflow_id,
                policy,
            ))
            .unwrap();
        engine
            .drive(workflow_id, &format!("drive-planner-{workflow_id}"))
            .unwrap();
        engine
            .drive(workflow_id, &format!("drive-implementation-{workflow_id}"))
            .unwrap();
        let terminal = engine
            .drive(workflow_id, &format!("drive-validation-{workflow_id}"))
            .unwrap();
        assert_eq!(terminal.state, WorkflowState::Completed);
        port.requests()
    }

    fn assert_requests(requests: &[DispatchRequest], variant: &str) {
        assert_eq!(requests.len(), 3);
        let expected = [
            (
                "planner",
                "planner",
                StepPurpose::Action,
                if variant == "a" {
                    ReasoningLevel::Max
                } else {
                    ReasoningLevel::High
                },
            ),
            (
                "implementation",
                "implementation",
                StepPurpose::Action,
                if variant == "a" {
                    ReasoningLevel::High
                } else {
                    ReasoningLevel::Medium
                },
            ),
            (
                "validation",
                "validate",
                StepPurpose::Validation,
                if variant == "a" {
                    ReasoningLevel::Low
                } else {
                    ReasoningLevel::Max
                },
            ),
        ];
        for (index, (request, (step_id, assignment, purpose, reasoning))) in
            requests.iter().zip(expected).enumerate()
        {
            let expected_role = format!("role-{assignment}-{variant}");
            let expected_agent = format!("agent-{assignment}-{variant}");
            let expected_model = format!("model-{assignment}-{variant}");
            assert_eq!(request.step_id, step_id);
            assert_eq!(request.role_id.as_deref(), Some(expected_role.as_str()));
            assert_eq!(request.agent_id.as_deref(), Some(expected_agent.as_str()));
            assert_eq!(request.model_id.as_deref(), Some(expected_model.as_str()));
            assert_eq!(request.reasoning_level, Some(reasoning));
            assert_eq!(request.purpose, purpose);
            if purpose == StepPurpose::Validation {
                assert_eq!(
                    request.validation,
                    Some(ValidationRule::RequiredPass {
                        evidence_kinds: vec!["tests".into(), "review".into()],
                    })
                );
            } else {
                assert_eq!(request.validation, None);
            }
            assert_eq!(
                request
                    .input_artifact
                    .as_ref()
                    .map(|artifact| artifact.digest.as_str()),
                Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            );
            assert_eq!(
                request.predecessor_artifacts.len(),
                if index > 0 { 1 } else { 0 }
            );
            for artifact in &request.predecessor_artifacts {
                assert!(!artifact.opaque_handle.is_empty() && artifact.opaque_handle.len() <= 128);
                assert_eq!(artifact.digest.len(), 64);
                assert!(artifact.digest.bytes().all(|byte| byte.is_ascii_hexdigit()));
            }
            if index > 0 {
                assert_eq!(
                    request.predecessor_artifacts[0].digest,
                    format!("{}", index).repeat(64)
                );
            }
            let serialized = serde_json::to_string(request).unwrap();
            for forbidden in [
                "\"prompt\"",
                "\"rawOutput\"",
                "\"summary\"",
                "synthetic-planner-output",
                "synthetic-implementation-output",
                "synthetic-validation-output",
            ] {
                assert!(
                    !serialized.contains(forbidden),
                    "dispatch request leaked {forbidden}"
                );
            }
        }
    }

    let policy_a = configured_policy("a");
    let policy_b = configured_policy("b");
    let without_assignments = |policy: &PolicyDocument| {
        let mut value = serde_json::to_value(policy).unwrap();
        for step in value["workflow"]["steps"].as_array_mut().unwrap() {
            for field in ["roleId", "agentId", "modelId", "reasoningLevel"] {
                step.as_object_mut().unwrap().remove(field);
            }
        }
        value
    };
    assert_eq!(
        without_assignments(&policy_a),
        without_assignments(&policy_b)
    );
    let compiled_a = CompiledPolicy::compile(policy_a.clone()).unwrap();
    let compiled_b = CompiledPolicy::compile(policy_b.clone()).unwrap();
    assert_ne!(compiled_a.revision_digest(), compiled_b.revision_digest());
    assert_eq!(
        compiled_a
            .ordered_steps()
            .iter()
            .map(|step| (&step.id, &step.purpose, &step.validation))
            .collect::<Vec<_>>(),
        compiled_b
            .ordered_steps()
            .iter()
            .map(|step| (&step.id, &step.purpose, &step.validation))
            .collect::<Vec<_>>(),
        "the comparison policies may differ only in role/agent/model/reasoning assignments",
    );

    let state_a = TempState::new("configured-dispatch-a");
    let requests_a = run_configured_policy(state_a.path(), policy_a, "workflow-config-a");
    assert_requests(&requests_a, "a");
    let state_b = TempState::new("configured-dispatch-b");
    let requests_b = run_configured_policy(state_b.path(), policy_b, "workflow-config-b");
    assert_requests(&requests_b, "b");
    assert_ne!(
        requests_a
            .iter()
            .map(|request| (
                &request.role_id,
                &request.agent_id,
                &request.model_id,
                request.reasoning_level
            ))
            .collect::<Vec<_>>(),
        requests_b
            .iter()
            .map(|request| (
                &request.role_id,
                &request.agent_id,
                &request.model_id,
                request.reasoning_level
            ))
            .collect::<Vec<_>>(),
    );
    let production = MODULE_SOURCE.to_ascii_lowercase();
    for fixture_literal in [
        "role-planner-a",
        "agent-implementation-a",
        "model-validate-a",
        "role-planner-b",
        "agent-implementation-b",
        "model-validate-b",
    ] {
        assert!(!production.contains(fixture_literal));
    }
}

#[test]
fn agent_orchestration_direct_reducer_transition_table_is_total_and_irreversible() {
    let compiled = CompiledPolicy::compile(policy(vec![
        step("first", None),
        step("second", Some("first")),
    ]))
    .unwrap();
    let initial = WorkflowSnapshot::initial("workflow-direct", &compiled);

    let false_state = reduce_all(
        initial.clone(),
        [
            WorkflowEvent::Admitted {
                input_artifact: ArtifactRef {
                    opaque_handle: "artifact-input-test".into(),
                    digest: "a".repeat(64),
                },
            },
            WorkflowEvent::ConditionEvaluated {
                step_id: "first".into(),
                matched: false,
            },
        ],
    )
    .unwrap();
    assert_eq!(false_state.step("first").unwrap().state, StepState::Skipped);
    assert_eq!(
        false_state.steps.len(),
        2,
        "predicate-false must retain the immutable full step vector"
    );

    let true_state = reduce_all(
        initial.clone(),
        [
            WorkflowEvent::Admitted {
                input_artifact: ArtifactRef {
                    opaque_handle: "artifact-input-test".into(),
                    digest: "a".repeat(64),
                },
            },
            WorkflowEvent::ConditionEvaluated {
                step_id: "first".into(),
                matched: true,
            },
            WorkflowEvent::DispatchStarted {
                step_id: "first".into(),
                attempt: 1,
                owner_fence: 7,
                absolute_deadline_ms: 101,
            },
        ],
    )
    .unwrap();
    assert_eq!(
        true_state.step("first").unwrap().state,
        StepState::Dispatching
    );
    assert_eq!(
        true_state
            .steps
            .iter()
            .filter(|step| step.state.is_active())
            .count(),
        1
    );

    let terminal_cases = [
        (
            WorkflowState::Completed,
            vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::ConditionEvaluated {
                    step_id: "first".into(),
                    matched: true,
                },
                WorkflowEvent::DispatchStarted {
                    step_id: "first".into(),
                    attempt: 1,
                    owner_fence: 7,
                    absolute_deadline_ms: 101,
                },
                WorkflowEvent::DispatchProvenSucceeded {
                    step_id: "first".into(),
                    artifact_handle: "artifact-1".into(),
                    digest: "a".repeat(64),
                },
                WorkflowEvent::ConditionEvaluated {
                    step_id: "second".into(),
                    matched: false,
                },
                WorkflowEvent::WorkflowCompleted,
            ],
        ),
        (
            WorkflowState::Failed,
            vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::WorkflowFailed {
                    reason_code: "known_failure".into(),
                },
            ],
        ),
        (
            WorkflowState::Cancelled,
            vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::WorkflowCancelled {
                    reason_code: "cancelled".into(),
                },
            ],
        ),
        (
            WorkflowState::Unknown,
            vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::WorkflowUnknown {
                    reason_code: "external_outcome_unproven".into(),
                },
            ],
        ),
    ];
    for (expected, events) in terminal_cases {
        let terminal = reduce_all(initial.clone(), events).unwrap();
        assert_eq!(terminal.state, expected);
        for late in [
            WorkflowEvent::Admitted {
                input_artifact: ArtifactRef {
                    opaque_handle: "artifact-input-test".into(),
                    digest: "a".repeat(64),
                },
            },
            WorkflowEvent::WorkflowCancelled {
                reason_code: "late_cancel".into(),
            },
            WorkflowEvent::DispatchProvenSucceeded {
                step_id: "first".into(),
                artifact_handle: "late".into(),
                digest: "b".repeat(64),
            },
        ] {
            assert_eq!(
                reduce_workflow_event(&terminal, &late).unwrap_err(),
                EngineErrorCode::TerminalState
            );
        }
    }

    let step_terminals = [
        StepState::Succeeded,
        StepState::Failed,
        StepState::Cancelled,
        StepState::Unknown,
        StepState::Skipped,
    ];
    for terminal_step in step_terminals {
        let events = match terminal_step {
            StepState::Succeeded => vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::ConditionEvaluated {
                    step_id: "first".into(),
                    matched: true,
                },
                WorkflowEvent::DispatchStarted {
                    step_id: "first".into(),
                    attempt: 1,
                    owner_fence: 7,
                    absolute_deadline_ms: 101,
                },
                WorkflowEvent::DispatchProvenSucceeded {
                    step_id: "first".into(),
                    artifact_handle: "artifact".into(),
                    digest: "c".repeat(64),
                },
            ],
            StepState::Failed => vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::ConditionEvaluated {
                    step_id: "first".into(),
                    matched: true,
                },
                WorkflowEvent::DispatchStarted {
                    step_id: "first".into(),
                    attempt: 1,
                    owner_fence: 7,
                    absolute_deadline_ms: 101,
                },
                WorkflowEvent::StepFailed {
                    step_id: "first".into(),
                    reason_code: "known_failure".into(),
                },
            ],
            StepState::Cancelled => vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::StepCancelled {
                    step_id: "first".into(),
                },
            ],
            StepState::Unknown => vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::ConditionEvaluated {
                    step_id: "first".into(),
                    matched: true,
                },
                WorkflowEvent::DispatchStarted {
                    step_id: "first".into(),
                    attempt: 1,
                    owner_fence: 7,
                    absolute_deadline_ms: 101,
                },
                WorkflowEvent::StepUnknown {
                    step_id: "first".into(),
                    reason_code: "external_outcome_unproven".into(),
                },
            ],
            StepState::Skipped => vec![
                WorkflowEvent::Admitted {
                    input_artifact: ArtifactRef {
                        opaque_handle: "artifact-input-test".into(),
                        digest: "a".repeat(64),
                    },
                },
                WorkflowEvent::ConditionEvaluated {
                    step_id: "first".into(),
                    matched: false,
                },
            ],
            _ => unreachable!(),
        };
        let state = reduce_all(initial.clone(), events).unwrap();
        assert_eq!(state.step("first").unwrap().state, terminal_step);
        let late = WorkflowEvent::DispatchProvenSucceeded {
            step_id: "first".into(),
            artifact_handle: "late".into(),
            digest: "d".repeat(64),
        };
        assert_eq!(
            reduce_workflow_event(&state, &late).unwrap_err(),
            EngineErrorCode::TerminalState
        );
    }

    let running = true_state;
    let cancelled = reduce_workflow_event(
        &running,
        &WorkflowEvent::WorkflowCancelled {
            reason_code: "cancelled".into(),
        },
    )
    .unwrap();
    assert_eq!(cancelled.state, WorkflowState::Cancelled);
    let late = WorkflowEvent::DispatchProvenSucceeded {
        step_id: "first".into(),
        artifact_handle: "late".into(),
        digest: "e".repeat(64),
    };
    assert_eq!(
        reduce_workflow_event(&cancelled, &late).unwrap_err(),
        EngineErrorCode::TerminalState
    );
}

#[test]
fn agent_orchestration_reducer_is_sequential_and_terminal_states_are_irreversible() {
    let state = TempState::new("sequential");
    let clock = ManualClock::new(10_000);
    let dispatch = ScriptedDispatch::with_outcomes([
        DispatchOutcome::Succeeded {
            summary: "step-one-ok".into(),
            digest: "a".repeat(64),
        },
        DispatchOutcome::ValidationPassed {
            summary: "validation-ok".into(),
            digest: "b".repeat(64),
        },
    ]);
    let mut first = step("one", None);
    first.approval = ApprovalRule::Required;
    let mut skipped = step("skip-me", Some("one"));
    skipped.condition = Condition::JsonPointerEquals {
        source_step_id: "one".into(),
        pointer: "/result/enabled".into(),
        expected: json!(true),
    };
    let mut validation = step("validate", Some("skip-me"));
    validation.purpose = StepPurpose::Validation;
    validation.context_step_ids = vec!["one".into()];
    validation.validation = Some(ValidationRule::RequiredPass {
        evidence_kinds: vec!["tests".into()],
    });
    let engine = open_engine(
        state.path(),
        dispatch.clone(),
        clock,
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();

    let admitted = engine
        .handle(submit_command(
            "submit-1",
            "workflow-sequential",
            policy(vec![first, skipped, validation]),
        ))
        .unwrap();
    assert_eq!(admitted.state, WorkflowState::Admitted);
    let waiting = engine
        .drive("workflow-sequential", "drive-approval")
        .unwrap();
    assert_eq!(waiting.state, WorkflowState::AwaitingApproval);
    assert_eq!(waiting.active_step_id.as_deref(), Some("one"));
    let snapshot = engine.workflow("workflow-sequential").unwrap();
    assert!(
        snapshot
            .steps
            .iter()
            .filter(|s| s.state.is_active())
            .count()
            <= 1
    );

    engine
        .handle(WorkflowCommand::Approve {
            idempotency_key: "approve-1".into(),
            workflow_id: "workflow-sequential".into(),
            step_id: "one".into(),
        })
        .unwrap();
    engine.drive("workflow-sequential", "drive-one").unwrap();
    engine.drive("workflow-sequential", "drive-skip").unwrap();
    let terminal = engine
        .drive("workflow-sequential", "drive-validation")
        .unwrap();
    assert_eq!(terminal.state, WorkflowState::Completed);
    let snapshot = engine.workflow("workflow-sequential").unwrap();
    assert_eq!(
        snapshot.step("skip-me").unwrap().state,
        super::StepState::Skipped
    );
    assert_eq!(
        snapshot.step("validate").unwrap().state,
        super::StepState::Succeeded
    );
    assert!(
        snapshot
            .steps
            .iter()
            .filter(|s| s.state.is_active())
            .count()
            <= 1
    );
    assert_eq!(
        dispatch.requests().len(),
        2,
        "skipped steps must not dispatch"
    );
    let validation_request = &dispatch.requests()[1];
    assert_eq!(validation_request.predecessor_artifacts.len(), 1);
    let artifact = &validation_request.predecessor_artifacts[0];
    assert!(!artifact.opaque_handle.is_empty() && artifact.opaque_handle.len() <= 128);
    assert_eq!(artifact.digest.len(), 64);
    assert!(
        !serde_json::to_string(artifact)
            .unwrap()
            .contains("step-one-ok")
    );

    let late = engine
        .handle(WorkflowCommand::Cancel {
            idempotency_key: "late-cancel".into(),
            workflow_id: "workflow-sequential".into(),
        })
        .unwrap_err();
    assert_eq!(late, EngineErrorCode::TerminalState);
    assert_eq!(
        engine.workflow("workflow-sequential").unwrap().state,
        WorkflowState::Completed
    );
}

#[test]
fn agent_orchestration_validation_failure_cancel_and_timeout_have_stable_reduction() {
    let retry_state = TempState::new("bounded-retry");
    let retry_dispatch = ScriptedDispatch::with_outcomes([
        DispatchOutcome::KnownFailure {
            reason_code: "synthetic_transient".into(),
            retryable: true,
        },
        DispatchOutcome::Succeeded {
            summary: "retry-succeeded".into(),
            digest: "0".repeat(64),
        },
    ]);
    let engine = open_engine(
        retry_state.path(),
        retry_dispatch.clone(),
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    let mut retried = step("retry", None);
    retried.max_attempts = 2;
    engine
        .handle(submit_command(
            "submit-r",
            "workflow-r",
            policy(vec![retried]),
        ))
        .unwrap();
    let retried = engine.drive("workflow-r", "drive-r").unwrap();
    assert_eq!(retried.state, WorkflowState::Completed);
    assert_eq!(retry_dispatch.requests().len(), 2);

    let continue_state = TempState::new("known-failure-continue");
    let continue_dispatch = ScriptedDispatch::with_outcomes([
        DispatchOutcome::KnownFailure {
            reason_code: "known_exhausted".into(),
            retryable: false,
        },
        DispatchOutcome::Succeeded {
            summary: "continued".into(),
            digest: "2".repeat(64),
        },
    ]);
    let mut may_continue = step("may-continue", None);
    may_continue.max_attempts = 1;
    may_continue.failure_action = FailureAction::Continue;
    let engine = open_engine(
        continue_state.path(),
        continue_dispatch,
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-k",
            "workflow-k",
            policy(vec![
                may_continue,
                step("after-known", Some("may-continue")),
            ]),
        ))
        .unwrap();
    engine.drive("workflow-k", "drive-known").unwrap();
    assert_eq!(
        engine
            .drive("workflow-k", "drive-after-known")
            .unwrap()
            .state,
        WorkflowState::Completed
    );

    let unknown_state = TempState::new("unknown-no-continue");
    let mut must_not_continue = step("unknown", None);
    must_not_continue.failure_action = FailureAction::Continue;
    let unknown_dispatch = ScriptedDispatch::with_outcomes([DispatchOutcome::Unknown {
        reason_code: "external_outcome_unproven".into(),
    }]);
    let engine = open_engine(
        unknown_state.path(),
        unknown_dispatch.clone(),
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-u",
            "workflow-u",
            policy(vec![
                must_not_continue,
                step("forbidden-next", Some("unknown")),
            ]),
        ))
        .unwrap();
    assert_eq!(
        engine.drive("workflow-u", "drive-u").unwrap().state,
        WorkflowState::Unknown
    );
    assert!(engine.drive("workflow-u", "drive-forbidden").is_err());
    assert_eq!(unknown_dispatch.requests().len(), 1);

    let validation_state = TempState::new("validation-fail");
    let mut validation = step("validate", None);
    validation.purpose = StepPurpose::Validation;
    validation.validation = Some(ValidationRule::RequiredPass {
        evidence_kinds: vec!["tests".into()],
    });
    let engine = open_engine(
        validation_state.path(),
        ScriptedDispatch::with_outcomes([DispatchOutcome::ValidationFailed {
            reason_code: "synthetic_check_failed".into(),
        }]),
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-v",
            "workflow-v",
            policy(vec![validation]),
        ))
        .unwrap();
    let failed = engine.drive("workflow-v", "drive-v").unwrap();
    assert_eq!(failed.state, WorkflowState::Failed);
    assert_eq!(
        failed.reason_code.as_deref(),
        Some("synthetic_check_failed")
    );

    let cancel_state = TempState::new("cancel");
    let engine = open_engine(
        cancel_state.path(),
        ScriptedDispatch::default(),
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-c",
            "workflow-c",
            policy(vec![step("one", None)]),
        ))
        .unwrap();
    let cancelled = engine
        .handle(WorkflowCommand::Cancel {
            idempotency_key: "cancel-c".into(),
            workflow_id: "workflow-c".into(),
        })
        .unwrap();
    assert_eq!(cancelled.state, WorkflowState::Cancelled);
    assert!(engine.drive("workflow-c", "late-drive").is_err());

    let timeout_state = TempState::new("timeout");
    let clock = ManualClock::new(100);
    let mut timed = step("timed", None);
    timed.timeout_ms = 10;
    timed.failure_action = FailureAction::Continue;
    let engine = open_engine(
        timeout_state.path(),
        ScriptedDispatch::default(),
        clock.clone(),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-t",
            "workflow-t",
            policy(vec![timed]),
        ))
        .unwrap();
    engine.begin_dispatch("workflow-t", "dispatch-t").unwrap();
    assert_eq!(
        engine
            .workflow("workflow-t")
            .unwrap()
            .step("timed")
            .unwrap()
            .deadline_ms,
        Some(110)
    );
    drop(engine);
    clock.advance_ms(11);
    let reopened = open_engine(
        timeout_state.path(),
        ScriptedDispatch::default(),
        clock,
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    let timed_out = reopened
        .handle(WorkflowCommand::Tick {
            idempotency_key: "tick-t".into(),
            workflow_id: "workflow-t".into(),
        })
        .unwrap();
    assert_eq!(timed_out.state, WorkflowState::Failed);
    assert_eq!(timed_out.reason_code.as_deref(), Some("step_timeout"));
}

#[test]
fn agent_orchestration_durable_replay_returns_original_receipt_and_one_effect() {
    let state = TempState::new("replay");
    let dispatch = ScriptedDispatch::with_outcomes([DispatchOutcome::Succeeded {
        summary: "bounded-success".into(),
        digest: "c".repeat(64),
    }]);
    let clock = ManualClock::new(50);
    let engine = open_engine(
        state.path(),
        dispatch.clone(),
        clock.clone(),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    let command = submit_command(
        "same-submit",
        "workflow-replay",
        policy(vec![step("one", None)]),
    );
    let first = engine.handle(command.clone()).unwrap();
    assert_eq!(engine.handle(command).unwrap(), first);
    let driven = engine.drive("workflow-replay", "same-drive").unwrap();
    assert_eq!(
        engine.drive("workflow-replay", "same-drive").unwrap(),
        driven
    );
    assert_eq!(dispatch.requests().len(), 1);
    let final_snapshot = engine.workflow("workflow-replay").unwrap();
    drop(engine);

    let reopened = open_engine(
        state.path(),
        dispatch.clone(),
        clock,
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    assert_eq!(reopened.recover().unwrap(), final_snapshot);
    let persisted_events = reopened.persisted_events("workflow-replay").unwrap();
    let pinned_policy = reopened.compiled_policy("workflow-replay").unwrap();
    let direct = reduce_all(
        WorkflowSnapshot::initial("workflow-replay", &pinned_policy),
        persisted_events,
    )
    .unwrap();
    assert_eq!(
        direct, final_snapshot,
        "engine replay must be exactly the public reducer fold over persisted events"
    );
    assert_eq!(
        reopened.drive("workflow-replay", "same-drive").unwrap(),
        driven
    );
    assert_eq!(
        dispatch.requests().len(),
        1,
        "restart and duplicate command must not repeat dispatch"
    );
}

#[test]
fn agent_orchestration_fenced_lease_survives_client_disconnect_and_rejects_late_owner() {
    let race_state = TempState::new("concurrent-lease");
    let race_root = race_state.path().to_path_buf();
    let start = Arc::new(Barrier::new(3));
    let finish = Arc::new(Barrier::new(3));
    let winners = std::thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..2 {
            let root = race_root.clone();
            let start = start.clone();
            let finish = finish.clone();
            handles.push(scope.spawn(move || {
                start.wait();
                let claim = DurableWorkflowStore::open(&root, store_limits());
                finish.wait();
                claim.is_ok()
            }));
        }
        start.wait();
        finish.wait();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .filter(|won| *won)
            .count()
    });
    assert_eq!(
        winners, 1,
        "concurrent claim must produce exactly one fenced owner"
    );

    let state = TempState::new("lease");
    let clock = ManualClock::new(1_000);
    let engine = open_engine(
        state.path(),
        ScriptedDispatch::default(),
        clock.clone(),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-l",
            "workflow-lease",
            policy(vec![step("one", None)]),
        ))
        .unwrap();
    let fence = engine.owner_fence();
    let client = engine.connect_control_plane("synthetic-client-a").unwrap();
    drop(client);

    let second_store = DurableWorkflowStore::open(state.path(), store_limits())
        .err()
        .unwrap();
    assert_eq!(second_store, EngineErrorCode::LeaseHeld);
    assert_eq!(
        engine.owner_fence(),
        fence,
        "control-plane disconnect must not transfer ownership"
    );
    let late = engine
        .record_dispatch_outcome(
            "workflow-lease",
            "one",
            fence.saturating_sub(1),
            DispatchOutcome::Succeeded {
                summary: "late".into(),
                digest: "d".repeat(64),
            },
        )
        .unwrap_err();
    assert_eq!(late, EngineErrorCode::StaleFence);
    assert_eq!(
        engine.workflow("workflow-lease").unwrap().state,
        WorkflowState::Admitted
    );
    drop(engine);
    let successor = open_engine(
        state.path(),
        ScriptedDispatch::default(),
        clock,
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    assert!(
        successor.owner_fence() > fence,
        "every new durable owner must receive a monotonic fence"
    );
}

#[test]
fn agent_orchestration_crash_boundaries_replay_deterministically_and_unknown_never_retries() {
    let cases = [
        (
            CrashBoundary::BeforeJournalAppend,
            None,
            false,
            false,
            0_usize,
            0_i64,
        ),
        (CrashBoundary::AfterJournalAppend, None, false, false, 0, 0),
        (
            CrashBoundary::BeforeSnapshotReplace,
            None,
            false,
            false,
            0,
            0,
        ),
        (
            CrashBoundary::AfterSnapshotReplace,
            None,
            false,
            false,
            0,
            0,
        ),
        (
            CrashBoundary::BeforeExternalDispatch,
            Some(WorkflowState::Admitted),
            true,
            false,
            0,
            1,
        ),
        (
            CrashBoundary::AfterExternalDispatchBeforeProof,
            Some(WorkflowState::Unknown),
            true,
            true,
            1,
            3,
        ),
    ];
    for (
        boundary,
        expected_state,
        submit_receipt,
        drive_receipt,
        expected_dispatches,
        expected_generation,
    ) in cases
    {
        let state = TempState::new(boundary.as_str());
        let dispatch = ScriptedDispatch::with_outcomes([DispatchOutcome::Succeeded {
            summary: "synthetic-effect".into(),
            digest: "e".repeat(64),
        }]);
        let clock = ManualClock::new(200);
        let engine = open_engine(
            state.path(),
            dispatch.clone(),
            clock.clone(),
            Arc::new(OneShotCrash::at(boundary)),
        )
        .unwrap();
        let submit = engine.handle(submit_command(
            "submit-crash",
            "workflow-crash",
            policy(vec![step("one", None)]),
        ));
        if submit.is_ok() {
            let _ = engine.drive("workflow-crash", "drive-crash");
        }
        drop(engine);

        let reopened = open_engine(
            state.path(),
            dispatch.clone(),
            clock,
            Arc::new(OneShotCrash::default()),
        )
        .unwrap();
        let recovered = reopened.recover_all().unwrap();
        assert_eq!(
            reopened.recover_all().unwrap(),
            recovered,
            "replay must be deterministic and side-effect free"
        );
        let workflow = recovered
            .iter()
            .find(|run| run.workflow_id == "workflow-crash");
        assert_eq!(
            workflow.map(|workflow| workflow.state),
            expected_state,
            "wrong recovered state at {}",
            boundary.as_str()
        );
        assert_eq!(
            reopened
                .receipt_for_idempotency_key("submit-crash")
                .unwrap()
                .is_some(),
            submit_receipt
        );
        assert_eq!(
            reopened
                .receipt_for_idempotency_key("drive-crash")
                .unwrap()
                .is_some(),
            drive_receipt
        );
        assert_eq!(
            dispatch.requests().len(),
            expected_dispatches,
            "wrong dispatch count at {}",
            boundary.as_str()
        );

        let connection = Connection::open(database_path(state.path())).unwrap();
        assert_eq!(
            connection
                .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
                .unwrap(),
            "ok"
        );
        let generations = [
            latest_generation(&connection, "workflow_journal"),
            latest_generation(&connection, "workflow_snapshots"),
            latest_generation(&connection, "workflow_events"),
            latest_generation(&connection, "workflow_idempotency"),
            latest_generation(&connection, "workflow_receipts"),
        ];
        assert!(
            generations
                .iter()
                .all(|generation| *generation == generations[0]),
            "partial durable commit at {}: {generations:?}",
            boundary.as_str()
        );
        assert_eq!(
            generations[0],
            expected_generation,
            "wrong durable generation at {}",
            boundary.as_str()
        );
        let expected_receipts =
            (if submit_receipt { 1 } else { 0 }) + (if drive_receipt { 1 } else { 0 });
        assert_eq!(
            query_count(&connection, "workflow_idempotency"),
            expected_receipts
        );
        assert_eq!(
            query_count(&connection, "workflow_receipts"),
            expected_receipts
        );
        if expected_state.is_none() {
            assert_eq!(query_count(&connection, "workflow_journal"), 0);
            assert_eq!(query_count(&connection, "workflow_snapshots"), 0);
            assert_eq!(query_count(&connection, "workflow_events"), 0);
            assert_eq!(query_count(&connection, "workflow_idempotency"), 0);
            assert_eq!(query_count(&connection, "workflow_receipts"), 0);
        }

        if boundary == CrashBoundary::AfterExternalDispatchBeforeProof {
            let workflow = workflow.unwrap();
            assert_eq!(
                workflow.reason_code.as_deref(),
                Some("external_outcome_unproven")
            );
            let before = dispatch.requests().len();
            assert!(reopened.drive("workflow-crash", "retry-forbidden").is_err());
            assert_eq!(
                dispatch.requests().len(),
                before,
                "unknown external effect must never retry"
            );
            let receipt = reopened
                .receipt_for_idempotency_key("drive-crash")
                .unwrap()
                .unwrap();
            assert_eq!(receipt.state, WorkflowState::Unknown);
        } else if let Some(workflow) = workflow {
            assert!(
                workflow
                    .steps
                    .iter()
                    .filter(|step| step.state.is_active())
                    .count()
                    <= 1
            );
            assert_ne!(
                workflow.state,
                WorkflowState::Unknown,
                "only an unproven external effect becomes unknown"
            );
        }
    }
}

#[test]
fn agent_orchestration_storage_events_receipts_and_privacy_are_bounded() {
    let state = TempState::new("bounds-privacy");
    let private_canaries = [
        "prompt: synthetic private instruction",
        "reasoning: synthetic hidden chain",
        "credential=synthetic-secret",
        "nativeSessionId=session-private",
        "<home-path>/sensitive/project/file.rs",
        "rawOutput: provider transcript",
    ];
    let dispatch = ScriptedDispatch::with_outcomes([DispatchOutcome::Succeeded {
        summary: private_canaries.join(" | "),
        digest: "f".repeat(64),
    }]);
    let engine = open_engine(
        state.path(),
        dispatch,
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
    )
    .unwrap();
    engine
        .handle(submit_command(
            "submit-p",
            "workflow-p",
            policy(vec![step("one", None)]),
        ))
        .unwrap();
    let receipt = engine.drive("workflow-p", "drive-p").unwrap();
    let receipt_json = serde_json::to_string(&receipt).unwrap();
    assert!(receipt_json.len() <= engine_limits().max_receipt_bytes);
    for canary in private_canaries {
        assert!(!receipt_json.contains(canary));
    }
    assert_eq!(
        receipt.reason_code.as_deref(),
        Some("provider_summary_redacted")
    );

    let first_page = engine.events("workflow-p", 0, 99).unwrap();
    assert!(first_page.events.len() <= engine_limits().max_events_per_page);
    let second_page = engine
        .events("workflow-p", first_page.next_cursor, 99)
        .unwrap();
    let first_ids: HashSet<_> = first_page.events.iter().map(|event| event.cursor).collect();
    assert!(
        second_page
            .events
            .iter()
            .all(|event| !first_ids.contains(&event.cursor))
    );

    let db_path = database_path(state.path());
    let connection = Connection::open(&db_path).unwrap();
    assert_eq!(
        connection
            .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
            .unwrap(),
        "ok"
    );
    assert_eq!(
        connection
            .query_row("PRAGMA journal_mode", [], |row| row.get::<_, String>(0))
            .unwrap()
            .to_ascii_lowercase(),
        "wal"
    );
    let tables: HashSet<String> = connection
        .prepare("SELECT name FROM sqlite_master WHERE type='table'")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    for required in [
        "workflow_journal",
        "workflow_snapshots",
        "workflow_events",
        "workflow_idempotency",
        "workflow_receipts",
        "workflow_leases",
        "store_metadata",
    ] {
        assert!(
            tables.contains(required),
            "missing durable table {required}"
        );
    }
    for (table, required_columns) in [
        (
            "workflow_journal",
            &["workflow_id", "sequence", "generation", "event_json"][..],
        ),
        (
            "workflow_snapshots",
            &["workflow_id", "generation", "snapshot_json"],
        ),
        (
            "workflow_events",
            &["workflow_id", "cursor", "generation", "event_json"],
        ),
        (
            "workflow_idempotency",
            &["scope", "idempotency_key", "generation", "receipt_json"],
        ),
        (
            "workflow_receipts",
            &[
                "workflow_id",
                "idempotency_key",
                "generation",
                "receipt_json",
            ],
        ),
        (
            "workflow_leases",
            &[
                "workflow_id",
                "owner_id",
                "owner_fence",
                "expires_at_ms",
                "generation",
            ],
        ),
        ("store_metadata", &["key", "value"]),
    ] {
        let columns: HashSet<String> = connection
            .prepare(&format!("PRAGMA table_info({table})"))
            .unwrap()
            .query_map([], |row| row.get(1))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        for column in required_columns {
            assert!(columns.contains(*column), "missing {table}.{column}");
        }
    }
    let indexes: HashSet<String> = connection
        .prepare("SELECT name FROM sqlite_master WHERE type='index'")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    for required in [
        "idx_workflow_journal_workflow_sequence",
        "idx_workflow_events_workflow_cursor",
        "idx_workflow_idempotency_scope_key",
        "idx_workflow_receipts_workflow",
    ] {
        assert!(
            indexes.contains(required),
            "missing durable index {required}"
        );
    }
    let stored_snapshot: String = connection.query_row(
        "SELECT snapshot_json FROM workflow_snapshots WHERE workflow_id = ?1 ORDER BY generation DESC LIMIT 1",
        ["workflow-p"], |row| row.get(0),
    ).unwrap();
    assert_eq!(
        serde_json::from_str::<WorkflowSnapshot>(&stored_snapshot).unwrap(),
        engine.workflow("workflow-p").unwrap()
    );
    let stored_receipt: String = connection
        .query_row(
            "SELECT receipt_json FROM workflow_receipts WHERE idempotency_key = ?1",
            ["drive-p"],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        serde_json::from_str::<WorkflowReceipt>(&stored_receipt).unwrap(),
        receipt
    );
    let persisted_events = engine.persisted_events("workflow-p").unwrap();
    let journal_events: Vec<WorkflowEvent> = connection
        .prepare("SELECT event_json FROM workflow_journal WHERE workflow_id = ?1 ORDER BY sequence")
        .unwrap()
        .query_map(["workflow-p"], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|row| serde_json::from_str(&row.unwrap()).unwrap())
        .collect();
    assert_eq!(journal_events, persisted_events);
    assert_eq!(
        query_count(&connection, "workflow_journal") as usize,
        persisted_events.len()
    );
    assert!(database_bytes(&db_path) <= store_limits().max_database_bytes as u64);
    assert!(
        connection
            .query_row(
                "SELECT COALESCE(MAX(length(event_json)), 0) FROM workflow_journal",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap() as usize
            <= store_limits().max_journal_bytes
    );
    assert!(
        connection
            .query_row(
                "SELECT COALESCE(MAX(length(snapshot_json)), 0) FROM workflow_snapshots",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap() as usize
            <= store_limits().max_snapshot_bytes
    );
    let persisted_columns = persisted_text_columns(&connection);
    let raw_database = fs::read(&db_path).unwrap();
    let raw_wal =
        fs::read(PathBuf::from(format!("{}-wal", db_path.to_string_lossy()))).unwrap_or_default();
    for canary in private_canaries {
        assert!(!persisted_columns.contains(canary));
        assert!(!String::from_utf8_lossy(&raw_database).contains(canary));
        assert!(!String::from_utf8_lossy(&raw_wal).contains(canary));
    }

    let mut unsafe_policy = policy(vec![step("one", None)]);
    unsafe_policy.workflow.steps[0].agent_id = Some("credential=synthetic-secret".into());
    let error = CompiledPolicy::compile(unsafe_policy).unwrap_err();
    assert_eq!(error.code(), CompileErrorCode::PrivacyViolation);

    let bounded_state = TempState::new("hard-store-bounds");
    let hard_limits = StoreLimits {
        max_journal_entries: 16,
        max_journal_bytes: 16 * 1024,
        max_snapshot_bytes: 16 * 1024,
        max_idempotency_entries: 3,
        max_events: 8,
        max_database_bytes: 512 * 1024,
    };
    let hard_max_journal_entries = hard_limits.max_journal_entries;
    let hard_max_journal_bytes = hard_limits.max_journal_bytes;
    let hard_max_snapshot_bytes = hard_limits.max_snapshot_bytes;
    let hard_max_idempotency_entries = hard_limits.max_idempotency_entries;
    let hard_max_events = hard_limits.max_events;
    let hard_max_database_bytes = hard_limits.max_database_bytes;
    let bounded_dispatch = ScriptedDispatch::with_outcomes([DispatchOutcome::Succeeded {
        summary: "old-effect".into(),
        digest: "1".repeat(64),
    }]);
    let bounded = open_engine_with_store_limits(
        bounded_state.path(),
        bounded_dispatch.clone(),
        ManualClock::new(1),
        Arc::new(OneShotCrash::default()),
        hard_limits,
    )
    .unwrap();
    bounded
        .handle(submit_command(
            "old-submit-key",
            "old-workflow",
            policy(vec![step("old-step", None)]),
        ))
        .unwrap();
    let old_receipt = bounded.drive("old-workflow", "old-drive-key").unwrap();
    let mut reached_bound_or_rejected = false;
    for index in 0..24 {
        let result = bounded.handle(submit_command(
            &format!("bounded-submit-{index}"),
            &format!("bounded-workflow-{index}"),
            policy(vec![]),
        ));
        if matches!(result, Err(EngineErrorCode::CapacityExceeded)) {
            reached_bound_or_rejected = true;
        }
        let db_path = database_path(bounded_state.path());
        let connection = Connection::open(&db_path).unwrap();
        let journal_entries = query_count(&connection, "workflow_journal") as usize;
        let event_entries = query_count(&connection, "workflow_events") as usize;
        let idempotency_entries = query_count(&connection, "workflow_idempotency") as usize;
        assert!(journal_entries <= hard_max_journal_entries);
        assert!(event_entries <= hard_max_events);
        assert!(idempotency_entries <= hard_max_idempotency_entries);
        assert!(
            connection
                .query_row(
                    "SELECT COALESCE(MAX(length(event_json)), 0) FROM workflow_journal",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap() as usize
                <= hard_max_journal_bytes
        );
        assert!(
            connection
                .query_row(
                    "SELECT COALESCE(MAX(length(snapshot_json)), 0) FROM workflow_snapshots",
                    [],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap() as usize
                <= hard_max_snapshot_bytes
        );
        assert!(database_bytes(&db_path) <= hard_max_database_bytes as u64);
        reached_bound_or_rejected |= idempotency_entries == hard_max_idempotency_entries
            || event_entries == hard_max_events
            || journal_entries == hard_max_journal_entries;
    }
    assert!(
        reached_bound_or_rejected,
        "small configured persistence bounds were never exercised"
    );
    assert_eq!(
        bounded.drive("old-workflow", "old-drive-key").unwrap(),
        old_receipt
    );
    assert_eq!(
        bounded_dispatch.requests().len(),
        1,
        "bounded idempotency cannot evict an old key and repeat its effect"
    );

    let connection = Connection::open(database_path(bounded_state.path())).unwrap();
    let generations = [
        latest_generation(&connection, "workflow_journal"),
        latest_generation(&connection, "workflow_snapshots"),
        latest_generation(&connection, "workflow_events"),
        latest_generation(&connection, "workflow_idempotency"),
        latest_generation(&connection, "workflow_receipts"),
    ];
    assert!(
        generations
            .iter()
            .all(|generation| *generation == generations[0]),
        "command tables were not committed at one generation: {generations:?}"
    );
}
