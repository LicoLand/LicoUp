//! V7-D1 migration harness — the published-strategy-store codec and its
//! conversion graph against **real database files**.
//!
//! What is real here: the entry (`client_state_migration::admit`), the SQLite
//! files, the SQLite engine, the file lock, and the published DDL. Every
//! fixture below is a file written the way the published writer wrote it, and
//! every assertion is read back out of the file afterwards.
//!
//! What each test proves, and what it takes as given:
//!
//! - `a_published_store_gains_the_delivery_tables_and_keeps_every_row` proves
//!   the conversion creates the current format's tables on a real file, that no
//!   pre-existing row changes, that the migration invents no delivery
//!   obligation the published format never named, and that a second admission
//!   writes nothing. It takes as given that the fixture is the published shape
//!   — it is built here from the published column lists, so it is a copy of the
//!   contract rather than the contract itself.
//! - `a_schema_one_store_reaches_the_current_format_with_its_rows_intact`
//!   proves the whole conversion graph runs on one real file, from the oldest
//!   published shape to the current one, preserving the rows that survive and
//!   the ones the published writer itself could not parse.
//! - `another_owner_holding_the_lock_stops_a_second_admission_from_running`
//!   proves mutual exclusion by observation: while this process holds the
//!   admission lock, an admission on another thread has not finished and has
//!   written nothing, and it completes once the lock is released. What it does
//!   not prove is anything about a *future* release holding the same lock; the
//!   plan's point that "a new lock only constrains programs that know it" is not
//!   a property a test can assert.
//! - `a_pending_conversion_record_is_resumed` proves the recovery record is the
//!   thing the next run resumes from, on a real file whose tables were never
//!   created.
//!
//! Deliberately not covered here: the store's own typed migrations (they are the
//! store crate's tests), the cross-format upgrade of a *second* strategy
//! database, and any device or release-channel behaviour.

use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use fs2::FileExt;
use licoup_native::domain::client_state_migration::{AdmissionResult, admit};
use rusqlite::{Connection, OptionalExtension};
use serde_json::Value;

const STRATEGY_DATABASE: &str = "client-state/adaptive-flywheel/strategies.sqlite3";
const ADMISSION_LOCK: &str = "client-state/migrations/admission.lock";
const LEDGER: &str = "client-state/migrations/ledger.json";
const CONVERSION_RECORD: &str =
    "client-state/migrations/artifacts/adaptive-flywheel-strategy-store.json";
const NOTICE_OUTBOX_STEP: &str = "adaptive-flywheel.strategy-store-notice-outbox";

fn temporary_root(label: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "licoup-v7-migration-{label}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).expect("temporary root");
    root
}

fn open(path: &Path) -> Connection {
    Connection::open(path).expect("sqlite database")
}

fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).expect("file mode");
}

/// The shape the published writer left at `strategy_meta.version = '3'`: state
/// rows, a delivery intent that still carries a copy of the committed body, and
/// a table the migration knows nothing about.
fn write_published_strategy_store(path: &Path, version: &str) {
    std::fs::create_dir_all(path.parent().expect("database parent")).expect("store directory");
    let connection = open(path);
    connection
        .execute_batch(&format!(
            "PRAGMA journal_mode=WAL;
             CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO strategy_meta(key,value) VALUES ('version','{version}');
             CREATE TABLE strategy_definitions(
               definition_id TEXT NOT NULL, revision_digest TEXT PRIMARY KEY,
               semantics_digest TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL,
               workflow_json TEXT NOT NULL, asset_count INTEGER NOT NULL,
               imported_at INTEGER NOT NULL
             );
             INSERT INTO strategy_definitions VALUES
               ('definition-1','revision-1','semantics-1','Imported','1',
                '{{not-a-workflow-document}}', 3, 11);
             CREATE TABLE strategy_runs(
               run_id TEXT PRIMARY KEY, revision_digest TEXT NOT NULL,
               semantics_digest TEXT NOT NULL, idempotency_key TEXT NOT NULL UNIQUE,
               request_digest TEXT NOT NULL, snapshot_json TEXT NOT NULL,
               conversation_id TEXT, terminal INTEGER,
               created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
             );
             INSERT INTO strategy_runs VALUES
               ('run-1','revision-1','semantics-1','idempotency-1','request-1',
                '{{\"status\":\"running\"}}','conversation-1',0,21,22);
             CREATE TABLE strategy_run_events(
               run_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_type TEXT NOT NULL,
               event_json TEXT NOT NULL, created_at INTEGER NOT NULL,
               PRIMARY KEY(run_id, sequence)
             );
             INSERT INTO strategy_run_events VALUES
               ('run-1', 1, 'command-claimed', '{{\"kind\":\"command-claimed\"}}', 23);
             CREATE TABLE workflow_transition_intents(
               run_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_json TEXT NOT NULL,
               before_json TEXT NOT NULL, after_json TEXT NOT NULL, status TEXT NOT NULL,
               created_at INTEGER NOT NULL, dispatched_at INTEGER,
               PRIMARY KEY(run_id, sequence)
             );
             INSERT INTO workflow_transition_intents VALUES
               ('run-1', 1, '{{\"kind\":\"command-claimed\"}}', '{{\"sequence\":0}}',
                '{{\"sequence\":1}}', 'pending', 24, NULL);
             CREATE TABLE undeclared_canary(value TEXT NOT NULL);
             INSERT INTO undeclared_canary(value) VALUES ('must-survive');"
        ))
        .expect("published strategy store");
}

fn table_names(path: &Path) -> Vec<String> {
    let connection = open(path);
    let mut statement = connection
        .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        .expect("schema query");
    statement
        .query_map([], |row| row.get::<_, String>(0))
        .expect("schema rows")
        .collect::<rusqlite::Result<Vec<_>>>()
        .expect("schema names")
}

fn columns(path: &Path, table: &str) -> Vec<String> {
    let connection = open(path);
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .expect("column query");
    statement
        .query_map([], |row| row.get::<_, String>(1))
        .expect("column rows")
        .collect::<rusqlite::Result<Vec<_>>>()
        .expect("column names")
}

fn index_names(path: &Path) -> Vec<String> {
    let connection = open(path);
    let mut statement = connection
        .prepare("SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        .expect("index query");
    statement
        .query_map([], |row| row.get::<_, String>(0))
        .expect("index rows")
        .collect::<rusqlite::Result<Vec<_>>>()
        .expect("index names")
}

/// Every stored value the fixture wrote, so "nothing changed" is a comparison
/// of contents rather than of file metadata.
fn stored_values(path: &Path) -> Vec<String> {
    let connection = open(path);
    let mut values = Vec::new();
    for table in table_names(path) {
        if table.starts_with("sqlite_") {
            continue;
        }
        let mut statement = connection
            .prepare(&format!("SELECT * FROM {table}"))
            .expect("row query");
        let column_count = statement.column_count();
        let rows = statement
            .query_map([], |row| {
                let mut cells = Vec::new();
                for index in 0..column_count {
                    let cell: rusqlite::types::Value = row.get(index)?;
                    cells.push(format!("{cell:?}"));
                }
                Ok(format!("{table}:{}", cells.join("|")))
            })
            .expect("row values")
            .collect::<rusqlite::Result<Vec<_>>>()
            .expect("rows");
        values.extend(rows);
    }
    values.sort();
    values
}

fn strategy_meta_version(path: &Path) -> Option<String> {
    open(path)
        .query_row(
            "SELECT value FROM strategy_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .optional()
        .expect("strategy_meta version")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(path).expect("json artifact")).expect("json document")
}

#[test]
fn a_published_store_gains_the_delivery_tables_and_keeps_every_row() {
    let root = temporary_root("delivery-tables");
    let database = root.join(STRATEGY_DATABASE);
    write_published_strategy_store(&database, "3");
    let before = stored_values(&database);
    let tables_before = table_names(&database);
    assert!(!tables_before.contains(&"workflow_notice_intents".to_owned()));
    assert!(
        !index_names(&database).contains(&"workflow_notice_intents_pending_idx".to_owned()),
        "the fixture must be the published shape, without the current format's index"
    );

    let admission: AdmissionResult = admit(&root).expect("admission");
    assert_eq!(admission.status, "ready");
    assert!(
        admission
            .applied_domain_ids
            .iter()
            .any(|domain| domain == "adaptive-flywheel"),
        "the store advanced, so the domain must not read as untouched: {admission:?}"
    );

    // The current format's tables, with the columns it publishes and the index
    // its pending query is covered by.
    assert_eq!(
        columns(&database, "workflow_notice_intents"),
        vec![
            "notice_id",
            "run_id",
            "sequence",
            "recipient",
            "kind",
            "status",
            "created_at",
            "accepted_at",
        ]
    );
    assert_eq!(
        columns(&database, "workflow_notice_acceptances"),
        vec![
            "notice_id",
            "run_id",
            "sequence",
            "recipient",
            "kind",
            "accept_count",
            "first_accepted_at",
            "last_accepted_at",
        ]
    );
    assert!(index_names(&database).contains(&"workflow_notice_intents_pending_idx".to_owned()));

    // Every row the published writer left is still there, byte for byte,
    // including the table this migration has never heard of and the legacy
    // delivery intent that still carries its body copy.
    assert_eq!(stored_values(&database), before);
    assert!(
        tables_before
            .iter()
            .all(|table| table_names(&database).contains(table))
    );

    // No delivery obligation is invented. The published format never recorded a
    // recipient or a kind for its post-commit intents, and a migration that
    // guessed one would create delivery work for a fact nobody addressed.
    let connection = open(&database);
    let notices: i64 = connection
        .query_row("SELECT COUNT(*) FROM workflow_notice_intents", [], |row| {
            row.get(0)
        })
        .expect("notice count");
    let acceptances: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM workflow_notice_acceptances",
            [],
            |row| row.get(0),
        )
        .expect("acceptance count");
    assert_eq!((notices, acceptances), (0, 0));
    // The status vocabulary came across as a constraint, not as documentation:
    // a row the current format would refuse is refused here too.
    connection
        .execute(
            "INSERT INTO workflow_notice_intents(
               notice_id, run_id, sequence, recipient, kind, status, created_at, accepted_at
             ) VALUES ('notice-1','run-1',1,'owner-1','kind-1','accepted',1,NULL)",
            [],
        )
        .expect("a storable intent");
    assert!(
        connection
            .execute(
                "INSERT INTO workflow_notice_intents(
                   notice_id, run_id, sequence, recipient, kind, status, created_at, accepted_at
                 ) VALUES ('notice-2','run-1',2,'owner-1','kind-1','delivered',2,NULL)",
                [],
            )
            .is_err(),
        "the published CHECK constraint must travel with the table"
    );
    drop(connection);

    // The recovery record states what was converted, from which published
    // shape, by which step.
    let record = read_json(&root.join(CONVERSION_RECORD));
    assert_eq!(record["domainId"], "adaptive-flywheel");
    assert_eq!(record["fromFormat"], "strategy-store-3");
    assert_eq!(record["targetFormat"], "strategy-store-4");
    assert_eq!(record["status"], "applied");
    assert_eq!(
        record["appliedStepIds"],
        serde_json::json!([NOTICE_OUTBOX_STEP])
    );

    // A second admission is a no-op: the shape is current, so the ordinary
    // start path writes nothing at all.
    let settled = stored_values(&database);
    let second = admit(&root).expect("second admission");
    assert!(second.applied_domain_ids.is_empty(), "{second:?}");
    assert_eq!(stored_values(&database), settled);
    assert_eq!(
        read_json(&root.join(CONVERSION_RECORD))["status"],
        "applied"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_schema_one_store_reaches_the_current_format_with_its_rows_intact() {
    let root = temporary_root("schema-one");
    let database = root.join(STRATEGY_DATABASE);
    std::fs::create_dir_all(database.parent().expect("database parent")).expect("store directory");
    let connection = open(&database);
    connection
        .execute_batch(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             INSERT INTO strategy_meta(key,value) VALUES ('version','1');
             CREATE TABLE strategy_definitions(
               definition_id TEXT NOT NULL, revision_digest TEXT PRIMARY KEY,
               semantics_digest TEXT NOT NULL, name TEXT NOT NULL, version TEXT NOT NULL,
               workflow_json TEXT NOT NULL, asset_count INTEGER NOT NULL,
               imported_at INTEGER NOT NULL
             );
             INSERT INTO strategy_definitions VALUES
               ('definition-1','revision-1','semantics-1','Imported','1',
                '{\"legacy\":true}', 0, 11);
             CREATE TABLE strategy_bindings(
               revision_digest TEXT NOT NULL, slot_id TEXT NOT NULL, value_id TEXT NOT NULL,
               revision INTEGER NOT NULL, PRIMARY KEY(revision_digest, slot_id)
             );
             INSERT INTO strategy_bindings VALUES ('revision-1','worker','agent:one',3);
             CREATE TABLE undeclared_canary(value TEXT NOT NULL);
             INSERT INTO undeclared_canary(value) VALUES ('must-survive');",
        )
        .expect("schema one store");
    drop(connection);

    admit(&root).expect("admission");

    // The domain version moves through both frontier edges; the file itself
    // reaches the current published shape.
    assert_eq!(strategy_meta_version(&database).as_deref(), Some("3"));
    assert_eq!(
        columns(&database, "strategy_bindings"),
        vec![
            "revision_digest",
            "slot_id",
            "ordinal",
            "value_id",
            "model",
            "reasoning_effort",
            "revision",
        ]
    );
    let connection = open(&database);
    let binding: (i64, String, String, String, i64) = connection
        .query_row(
            "SELECT ordinal, value_id, model, reasoning_effort, revision FROM strategy_bindings",
            [],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .expect("migrated binding");
    assert_eq!(
        binding,
        (0, "agent:one".to_owned(), String::new(), String::new(), 3),
        "the published ordinal-bindings move keeps the value and its revision"
    );
    let workflow: String = connection
        .query_row(
            "SELECT workflow_json FROM strategy_definitions WHERE revision_digest='revision-1'",
            [],
            |row| row.get(0),
        )
        .expect("definition row");
    assert_eq!(
        workflow, "{\"legacy\":true}",
        "a legacy document the published writer could not parse is preserved, not dropped"
    );
    let canary: String = connection
        .query_row("SELECT value FROM undeclared_canary", [], |row| row.get(0))
        .expect("canary");
    assert_eq!(canary, "must-survive");
    drop(connection);

    assert!(columns(&database, "workflow_notice_intents").contains(&"status".to_owned()));
    let record = read_json(&root.join(CONVERSION_RECORD));
    assert_eq!(record["fromFormat"], "strategy-store-1");
    assert_eq!(record["targetFormat"], "strategy-store-4");
    assert_eq!(record["status"], "applied");
    assert_eq!(
        record["appliedStepIds"],
        serde_json::json!([
            "adaptive-flywheel.strategy-store-ordinal-bindings",
            "adaptive-flywheel.strategy-store-workflow-routing",
            NOTICE_OUTBOX_STEP,
        ])
    );

    let ledger = read_json(&root.join(LEDGER));
    assert_eq!(ledger["domains"]["adaptive-flywheel"]["schemaVersion"], 2);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_pending_conversion_record_is_resumed() {
    let root = temporary_root("resume");
    let database = root.join(STRATEGY_DATABASE);
    write_published_strategy_store(&database, "3");
    // The state an interrupted conversion between its record and its commit
    // leaves behind: the record, and a store still in the published shape.
    let record_path = root.join(CONVERSION_RECORD);
    let record_dir = record_path.parent().expect("record parent");
    std::fs::create_dir_all(record_dir).expect("record directory");
    // Migration metadata is private state, and the admission reads it through
    // the 0700/0600-enforcing path: a fixture standing in for a real interrupted
    // run has to carry those modes, or it is refused for being world-readable
    // rather than for what it says.
    set_mode(record_dir, 0o700);
    std::fs::write(
        &record_path,
        serde_json::to_vec(&serde_json::json!({
            "schemaVersion": "v0.0.1:strategy-store-conversion-artifact-1",
            "domainId": "adaptive-flywheel",
            "fromFormat": "strategy-store-3",
            "targetFormat": "strategy-store-4",
            "appliedStepIds": [],
            "status": "pending",
        }))
        .expect("record json"),
    )
    .expect("record");
    set_mode(&record_path, 0o600);

    admit(&root).expect("resumed admission");

    assert!(columns(&database, "workflow_notice_intents").contains(&"status".to_owned()));
    let record = read_json(&record_path);
    assert_eq!(record["status"], "applied");
    assert_eq!(
        record["appliedStepIds"],
        serde_json::json!([NOTICE_OUTBOX_STEP])
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn another_owner_holding_the_lock_stops_a_second_admission_from_running() {
    let root = temporary_root("lock");
    let database = root.join(STRATEGY_DATABASE);
    write_published_strategy_store(&database, "3");

    let lock_path = root.join(ADMISSION_LOCK);
    std::fs::create_dir_all(lock_path.parent().expect("lock parent")).expect("migration directory");
    let held = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .expect("lock file");
    held.lock_exclusive().expect("maintenance lock");

    // The lock excludes a second owner on this path: that is the primitive the
    // admission takes, so a second admission cannot be running while this one
    // is held.
    let second_owner = OpenOptions::new()
        .read(true)
        .write(true)
        .open(&lock_path)
        .expect("second lock file");
    assert!(
        second_owner.try_lock_exclusive().is_err(),
        "two owners must not hold the maintenance lock at once"
    );
    drop(second_owner);

    // Observed, not assumed: the admission on another thread is still inside
    // the lock, and has written nothing yet.
    let admission_root = root.clone();
    let admission = thread::spawn(move || admit(&admission_root));
    let deadline = Instant::now() + Duration::from_millis(150);
    while Instant::now() < deadline {
        thread::yield_now();
    }
    assert!(
        !admission.is_finished(),
        "a second admission must not proceed while the lock is held"
    );
    assert!(
        !root.join(LEDGER).exists(),
        "a blocked admission must not have written any state"
    );
    assert!(
        !columns(&database, "workflow_notice_intents").contains(&"status".to_owned()),
        "a blocked admission must not have converted the store"
    );

    held.unlock().expect("release maintenance lock");
    let result = admission.join().expect("admission thread");
    let admission: AdmissionResult = result.expect("admission after release");
    assert_eq!(admission.status, "ready");
    assert!(columns(&database, "workflow_notice_intents").contains(&"status".to_owned()));
    assert!(root.join(LEDGER).exists());
    let _ = std::fs::remove_dir_all(root);
}

/// The lock in this harness is the one the admission takes, and the file it is
/// taken on is the one a running client would find: if either moved, the
/// exclusion proof above would be about a file nobody uses.
#[test]
fn the_lock_this_harness_holds_is_the_one_the_admission_uses() {
    let root = temporary_root("lock-path");
    let database = root.join(STRATEGY_DATABASE);
    write_published_strategy_store(&database, "3");
    admit(&root).expect("admission");
    assert!(root.join(ADMISSION_LOCK).exists());
    let _ = std::fs::remove_dir_all(root);
}
