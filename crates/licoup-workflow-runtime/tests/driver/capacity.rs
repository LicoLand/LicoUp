//! The in-flight bound, and what happens to an effect that never reports.

use std::sync::Arc;

use licoup_workflow::{CommandStatus, MAX_ACTIVE_EFFECTS};
use licoup_workflow_runtime::driver::{DriveStop, DriverError, DriverLimits};
use licoup_workflow_runtime::node::NodeOutcomeKind;

use crate::fixture::{Fixture, Gate, Script, drive_in_background, driver, limits};

#[test]
fn the_in_flight_bound_is_enforced_at_admission() {
    let fixture = Fixture::new();
    let mut gates = Vec::new();
    for command_id in ["a", "b", "c", "d"] {
        fixture.declare(command_id, &[]);
        let gate = Gate::new();
        fixture.script(command_id, Script::Hold(Arc::clone(&gate)));
        gates.push((command_id, gate));
    }
    let driver = driver(&fixture, limits(2));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a and b invoked", |probe| probe.invocations.len() == 2);
    // Two effects exist because two slots exist. A driver without an admission
    // bound would have invoked all four before any of them settled, which the
    // concurrency high-water mark and the trace both show.
    assert_eq!(fixture.peak_running(), 2);
    let mut invoked = fixture.probe().invocations;
    invoked.sort();
    assert_eq!(invoked, vec!["a", "b"], "only two effects exist so far");

    // Freeing a slot admits exactly one more, and the run continues to quiescence.
    gates[0].1.open();
    fixture.wait_for("c invoked", |probe| probe.invoked("c"));
    gates[1].1.open();
    gates[2].1.open();
    gates[3].1.open();
    let report = driving.report();

    assert_eq!(fixture.peak_running(), 2);
    for admission in report.trace.admissions() {
        assert!(
            admission.in_flight <= 2,
            "{} was admitted with {} in flight",
            admission.command_id,
            admission.in_flight
        );
    }
    assert_eq!(report.effects.claimed, 4);
    assert_eq!(report.effects.succeeded, 4);
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
    assert!(
        fixture.violations().is_empty(),
        "{:?}",
        fixture.violations()
    );
}

#[test]
fn limits_that_cannot_be_honoured_are_refused_by_name() {
    let fixture = Fixture::new();
    let too_many = DriverLimits {
        max_in_flight: MAX_ACTIVE_EFFECTS + 1,
        ..DriverLimits::default()
    };
    let error = licoup_workflow_runtime::driver::Driver::new(
        Arc::new(fixture.clone()),
        Arc::new(fixture.clone()),
        licoup_workflow_runtime::driver::OwnerId::new("host-a"),
        too_many,
    )
    .expect_err("a bound above the machine's own must be refused");
    assert!(matches!(
        error,
        DriverError::InvalidLimits { reason } if reason.contains("MAX_ACTIVE_EFFECTS")
    ));

    let renewed_after_expiry = DriverLimits {
        lease_millis: 100,
        wait_millis: 100,
        ..DriverLimits::default()
    };
    let error = licoup_workflow_runtime::driver::Driver::new(
        Arc::new(fixture.clone()),
        Arc::new(fixture.clone()),
        licoup_workflow_runtime::driver::OwnerId::new("host-a"),
        renewed_after_expiry,
    )
    .expect_err("a wait that outlasts the lease must be refused");
    assert!(matches!(
        error,
        DriverError::InvalidLimits { reason } if reason.contains("wait_millis")
    ));
}

#[test]
fn an_effect_that_never_reports_is_settled_in_doubt() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &["a"]);
    // The thread ends without a verdict: no completion ever arrives for it.
    fixture.script("a", Script::Panic);
    let report = driver(&fixture, limits(2)).drive("run-1").expect("drive");

    assert_eq!(report.effects.lost, 1);
    assert_eq!(report.effects.unknown, 1);
    assert_eq!(report.effects.succeeded, 1);
    // In doubt, not failed and not retried: the durable marker says the effect
    // may have happened.
    assert_eq!(fixture.command_status("a"), CommandStatus::InDoubt);
    assert_eq!(fixture.command_status("b"), CommandStatus::Succeeded);
    assert_eq!(fixture.result_ref("a"), None);
    assert_eq!(
        report
            .trace
            .settlements()
            .find(|settlement| settlement.command_id == "a")
            .map(|settlement| settlement.outcome),
        Some(NodeOutcomeKind::Unknown)
    );
    assert!(
        report
            .trace
            .lost()
            .any(|(command_id, ..)| command_id == "a")
    );
    // The sibling continued: a lost effect is not a reason to stop the run.
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
}

#[test]
fn an_adapter_that_cannot_say_what_happened_settles_the_effect_in_doubt() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    // An adapter that cannot say whether the effect ran says exactly that, and a
    // code written for humans does not become the durable code.
    fixture.script(
        "a",
        Script::Unknown {
            code: "Host Lost!".to_owned(),
        },
    );
    let report = driver(&fixture, limits(1)).drive("run-1").expect("drive");

    assert_eq!(report.effects.unknown, 1);
    assert_eq!(fixture.command_status("a"), CommandStatus::InDoubt);
    // In doubt is not retryable, and there is no result to read: the fixture's
    // commit would have refused a code that durable state cannot hold.
    assert_eq!(fixture.result_ref("a"), None);
    assert!(
        fixture.violations().is_empty(),
        "{:?}",
        fixture.violations()
    );
}

#[test]
fn an_adapter_that_cannot_report_leaves_the_effect_in_doubt() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.script("a", Script::Error("adapter_transport_gone".to_owned()));
    let report = driver(&fixture, limits(1)).drive("run-1").expect("drive");

    assert_eq!(report.effects.unknown, 1);
    assert_eq!(report.effects.lost, 0, "the thread did report");
    assert_eq!(fixture.command_status("a"), CommandStatus::InDoubt);
    assert!(
        report.trace.events().iter().any(|event| matches!(
            event,
            licoup_workflow_runtime::driver::DriveEvent::AdapterError { .. }
        )),
        "the adapter's own failure is recorded"
    );
}
