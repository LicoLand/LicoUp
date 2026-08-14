use licoup_native::domain::delivery_plan::{
    AcceptanceCriterion, DecisionOption, DecisionQuestion, DeliveryPlanEngine, DispatchBinding,
    ExecutionPolicy, Output, Plan, PlanError, Prerequisite, Requirement, Role, RoleContract, Scope,
    Task, TaskStatus,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn root(label: &str) -> PathBuf {
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("delivery-plan-contract-{label}-{sequence}"))
}

fn task(code: &str, output: &str, writes: &[&str]) -> Task {
    Task {
        code: code.to_string(),
        title: code.to_string(),
        contract: format!("exact-{code}"),
        requirements: vec!["REQ-001".to_string()],
        outputs: vec![output.to_string()],
        acceptance_criteria: vec![format!("AC-{code}")],
        prerequisites: Vec::new(),
        owned_writes: writes.iter().map(|value| (*value).to_string()).collect(),
        references: Vec::new(),
        execution_policy: ExecutionPolicy::default(),
    }
}

fn fixture_plan() -> Plan {
    let mut plan = Plan::new("PLAN-CONTRACT-001", "Contract fixture");
    plan.intent.scope = Scope {
        r#in: vec!["crates/licoup-native/src/domain/delivery_plan".to_string()],
        out: vec![],
    };
    plan.dossier.questions = vec![DecisionQuestion {
        code: "Q-001".to_string(),
        question: "Which boundary?".to_string(),
        context: "Synthetic".to_string(),
        options: vec![DecisionOption {
            id: "native".to_string(),
            label: "Native".to_string(),
        }],
        default: None,
        selected: None,
    }];
    plan.requirements = vec![Requirement {
        code: "REQ-001".to_string(),
        statement: "Synthetic requirement".to_string(),
    }];
    plan.tasks = vec![
        task("TASK-001", "OUT-001", &["src/a.rs"]),
        task("TASK-002", "OUT-002", &["src/b.rs"]),
        Task {
            code: "TASK-003".to_string(),
            title: "Downstream".to_string(),
            contract: "exact-TASK-003".to_string(),
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
        },
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
        Output {
            code: "OUT-003".to_string(),
            title: "C".to_string(),
            produced_by: "TASK-003".to_string(),
            references: Vec::new(),
        },
    ];
    plan.acceptance_criteria = plan
        .tasks
        .iter()
        .map(|task| AcceptanceCriterion {
            code: format!("AC-{}", task.code),
            statement: "Synthetic acceptance".to_string(),
            task: Some(task.code.clone()),
            requirement: Some("REQ-001".to_string()),
            output: task.outputs.first().cloned(),
        })
        .collect();
    plan
}

fn resolve_and_authorize(engine: &mut DeliveryPlanEngine) {
    engine
        .resolve_dossier(BTreeMap::from([(
            "Q-001".to_string(),
            "native".to_string(),
        )]))
        .unwrap();
    engine.open_designer("native://designer/fixture").unwrap();
    engine
        .complete_designer(Some("designer-returned".to_string()))
        .unwrap();
    engine.mark_ready().unwrap();
    engine.authorize().unwrap();
}

fn assert_code(result: Result<(), PlanError>, expected: &str) {
    let error = result.unwrap_err();
    assert_eq!(error.code(), expected);
}

#[test]
fn contract_lifecycle_frontier_and_reload_are_deterministic() {
    let state = root("lifecycle");
    let mut engine = DeliveryPlanEngine::create(&state, fixture_plan()).unwrap();
    resolve_and_authorize(&mut engine);
    assert_eq!(engine.checkpoints().revision, 1);
    assert_eq!(
        engine.eligible_tasks().unwrap(),
        vec!["TASK-001".to_string(), "TASK-002".to_string()]
    );

    for code in ["TASK-001", "TASK-002"] {
        let dispatch = format!("dispatch-{code}");
        engine
            .bind_dispatch(DispatchBinding {
                id: dispatch.clone(),
                task_code: code.to_string(),
                attempt: 1,
                conversation_location: Some(format!("native://worker/{code}")),
                receipt: Some(format!("receipt-{code}")),
            })
            .unwrap();
        engine
            .complete_dispatch(&dispatch, vec!["synthetic-evidence".to_string()])
            .unwrap();
        engine
            .accept_task(code, &dispatch, Some(format!("accepted-{code}")))
            .unwrap();
    }

    assert_eq!(
        engine.eligible_tasks().unwrap(),
        vec!["TASK-003".to_string()]
    );
    let loaded = DeliveryPlanEngine::load(&state).unwrap();
    assert_eq!(
        loaded.eligible_tasks().unwrap(),
        engine.eligible_tasks().unwrap()
    );
    assert_eq!(loaded.checkpoints().revision, engine.checkpoints().revision);
    assert_eq!(
        loaded.checkpoints().tasks["TASK-001"].status,
        TaskStatus::Completed
    );
    let _ = fs::remove_dir_all(state);
}

#[test]
fn brief_is_exact_projection_without_context_material() {
    let state = root("brief");
    let mut engine = DeliveryPlanEngine::create(&state, fixture_plan()).unwrap();
    resolve_and_authorize(&mut engine);
    let brief = engine
        .compile_task_brief("TASK-003", Some("native://worker/downstream".to_string()))
        .unwrap();
    let rendered = serde_json::to_string(&brief).unwrap();
    assert!(rendered.contains("\"selected_decisions\""));
    assert!(rendered.contains("\"direct_inputs\""));
    assert!(rendered.contains("\"execution_policy\""));
    assert!(rendered.contains("native://worker/downstream"));
    for forbidden in [
        "source_excerpt",
        "transcript",
        "summary",
        "compression",
        "cached_prompt",
        "conversation_message",
    ] {
        assert!(
            !rendered.contains(forbidden),
            "forbidden Brief field {forbidden}"
        );
    }
    let _ = fs::remove_dir_all(state);
}

#[test]
fn invalid_variants_fail_at_stable_first_stage() {
    let mut unsupported = serde_json::to_value(fixture_plan()).unwrap();
    unsupported["schema"] = Value::String("better-plan.plan/v2".to_string());
    let error = Plan::from_json_str(&serde_json::to_string(&unsupported).unwrap()).unwrap_err();
    assert_eq!(error.code(), "unsupported_schema");

    let mut unknown = serde_json::to_value(fixture_plan()).unwrap();
    unknown["unknown"] = Value::Bool(true);
    let error = Plan::from_json_str(&serde_json::to_string(&unknown).unwrap()).unwrap_err();
    assert_eq!(error.code(), "unknown_field");

    let mut unsafe_reference = fixture_plan();
    unsafe_reference
        .references
        .push(licoup_native::domain::delivery_plan::RepositoryReference {
            path: "../outside".to_string(),
            purpose: "synthetic".to_string(),
        });
    assert_code(
        DeliveryPlanEngine::create(root("unsafe-reference"), unsafe_reference).map(|_| ()),
        "non_relative_reference",
    );

    let mut invalid_roles = fixture_plan();
    invalid_roles.roles.push(RoleContract {
        role: Role::Designer,
        authority: "second".to_string(),
        execution_policy: ExecutionPolicy::default(),
        references: Vec::new(),
    });
    assert_code(
        DeliveryPlanEngine::create(root("roles"), invalid_roles).map(|_| ()),
        "role_cardinality",
    );

    let mut cycle = fixture_plan();
    cycle.tasks[0].prerequisites.push(Prerequisite {
        from: "TASK-003".to_string(),
        output: "OUT-003".to_string(),
        guarantee_input: "cycle".to_string(),
    });
    assert_code(
        DeliveryPlanEngine::create(root("cycle"), cycle).map(|_| ()),
        "cycle",
    );
}
