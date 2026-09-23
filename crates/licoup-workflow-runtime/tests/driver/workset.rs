//! Workset visits: several items of one visit, each its own effect.
//!
//! A workset visit is one node visit that runs several items at once. The
//! machine gives every ready item its own command — `emit_command` hashes the
//! item into the command id while `state_id` and `state_visit` stay the visit's
//! — and a store hands those commands out one at a time. The production entry
//! found the ledger keying on the visit alone, refusing the second item as a
//! duplicate in-flight visit and stopping a run that was behaving correctly.
//!
//! These are the contract-level counterexamples for that shape. The production
//! entry itself is V7-I1's, at the host that owns the real store and adapters.

use std::sync::Arc;

use licoup_workflow::{CommandStatus, RunSnapshot, StrategyRunStatus};
use licoup_workflow_runtime::driver::{ControlRequest, DriveStop};
use licoup_workflow_runtime::node::NodeVisitKey;
use licoup_workflow_runtime::ports::StatePort;

use crate::fixture::{Fixture, RUN, Script, drive_in_background, driver, limits};

/// The workset state every item of these tests belongs to, and its visit.
const TASKS: &str = "tasks";
const VISIT: u64 = 1;

/// The visit key the whole workset run reports: one visit, whichever item.
fn tasks() -> NodeVisitKey {
    NodeVisitKey::new(TASKS, VISIT)
}

/// Declare one item of the workset, returning its command id.
fn declare_item(fixture: &Fixture, item: &str, predecessors: &[&str]) -> String {
    let command_id = format!("command-{item}");
    fixture.declare_item(&command_id, TASKS, VISIT, item, predecessors);
    command_id
}

/// The command the store currently holds for one item.
fn item_command(fixture: &Fixture, command_id: &str) -> licoup_workflow::RunCommand {
    let snapshot: RunSnapshot = StatePort::checkpoint(fixture, RUN).expect("checkpoint");
    snapshot
        .commands
        .get(command_id)
        .cloned()
        .expect("fixture_declared_command")
}

#[test]
fn two_items_of_one_workset_visit_run_side_by_side() {
    let fixture = Fixture::new();
    let a = declare_item(&fixture, "a", &[]);
    let b = declare_item(&fixture, "b", &[]);
    let c = declare_item(&fixture, "c", &[&a]);
    let hold_a = fixture.gate("hold:a");
    let hold_b = fixture.gate("hold:b");
    let hold_c = fixture.gate("hold:c");
    fixture.script(&a, Script::Hold(Arc::clone(&hold_a)));
    fixture.script(&b, Script::Hold(Arc::clone(&hold_b)));
    fixture.script(&c, Script::Hold(Arc::clone(&hold_c)));
    let driver = driver(&fixture, limits(2));
    let driving = drive_in_background(Arc::clone(&driver));

    // The defect: the second item of the visit was refused as a duplicate
    // in-flight visit, so the drive stopped before either effect ran.
    fixture.wait_for("a and b both in flight", |probe| {
        probe.invoked(&a) && probe.invoked(&b)
    });
    assert_eq!(
        fixture.peak_running(),
        2,
        "two items of one visit hold their admissions together"
    );
    assert_eq!(fixture.command_status(&a), CommandStatus::Running);
    assert_eq!(fixture.command_status(&b), CommandStatus::Running);

    // The shape is the machine's: one state and visit, two items, two commands.
    let first = item_command(&fixture, &a);
    let second = item_command(&fixture, &b);
    assert_eq!(first.state_id, TASKS);
    assert_eq!(second.state_id, TASKS);
    assert_eq!(first.state_visit, VISIT);
    assert_eq!(second.state_visit, VISIT);
    assert_eq!(first.item_id.as_deref(), Some("a"));
    assert_eq!(second.item_id.as_deref(), Some("b"));
    assert_ne!(first.id, second.id, "each item has its own command");

    // Item a settles; its successor item c starts while item b is still in
    // flight, which is A04's concurrency property inside one workset visit.
    hold_a.open();
    fixture.wait_for("c in flight", |probe| probe.invoked(&c));
    assert_eq!(fixture.command_status(&a), CommandStatus::Succeeded);
    assert_eq!(fixture.command_status(&c), CommandStatus::Running);
    assert_eq!(fixture.command_status(&b), CommandStatus::Running);
    assert!(
        !fixture.probe().returned(&b),
        "item b must still be in flight when item c starts"
    );

    hold_c.open();
    hold_b.open();
    let report = driving.report();
    assert_eq!(report.effects.succeeded, 3);
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
    assert_eq!(fixture.status(), StrategyRunStatus::Running);
    // Every settlement names the parent visit, and every command the item.
    let settled: Vec<(String, NodeVisitKey)> = report
        .trace
        .settlements()
        .map(|settlement| (settlement.command_id.clone(), settlement.node.clone()))
        .collect();
    assert_eq!(
        settled.len(),
        3,
        "each item settled as its own effect: {settled:?}"
    );
    assert!(
        settled.iter().all(|(_, node)| *node == tasks()),
        "one workset visit is one parent identity: {settled:?}"
    );
    assert!(fixture.violations().is_empty());
}

#[test]
fn a_run_cancel_freezes_every_item_of_the_visit() {
    let fixture = Fixture::new();
    let a = declare_item(&fixture, "a", &[]);
    let b = declare_item(&fixture, "b", &[]);
    let hold_a = fixture.gate("hold:a");
    let hold_b = fixture.gate("hold:b");
    fixture.script(&a, Script::Hold(Arc::clone(&hold_a)));
    fixture.script(&b, Script::Hold(Arc::clone(&hold_b)));
    fixture.confirm_cancel(
        &a,
        licoup_workflow_runtime::driver::CancelConfirmation::Acknowledged,
    );
    fixture.confirm_cancel(
        &b,
        licoup_workflow_runtime::driver::CancelConfirmation::Acknowledged,
    );
    let driver = driver(&fixture, limits(2));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a and b both in flight", |probe| {
        probe.invoked(&a) && probe.invoked(&b)
    });
    driver
        .control(RUN, ControlRequest::cancel("control-1"))
        .expect("the cancel is accepted");
    fixture.wait_for("both items were asked to stop", |probe| {
        probe.cancel_asked(&a) && probe.cancel_asked(&b)
    });
    hold_a.open();
    hold_b.open();
    let report = driving.report();

    // Both items of the visit were recipients of the run-scoped instruction:
    // the frozen set names every live effect and the visit once.
    let receipt = report
        .trace
        .controls()
        .find(|receipt| receipt.request_id == "control-1")
        .expect("the cancel was handled")
        .clone();
    let mut commands = receipt.frozen.commands.clone();
    commands.sort();
    assert_eq!(commands, vec![a.clone(), b.clone()]);
    assert_eq!(
        receipt.frozen.visits,
        vec![tasks()],
        "the parent visit is one recipient"
    );
    assert_eq!(receipt.in_flight, 2);
    assert_eq!(fixture.command_status(&a), CommandStatus::Cancelled);
    assert_eq!(fixture.command_status(&b), CommandStatus::Cancelled);
    assert_eq!(fixture.status(), StrategyRunStatus::Cancelled);
}

#[test]
fn a_retried_item_is_a_new_command_of_the_same_unit() {
    let fixture = Fixture::new();
    let first = declare_item(&fixture, "a", &[]);
    // A retry is the machine emitting a new command for the same item: same
    // state and visit, same item id, a different command id.
    let retry = "command-a-retry".to_owned();
    fixture.declare_item(&retry, TASKS, VISIT, "a", &[&first]);
    fixture.script(
        &first,
        Script::Fail {
            class: licoup_workflow::FailureClass::Transient,
            code: "transient".to_owned(),
        },
    );
    let driver = driver(&fixture, limits(1));

    let report = driver.drive(RUN).expect("drive");
    assert_eq!(report.effects.failed, 1);
    assert_eq!(report.effects.succeeded, 1);
    assert_eq!(fixture.command_status(&first), CommandStatus::Failed);
    assert_eq!(fixture.command_status(&retry), CommandStatus::Succeeded);
    let settled: Vec<String> = report
        .trace
        .settlements()
        .map(|settlement| settlement.command_id.clone())
        .collect();
    assert_eq!(settled, vec![first.clone(), retry.clone()]);
    assert!(fixture.violations().is_empty());
}
