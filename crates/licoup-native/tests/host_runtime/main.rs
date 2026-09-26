//! V7-I1 host wiring harness — the runtime-owned drive at the production entry.
//!
//! The entry under test is `StrategyService::execute`, the same call the stdio
//! RPC server makes for `strategy.*` actions. Everything below runs against a
//! real portable root: a real Conversation authority, a real imported package,
//! the real `strategies.sqlite3`, the real recovery assembly, and a real actor
//! turn port. Only the actor executor is synthetic — a closure standing in for
//! `conversation::strategy_turn_port` — and slots are bound through the public
//! `StrategyStore::replace_slot_bindings` rather than the
//! `strategy.binding.update` action, because that action also asks a real
//! installed agent for its capability catalog and a synthetic agent has none.
//! Both are setup, not the behaviour under test.
//!
//! The graph is the acceptance shape: one Workset whose items declare their
//! prerequisites, so item `c` depends on item `a` while item `b` is
//! independent. That is the production way to express "A feeds C, B is
//! independent" — fork branches are structural control flow and may not carry
//! failure edges of their own.
//!
//! What each case is here to show:
//!
//! * `a_successor_is_emitted_and_driven_on_its_predecessors_completion` — the
//!   successor exists only because its predecessor completed, and the drive
//!   picks it up from that completion. The old batch loop committed nothing
//!   until its whole batch was joined.
//! * `a_revoked_authorization_refuses_the_next_effect...` — A08: the authority
//!   recorded at admission is rechecked at the effect boundary, and a
//!   revocation after admission parks the run in `AuthorizationRequired`
//!   instead of starting the effect.
//! * `a_durable_pause_admitted_by_the_legacy_control_path...` — A08: a pause
//!   written by the controlled store's pause row (the path that does *not* set
//!   the graph barrier flag) still fences new visits for a later drive call.
//! * `a_started_marker_without_an_outcome_is_held...` — A02: an attempt whose
//!   possible-effect marker is durable is never re-dispatched by the next
//!   drive.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use licoup_native::domain::client_conversation::{
    ConversationStore, MembershipAccess, Principal, PrincipalKind,
};
use licoup_native::domain::workflow_runtime::{
    ActorTurnPort, StrategyService,
    authority_adapter::{BarrierKind, BarrierRequest, BarrierScope, StoreScopeBarrier},
};
use licoup_native::domain::workflow_store::{BindingCandidate, DurableControlledStore};
use licoup_native::platform::runtime_adapters::RuntimeAdapterError;
use licoup_workflow::{CommandStatus, RunSnapshot, StrategyRunStatus};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::{StoreStatePort, WorkflowDatabase};
use serde_json::{Value, json};

const SLOT_WORKER: &str = "worker";
const ITEMS: [&str; 3] = ["a", "b", "c"];

// ---------------------------------------------------------------------------
// Harness plumbing
// ---------------------------------------------------------------------------

/// The heavy cases each spin a real host (SQLite writers, drive threads, effect
/// threads). Running them concurrently exhausts the process's descriptors and
/// threads and surfaces as `disk I/O error`, which says nothing about the
/// behaviour under test. One guard serializes them inside this binary while
/// still using the normal test harness.
fn serial_guard() -> std::sync::MutexGuard<'static, ()> {
    static GUARD: std::sync::Mutex<()> = std::sync::Mutex::new(());
    GUARD.lock().unwrap_or_else(|poison| poison.into_inner())
}

fn root() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let path = std::env::temp_dir().join(format!(
        "lico-v7-host-{}-{nanos}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).expect("create scratch root");
    path
}

fn remove_root(path: PathBuf) {
    let _ = std::fs::remove_dir_all(path);
}

fn wait_for<F: Fn() -> bool>(what: &str, predicate: F) {
    // The suite runs several SQLite-backed hosts in parallel; the deadline
    // covers a loaded machine without changing what is awaited.
    let deadline = Instant::now() + Duration::from_secs(60);
    while Instant::now() < deadline {
        if predicate() {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    panic!("timed out waiting for {what}");
}

fn call(service: &StrategyService, request: Value) -> Value {
    let action = request["action"].clone();
    let response = service.execute(request).expect("execute");
    assert_eq!(response["ok"], true, "entry rejected {action}: {response}");
    response["result"].clone()
}

/// A one-shot gate an effect can be held on.
#[derive(Clone, Default)]
struct Gate {
    state: Arc<(Mutex<bool>, Condvar)>,
}

impl Gate {
    fn new() -> Self {
        Self::default()
    }

    fn wait(&self) {
        let (lock, condvar) = &*self.state;
        let mut open = lock.lock().expect("gate lock");
        while !*open {
            open = condvar.wait(open).expect("gate wait");
        }
    }

    fn open(&self) {
        let (lock, condvar) = &*self.state;
        *lock.lock().expect("gate lock") = true;
        condvar.notify_all();
    }
}

/// What the synthetic turn executor saw, keyed by workset item.
#[derive(Clone, Default)]
struct TurnProbe {
    invoked: Arc<Mutex<BTreeSet<String>>>,
    returned: Arc<Mutex<BTreeSet<String>>>,
}

impl TurnProbe {
    fn note_invoked(&self, item: &str) {
        self.invoked
            .lock()
            .expect("probe lock")
            .insert(item.to_owned());
    }

    fn note_returned(&self, item: &str) {
        self.returned
            .lock()
            .expect("probe lock")
            .insert(item.to_owned());
    }

    fn invoked(&self) -> BTreeSet<String> {
        self.invoked.lock().expect("probe lock").clone()
    }

    fn returned(&self) -> BTreeSet<String> {
        self.returned.lock().expect("probe lock").clone()
    }
}

/// The item one turn belongs to.
///
/// The effect request carries no item id, but the state instruction puts the
/// item's own JSON into the prompt (`effect_input_for`), so the synthetic
/// executor reads it back from the text it was handed. A real executor reads
/// the same input as its task description.
fn item_of(params: &Value) -> String {
    let text = params
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    for item in ITEMS {
        if text.contains(&format!("\"id\":\"{item}\"")) {
            return item.to_owned();
        }
    }
    params
        .get("agentId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// The synthetic Conversation-dispatch port: one held or immediate turn per
/// item, exactly as `strategy_turn_port` composes the real one.
fn turn_port(probe: TurnProbe, gates: Vec<(String, Gate)>) -> ActorTurnPort {
    let gates = Arc::new(gates.into_iter().collect::<BTreeMap<_, _>>());
    let runs = Arc::new(AtomicU64::new(0));
    ActorTurnPort {
        open: Arc::new({
            let runs = Arc::clone(&runs);
            move |_params: &Value| {
                Ok(format!(
                    "v7-host-turn-{}",
                    runs.fetch_add(1, Ordering::SeqCst)
                ))
            }
        }),
        run: Arc::new({
            let probe = probe.clone();
            let gates = Arc::clone(&gates);
            move |_handle: &str, params: &Value| -> Result<Value, RuntimeAdapterError> {
                let item = item_of(params);
                probe.note_invoked(&item);
                if let Some(gate) = gates.get(&item) {
                    gate.wait();
                }
                probe.note_returned(&item);
                Ok(json!({
                    "ok": true,
                    "output": format!("{item}-done"),
                    "nativeSessionId": format!("session-{item}"),
                }))
            }
        }),
        abandon: Arc::new(|_handle: &str| {}),
    }
}

// ---------------------------------------------------------------------------
// The fixture: one Workset whose item c depends on item a
// ---------------------------------------------------------------------------

fn workset_workflow_json(max_parallelism: u32) -> Value {
    json!({
        "schema": "licoup.adaptive-flywheel.workflow.v1",
        "metadata": {
            "id": "v7-host-fork",
            "name": "V7 Host Fork",
            "version": "1.0.0",
            "description": "A feeds C; B is independent.",
        },
        "limits": {
            "maxParallelism": max_parallelism,
            "maxWorksetItems": 8,
            "maxAttempts": 3,
        },
        "actorSlots": [
            {
                "id": SLOT_WORKER,
                "kind": "actor",
                "label": "Worker",
                "required": true,
                "sessionPolicy": "new",
                "entry": true,
            },
        ],
        "runtimes": [],
        "worksets": [
            {"id": "tasks", "itemBinding": "id", "predecessorField": "prerequisites"},
        ],
        "initial": "tasks",
        "states": [
            {
                "id": "tasks",
                "kind": "workset",
                "label": "Tasks",
                "instruction": "Execute one item.",
                "binding": SLOT_WORKER,
                "workset": "tasks",
                "retry": {"maxAttempts": 3, "transientOnly": false},
            },
            {"id": "done", "kind": "succeed", "label": "Done"},
            {"id": "failed", "kind": "fail", "label": "Failed"},
        ],
        "transitions": [
            {"id": "tasks-done", "from": "tasks", "to": "done", "event": "success", "mode": "flow"},
            {"id": "tasks-failed", "from": "tasks", "to": "failed", "event": "failure", "mode": "flow"},
        ],
    })
}

/// One actor state and a terminal state: the simplest host-admitted graph.
///
/// Used where the effect boundary itself is under test, so the run's status is
/// the non-workset one (a refused Authority effect parks the run in
/// `AuthorizationRequired`).
fn actor_workflow_json() -> Value {
    json!({
        "schema": "licoup.adaptive-flywheel.workflow.v1",
        "metadata": {
            "id": "v7-host-fork",
            "name": "V7 Host Fork",
            "version": "1.0.0",
            "description": "One actor effect.",
        },
        "limits": {
            "maxParallelism": 1,
            "maxWorksetItems": 8,
            "maxAttempts": 3,
        },
        "actorSlots": [
            {
                "id": SLOT_WORKER,
                "kind": "actor",
                "label": "Worker",
                "required": true,
                "sessionPolicy": "new",
                "entry": true,
            },
        ],
        "runtimes": [],
        "worksets": [],
        "initial": "work",
        "states": [
            {
                "id": "work",
                "kind": "actor",
                "label": "Work",
                "instruction": "Do the work.",
                "binding": SLOT_WORKER,
                "retry": {"maxAttempts": 3, "transientOnly": false},
            },
            {"id": "done", "kind": "succeed", "label": "Done"},
            {"id": "failed", "kind": "fail", "label": "Failed"},
        ],
        "transitions": [
            {"id": "work-done", "from": "work", "to": "done", "event": "success", "mode": "flow"},
            {"id": "work-failed", "from": "work", "to": "failed", "event": "failure", "mode": "flow"},
        ],
    })
}

/// Only the dependent pair: `a`, then `c` once `a` succeeded.
///
/// The sibling `b` belongs to the A04 repro; with one admitted effect at a time
/// the claim order between two ready siblings is arbitrary, and the test here
/// is about the completion that emits the successor, not about ordering.
fn successor_input() -> Value {
    json!({
        "message": "run the workset",
        "worksets": {"tasks": [{"id": "a"}, {"id": "c", "prerequisites": ["a"]}]},
    })
}

/// `a` and the independent `b`.
fn independent_pair_input() -> Value {
    json!({
        "message": "run the workset",
        "worksets": {"tasks": [{"id": "a"}, {"id": "b"}]},
    })
}

/// `a`, the independent `b`, and the dependent `c`.
fn full_input() -> Value {
    json!({
        "message": "run the workset",
        "worksets": {
            "tasks": [
                {"id": "a"},
                {"id": "b"},
                {"id": "c", "prerequisites": ["a"]},
            ],
        },
    })
}

fn package_bytes(workflow: &Value) -> Vec<u8> {
    let mut buffer = std::io::Cursor::new(Vec::new());
    {
        let mut writer = zip::ZipWriter::new(&mut buffer);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        writer
            .start_file("workflow.json", options)
            .expect("start workflow entry");
        std::io::Write::write_all(&mut writer, workflow.to_string().as_bytes())
            .expect("write workflow entry");
        writer.finish().expect("finish package");
    }
    buffer.into_inner()
}

fn import_revision(service: &StrategyService, root: &Path, workflow: &Value) -> String {
    let package = root.join("fixture.zip");
    std::fs::write(&package, package_bytes(workflow)).expect("write package");
    let prepared = call(
        service,
        json!({
            "action": "strategy.package.prepare-import",
            "sourcePath": package.to_string_lossy(),
            "selectionToken": "v7-host-selection",
        }),
    );
    let committed = call(
        service,
        json!({
            "action": "strategy.package.commit-import",
            "preparationId": prepared["preparationId"],
            "expectedRevisionDigest": prepared["revisionDigest"],
        }),
    );
    assert_eq!(committed["definitionId"], "v7-host-fork");
    prepared["revisionDigest"].as_str().unwrap().to_owned()
}

/// Create the Conversation authority the actor dispatch resolves against and
/// return `(conversationId, membershipId)`.
fn create_conversation(root: &Path) -> (String, String) {
    let store = ConversationStore::open(root).unwrap();
    let now = 1_700_000_000_000;
    let conversation = store
        .create_conversation_with_members(
            "v7 host",
            Principal {
                id: "user-v7".into(),
                kind: PrincipalKind::Human,
                display_name: "V7 Operator".into(),
                agent_id: None,
                created_at_unix_ms: now,
            },
            &[(
                Principal {
                    id: "agent-v7".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "V7 Worker".into(),
                    agent_id: Some("v7-host-worker".into()),
                    created_at_unix_ms: now,
                },
                MembershipAccess::Member,
            )],
        )
        .unwrap();
    let membership = conversation
        .memberships
        .iter()
        .find(|membership| membership.principal.id == "agent-v7")
        .expect("the agent membership was created")
        .id
        .clone();
    let owner = conversation
        .memberships
        .iter()
        .find(|membership| membership.principal.kind == PrincipalKind::Human)
        .expect("the human membership exists")
        .id
        .clone();
    let revision = store.get(&conversation.id).unwrap().revision;
    store
        .set_conversation_assistant(&conversation.id, &owner, revision, Some(&membership))
        .expect("designate the Assistant");
    (conversation.id, membership)
}

fn bind_slots(service: &StrategyService, revision: &str, membership_id: &str) {
    service
        .store()
        .replace_slot_bindings(
            revision,
            SLOT_WORKER,
            &[BindingCandidate {
                value_id: membership_id.to_owned(),
                model: String::new(),
                reasoning_effort: String::new(),
            }],
            None,
        )
        .unwrap_or_else(|error| panic!("bind {SLOT_WORKER}: {error}"));
}

fn grant(service: &StrategyService, revision: &str) {
    let preview = service.store().authorization_preview(revision).unwrap();
    service
        .store()
        .grant_authorization(revision, &preview.authorization_digest)
        .unwrap();
}

fn start_run(
    service: &StrategyService,
    revision: &str,
    conversation_id: &str,
    input: Value,
) -> String {
    start_run_with_key(service, revision, conversation_id, input, "v7-host-run")
}

fn start_run_with_key(
    service: &StrategyService,
    revision: &str,
    conversation_id: &str,
    input: Value,
    key: &str,
) -> String {
    let started = call(
        service,
        json!({
            "action": "strategy.run.start",
            "revisionDigest": revision,
            "input": input,
            "idempotencyKey": key,
            "conversationId": conversation_id,
        }),
    );
    started["runId"].as_str().expect("run id").to_owned()
}

fn item_command<'a>(run: &'a RunSnapshot, item: &str) -> &'a licoup_workflow::RunCommand {
    run.commands
        .values()
        .find(|command| command.item_id.as_deref() == Some(item))
        .unwrap_or_else(|| panic!("no command for item {item}"))
}

/// A prepared host: service with its synthetic port, an imported revision, a
/// bound slot, and an active authorization.
fn prepared_host(
    root: &Path,
    probe: &TurnProbe,
    gates: Vec<(String, Gate)>,
) -> (StrategyService, String, String) {
    let service = StrategyService::open(root)
        .expect("open service")
        .with_actor_turn_port(turn_port(probe.clone(), gates));
    let revision = import_revision(&service, root, &workset_workflow_json(1));
    let (conversation_id, membership_id) = create_conversation(root);
    bind_slots(&service, &revision, &membership_id);
    grant(&service, &revision);
    (service, revision, conversation_id)
}

fn handoff_count(database: &Arc<WorkflowDatabase>, run_id: &str) -> i64 {
    database
        .read(|connection| {
            Ok(connection.query_row(
                "SELECT COUNT(*) FROM workflow_successor_handoffs WHERE run_id=?1",
                rusqlite::params![run_id],
                |row| row.get(0),
            )?)
        })
        .unwrap_or(0)
}

fn workflow_database(root: &Path) -> Arc<WorkflowDatabase> {
    Arc::new(
        WorkflowDatabase::open(
            &root
                .join("client-state")
                .join("adaptive-flywheel")
                .join("strategies.sqlite3"),
        )
        .expect("open the workflow database"),
    )
}

// ---------------------------------------------------------------------------
// Per-completion — a successor is emitted and driven on its predecessor's
// completion
// ---------------------------------------------------------------------------

#[test]
fn a_successor_is_emitted_and_driven_on_its_predecessors_completion() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let gate_a = Gate::new();
    let gate_c = Gate::new();
    let service = StrategyService::open(&root)
        .expect("open service")
        .with_actor_turn_port(turn_port(
            probe.clone(),
            vec![
                ("a".to_owned(), gate_a.clone()),
                ("c".to_owned(), gate_c.clone()),
            ],
        ));
    let revision = import_revision(&service, &root, &workset_workflow_json(1));
    let (conversation_id, membership_id) = create_conversation(&root);
    bind_slots(&service, &revision, &membership_id);
    grant(&service, &revision);

    let run_id = start_run(&service, &revision, &conversation_id, successor_input());

    // Only the first item starts; the successor is not even emitted yet.
    wait_for("a invoked", || probe.invoked().contains("a"));
    assert_eq!(
        probe.invoked(),
        BTreeSet::from(["a".to_owned()]),
        "the successor must wait for its predecessor"
    );
    let run = service.store().run(&run_id).unwrap();
    assert_eq!(
        item_command(&run, "a").status,
        CommandStatus::Running,
        "the first effect is in flight"
    );
    assert!(
        !run.commands
            .values()
            .any(|command| command.item_id.as_deref() == Some("c")),
        "the successor command does not exist before its predecessor completes"
    );

    // A settles; its outcome is durable and the successor is emitted from that
    // completion, not from the end of the workset.
    gate_a.open();
    wait_for("c invoked", || probe.invoked().contains("c"));
    let run = service.store().run(&run_id).unwrap();
    assert_eq!(
        item_command(&run, "a").status,
        CommandStatus::Succeeded,
        "A's outcome is committed as its own effect completes"
    );
    assert!(
        item_command(&run, "a")
            .output_digest
            .as_deref()
            .is_some_and(|digest| !digest.is_empty()),
        "A's committed outcome carries its result reference"
    );
    assert_eq!(
        item_command(&run, "c").status,
        CommandStatus::Running,
        "C is running on A's completion"
    );

    gate_c.open();
    wait_for("the run to complete", || {
        service
            .store()
            .run(&run_id)
            .is_ok_and(|run| run.status == StrategyRunStatus::Completed)
    });
    remove_root(root);
}

/// A04: C starts while the independent B is still in flight.
///
/// `maxParallelism: 2` admits items `a` and `b` in one admit loop; the runtime
/// ledger keys an in-flight effect by the workset item it runs, so two items of
/// one visit are two work units. The old batch loop joined both before it
/// committed either, which is the ordering this case rules out.
#[test]
fn a04_c_starts_while_independent_b_is_still_in_flight() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let gate_a = Gate::new();
    let gate_b = Gate::new();
    let gate_c = Gate::new();
    let service = StrategyService::open(&root)
        .expect("open service")
        .with_actor_turn_port(turn_port(
            probe.clone(),
            vec![
                ("a".to_owned(), gate_a.clone()),
                ("b".to_owned(), gate_b.clone()),
                ("c".to_owned(), gate_c.clone()),
            ],
        ));
    let revision = import_revision(&service, &root, &workset_workflow_json(2));
    let (conversation_id, membership_id) = create_conversation(&root);
    bind_slots(&service, &revision, &membership_id);
    grant(&service, &revision);

    let run_id = start_run(&service, &revision, &conversation_id, full_input());
    wait_for("a and b invoked", || {
        let invoked = probe.invoked();
        invoked.contains("a") && invoked.contains("b")
    });
    gate_a.open();
    wait_for("c invoked", || probe.invoked().contains("c"));
    let run = service.store().run(&run_id).unwrap();
    assert_eq!(item_command(&run, "a").status, CommandStatus::Succeeded);
    assert_eq!(item_command(&run, "c").status, CommandStatus::Running);
    assert_eq!(item_command(&run, "b").status, CommandStatus::Running);
    assert!(!probe.returned().contains("b"));
    gate_b.open();
    gate_c.open();
    wait_for("the run to complete", || {
        service
            .store()
            .run(&run_id)
            .is_ok_and(|run| run.status == StrategyRunStatus::Completed)
    });
    remove_root(root);
}

// ---------------------------------------------------------------------------
// A08 — the authority recheck refuses the next effect after a revocation
// ---------------------------------------------------------------------------

#[test]
fn a_revoked_authorization_refuses_the_next_effect_at_the_production_entry() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let service = StrategyService::open(&root)
        .expect("open service")
        .with_actor_turn_port(turn_port(probe.clone(), vec![]));
    let revision = import_revision(&service, &root, &actor_workflow_json());
    let (conversation_id, membership_id) = create_conversation(&root);
    bind_slots(&service, &revision, &membership_id);
    grant(&service, &revision);

    // The run exists without a drive, so the revocation lands before any
    // effect is admitted.
    let run = service
        .store()
        .start_run(
            &revision,
            json!({"message": "do the work"}),
            "v7-host-revoked",
            Some(&conversation_id),
            None,
        )
        .unwrap();
    let revoked = call(
        &service,
        json!({"action": "strategy.authorization.revoke", "revisionDigest": revision}),
    );
    assert_eq!(revoked["revoked"], true);

    // The ordinary entry admits the run and the effect boundary refuses it.
    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    wait_for("the run parked on its authorization gate", || {
        service
            .store()
            .run(&run.run_id)
            .is_ok_and(|run| run.status == StrategyRunStatus::AuthorizationRequired)
    });
    let run = service.store().run(&run.run_id).unwrap();
    assert_eq!(
        run.status,
        StrategyRunStatus::AuthorizationRequired,
        "the effect boundary refused the effect"
    );
    assert!(
        probe.invoked().is_empty(),
        "no effect may be invoked under a revoked grant, saw {:?}",
        probe.invoked()
    );
    let command = run
        .commands
        .values()
        .find(|command| command.state_id == "work")
        .expect("the work command exists");
    assert_eq!(command.status, CommandStatus::Retryable);
    assert_eq!(
        command.failure_class,
        Some(licoup_workflow::FailureClass::Authority)
    );
    remove_root(root);
}

// ---------------------------------------------------------------------------
// A08 — a durable pause fences new visits for a later drive call
// ---------------------------------------------------------------------------

#[test]
fn a_durable_pause_admitted_by_the_legacy_control_path_fences_new_visits() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);

    // The run exists without a drive, so the pause is durable before any
    // admission can race it.
    let run = service
        .store()
        .start_run(
            &revision,
            full_input(),
            "v7-host-pause",
            Some(&conversation_id),
            None,
        )
        .unwrap();

    // The pause is written the way the controlled store writes one: a pause
    // row for the graph scope, without the barrier flag. The drive must honour
    // it anyway — this is the read side of the R2 gap.
    let controlled = DurableControlledStore::open(&root).expect("open the controlled store");
    controlled
        .mark_pause_negotiating(&run.run_id, "graph")
        .expect("record the pause");
    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        probe.invoked().is_empty(),
        "a paused scope must not start a new visit, saw {:?}",
        probe.invoked()
    );

    // Publishing through the scope barrier fences the next drive the same way.
    StoreScopeBarrier::new(service.store().clone())
        .publish(&BarrierRequest {
            graph_id: run.run_id.clone(),
            scope: BarrierScope::Graph,
            kind: BarrierKind::Pause,
            reason: "v7-host-pause".to_owned(),
            recipients: vec![],
        })
        .expect("publish the scope barrier");
    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        probe.invoked().is_empty(),
        "a published barrier must fence the drive"
    );

    // Clearing the pause lets the next ordinary entry resume the run.
    controlled
        .clear_pause_negotiating(&run.run_id, "graph")
        .expect("clear the pause");
    controlled
        .set_graph_barrier(&run.run_id, false)
        .expect("clear the barrier");
    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    wait_for(
        "the run to start its effects after the pause cleared",
        || !probe.invoked().is_empty(),
    );
    remove_root(root);
}

// ---------------------------------------------------------------------------
// A02 — a durable marker is not re-dispatched
// ---------------------------------------------------------------------------

#[test]
fn a_started_marker_without_an_outcome_is_held_across_hosts() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);

    // The run exists without a drive: this test plays the host that must take
    // it over, not the one that started it. Two independent items, so the old
    // owner starts one and leaves the other queued for the successor.
    let run = service
        .store()
        .start_run(
            &revision,
            independent_pair_input(),
            "v7-host-started-marker",
            Some(&conversation_id),
            None,
        )
        .unwrap();

    // The previous host claimed and started its first effect, then died before
    // committing an outcome. Those are the durable facts it would have left: a
    // claim and the possible-effect marker. Its lease is short, because a live
    // claim legitimately holds the run's effect bound.
    let database = workflow_database(&root);
    let state = StoreStatePort::new(database.clone());
    let lease = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0))
        + 1_000;
    let claimed = state
        .claim_next(&run.run_id, "previous-host#1", lease)
        .expect("claim")
        .expect("one claimable command");
    state
        .mark_started(&run.run_id, &claimed.id, &claimed.attempt_token)
        .expect("mark started");
    let queued_item = if claimed.item_id.as_deref() == Some("a") {
        "b"
    } else {
        "a"
    };

    // The owner stopped without settling; the successor takes the run over
    // (A21) and starts only the migrated intent — never the started one.
    std::thread::sleep(Duration::from_millis(1_400));
    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while handoff_count(&database, &run.run_id) == 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(handoff_count(&database, &run.run_id), 1);
    let deadline = std::time::Instant::now() + Duration::from_secs(45);
    while !probe.invoked().contains(queued_item) && std::time::Instant::now() < deadline {
        call(
            &service,
            json!({"action": "strategy.run.resume", "runId": run.run_id}),
        );
        std::thread::sleep(Duration::from_millis(250));
    }

    let run = service.store().run(&run.run_id).unwrap();
    assert_eq!(
        run.commands[&claimed.id].status,
        CommandStatus::Running,
        "the started attempt stays exactly as the old owner left it"
    );
    assert_eq!(
        run.commands[&claimed.id].failure_code, None,
        "no one declared the old owner lost: the attempt is Unknown, not failed"
    );
    assert_eq!(
        probe.invoked(),
        BTreeSet::from([queued_item.to_owned()]),
        "only the queued intent was started, exactly once"
    );
    remove_root(root);
}

// ---------------------------------------------------------------------------
// A21 — the successor take-over, accepted and refused whole
// ---------------------------------------------------------------------------

/// A run whose first attempt is live under another owner is taken over.
///
/// The old owner keeps what it started (the successor never re-dispatches it),
/// the unstarted intent is started exactly once by the successor, and the
/// handoff record names the boundary revision, the migrated set and the kept
/// attempt.
#[test]
fn a_live_foreign_owner_is_taken_over_by_a_committed_handoff() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);

    // The run exists without a drive, so the previous owner's claim and marker
    // are durable facts before any successor looks at it.
    let run = service
        .store()
        .start_run(
            &revision,
            independent_pair_input(),
            "v7-host-takeover",
            Some(&conversation_id),
            None,
        )
        .unwrap();

    // The previous host started one item and is still alive: a live claim with
    // the possible-effect marker, owned by another fence.
    let database = workflow_database(&root);
    let state = StoreStatePort::new(database.clone());
    // The previous owner stopped without settling: a short lease that lapses
    // before any successor looks at the run.
    let lease = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0))
        + 1_000;
    let claimed = state
        .claim_next(&run.run_id, "previous-host#1", lease)
        .expect("claim")
        .expect("one claimable command");
    state
        .mark_started(&run.run_id, &claimed.id, &claimed.attempt_token)
        .expect("mark started");
    let queued_item = if claimed.item_id.as_deref() == Some("a") {
        "b"
    } else {
        "a"
    };
    std::thread::sleep(Duration::from_millis(1_400));

    // The first pass takes the run over from the stopped owner: the transfer is
    // committed from the durable boundary, and the started attempt is never
    // touched.
    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while handoff_count(&database, &run.run_id) == 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        handoff_count(&database, &run.run_id),
        1,
        "the take-over is committed for a stopped owner"
    );

    // The successor starts the intent the old owner never began; each pass is
    // one drive.
    let deadline = std::time::Instant::now() + Duration::from_secs(45);
    while !probe.invoked().contains(queued_item) && std::time::Instant::now() < deadline {
        call(
            &service,
            json!({"action": "strategy.run.resume", "runId": run.run_id}),
        );
        std::thread::sleep(Duration::from_millis(250));
    }

    let run = service.store().run(&run.run_id).unwrap();
    assert_eq!(
        run.commands[&claimed.id].status,
        CommandStatus::Running,
        "the started attempt stays with the owner that started it"
    );
    assert_eq!(
        run.commands[&claimed.id].failure_code, None,
        "the successor did not settle the old owner's effect"
    );
    assert!(
        probe.invoked() == BTreeSet::from([queued_item.to_owned()]),
        "the successor started exactly the unstarted intent, saw {:?}",
        probe.invoked()
    );

    // The transfer is durable and readable.
    let record = database
        .read(|connection| {
            Ok(connection.query_row(
                "SELECT new_owner, boundary_revision, migrated_json, started_json
                 FROM workflow_successor_handoffs WHERE run_id=?1",
                rusqlite::params![run.run_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )?)
        })
        .expect("the handoff row exists");
    assert_eq!(record.0, format!("licoup-host-{}", std::process::id()));
    assert!(record.1 > 0, "the boundary revision is recorded");
    assert!(
        record.2.contains("command:"),
        "the migrated set is recorded"
    );
    assert!(record.3.contains(&claimed.id), "the kept attempt is named");
    remove_root(root);
}

/// A live writer is never displaced on the strength of a new fence row.
///
/// The old generation may not read the successor tables at all, so committing
/// a transfer here would presume cooperation this host does not have. With no
/// cooperative contract the run stays exactly where it is: nothing is
/// claimed, nothing is transferred, and the live attempt is untouched.
#[test]
fn a_live_foreign_owner_is_not_displaced_without_cooperation() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);
    let run = service
        .store()
        .start_run(
            &revision,
            independent_pair_input(),
            "v7-host-live-owner",
            Some(&conversation_id),
            None,
        )
        .unwrap();

    let database = workflow_database(&root);
    let state = StoreStatePort::new(database.clone());
    let live = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0))
        + 60_000;
    let claimed = state
        .claim_next(&run.run_id, "previous-host#1", live)
        .expect("claim")
        .expect("one claimable command");
    state
        .mark_started(&run.run_id, &claimed.id, &claimed.attempt_token)
        .expect("mark started");

    call(
        &service,
        json!({"action": "strategy.run.resume", "runId": run.run_id}),
    );
    std::thread::sleep(Duration::from_millis(400));

    assert_eq!(
        handoff_count(&database, &run.run_id),
        0,
        "a live owner is not displaced: no transfer is committed"
    );
    assert!(
        probe.invoked().is_empty(),
        "no work is started against a live owner, saw {:?}",
        probe.invoked()
    );
    let run = service.store().run(&run.run_id).unwrap();
    assert_eq!(run.status, StrategyRunStatus::Running);
    assert_eq!(run.commands[&claimed.id].status, CommandStatus::Running);
    assert_eq!(run.commands[&claimed.id].failure_code, None);
    remove_root(root);
}

/// A handoff the store refuses transfers nothing.
///
/// The manifest is built from the durable boundary; a stale revision under it
/// makes the compare-and-set refuse whole, and the run is untouched.
#[test]
fn a_handoff_over_a_moved_boundary_is_refused_whole() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);
    let run = service
        .store()
        .start_run(
            &revision,
            independent_pair_input(),
            "v7-host-handoff-refused",
            Some(&conversation_id),
            None,
        )
        .unwrap();

    let database = workflow_database(&root);
    let recovery = licoup_workflow_store::recovery::RecoveryAssembly::assemble(database.clone())
        .expect("assemble recovery");
    let snapshot = service.store().run(&run.run_id).unwrap();
    let manifest = licoup_workflow_runtime::successor::handoff::SuccessorManifest {
        handoff_id: "stale-manifest".to_owned(),
        run_id: run.run_id.clone(),
        expected_revision: snapshot.sequence.saturating_sub(1),
        old_owner: "previous-host#1".to_owned(),
        new_owner: "successor-host#1".to_owned(),
        old_binding: licoup_workflow::compile::RecordedPlanKey {
            definition_revision: revision.clone(),
            compiler_semantics: String::new(),
            engine_semantics: String::new(),
            lowering_capabilities: Vec::new(),
        },
        new_owner_profile: licoup_workflow::compile::InterpreterProfile::current(
            licoup_workflow::compile::LoweringCapabilities::none(),
        ),
        unstarted: Vec::new(),
        started: Vec::new(),
    };
    let outcome = licoup_workflow_runtime::successor::handoff::SuccessorPort::handoff(
        &recovery.successor(),
        &manifest,
    )
    .expect("handoff call");
    match outcome {
        licoup_workflow_runtime::successor::handoff::HandoffOutcome::Refused { refusal } => {
            assert!(
                matches!(
                    refusal,
                    licoup_workflow_runtime::successor::handoff::HandoffRefusal::RevisionMoved { .. }
                ),
                "expected a revision refusal, got {refusal:?}"
            );
        }
        other => panic!("a moved boundary must refuse whole, got {other:?}"),
    }
    let (handoffs, status) = database
        .read(|connection| {
            let handoffs: i64 = connection.query_row(
                "SELECT COUNT(*) FROM workflow_successor_handoffs WHERE run_id=?1",
                rusqlite::params![run.run_id],
                |row| row.get(0),
            )?;
            let snapshot_json: String = connection.query_row(
                "SELECT snapshot_json FROM strategy_runs WHERE run_id=?1",
                rusqlite::params![run.run_id],
                |row| row.get(0),
            )?;
            let snapshot: licoup_workflow::RunSnapshot =
                serde_json::from_str(&snapshot_json).expect("checkpoint parses");
            Ok((handoffs, snapshot.status))
        })
        .unwrap();
    assert_eq!(handoffs, 0);
    assert_eq!(status, StrategyRunStatus::Running);
    remove_root(root);
}

/// A missing definition is fail-closed: the drive does not start work.
#[test]
fn a_run_without_its_definition_is_not_advanced() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);
    let run = service
        .store()
        .start_run(
            &revision,
            independent_pair_input(),
            "v7-host-no-definition",
            Some(&conversation_id),
            None,
        )
        .unwrap();

    let database = workflow_database(&root);
    database
        .read(|connection| {
            // The point of the case is a run whose definition cannot be read;
            // the reference is left dangling on purpose.
            connection.execute_batch("PRAGMA foreign_keys=OFF;")?;
            connection.execute(
                "DELETE FROM strategy_definitions WHERE revision_digest=?1",
                rusqlite::params![revision],
            )?;
            Ok(())
        })
        .expect("remove the definition");

    let refused = service
        .execute(json!({"action": "strategy.run.resume", "runId": run.run_id}))
        .expect("execute");
    assert_eq!(
        refused["ok"], false,
        "a run whose definition is missing is refused at the entry: {refused}"
    );
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        probe.invoked().is_empty(),
        "a run whose definition is missing must not be advanced, saw {:?}",
        probe.invoked()
    );
    remove_root(root);
}

// ---------------------------------------------------------------------------
// A09 — the notice outbox: crash window, unassembled owner, exactly once
// ---------------------------------------------------------------------------

/// A committed obligation survives a host that never delivered it.
///
/// The first host commits the fact but is composed without a wake port: the
/// intent is durable and unacknowledged, which is the crash window in
/// miniature. A later drive pass delivers it exactly once.
#[test]
fn an_undelivered_wake_is_delivered_once_by_the_next_entry() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let (service, revision, conversation_id) = prepared_host(&root, &probe, vec![]);

    // This host commits the settlement but has no wake owner assembled.
    let run_id = start_run(&service, &revision, &conversation_id, successor_input());
    wait_for("the run to complete", || {
        service
            .store()
            .run(&run_id)
            .is_ok_and(|run| run.status == StrategyRunStatus::Completed)
    });

    let database = workflow_database(&root);
    let wake_owner = "assistant-wake";
    let pending = database
        .pending_notice_intents(64)
        .expect("pending intents");
    assert!(
        pending
            .iter()
            .any(|intent| intent.recipient == wake_owner && intent.run_id == run_id),
        "the wake intent is durable and unacknowledged: {pending:?}"
    );

    // The next host has a wake owner; a later drive pass delivers what the
    // previous host committed and never accepted.
    let wakes = Arc::new(Mutex::new(Vec::<Value>::new()));
    let wake_log = Arc::clone(&wakes);
    let resumed = StrategyService::open(&root)
        .expect("open service")
        .with_actor_turn_port(turn_port(TurnProbe::default(), vec![]))
        .with_assistant_wake_port(licoup_native::domain::workflow_runtime::AssistantWakePort {
            wake: Arc::new(move |_conversation, _master, notice| {
                wake_log.lock().expect("wake log").push(notice.clone());
                Ok(())
            }),
        });
    // The wake notice was released with a retry delay when this host had no
    // owner for it; each later drive pass is what delivers it. The pass tries
    // until the obligation is accepted, then proves it is not repeated.
    let run_wakes = |wakes: &Arc<Mutex<Vec<Value>>>| {
        wakes
            .lock()
            .expect("wake log")
            .iter()
            .filter(|notice| notice["runId"] == json!(run_id))
            .count()
    };
    let mut passes = 0;
    let deadline = std::time::Instant::now() + Duration::from_secs(45);
    while run_wakes(&wakes) == 0 && std::time::Instant::now() < deadline {
        passes += 1;
        start_run_with_key(
            &resumed,
            &revision,
            &conversation_id,
            successor_input(),
            &format!("v7-host-run-pass-{passes}"),
        );
        std::thread::sleep(Duration::from_millis(250));
    }
    let accepted = run_wakes(&wakes);
    assert!(
        accepted >= 1,
        "a later drive pass delivered the durable obligation after {passes} passes"
    );

    // A further pass has nothing left to deliver for that run.
    start_run_with_key(
        &resumed,
        &revision,
        &conversation_id,
        successor_input(),
        "v7-host-run-after",
    );
    std::thread::sleep(Duration::from_millis(250));
    assert_eq!(
        run_wakes(&wakes),
        accepted,
        "an acknowledged fact is not delivered twice"
    );

    let pending_after = database
        .pending_notice_intents(64)
        .expect("pending intents");
    assert!(
        !pending_after
            .iter()
            .any(|intent| intent.recipient == wake_owner && intent.run_id == run_id),
        "the wake intent is acknowledged: {pending_after:?}"
    );
    remove_root(root);
}

/// Each owner acknowledges its own fact; the projection is durably single.
#[test]
fn the_projection_and_the_wake_are_acknowledged_independently() {
    let _serial = serial_guard();
    let root = root();
    let probe = TurnProbe::default();
    let wakes = Arc::new(Mutex::new(Vec::<Value>::new()));
    let wake_log = Arc::clone(&wakes);
    let service = StrategyService::open(&root)
        .expect("open service")
        .with_actor_turn_port(turn_port(probe.clone(), vec![]))
        .with_assistant_wake_port(licoup_native::domain::workflow_runtime::AssistantWakePort {
            wake: Arc::new(move |conversation, master, notice| {
                let _ = (conversation, master);
                wake_log.lock().expect("wake log").push(notice.clone());
                Ok(())
            }),
        });
    let revision = import_revision(&service, &root, &workset_workflow_json(1));
    let (conversation_id, membership_id) = create_conversation(&root);
    bind_slots(&service, &revision, &membership_id);
    grant(&service, &revision);

    let run_id = start_run(&service, &revision, &conversation_id, successor_input());
    wait_for("the run to complete", || {
        service
            .store()
            .run(&run_id)
            .is_ok_and(|run| run.status == StrategyRunStatus::Completed)
    });
    wait_for("the wake", || !wakes.lock().expect("wake log").is_empty());

    // The two owners are served independently; the projection lands on the
    // timeline as its own acceptance.
    let conversation_store =
        licoup_native::domain::client_conversation::ConversationStore::open(&root).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut settled: Vec<Value> = Vec::new();
    while std::time::Instant::now() < deadline {
        let page = conversation_store
            .page_events(&conversation_id, None, 128)
            .expect("page events");
        settled = page
            .events
            .iter()
            .flat_map(|event| event.parts.iter())
            .filter(|part| {
                part.kind == licoup_native::domain::client_conversation::EventPartKind::Metadata
            })
            .filter_map(|part| serde_json::from_str::<Value>(&part.content).ok())
            .filter(|content| content["kind"] == json!("strategy-flow-settled"))
            .collect();
        if settled
            .iter()
            .any(|notice| notice["stateId"] == json!("tasks"))
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        settled
            .iter()
            .any(|notice| notice["stateId"] == json!("tasks")),
        "the projected settlement is durable: {settled:?}"
    );
    assert!(!wakes.lock().expect("wake log").is_empty());
    remove_root(root);
}
