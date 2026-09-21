//! Advancing on each completion, and the marker ordering the ports rest on.

use std::collections::BTreeSet;
use std::sync::Arc;

use licoup_workflow::CommandStatus;
use licoup_workflow_runtime::driver::{DriveStop, DriveTrace};

use crate::fixture::{Fixture, Gate, Script, drive_in_background, driver, limits, node_of};

/// A run shaped like the acceptance case: A feeds C, B is independent.
///
/// A, B and C are each held until the test releases them, so every overlap the
/// test asserts is a fact it created rather than one it hoped the scheduler
/// would produce.
fn a_to_c_with_independent_b(
    release_a: &Arc<Gate>,
    release_b: &Arc<Gate>,
    release_c: &Arc<Gate>,
) -> Fixture {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &[]);
    fixture.declare("c", &["a"]);
    fixture.script("a", Script::Hold(Arc::clone(release_a)));
    fixture.script("b", Script::Hold(Arc::clone(release_b)));
    fixture.script("c", Script::Hold(Arc::clone(release_c)));
    fixture
}

#[test]
fn a_successor_is_admitted_as_soon_as_its_predecessor_settles() {
    let release_a = Gate::new();
    let release_b = Gate::new();
    let release_c = Gate::new();
    let fixture = a_to_c_with_independent_b(&release_a, &release_b, &release_c);
    let driver = driver(&fixture, limits(2));
    let driving = drive_in_background(std::sync::Arc::clone(&driver));

    // Both effects are in flight at once: the bound is two, and admission does
    // not wait for a result before taking the next claimable effect.
    fixture.wait_for("a and b invoked", |probe| {
        probe.invoked("a") && probe.invoked("b")
    });
    assert_eq!(
        fixture.peak_running(),
        2,
        "a and b hold their admissions at the same time"
    );

    // A settles while B is still in flight, and C is admitted without waiting
    // for the rest of the in-flight set.
    release_a.open();
    fixture.wait_for("c invoked", |probe| probe.invoked("c"));
    // The store's own view at that moment: A's outcome is persisted with its
    // result, C is running, and B is still running too.
    assert_eq!(fixture.command_status("a"), CommandStatus::Succeeded);
    assert_eq!(fixture.result_ref("a"), Some("result-a".to_owned()));
    assert_eq!(fixture.command_status("c"), CommandStatus::Running);
    assert_eq!(fixture.command_status("b"), CommandStatus::Running);
    let mut invoked = fixture.probe().invocations;
    invoked.sort();
    assert_eq!(invoked, vec!["a", "b", "c"]);
    assert!(
        !fixture.probe().returned("b"),
        "B must still be in flight when C is admitted"
    );

    release_c.open();
    release_b.open();
    let report = driving.report();

    // The trace names the settlement that opened the admission, and the
    // admission follows it.
    let settlements = report.trace.settlements().cloned().collect::<Vec<_>>();
    let admissions = report.trace.admissions().cloned().collect::<Vec<_>>();
    let c = admissions
        .iter()
        .find(|admission| admission.command_id == "c")
        .expect("c was admitted");
    assert_eq!(c.after.as_deref(), Some("a"));
    assert_eq!(c.node, node_of("c"));
    let a_settled = report.trace.index_of_settlement("a").expect("a settled");
    let c_admitted = report.trace.index_of_admission("c").expect("c admitted");
    assert!(
        a_settled < c_admitted,
        "C's admission must follow A's committed outcome"
    );
    assert_eq!(settlements.len(), 3, "a, b and c all settled");
    assert_eq!(report.effects.claimed, 3);
    assert_eq!(report.effects.succeeded, 3);
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
    assert_eq!(
        report
            .settled_visits
            .iter()
            .cloned()
            .collect::<BTreeSet<_>>(),
        ["a", "b", "c"]
            .iter()
            .map(|id| node_of(id))
            .collect::<BTreeSet<_>>()
    );
    assert!(
        fixture.violations().is_empty(),
        "{:?}",
        fixture.violations()
    );
}

#[test]
fn the_possible_effect_marker_is_durable_before_each_invocation() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &["a"]);
    let report = driver(&fixture, limits(2)).drive("run-1").expect("drive");

    // The fixture files a violation when an adapter runs for a command whose
    // marker is not durable, and the ordered log lets the test check the same
    // fact from the other side.
    assert!(
        fixture.violations().is_empty(),
        "{:?}",
        fixture.violations()
    );
    let order = fixture.order();
    for command_id in ["a", "b"] {
        let marker = order
            .iter()
            .position(|step| matches!(step, crate::fixture::Step::Marker { command_id: id } if id == command_id))
            .unwrap_or_else(|| panic!("{command_id} has a durable marker"));
        let invoked = order
            .iter()
            .position(|step| matches!(step, crate::fixture::Step::Invoked { command_id: id } if id == command_id))
            .unwrap_or_else(|| panic!("{command_id} was invoked"));
        assert!(marker < invoked, "{command_id}: marker precedes invocation");
    }
    // The same fact as the driver records it: the marker's sequence precedes the
    // outcome's, and every marker was committed before its effect settled.
    for admission in report.trace.admissions() {
        let settled = report
            .trace
            .settlements()
            .find(|settlement| settlement.command_id == admission.command_id)
            .expect("every admitted effect settled");
        assert!(admission.marker_sequence < settled.sequence);
    }
    assert_eq!(fixture.sequence(), report.sequence);
}

#[test]
fn a_failed_effect_settles_without_stopping_its_siblings() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &[]);
    fixture.script(
        "a",
        Script::Fail {
            class: licoup_workflow::FailureClass::Permanent,
            code: "ToolFailed".to_owned(),
        },
    );
    let report = driver(&fixture, limits(2)).drive("run-1").expect("drive");

    assert_eq!(report.effects.failed, 1);
    assert_eq!(report.effects.succeeded, 1);
    // The adapter's code is normalized at the boundary: durable state only
    // accepts lowercase codes, and a badly formulated one is not a way to fail
    // the drive. The fixture checks the durable code itself, so the commit
    // landing at all is the evidence.
    assert_eq!(fixture.command_status("a"), CommandStatus::Failed);
    assert!(
        fixture.violations().is_empty(),
        "{:?}",
        fixture.violations()
    );
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
}

#[test]
fn a_result_that_does_not_belong_to_its_command_is_refused() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.script("a", Script::Misreport);
    let error = driver(&fixture, limits(1))
        .drive("run-1")
        .expect_err("a settlement for another command must be refused");
    let text = error.to_string();
    assert!(text.contains("effect_settlement_refused"), "{text}");
    // Nothing was committed for the effect whose settlement was refused: the
    // command stays in doubt rather than being settled by someone else's fact.
    assert_eq!(fixture.command_status("a"), CommandStatus::Running);
    assert_eq!(fixture.result_ref("a"), None);
}

#[test]
fn the_drive_yields_when_its_effect_budget_is_spent() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &["a"]);
    let driver = driver(
        &fixture,
        licoup_workflow_runtime::driver::DriverLimits {
            max_in_flight: 1,
            max_effects_per_drive: 1,
            ..licoup_workflow_runtime::driver::DriverLimits::default()
        },
    );
    let first = driver.drive("run-1").expect("first drive");
    assert_eq!(
        first.stop,
        DriveStop::Quiescent {
            budget_exhausted: true
        }
    );
    assert_eq!(first.effects.claimed, 1);
    // The run is not done; a second call continues it, which is what keeps a
    // host loop honest about what one call owns. The second call's budget is
    // spent by its own single effect, so the flag stays set: it says the budget
    // stopped the drive from *asking* for more, not that more work exists.
    let second = driver.drive("run-1").expect("second drive");
    assert_eq!(second.effects.claimed, 1);
    assert_eq!(
        second.stop,
        DriveStop::Quiescent {
            budget_exhausted: true
        }
    );
    assert_eq!(second.sequence, fixture.sequence());
    assert_eq!(
        fixture.command_status("b"),
        CommandStatus::Succeeded,
        "the successor ran in the second call"
    );
}

#[test]
fn a_trace_records_the_owner_and_the_stop() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let report = driver(&fixture, limits(1)).drive("run-1").expect("drive");
    let trace: &DriveTrace = &report.trace;
    assert!(trace.len() >= 4, "owned, admitted, settled, stopped");
    assert_eq!(report.claimant, "host-a#1");
    assert!(matches!(
        trace.events().first(),
        Some(licoup_workflow_runtime::driver::DriveEvent::Owned { .. })
    ));
    assert_eq!(
        trace.stop(),
        Some(&DriveStop::Quiescent {
            budget_exhausted: false
        })
    );
}
