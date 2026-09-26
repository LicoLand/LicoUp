//! One transaction per transition: the compare-and-set, the state, the
//! commands, and the delivery intents commit together or not at all.

use anyhow::Result;
use licoup_workflow::{CommandStatus, ReducerEvent};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_store::transactions::{NoticeRequest, StoreStatePort};
use std::path::Path;

use crate::support;

fn notice(recipient: &str) -> NoticeRequest {
    NoticeRequest {
        recipient: recipient.to_owned(),
        kind: "timeline".to_owned(),
    }
}

/// A run one event in, holding one pending actor command.
fn started(label: &str) -> Result<(support::ScratchDatabase, StoreStatePort)> {
    let scratch = support::ScratchDatabase::new(label)?;
    let port = scratch.port();
    let snapshot = support::started_run(&port);
    assert_eq!(snapshot.sequence, 1);
    Ok((scratch, port))
}

fn pending_command(port: &StoreStatePort) -> licoup_workflow::RunCommand {
    let snapshot = port.checkpoint("run-1").expect("checkpoint reads");
    snapshot
        .commands
        .values()
        .find(|command| command.status == CommandStatus::Pending)
        .expect("the started run holds a pending command")
        .clone()
}

#[test]
fn a_stale_expected_sequence_fails_instead_of_rebasing() {
    let (scratch, port) = started("stale").expect("fixture");
    let head = port.checkpoint("run-1").expect("checkpoint reads");

    // One writer moves the run on.
    let advanced = port
        .commit("run-1", head.sequence, ReducerEvent::CancelRequested)
        .expect("the first writer commits");
    assert_eq!(advanced.sequence, head.sequence + 1);

    // A second writer that decided from the older view must fail rather than
    // have its decision applied to a state it never saw.
    let error = port
        .commit("run-1", head.sequence, ReducerEvent::CancelRequested)
        .expect_err("the stale writer is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_state_sequence_stale"),
        "unexpected error: {error}"
    );
    let after = port.checkpoint("run-1").expect("checkpoint reads");
    assert_eq!(after.sequence, advanced.sequence);
    assert_eq!(after, advanced, "the refused decision changed nothing");
    assert_eq!(
        support::count(scratch.database(), "strategy_run_events", "run_id='run-1'"),
        2,
        "one event row per committed transition, and none for the refusal"
    );
}

#[test]
fn a_failed_intent_rolls_back_the_state_the_commands_and_the_intents_together() {
    let (scratch, port) = started("atomic").expect("fixture");
    let before = port.checkpoint("run-1").expect("checkpoint reads");
    let database = scratch.database();
    let commands_before = support::count(database, "strategy_commands", "run_id='run-1'");
    let events_before = support::count(database, "strategy_run_events", "run_id='run-1'");

    // A recipient the format cannot store fails the commit at the very end of
    // the transaction, after the event, the checkpoint, and the commands have
    // already been written inside it.
    let error = port
        .commit_with_notices(
            "run-1",
            before.sequence,
            ReducerEvent::CancelRequested,
            &[notice("owner\u{7}invalid")],
        )
        .expect_err("an unstorable recipient fails the commit")
        .to_string();
    assert!(
        error.contains("workflow_notice_invalid"),
        "unexpected: {error}"
    );

    assert_eq!(
        port.checkpoint("run-1").expect("checkpoint reads").sequence,
        before.sequence,
        "the checkpoint did not advance"
    );
    assert_eq!(
        support::count(database, "strategy_run_events", "run_id='run-1'"),
        events_before,
        "no history row survived the rollback"
    );
    assert_eq!(
        support::count(database, "strategy_commands", "run_id='run-1'"),
        commands_before
    );
    assert_eq!(
        support::count(database, "workflow_notice_intents", "1=1"),
        0,
        "no intent survived the rollback"
    );

    // The same commit without the bad intent lands, which shows the refusal was
    // the intent and not something incidental about the transition.
    port.commit_with_notices(
        "run-1",
        before.sequence,
        ReducerEvent::CancelRequested,
        &[notice("owner-timeline")],
    )
    .expect("the commit lands");
    assert_eq!(
        support::count(database, "workflow_notice_intents", "status='pending'"),
        1
    );
}

#[test]
fn the_possible_effect_marker_is_durable_before_anything_could_have_effect() {
    let (scratch, port) = started("marker").expect("fixture");
    let command = pending_command(&port);

    // A marker for a token this command never had is refused: the marker names
    // the exact attempt, so a late caller cannot mark a newer attempt started.
    let error = port
        .mark_started("run-1", &command.id, "attempt-not-this-one")
        .expect_err("a foreign token is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_callback_stale"),
        "unexpected: {error}"
    );

    let claimed = port
        .claim_next("run-1", "host-1", support::future_ms())
        .expect("claim runs")
        .expect("a command is claimable");
    let marked = port
        .mark_started("run-1", &claimed.id, &claimed.attempt_token)
        .expect("the marker commits");
    assert_eq!(
        marked.commands[&claimed.id].status,
        CommandStatus::Running,
        "the marker is what recovery reads"
    );
    // Durable, not merely returned: a fresh read of the checkpoint agrees.
    let reread = port.checkpoint("run-1").expect("checkpoint reads");
    assert_eq!(reread.commands[&claimed.id].status, CommandStatus::Running);
    assert_eq!(
        support::count(scratch.database(), "strategy_run_events", "run_id='run-1'"),
        3,
        "start, claim, and the marker are three committed events"
    );
}

#[test]
fn a_lease_can_only_be_renewed_by_its_owner() {
    let (_scratch, port) = started("lease").expect("fixture");
    let claimed = port
        .claim_next("run-1", "host-1", support::future_ms())
        .expect("claim runs")
        .expect("a command is claimable");

    let error = port
        .renew_lease(&claimed.id, "host-2", support::future_ms())
        .expect_err("another owner cannot renew")
        .to_string();
    assert!(
        error.starts_with("workflow_lease_lost"),
        "unexpected: {error}"
    );
    port.renew_lease(&claimed.id, "host-1", support::future_ms())
        .expect("the owner renews");
}

/// The files that write inside a transaction, and what must never appear in
/// them.
///
/// "No compilation and no external call inside a write transaction" is a rule
/// about reachability, so it is checked by reading the code that runs inside
/// one rather than by trusting a convention. `state` is deliberately not in the
/// list: computing a reduction there, outside the lock, is the design.
const WRITE_TRANSACTION_FILES: [&str; 4] = ["write.rs", "database.rs", "gate.rs", "outbox.rs"];
const FORBIDDEN_IN_WRITE_TRANSACTION: [&str; 6] = [
    "compile_workflow",
    "CompiledWorkflow",
    "WorkflowDefinition",
    "reduce(",
    "AuthorityPort",
    "EffectPort",
];

fn transactions_source(file: &str) -> String {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join("transactions")
        .join(file);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{} is readable: {error}", path.display()))
}

#[test]
fn a_write_transaction_cannot_reach_a_compiler_or_a_port() {
    let mut violations = Vec::new();
    for file in WRITE_TRANSACTION_FILES {
        let source = transactions_source(file);
        for forbidden in FORBIDDEN_IN_WRITE_TRANSACTION {
            if source.contains(forbidden) {
                violations.push(format!("{file} names {forbidden}"));
            }
        }
    }
    assert!(
        violations.is_empty(),
        "a write transaction must not be able to compile a definition or call a \
         port, so a reduction has to arrive already computed: {}",
        violations.join(", ")
    );

    // The check has teeth only if the module that does compile is really
    // there to be excluded — otherwise it would pass on an empty directory.
    let state = transactions_source("state.rs");
    assert!(state.contains("compile_workflow"));
}

#[test]
fn the_reduction_module_is_where_compilation_is_allowed_to_happen() {
    // Positive half of the same rule: the adapter computes a reduction before
    // it takes the write gate, and it does that by naming the compiler here.
    let state = transactions_source("state.rs");
    assert!(state.contains("let output = reduce(&compiled, &previous"));
}

#[test]
fn a_commit_that_names_another_run_is_refused() {
    let (_scratch, port) = started("identity").expect("fixture");
    let error = port
        .commit("run-other", 0, ReducerEvent::CancelRequested)
        .expect_err("a run that does not exist is refused")
        .to_string();
    assert!(
        error.starts_with("workflow_run_not_found"),
        "unexpected: {error}"
    );
}
