//! An active checkpoint plus incremental facts: what a commit costs when the
//! history behind it is long.
//!
//! A07 asks for a fixed active set with 10^3/10^4/10^5 retained events, and for
//! the write amplification to follow the change rather than the history. This
//! is the component-level half of that: the cost of one commit is measured
//! exactly — rows changed and payload bytes — at a shallow history and again
//! after a thousand commits have accumulated in the same tables, and the two
//! are compared. Nothing here is a percentile or a wall-clock budget; the
//! production levels (10^4, 10^5, and write-transaction percentiles) belong to
//! the acceptance that runs on a real device.
//!
//! What is deliberately *not* claimed: that the checkpoint itself stays small
//! as the active set grows. Settled commands stay in the snapshot in this
//! format, and the format is the production store's — the adapter reads the
//! rows that writer reads, so it is not free to change what they mean.

use anyhow::Result;
use licoup_workflow::ReducerEvent;
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::{WorkflowDatabase, WriteStats};
use std::sync::Arc;

use crate::support;

/// Commit one transition on a fresh run and report what it cost, exactly.
///
/// The event is the same every time and the runs differ only in their names, so
/// two calls differing in cost would be differing by history, not by content.
fn measured_commit(database: &Arc<WorkflowDatabase>, label: &str) -> Result<WriteStats> {
    let port = support::graph(database, label)?;
    let sequence = port.checkpoint(label)?.sequence;
    let committed =
        port.commit_with_notices(label, sequence, ReducerEvent::CancelRequested, &[])?;

    // The accounting is checked against the change itself, recomputed here:
    // one history row, one run row, and one row per command in the checkpoint.
    let event_bytes = serde_json::to_string(&ReducerEvent::CancelRequested)?.len();
    let checkpoint_bytes = serde_json::to_string(&committed.snapshot)?.len();
    let command_bytes: usize = committed
        .snapshot
        .commands
        .values()
        .map(|command| serde_json::to_string(command).map(|json| json.len()))
        .collect::<serde_json::Result<Vec<usize>>>()?
        .into_iter()
        .sum();
    assert_eq!(
        committed.write.rows_changed,
        2 + committed.snapshot.commands.len(),
        "a commit writes its event, its checkpoint, and its commands"
    );
    assert_eq!(
        committed.write.bytes_written,
        event_bytes + checkpoint_bytes + command_bytes,
        "the bytes written are this change's payloads, with no part of the \
         history in them"
    );
    Ok(committed.write)
}

/// The tables the history lives in, counted for the assertions below.
fn history_rows(database: &WorkflowDatabase) -> i64 {
    support::count(database, "strategy_run_events", "1=1")
}

#[test]
fn a_commit_costs_the_same_after_a_thousand_events_as_before_them() {
    let path = support::scratch_path("history");
    let database = Arc::new(WorkflowDatabase::open(&path).expect("open"));
    support::seed_definition(
        &database,
        support::REVISION,
        support::SEMANTICS,
        &support::actor_workflow(2),
    )
    .expect("definition seeds");

    let shallow = measured_commit(&database, "run-history-base").expect("the first commit");
    assert_eq!(history_rows(&database), 2);

    // A thousand commits, each its own run so the active set stays fixed and
    // only the history grows. Their bodies are kept: this is the workload A07
    // describes, not a workload that shrinks it.
    const HISTORY: usize = 1_000;
    for index in 0..HISTORY {
        measured_commit(&database, &format!("run-history-{index}")).expect("commit lands");
    }
    assert_eq!(history_rows(&database), 2 * (HISTORY as i64 + 1));

    let deep = measured_commit(&database, "run-history-deep").expect("the later commit");
    assert_eq!(
        deep, shallow,
        "the cost of a commit must follow the change, not the {HISTORY} rows \
         behind it"
    );

    // The bodies are all still there, whole. A store that reached a constant
    // cost by dropping or truncating history would show up here instead.
    let first = support::event_body(&database, "run-history-base", 1).expect("the first body");
    let last = support::event_body(&database, "run-history-deep", 1).expect("the last body");
    assert_eq!(first, last, "every history row holds its own event, whole");
    assert_eq!(
        support::count(
            &database,
            "strategy_run_events",
            "event_json IS NULL OR length(event_json)=0"
        ),
        0,
        "no history row is empty"
    );

    drop(database);
    support::remove_database(&path);
}

#[test]
fn the_active_checkpoint_read_does_not_touch_the_history() {
    let scratch = support::ScratchDatabase::new("checkpoint-plan").expect("fixture");
    let plan = support::query_plan(
        scratch.database(),
        "SELECT snapshot_json FROM strategy_runs WHERE run_id='run-1'",
    )
    .join(" | ");
    assert!(
        !plan.contains("SCAN") || plan.contains("USING"),
        "the checkpoint read must be a keyed lookup: {plan}"
    );
    assert!(
        !plan.contains("strategy_run_events"),
        "reading the active checkpoint must not read history at all: {plan}"
    );

    let commands = support::query_plan(
        scratch.database(),
        "SELECT command_json FROM strategy_commands
         WHERE run_id='run-1' AND status='pending' AND kind!='authorization'
         ORDER BY command_id ASC LIMIT 1",
    )
    .join(" | ");
    assert!(
        commands.contains("strategy_commands") && !commands.contains("TEMP B-TREE"),
        "picking up work must be a keyed, ordered lookup: {commands}"
    );
}

#[test]
fn a_long_history_does_not_slow_the_commit_path_down_into_an_unbounded_scan() {
    // The other half of the same property, stated as plans rather than as
    // sizes: every statement a commit runs is keyed, so none of them can
    // degrade into reading the table that grows.
    let scratch = support::ScratchDatabase::new("commit-plan").expect("fixture");
    let database = scratch.database();
    for statement in [
        "SELECT json_extract(snapshot_json, '$.sequence') FROM strategy_runs WHERE run_id='run-1'",
        "UPDATE strategy_runs SET updated_at=0 WHERE run_id='run-1'",
        "UPDATE strategy_commands SET updated_at=0 WHERE command_id='command-1'",
    ] {
        let plan = support::query_plan(database, statement).join(" | ");
        assert!(
            !plan.contains("SCAN strategy_run_events") && !plan.contains("SCAN strategy_commands"),
            "a plan a commit relies on must not scan the tables that grow: {statement} -> {plan}"
        );
    }
}

#[test]
fn the_history_index_is_the_one_a_sequence_read_uses() {
    let scratch = support::ScratchDatabase::new("history-index").expect("fixture");
    let plan = support::query_plan(
        scratch.database(),
        "SELECT event_json FROM strategy_run_events WHERE run_id='run-1' AND sequence=1",
    )
    .join(" | ");
    assert!(
        plan.contains("sqlite_autoindex_strategy_run_events_1") || plan.contains("USING INDEX"),
        "history must be read by its primary key, not scanned: {plan}"
    );
}

#[test]
fn the_checkpoint_read_survives_a_thousand_rows_in_the_same_table() {
    // The same claim as the plan assertions, carried out for real: with a
    // thousand runs in the checkpoint table, one run's checkpoint reads back
    // exactly as it was written.
    let path = support::scratch_path("checkpoint-read");
    let database = Arc::new(WorkflowDatabase::open(&path).expect("open"));
    support::seed_definition(
        &database,
        support::REVISION,
        support::SEMANTICS,
        &support::actor_workflow(2),
    )
    .expect("definition seeds");
    let port = support::graph(&database, "run-checkpoint").expect("the run starts");
    let written = port.checkpoint("run-checkpoint").expect("checkpoint reads");

    for index in 0..1_000 {
        support::seed_run(
            &database,
            format!("run-filler-{index}"),
            support::REVISION,
            support::SEMANTICS,
        )
        .expect("filler run seeds");
    }
    assert_eq!(support::count(&database, "strategy_runs", "1=1"), 1_001);
    assert_eq!(
        port.checkpoint("run-checkpoint").expect("checkpoint reads"),
        written,
        "another thousand runs in the table change nothing about this one"
    );
    drop(port);
    drop(database);
    support::remove_database(&path);
}
