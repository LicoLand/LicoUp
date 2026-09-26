//! Fixtures shared by the transaction tests.
//!
//! These tests run against a real database file rather than an in-memory one:
//! the format, the journal mode, the schema validation, and the old-writer
//! compatibility all live in the file, and an in-memory database would quietly
//! let several of those go untested.

#![allow(dead_code)]

use anyhow::Result;
use licoup_workflow::{
    ActorSlot, GraphState, GraphStateKind, RetryPolicy, RunSnapshot, Transition, TransitionEvent,
    TransitionMode, WorkflowDefinition, WorkflowLimits, WorkflowMetadata,
};
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::{StoreStatePort, WorkflowDatabase};

/// Revision digest of the definition every fixture seeds.
pub const REVISION: &str = "revision-fixture-v1";
/// Semantics digest bound to [`REVISION`].
pub const SEMANTICS: &str = "semantics-fixture-v1";

static COUNTER: AtomicU64 = AtomicU64::new(0);

/// A path in the system temp directory, unique per process and per call.
///
/// Built from parts on purpose: a literal absolute path in a test is a leak the
/// repository scanners treat as real user data.
pub fn scratch_path(label: &str) -> PathBuf {
    let unique = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!(
        "licoup-workflow-store-{label}-{}-{unique}-{nanos}.sqlite3",
        std::process::id()
    ))
}

/// Remove a database file and the journal files SQLite keeps beside it.
pub fn remove_database(path: &Path) {
    for suffix in ["", "-wal", "-shm"] {
        let mut name = path.as_os_str().to_owned();
        name.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(name));
    }
}

/// A database file that removes itself when the test ends.
pub struct ScratchDatabase {
    path: PathBuf,
    database: Arc<WorkflowDatabase>,
}

impl ScratchDatabase {
    /// Open a scratch database and seed one definition and one pending run.
    pub fn new(label: &str) -> Result<Self> {
        let path = scratch_path(label);
        let database = WorkflowDatabase::open(&path)?;
        seed_definition(&database, REVISION, SEMANTICS, &actor_workflow(2))?;
        seed_run(&database, "run-1".into(), REVISION, SEMANTICS)?;
        Ok(Self {
            path,
            database: Arc::new(database),
        })
    }

    /// Open a scratch database with no rows at all.
    pub fn empty(label: &str) -> Result<Self> {
        let path = scratch_path(label);
        let database = WorkflowDatabase::open(&path)?;
        Ok(Self {
            path,
            database: Arc::new(database),
        })
    }

    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }

    pub fn port(&self) -> StoreStatePort {
        StoreStatePort::new(self.database.clone())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for ScratchDatabase {
    fn drop(&mut self) {
        remove_database(&self.path);
    }
}

/// One actor state that succeeds into a terminal state, plus a failure state.
///
/// The smallest definition that produces real work: starting a run emits one
/// actor command, and settling that command ends the run.
pub fn actor_workflow(max_parallelism: u8) -> WorkflowDefinition {
    WorkflowDefinition {
        schema: licoup_workflow::WORKFLOW_SCHEMA_VERSION.into(),
        metadata: WorkflowMetadata {
            id: "store-transaction-fixture".into(),
            name: "Store transaction fixture".into(),
            version: "1".into(),
            description: String::new(),
        },
        limits: WorkflowLimits {
            max_parallelism,
            ..WorkflowLimits::default()
        },
        actor_slots: vec![ActorSlot::required_actor("worker", "Worker")],
        runtimes: vec![],
        worksets: vec![],
        initial: "work".into(),
        states: vec![
            GraphState {
                id: "work".into(),
                kind: GraphStateKind::Actor,
                label: "Work".into(),
                instruction: String::new(),
                binding: Some("worker".into()),
                runtime: None,
                entry: None,
                workset: None,
                retry: RetryPolicy::default(),
            },
            GraphState {
                id: "done".into(),
                kind: GraphStateKind::Succeed,
                label: "Done".into(),
                instruction: String::new(),
                binding: None,
                runtime: None,
                entry: None,
                workset: None,
                retry: RetryPolicy::default(),
            },
            GraphState {
                id: "fail".into(),
                kind: GraphStateKind::Fail,
                label: "Fail".into(),
                instruction: String::new(),
                binding: None,
                runtime: None,
                entry: None,
                workset: None,
                retry: RetryPolicy::default(),
            },
        ],
        transitions: vec![
            Transition {
                id: "done".into(),
                from: "work".into(),
                to: "done".into(),
                event: TransitionEvent::Success,
                mode: TransitionMode::Flow,
                guard: None,
            },
            Transition {
                id: "failed".into(),
                from: "work".into(),
                to: "fail".into(),
                event: TransitionEvent::Failure,
                mode: TransitionMode::Flow,
                guard: None,
            },
        ],
    }
}

/// Register a definition the way `AdmissionPort::commit` would.
pub fn seed_definition(
    database: &WorkflowDatabase,
    revision_digest: &str,
    semantics_digest: &str,
    workflow: &WorkflowDefinition,
) -> Result<()> {
    let (_, _) = database.write(|transaction, _| {
        Ok(transaction.execute(
            "INSERT INTO strategy_definitions(
               definition_id, revision_digest, semantics_digest, name, version,
               workflow_json, asset_count, imported_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, ?7)",
            rusqlite::params![
                "store-transaction-fixture",
                revision_digest,
                semantics_digest,
                "Store transaction fixture",
                "1",
                serde_json::to_string(workflow)?,
                1_i64
            ],
        )?)
    })?;
    Ok(())
}

/// Seed a run row in the state a reduction can start from: pending, sequence 0.
///
/// The store's own admission path creates this row; it is written here directly
/// because admission is not what these tests are measuring, and a test that had
/// to drive admission first would be testing two things at once.
pub fn seed_run(
    database: &WorkflowDatabase,
    run_id: String,
    revision_digest: &str,
    semantics_digest: &str,
) -> Result<()> {
    let snapshot = RunSnapshot::empty(
        run_id.clone(),
        revision_digest.to_owned(),
        semantics_digest.to_owned(),
    );
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
                semantics_digest,
                format!("idempotency-{run_id}"),
                format!("request-{run_id}"),
                snapshot_json,
                1_i64
            ],
        )?)
    })?;
    Ok(())
}

/// The start event every fixture run begins with.
pub fn start_event() -> licoup_workflow::ReducerEvent {
    licoup_workflow::ReducerEvent::Start {
        input: json!({"input": "synthetic"}),
    }
}

/// Seed and start one run, which is the state an admitted graph is in: one
/// history row, one pending actor command, sequence 1.
pub fn graph(database: &Arc<WorkflowDatabase>, label: &str) -> Result<StoreStatePort> {
    seed_run(database, label.to_owned(), REVISION, SEMANTICS)?;
    let port = StoreStatePort::new(database.clone());
    port.commit(label, 0, start_event())?;
    Ok(port)
}

/// Start the fixture run so it holds one pending actor command.
pub fn started_run(port: &StoreStatePort) -> RunSnapshot {
    port.commit("run-1", 0, start_event())
        .expect("the fixture run starts")
}

/// Count rows in a table, for assertions about what a write did and did not do.
pub fn count(database: &WorkflowDatabase, table: &str, predicate: &str) -> i64 {
    database
        .read(|connection| {
            Ok(connection.query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE {predicate}"),
                [],
                |row| row.get::<_, i64>(0),
            )?)
        })
        .expect("count query runs")
}

/// The committed body of one event, read back from the history table.
pub fn event_body(database: &WorkflowDatabase, run_id: &str, sequence: u64) -> Option<String> {
    database
        .read(|connection| {
            use rusqlite::OptionalExtension;
            Ok(connection
                .query_row(
                    "SELECT event_json FROM strategy_run_events WHERE run_id=?1 AND sequence=?2",
                    rusqlite::params![run_id, sequence as i64],
                    |row| row.get::<_, String>(0),
                )
                .optional()?)
        })
        .expect("history read runs")
}

/// The query plan SQLite chooses for one statement, for bounds that must not
/// depend on how much history exists.
pub fn query_plan(database: &WorkflowDatabase, sql: &str) -> Vec<String> {
    database
        .read(|connection| {
            let mut statement = connection.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
            let plan = statement
                .query_map([], |row| row.get::<_, String>(3))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(plan)
        })
        .expect("the query planner answers")
}

/// A timestamp comfortably in the future, for leases that must hold.
pub fn future_ms() -> i64 {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0);
    now + 60_000
}
