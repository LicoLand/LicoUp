//! V7-H1 recovery harness — acceptance case A02 at `production-integration`
//! level.
//!
//! The entry under test is `StrategyService::execute`, the same call the stdio
//! RPC server makes for `strategy.*` actions
//! (`crates/licoup-native/src/bin/licoup/stdio_rpc/server.rs:529`). Everything
//! below runs against a real portable root: a real Conversation authority, a
//! real imported package, the real drive loop, and a real actor turn port.
//!
//! Host death here is a **real process death**, not a simulated one. This test
//! re-executes its own binary as a child (`host_a_process`) which starts the
//! run and then blocks inside the actor effect; the parent kills that child
//! with SIGKILL once the durable command has reached `running`. A killed host
//! gets no chance to release leases, drop drive reservations, or commit an
//! outcome — which is exactly the window A02 is about, and why an in-process
//! model would be a weaker proof: a blocked thread in this process still holds
//! the run's drive reservation, so the replacement host would refuse to drive.
//!
//! The external effect appends a line to a file. It is non-idempotent and
//! visible across processes, so "dispatched at most once" is a line count.
//!
//! What is real: the entry, the drive loop, the SQLite stores, the Conversation
//! authority, the package import, and the two host processes.
//!
//! What is synthetic, stated plainly: the actor executor is a closure standing
//! in for `conversation::strategy_turn_port`, and slots are bound through the
//! public `StrategyStore::replace_slot_bindings` rather than the
//! `strategy.binding.update` action, because that action also asks a real
//! installed agent for its capability catalog and a synthetic agent has none.
//! The harness also models an already-authorized host-loss declaration by
//! expiring the exact durable lease in SQL before calling the public recovery
//! port; production does not infer that authorization from process exit. These
//! are setup, not the behaviour under test.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use licoup_native::domain::client_conversation::{
    ConversationStore, MembershipAccess, Principal, PrincipalKind,
};
use licoup_native::domain::workflow_runtime::{
    ActorTurnPort, StrategyService, synthetic_fixture_package_bytes,
};
use licoup_native::domain::workflow_store::BindingCandidate;
use licoup_native::platform::runtime_adapters::RuntimeAdapterError;
use licoup_workflow::{CommandKind, CommandStatus, FailureClass};
use licoup_workflow_runtime::successor::recovery::{RecoveryCause, RecoveryPort, RecoveryRequest};
use licoup_workflow_store::recovery::RecoveryAssembly;
use licoup_workflow_store::transactions::WorkflowDatabase;
use serde_json::{Value, json};

const SLOT_ENTRY: &str = "entry";
const SLOT_WORKER: &str = "worker-a";

const ROLE_ENV: &str = "V7_RECOVERY_ROLE";
const ROOT_ENV: &str = "V7_RECOVERY_ROOT";
const CONVERSATION_ENV: &str = "V7_RECOVERY_CONVERSATION";
const REVISION_ENV: &str = "V7_RECOVERY_REVISION";
const EFFECT_LOG_ENV: &str = "V7_RECOVERY_EFFECT_LOG";
const RUN_ID_ENV: &str = "V7_RECOVERY_RUN_ID_FILE";

// ---------------------------------------------------------------------------
// The non-idempotent external effect
// ---------------------------------------------------------------------------

/// Every dispatch appends one line. A second dispatch of the same effect is a
/// second line, in every process, on disk.
fn record_dispatch(log: &Path) {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .expect("open effect log");
    writeln!(file, "dispatch").expect("append dispatch");
    file.sync_all().expect("durable dispatch");
}

fn dispatch_count(log: &Path) -> usize {
    std::fs::read_to_string(log)
        .map(|body| body.lines().filter(|line| !line.is_empty()).count())
        .unwrap_or(0)
}

fn effect_port(log: PathBuf, block_forever: bool) -> ActorTurnPort {
    ActorTurnPort {
        open: Arc::new(|_params: &Value| -> Result<String, RuntimeAdapterError> {
            Ok("turn-entry".to_owned())
        }),
        run: Arc::new(
            move |_handle: &str, _params: &Value| -> Result<Value, RuntimeAdapterError> {
                record_dispatch(&log);
                if block_forever {
                    // Hold the effect in flight until the process is killed, so
                    // the durable command stays `running` with no outcome.
                    loop {
                        std::thread::sleep(Duration::from_secs(3600));
                    }
                }
                Ok(json!({"status": "ok"}))
            },
        ),
        abandon: Arc::new(|_handle: &str| {}),
    }
}

// ---------------------------------------------------------------------------
// The child: a real host process that dies mid-effect
// ---------------------------------------------------------------------------

/// Runs as a real host process: starts the run, writes its id where the parent
/// can find it, and blocks inside the effect until it is killed.
///
/// Ignored during ordinary test runs; the harness re-executes this binary with
/// `--ignored --exact host_a_process`.
#[test]
#[ignore = "spawned as a child process by the recovery harness"]
fn host_a_process() {
    if std::env::var(ROLE_ENV).as_deref() != Ok("host-a") {
        // Ordinary test run: nothing to do.
        return;
    }
    let root = PathBuf::from(std::env::var(ROOT_ENV).expect("root"));
    let conversation_id = std::env::var(CONVERSATION_ENV).expect("conversation");
    let revision = std::env::var(REVISION_ENV).expect("revision");
    let log = PathBuf::from(std::env::var(EFFECT_LOG_ENV).expect("effect log"));
    let run_id_file = PathBuf::from(std::env::var(RUN_ID_ENV).expect("run id file"));

    let host = StrategyService::open(&root)
        .expect("open host a")
        .with_actor_turn_port(effect_port(log, true));

    let response = host
        .execute(json!({
            "action": "strategy.run.start",
            "revisionDigest": revision,
            "input": {"message": "do the work"},
            "idempotencyKey": "v7-recovery-mid-effect",
            "conversationId": conversation_id,
        }))
        .expect("run.start");
    assert_eq!(
        response["ok"], true,
        "host a could not start the run: {response}"
    );
    std::fs::write(
        &run_id_file,
        response["result"]["runId"].as_str().unwrap_or_default(),
    )
    .expect("publish run id");

    // Block until killed: the effect is in flight and no outcome is committed.
    // The cap bounds this process's lifetime, so a parent that dies before it
    // can kill us does not leave an orphan holding the scratch root's databases.
    let deadline = Instant::now() + Duration::from_secs(300);
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(200));
    }
    eprintln!("host a outlived its deadline without being killed");
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn call(service: &StrategyService, request: Value) -> Value {
    let action = request["action"].clone();
    let response = service.execute(request).expect("execute");
    assert_eq!(response["ok"], true, "entry rejected {action}: {response}");
    response["result"].clone()
}

fn import_revision(service: &StrategyService, root: &Path) -> String {
    let package = root.join("fixture.zip");
    std::fs::write(&package, synthetic_fixture_package_bytes().unwrap()).unwrap();
    let prepared = call(
        service,
        json!({
            "action": "strategy.package.prepare-import",
            "sourcePath": package.to_string_lossy(),
            "selectionToken": "v7-recovery-selection",
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
    assert_eq!(committed["definitionId"], "fixture-entry-worker");
    prepared["revisionDigest"].as_str().unwrap().to_owned()
}

/// Create the Conversation authority the actor dispatch resolves against and
/// return `(conversationId, membershipId)`.
///
/// The membership id is what actor slots bind to: `group_actor_target` resolves
/// a binding by looking for an active membership whose id *is* the binding
/// value, and the turn then runs as that membership's `agent_id` — which must
/// be a lowercase actor identifier, because `actor_fingerprint` rejects
/// anything else.
fn create_conversation(root: &Path) -> (String, String) {
    let store = ConversationStore::open(root).unwrap();
    let now = 1_700_000_000_000;
    let conversation = store
        .create_conversation_with_members(
            "v7 recovery",
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
                    agent_id: Some("v7-recovery-agent".into()),
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
    (conversation.id, membership)
}

fn bind_slots(service: &StrategyService, revision: &str, membership_id: &str) {
    for slot in [SLOT_ENTRY, SLOT_WORKER] {
        service
            .store()
            .replace_slot_bindings(
                revision,
                slot,
                &[BindingCandidate {
                    value_id: membership_id.to_owned(),
                    model: String::new(),
                    reasoning_effort: String::new(),
                }],
                None,
            )
            .unwrap_or_else(|error| panic!("bind {slot}: {error}"));
    }
}

fn wait_for<F: Fn() -> bool>(what: &str, predicate: F) {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if predicate() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for {what}");
}

fn actor_statuses(service: &StrategyService, run_id: &str) -> Vec<CommandStatus> {
    service
        .store()
        .run(run_id)
        .expect("read run")
        .commands
        .values()
        .filter(|command| matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem))
        .map(|command| command.status)
        .collect()
}

/// Model an already-authorized host-loss declaration.
///
/// Process exit alone cannot revoke a live durable lease. The test harness
/// expires the one exact claimant it was authorized to declare lost; only then
/// may the public recovery port record that owner's started attempt as unknown.
fn declare_exact_owner_lost(service: &StrategyService, run_id: &str) {
    let database = Arc::new(WorkflowDatabase::open(service.store().db_path()).unwrap());
    let now_unix_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("wall clock follows the Unix epoch")
        .as_millis()
        .min(i64::MAX as u128) as i64;
    let ((command_id, owner), _) = database
        .write(|transaction, _| {
            let rows = {
                let mut statement = transaction.prepare(
                    "SELECT command_id, lease_owner, lease_until
                     FROM strategy_commands
                     WHERE run_id=?1 AND status='running'
                     ORDER BY command_id",
                )?;
                statement
                    .query_map(rusqlite::params![run_id], |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, i64>(2)?,
                        ))
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            };
            assert_eq!(rows.len(), 1, "the test declares one exact claimant lost");
            let (command_id, owner, lease_until) = rows.into_iter().next().unwrap();
            assert!(
                lease_until > now_unix_ms,
                "the declaration explicitly revokes a live lease"
            );
            let changed = transaction.execute(
                "UPDATE strategy_commands SET lease_until=0
                     WHERE run_id=?1 AND command_id=?2 AND lease_owner=?3
                       AND status='running' AND lease_until>?4",
                rusqlite::params![run_id, command_id, owner, now_unix_ms],
            )?;
            assert_eq!(changed, 1, "only the declared owner's live attempt moved");
            Ok((command_id, owner))
        })
        .expect("the authority expires the exact lost owner's lease");

    let recovery = RecoveryAssembly::assemble(database)
        .expect("assemble recovery")
        .recovery();
    let report = recovery
        .sweep(&RecoveryRequest {
            run_id: run_id.to_owned(),
            cause: RecoveryCause::HostDeclaredLost {
                owner: owner.clone(),
                source: "host-monitor".to_owned(),
            },
            now_unix_ms,
        })
        .expect("the declared-lost owner is reconciled");
    assert_eq!(report.settled_unknown, vec![command_id]);
}

fn successor_handoff_count(service: &StrategyService, run_id: &str) -> i64 {
    WorkflowDatabase::open(service.store().db_path())
        .unwrap()
        .read(|connection| {
            connection
                .query_row(
                    "SELECT COUNT(*) FROM workflow_successor_handoffs WHERE run_id=?1",
                    rusqlite::params![run_id],
                    |row| row.get(0),
                )
                .map_err(Into::into)
        })
        .unwrap()
}

/// The child publishes the run it started; the durable store stays the
/// authority, this file only tells us which run to look at.
fn wait_for_run_id(run_id_file: &Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        if let Ok(body) = std::fs::read_to_string(run_id_file) {
            let trimmed = body.trim();
            if !trimmed.is_empty() {
                return trimmed.to_owned();
            }
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for host a to publish its run id");
}

fn scratch_root(label: &str) -> PathBuf {
    let root =
        std::env::temp_dir().join(format!("lico-v7-recovery-{label}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

/// Removes the scratch tree on the way out, including when an assertion
/// panics, so a failing run does not leave state behind.
///
/// The imported package publishes read-only revision content, so removal has
/// to restore write permission first — the same two steps the crate's own
/// store tests take.
struct ScratchRoot(PathBuf);

impl Drop for ScratchRoot {
    fn drop(&mut self) {
        make_writable_tree(&self.0);
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn make_writable_tree(root: &Path) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(current) = stack.pop() {
        let Ok(metadata) = std::fs::symlink_metadata(&current) else {
            continue;
        };
        let mut permissions = metadata.permissions();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let owner_bits = if metadata.is_dir() { 0o700 } else { 0o600 };
            permissions.set_mode(permissions.mode() | owner_bits);
        }
        #[cfg(not(unix))]
        permissions.set_readonly(false);
        let _ = std::fs::set_permissions(&current, permissions);
        if metadata.is_dir()
            && let Ok(entries) = std::fs::read_dir(&current)
        {
            stack.extend(entries.flatten().map(|entry| entry.path()));
        }
    }
}

/// Kills the child host on the way out, so a panicking run cannot leave a
/// blocked host process behind.
struct ChildGuard(std::process::Child);

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

// ---------------------------------------------------------------------------
// The acceptance case
// ---------------------------------------------------------------------------

#[test]
fn a_live_lease_blocks_takeover_then_declared_loss_settles_without_redispatch() {
    let scratch = ScratchRoot(scratch_root("mid-effect"));
    let root = scratch.0.clone();
    let effect_log = root.join("effects.log");
    let run_id_file = root.join("run-id");

    // --- Setup through the real entry, on the root both hosts share. -------
    let setup = StrategyService::open(&root).unwrap();
    let (conversation_id, membership_id) = create_conversation(&root);
    let revision = import_revision(&setup, &root);
    bind_slots(&setup, &revision, &membership_id);
    let preview = call(
        &setup,
        json!({"action": "strategy.authorization.preview", "revisionDigest": revision}),
    );
    call(
        &setup,
        json!({
            "action": "strategy.authorization.grant",
            "revisionDigest": revision,
            "authorizationDigest": preview["authorizationDigest"],
            "confirmed": true,
        }),
    );
    drop(setup);

    // --- Host A: a real, separate process. ---------------------------------
    let child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--ignored", "--exact", "host_a_process", "--nocapture"])
        .env(ROLE_ENV, "host-a")
        .env(ROOT_ENV, &root)
        .env(CONVERSATION_ENV, &conversation_id)
        .env(REVISION_ENV, &revision)
        .env(EFFECT_LOG_ENV, &effect_log)
        .env(RUN_ID_ENV, &run_id_file)
        .spawn()
        .expect("spawn host a");
    let mut child = ChildGuard(child);

    // Wait until the effect has actually been dispatched and the durable
    // command is running, so the kill lands inside the window under test.
    wait_for("host a to dispatch the effect", || {
        dispatch_count(&effect_log) >= 1
    });
    let run_id = wait_for_run_id(&run_id_file);

    let observer = StrategyService::open(&root).unwrap();
    wait_for("the durable command to be running", || {
        actor_statuses(&observer, &run_id).contains(&CommandStatus::Running)
    });
    drop(observer);

    // The host dies with SIGKILL: no lease release, no reservation drop, no
    // committed outcome.
    child.0.kill().expect("kill host a");
    let _ = child.0.wait();

    // --- Host B: the replacement host, same root, same real entry. ---------
    let host_b = StrategyService::open(&root)
        .expect("open replacement host")
        .with_actor_turn_port(effect_port(effect_log.clone(), false));
    let resumed = call(
        &host_b,
        json!({"action": "strategy.run.resume", "runId": run_id}),
    );
    assert_eq!(resumed["runId"], run_id);

    // Process death is not lease revocation. The replacement must leave a
    // still-live claimant alone, even though that means resume cannot advance.
    std::thread::sleep(Duration::from_millis(250));
    assert!(
        actor_statuses(&host_b, &run_id).contains(&CommandStatus::Running),
        "an unexpired lease is never inferred dead from process exit"
    );
    assert_eq!(
        dispatch_count(&effect_log),
        1,
        "a refused takeover cannot dispatch the effect again"
    );
    assert_eq!(
        successor_handoff_count(&host_b, &run_id),
        0,
        "the live lease prevents a successor handoff"
    );

    // The harness now models authorized revocation of the exact old lease and
    // declares that same opaque claimant lost through the public recovery port.
    declare_exact_owner_lost(&host_b, &run_id);

    // --- The property under test. ------------------------------------------
    let snapshot = host_b.store().run(&run_id).unwrap();
    let started_effect = snapshot
        .commands
        .values()
        .find(|command| {
            matches!(command.kind, CommandKind::Actor | CommandKind::WorksetItem)
                && command.status == CommandStatus::InDoubt
        })
        .unwrap_or_else(|| {
            panic!(
                "the started effect must be left in doubt, not re-dispatched: {:?}",
                actor_statuses(&host_b, &run_id)
            )
        });
    assert_eq!(
        started_effect.failure_class,
        Some(FailureClass::InDoubt),
        "an unrecorded outcome must not be classified as retryable"
    );
    assert_eq!(
        started_effect.failure_code.as_deref(),
        Some("host_runtime_lost"),
        "losing the host stays the distinct reason"
    );
    assert_eq!(
        started_effect.attempt, 1,
        "a started effect must not gain a second attempt"
    );
    assert_eq!(
        dispatch_count(&effect_log),
        1,
        "a non-idempotent effect must be dispatched at most once across a host restart"
    );
    assert!(
        !actor_statuses(&host_b, &run_id)
            .iter()
            .any(|status| matches!(
                status,
                CommandStatus::Pending | CommandStatus::Claimed | CommandStatus::Retryable
            )),
        "the replacement host must not be handed new work for a started effect"
    );

    // Give a wrongly re-dispatched effect time to land before the final read.
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(
        dispatch_count(&effect_log),
        1,
        "the effect log must not gain a second dispatch"
    );
}
