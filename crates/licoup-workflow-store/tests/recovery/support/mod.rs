//! Fixtures shared by the recovery tests.
//!
//! These tests run against a real database file through the production store's
//! own ports, with real definitions and real reducer events: the checkpoint is
//! written by the transaction adapter, the command rows carry real claims, and
//! recovery is asked through the assembled ports rather than through a stand-in
//! for them. The one thing the tests supply themselves is the effect owner: a
//! dispatch counter that lives outside the database, so "the effect happened
//! twice" is observable as a number and not as a second row someone agreed to
//! look at.

#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Result, anyhow};
use licoup_workflow::compile::{
    CompilerSemantics, DefinitionRevision, EngineSemantics, InterpreterProfile,
    LoweringCapabilities, RecordedPlanKey,
};
use licoup_workflow::{
    ActorSlot, CallbackDecisionKind, GraphState, GraphStateKind, ReducerEvent, RetryPolicy,
    RunCommand, RunSnapshot, Transition, TransitionEvent, TransitionMode, WorkflowDefinition,
    WorkflowLimits, WorkflowMetadata,
};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_runtime::successor::handoff::{
    LiveAttempt, SuccessorManifest, UnstartedIntent,
};
use licoup_workflow_runtime::successor::recovery::EffectBoundary;
use licoup_workflow_store::recovery::{
    FencedState, RecoveryAssembly, StoreRecovery, StoreSuccessor,
};
use licoup_workflow_store::transactions::{StoreStatePort, WorkflowDatabase};
use serde_json::{Value, json};

/// The semantics digest every fixture binds to its definition.
pub const SEMANTICS: &str = "semantics-fixture-v1";

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A path in the system temp directory, unique per process and per call.
pub fn scratch_path(label: &str) -> PathBuf {
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!(
        "licoup-workflow-recovery-{label}-{}-{unique}-{nanos}.sqlite3",
        std::process::id()
    ))
}

/// Remove a database file and the journal files SQLite keeps beside it.
pub fn remove_database(path: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut name = path.as_os_str().to_owned();
        name.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(name));
    }
}

// ---------------------------------------------------------------------------
// Definitions
// ---------------------------------------------------------------------------

fn state(id: &str, kind: GraphStateKind) -> GraphState {
    GraphState {
        id: id.into(),
        kind,
        label: id.into(),
        instruction: String::new(),
        binding: None,
        runtime: None,
        entry: None,
        workset: None,
        retry: RetryPolicy::default(),
    }
}

fn actor(id: &str) -> GraphState {
    GraphState {
        binding: Some("worker".into()),
        // A retry policy that allows a first transient retry, which is what a
        // known-not-executed claim is: without it the machine settles the
        // attempt as failed instead of scheduling a replacement, and the test
        // would be measuring the default policy rather than recovery.
        retry: RetryPolicy {
            max_attempts: 3,
            ..RetryPolicy::default()
        },
        ..state(id, GraphStateKind::Actor)
    }
}

fn succeed(id: &str) -> GraphState {
    state(id, GraphStateKind::Succeed)
}

fn fail(id: &str) -> GraphState {
    state(id, GraphStateKind::Fail)
}

fn edge(from: &str, to: &str, event: TransitionEvent, mode: TransitionMode) -> Transition {
    // Identifier-shaped and unique per (from, to, event): a branch may exit on
    // either event to the same target, so the event has to be in the identity.
    let suffix = match event {
        TransitionEvent::Success => "ok",
        TransitionEvent::Failure => "failure",
        TransitionEvent::Complete => "complete",
    };
    Transition {
        id: format!("{from}-{to}-{suffix}"),
        from: from.into(),
        to: to.into(),
        event,
        mode,
        guard: None,
    }
}

fn definition(
    id: &str,
    initial: &str,
    states: Vec<GraphState>,
    transitions: Vec<Transition>,
) -> WorkflowDefinition {
    WorkflowDefinition {
        schema: licoup_workflow::WORKFLOW_SCHEMA_VERSION.into(),
        metadata: WorkflowMetadata {
            id: id.into(),
            name: id.into(),
            version: "1".into(),
            description: String::new(),
        },
        limits: WorkflowLimits::default(),
        actor_slots: vec![ActorSlot::required_actor("worker", "Worker")],
        runtimes: vec![],
        worksets: vec![],
        initial: initial.into(),
        states,
        transitions,
    }
}

/// The smallest run that produces one actor effect.
pub fn single_actor() -> WorkflowDefinition {
    definition(
        "single-actor",
        "work",
        vec![actor("work"), succeed("done"), fail("fail")],
        vec![
            edge(
                "work",
                "done",
                TransitionEvent::Success,
                TransitionMode::Flow,
            ),
            edge(
                "work",
                "fail",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
        ],
    )
}

/// Three actor branches that reconverge on one join, then one finishing actor.
///
/// This is the shape a boundary needs: one settled branch (a result to name),
/// one live branch (an attempt that stays with its owner), and one queued
/// branch (an intent a successor may start).
pub fn three_branch_fork_join() -> WorkflowDefinition {
    definition(
        "three-branch",
        "start",
        vec![
            state("start", GraphStateKind::Pass),
            state("fan", GraphStateKind::Fork),
            actor("a"),
            actor("b"),
            actor("c"),
            state("join", GraphStateKind::Join),
            actor("finish"),
            succeed("done"),
            fail("fail"),
        ],
        vec![
            edge(
                "start",
                "fan",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge("fan", "a", TransitionEvent::Complete, TransitionMode::Flow),
            edge("fan", "b", TransitionEvent::Complete, TransitionMode::Flow),
            edge("fan", "c", TransitionEvent::Complete, TransitionMode::Flow),
            edge("a", "join", TransitionEvent::Success, TransitionMode::Flow),
            edge("a", "join", TransitionEvent::Failure, TransitionMode::Flow),
            edge("b", "join", TransitionEvent::Success, TransitionMode::Flow),
            edge("b", "join", TransitionEvent::Failure, TransitionMode::Flow),
            edge("c", "join", TransitionEvent::Success, TransitionMode::Flow),
            edge("c", "join", TransitionEvent::Failure, TransitionMode::Flow),
            edge(
                "join",
                "finish",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "finish",
                "done",
                TransitionEvent::Success,
                TransitionMode::Flow,
            ),
            edge(
                "finish",
                "fail",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
        ],
    )
}

/// Four actor branches where the first arrives only by an explicit decision.
///
/// `branch-a`'s edge is a callback, so its visit parks until a master decides;
/// `branch-b`, `branch-c` and `branch-d` flow straight to the join. That is the
/// reachable way to make the join see contributions from two different visits,
/// with one more branch left live so recovery has something to act on while the
/// mixed ledger exists.
pub fn mixed_epoch_fork_join() -> WorkflowDefinition {
    definition(
        "mixed-epoch",
        "start",
        vec![
            state("start", GraphStateKind::Pass),
            state("fan", GraphStateKind::Fork),
            actor("branch-a"),
            actor("branch-b"),
            actor("branch-c"),
            actor("branch-d"),
            state("join", GraphStateKind::Join),
            actor("finish"),
            succeed("done"),
            fail("fail"),
        ],
        vec![
            edge(
                "start",
                "fan",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "fan",
                "branch-a",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "fan",
                "branch-b",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "fan",
                "branch-c",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "fan",
                "branch-d",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "branch-a",
                "join",
                TransitionEvent::Success,
                TransitionMode::Callback,
            ),
            edge(
                "branch-a",
                "join",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
            edge(
                "branch-b",
                "join",
                TransitionEvent::Success,
                TransitionMode::Flow,
            ),
            edge(
                "branch-b",
                "join",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
            edge(
                "branch-c",
                "join",
                TransitionEvent::Success,
                TransitionMode::Flow,
            ),
            edge(
                "branch-c",
                "join",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
            edge(
                "branch-d",
                "join",
                TransitionEvent::Success,
                TransitionMode::Flow,
            ),
            edge(
                "branch-d",
                "join",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
            edge(
                "join",
                "finish",
                TransitionEvent::Complete,
                TransitionMode::Flow,
            ),
            edge(
                "finish",
                "done",
                TransitionEvent::Success,
                TransitionMode::Flow,
            ),
            edge(
                "finish",
                "fail",
                TransitionEvent::Failure,
                TransitionMode::Flow,
            ),
        ],
    )
}

// ---------------------------------------------------------------------------
// One database, assembled
// ---------------------------------------------------------------------------

/// A database file that removes itself when the test ends.
pub struct Fixture {
    path: PathBuf,
    database: Arc<WorkflowDatabase>,
    revision_digest: String,
}

impl Fixture {
    /// A scratch database seeded with one definition and one pending run.
    pub fn with_definition(
        label: &str,
        run_id: &str,
        workflow: &WorkflowDefinition,
    ) -> Result<Self> {
        let revision_digest = DefinitionRevision::of(workflow)?.as_str().to_owned();
        let path = scratch_path(label);
        let database = WorkflowDatabase::open(&path)?;
        seed_definition(&database, &revision_digest, workflow)?;
        seed_run(&database, run_id, &revision_digest)?;
        Ok(Self {
            path,
            database: Arc::new(database),
            revision_digest,
        })
    }

    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }

    pub fn revision_digest(&self) -> &str {
        &self.revision_digest
    }

    /// The assembled recovery side, which is also the proof its tables exist.
    pub fn assembly(&self) -> RecoveryAssembly {
        RecoveryAssembly::assemble(self.database.clone()).expect("the recovery side assembles")
    }

    pub fn recovery(&self) -> StoreRecovery {
        self.assembly().recovery()
    }

    pub fn successor(&self) -> StoreSuccessor {
        self.assembly().successor()
    }

    pub fn fenced_state(&self) -> FencedState {
        self.assembly().fenced_state()
    }

    pub fn port(&self) -> StoreStatePort {
        StoreStatePort::new(self.database.clone())
    }

    pub fn start(&self, run_id: &str) -> Result<RunSnapshot> {
        self.port().commit(
            run_id,
            0,
            ReducerEvent::Start {
                input: json!({"input": "synthetic"}),
            },
        )
    }

    /// The binding a run at this fixture's revision is on, as a checkpoint
    /// would record it.
    pub fn binding(&self) -> RecordedPlanKey {
        RecordedPlanKey {
            definition_revision: self.revision_digest.clone(),
            compiler_semantics: CompilerSemantics::CURRENT.wire(),
            engine_semantics: EngineSemantics::CURRENT.wire(),
            lowering_capabilities: Vec::new(),
        }
    }

    pub fn profile(&self) -> InterpreterProfile {
        InterpreterProfile::current(LoweringCapabilities::none())
    }

    pub fn snapshot(&self, run_id: &str) -> Result<RunSnapshot> {
        self.port().checkpoint(run_id)
    }

    pub fn snapshot_json(&self, run_id: &str) -> Result<String> {
        self.database.read(|connection| {
            Ok(connection.query_row(
                "SELECT snapshot_json FROM strategy_runs WHERE run_id=?1",
                rusqlite::params![run_id],
                |row| row.get::<_, String>(0),
            )?)
        })
    }

    /// Rewrite the checkpoint body, which is how an older one is staged.
    pub fn rewrite_snapshot(
        &self,
        run_id: &str,
        edit: impl FnOnce(&mut Value) -> bool,
    ) -> Result<()> {
        let raw = self.snapshot_json(run_id)?;
        let mut value: Value = serde_json::from_str(&raw)?;
        if !edit(&mut value) {
            return Err(anyhow!("fixture_edit_did_not_apply"));
        }
        let (_, _) = self.database.write(|transaction, _| {
            Ok(transaction.execute(
                "UPDATE strategy_runs SET snapshot_json=?2 WHERE run_id=?1",
                rusqlite::params![run_id, serde_json::to_string(&value)?],
            )?)
        })?;
        Ok(())
    }

    pub fn delete_definition(&self) -> Result<()> {
        let (_, _) = self.database.write(|transaction, _| {
            Ok(transaction.execute(
                "DELETE FROM strategy_definitions WHERE revision_digest=?1",
                rusqlite::params![self.revision_digest],
            )?)
        })?;
        Ok(())
    }

    /// Write a checkpoint body verbatim, which is how a corrupt one is staged.
    pub fn set_snapshot_json(&self, run_id: &str, raw: &str) -> Result<()> {
        let (_, _) = self.database.write(|transaction, _| {
            Ok(transaction.execute(
                "UPDATE strategy_runs SET snapshot_json=?2 WHERE run_id=?1",
                rusqlite::params![run_id, raw],
            )?)
        })?;
        Ok(())
    }

    /// Rewrite the semantics digest the run was admitted under.
    pub fn set_run_semantics(&self, run_id: &str, semantics: &str) -> Result<()> {
        let (_, _) = self.database.write(|transaction, _| {
            Ok(transaction.execute(
                "UPDATE strategy_runs SET semantics_digest=?2 WHERE run_id=?1",
                rusqlite::params![run_id, semantics],
            )?)
        })?;
        Ok(())
    }

    pub fn command_row(&self, command_id: &str) -> Result<CommandRow> {
        self.database.read(|connection| {
            let (status, attempt_token, lease_owner, lease_until, command_json): (
                String,
                String,
                Option<String>,
                Option<i64>,
                String,
            ) = connection.query_row(
                "SELECT status, attempt_token, lease_owner, lease_until, command_json
                 FROM strategy_commands WHERE command_id=?1",
                rusqlite::params![command_id],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                    ))
                },
            )?;
            let command: RunCommand = serde_json::from_str(&command_json)?;
            Ok(CommandRow {
                status,
                attempt_token,
                lease_owner,
                lease_until,
                node_id: command.state_id,
                node_visit: command.state_visit,
            })
        })
    }

    /// The file this fixture owns, for a test that must open its own
    /// connection (a damaged file is not something the store's own pragmas let
    /// a test write).
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn command_ids(&self, run_id: &str) -> Result<Vec<String>> {
        self.database.read(|connection| {
            let mut statement = connection.prepare(
                "SELECT command_id FROM strategy_commands WHERE run_id=?1 ORDER BY command_id",
            )?;
            let ids = statement
                .query_map(rusqlite::params![run_id], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(ids)
        })
    }

    pub fn count(&self, table: &str, predicate: &str) -> i64 {
        self.database
            .read(|connection| {
                Ok(connection.query_row(
                    &format!("SELECT COUNT(*) FROM {table} WHERE {predicate}"),
                    [],
                    |row| row.get::<_, i64>(0),
                )?)
            })
            .expect("count query runs")
    }

    pub fn receipts(&self, run_id: &str) -> Result<Vec<(String, String, String, Option<String>)>> {
        self.database.read(|connection| {
            let mut statement = connection.prepare(
                "SELECT command_id, attempt_token, outcome, result_digest
                 FROM workflow_effect_reconciliations WHERE run_id=?1 ORDER BY command_id",
            )?;
            let rows = statement
                .query_map(rusqlite::params![run_id], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(rows)
        })
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        remove_database(&self.path);
    }
}

/// One command row, as a test reads it.
#[derive(Clone, Debug)]
pub struct CommandRow {
    pub status: String,
    pub attempt_token: String,
    pub lease_owner: Option<String>,
    pub lease_until: Option<i64>,
    pub node_id: String,
    pub node_visit: u64,
}

/// Register a definition the way admission would.
pub fn seed_definition(
    database: &WorkflowDatabase,
    revision_digest: &str,
    workflow: &WorkflowDefinition,
) -> Result<()> {
    let (_, _) = database.write(|transaction, _| {
        Ok(transaction.execute(
            "INSERT INTO strategy_definitions(
               definition_id, revision_digest, semantics_digest, name, version,
               workflow_json, asset_count, imported_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)",
            rusqlite::params![
                workflow.metadata.id,
                revision_digest,
                SEMANTICS,
                workflow.metadata.name,
                workflow.metadata.version,
                serde_json::to_string(workflow)?,
                1_i64
            ],
        )?)
    })?;
    Ok(())
}

/// Seed a run row in the state a reduction can start from: pending, sequence 0.
pub fn seed_run(database: &WorkflowDatabase, run_id: &str, revision_digest: &str) -> Result<()> {
    let snapshot = RunSnapshot::empty(run_id.to_owned(), revision_digest.to_owned(), SEMANTICS);
    let snapshot_json = serde_json::to_string(&snapshot)?;
    let (_, _) = database.write(|transaction, _| {
        Ok(transaction.execute(
            "INSERT INTO strategy_runs(
               run_id, revision_digest, semantics_digest, idempotency_key, request_digest,
               snapshot_json, conversation_id, terminal, created_at, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, 0, ?7, ?7)",
            rusqlite::params![
                run_id,
                revision_digest,
                SEMANTICS,
                format!("idempotency-{run_id}"),
                format!("request-{run_id}"),
                snapshot_json,
                1_i64
            ],
        )?)
    })?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Driving a run through the store's own ports
// ---------------------------------------------------------------------------

/// Commit one event with the sequence the checkpoint is at.
pub fn commit(port: &StoreStatePort, run_id: &str, event: ReducerEvent) -> Result<RunSnapshot> {
    let sequence = port.checkpoint(run_id)?.sequence;
    port.commit(run_id, sequence, event)
}

/// Every pending command of one run, in the store's own order.
pub fn pending_commands(fixture: &Fixture, run_id: &str) -> Result<Vec<RunCommand>> {
    let snapshot = fixture.snapshot(run_id)?;
    Ok(snapshot
        .commands
        .values()
        .filter(|command| command.status == licoup_workflow::CommandStatus::Pending)
        .cloned()
        .collect())
}

/// The first command of one node that is not settled.
///
/// Preferring unsettled commands keeps a re-entered visit usable: a node that
/// ran twice has two commands, and the test always means the one a decision is
/// about.
pub fn command_at(snapshot: &RunSnapshot, node: &str) -> RunCommand {
    let unsettled = |command: &&RunCommand| {
        matches!(
            command.status,
            licoup_workflow::CommandStatus::Pending
                | licoup_workflow::CommandStatus::Claimed
                | licoup_workflow::CommandStatus::Running
                | licoup_workflow::CommandStatus::Retryable
                | licoup_workflow::CommandStatus::CancelRequested
        )
    };
    snapshot
        .commands
        .values()
        .filter(|command| command.state_id == node)
        .find(unsettled)
        .or_else(|| {
            snapshot
                .commands
                .values()
                .find(|command| command.state_id == node)
        })
        .cloned()
        .unwrap_or_else(|| panic!("the run has a command for {node}"))
}

/// Claim the node's pending command for one owner.
///
/// The store's claim path hands out the run's next claimable command, so a
/// multi-command run is claimed in its own order. This helper takes whatever
/// that order produces for as long as it must to reach the node asked for, and
/// the runs that need a specific node are staged by role instead.
pub fn claim(
    port: &StoreStatePort,
    run_id: &str,
    node: &str,
    claimant: &str,
    lease_until_unix_ms: i64,
) -> Result<RunCommand> {
    let target = command_at(&port.checkpoint(run_id)?, node);
    for _ in 0..64 {
        match port.claim_next(run_id, claimant, lease_until_unix_ms)? {
            Some(claimed) if claimed.id == target.id => return Ok(claimed),
            Some(_) => continue,
            None => break,
        }
    }
    Err(anyhow!("fixture_claim_not_available"))
}

/// Claim whichever command the run's claim path hands out next.
///
/// Tests that need a boundary rather than a named node use this: which branch
/// comes back is the store's decision, and the test classifies it afterwards.
pub fn claim_next(
    port: &StoreStatePort,
    run_id: &str,
    claimant: &str,
    lease_until_unix_ms: i64,
) -> Result<RunCommand> {
    port.claim_next(run_id, claimant, lease_until_unix_ms)?
        .ok_or_else(|| anyhow!("fixture_claim_not_available"))
}

/// The command of one node that is still pending.
pub fn pending_at(snapshot: &RunSnapshot, node: &str) -> Option<RunCommand> {
    snapshot
        .commands
        .values()
        .find(|command| {
            command.state_id == node && command.status == licoup_workflow::CommandStatus::Pending
        })
        .cloned()
}

/// Move a claim's lease into the past.
///
/// This is the durable state a host leaves when it stops renewing: the row, the
/// owner and the attempt identity are untouched, and only the claim's time ran
/// out. Recovery is then asked what that means, which is the question under
/// test — sleeping until a lease lapses would test the clock instead.
pub fn expire_lease(fixture: &Fixture, command_id: &str, until_unix_ms: i64) -> Result<()> {
    let (_, _) = fixture.database().write(|transaction, _| {
        Ok(transaction.execute(
            "UPDATE strategy_commands SET lease_until=?2 WHERE command_id=?1",
            rusqlite::params![command_id, until_unix_ms],
        )?)
    })?;
    Ok(())
}

/// Commit the possible-effect marker for one claimed command.
pub fn start_command(
    port: &StoreStatePort,
    run_id: &str,
    command: &RunCommand,
) -> Result<RunSnapshot> {
    port.mark_started(run_id, &command.id, &command.attempt_token)
}

/// Settle one started command as succeeded with a synthetic output.
pub fn settle_command(
    port: &StoreStatePort,
    run_id: &str,
    command: &RunCommand,
    output: Value,
) -> Result<RunSnapshot> {
    commit(
        port,
        run_id,
        ReducerEvent::CommandSucceeded {
            command_id: command.id.clone(),
            attempt_token: command.attempt_token.clone(),
            output,
        },
    )
}

/// A timestamp `offset` milliseconds away from now.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

pub fn future_ms() -> i64 {
    now_ms() + 60_000
}

pub fn past_ms() -> i64 {
    now_ms() - 60_000
}

// ---------------------------------------------------------------------------
// The effect owner's own account
// ---------------------------------------------------------------------------

/// Stage a run whose join has contributions from two different visits.
///
/// `branch-a` parks on its callback edge, is returned, and contributes at visit
/// 2; `branch-b` and `branch-c` contribute at visit 1; `branch-d` is left a
/// live attempt whose lease has run out, so recovery has something to decide
/// while the mixed ledger exists. The live command is returned.
pub fn stage_mixed_epoch(fixture: &Fixture) -> Result<RunCommand> {
    fixture.start("run-1")?;
    let port = fixture.port();
    // A drive claims every branch of a fork; which one comes back first is the
    // store's order, so branches are classified by the node they belong to.
    let mut commands = Vec::new();
    for _ in 0..4 {
        commands.push(claim_next(&port, "run-1", "host-a#1", future_ms())?);
    }
    for command in commands
        .iter()
        .filter(|command| command.state_id == "branch-b" || command.state_id == "branch-c")
    {
        settle_command(
            &port,
            "run-1",
            command,
            json!({"value": command.state_id.clone()}),
        )?;
    }
    let first_visit = commands
        .iter()
        .find(|command| command.state_id == "branch-a")
        .cloned()
        .ok_or_else(|| anyhow!("branch-a was claimed"))?;
    settle_command(&port, "run-1", &first_visit, json!({"value": "a1"}))?;
    commit(
        &port,
        "run-1",
        ReducerEvent::CallbackDecision {
            state_id: "branch-a".into(),
            state_visit: 1,
            decision: CallbackDecisionKind::Return,
        },
    )?;
    let second_visit = claim_next(&port, "run-1", "host-a#1", future_ms())?;
    assert_eq!(second_visit.state_id, "branch-a");
    settle_command(&port, "run-1", &second_visit, json!({"value": "a2"}))?;
    commit(
        &port,
        "run-1",
        ReducerEvent::CallbackDecision {
            state_id: "branch-a".into(),
            state_visit: 2,
            decision: CallbackDecisionKind::Advance,
        },
    )?;

    let live = commands
        .iter()
        .find(|command| command.state_id == "branch-d")
        .cloned()
        .ok_or_else(|| anyhow!("branch-d was claimed"))?;
    start_command(&port, "run-1", &live)?;
    expire_lease(fixture, &live.id, past_ms())?;
    Ok(live)
}

/// The handoff manifest a caller builds from a run's durable facts.
///
/// Reading the sets from the same rows the compare-and-set will read is what a
/// real caller does; the negative tests then change exactly one fact to show
/// which comparison refuses it.
pub fn manifest_from(
    fixture: &Fixture,
    run_id: &str,
    handoff_id: &str,
    old_owner: &str,
    new_owner: &str,
) -> Result<SuccessorManifest> {
    let snapshot = fixture.snapshot(run_id)?;
    let mut unstarted = Vec::new();
    let mut started = Vec::new();
    for command in snapshot.commands.values() {
        match command.status {
            licoup_workflow::CommandStatus::Pending | licoup_workflow::CommandStatus::Retryable => {
                unstarted.push(UnstartedIntent {
                    command_id: command.id.clone(),
                    attempt_token: command.attempt_token.clone(),
                    node_id: command.state_id.clone(),
                    node_visit: command.state_visit,
                });
            }
            licoup_workflow::CommandStatus::Claimed
            | licoup_workflow::CommandStatus::Running
            | licoup_workflow::CommandStatus::CancelRequested => {
                let phase = if command.status == licoup_workflow::CommandStatus::Claimed {
                    EffectBoundary::Claimed
                } else {
                    EffectBoundary::Started
                };
                started.push(LiveAttempt {
                    command_id: command.id.clone(),
                    attempt_token: command.attempt_token.clone(),
                    node_id: command.state_id.clone(),
                    node_visit: command.state_visit,
                    phase,
                });
            }
            _ => {}
        }
    }
    Ok(SuccessorManifest {
        handoff_id: handoff_id.to_owned(),
        run_id: run_id.to_owned(),
        expected_revision: snapshot.sequence,
        old_owner: old_owner.to_owned(),
        new_owner: new_owner.to_owned(),
        old_binding: fixture.binding(),
        new_owner_profile: fixture.profile(),
        unstarted,
        started,
    })
}

/// A non-idempotent effect, counted outside the database.
///
/// One dispatch appends one line, so "at most once" is a number rather than an
/// interpretation. Recovery never writes here: if a line appears without the
/// test having dispatched, something re-dispatched.
pub struct DispatchCounter {
    path: PathBuf,
}

impl DispatchCounter {
    pub fn new(label: &str) -> Self {
        let path = scratch_path(&format!("dispatch-{label}")).with_extension("log");
        Self { path }
    }

    pub fn record(&self, what: &str) {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .expect("the counter file opens");
        writeln!(file, "{what}").expect("the dispatch is recorded");
    }

    pub fn count(&self) -> usize {
        std::fs::read_to_string(&self.path)
            .map(|text| text.lines().filter(|line| !line.is_empty()).count())
            .unwrap_or(0)
    }
}

impl Drop for DispatchCounter {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
