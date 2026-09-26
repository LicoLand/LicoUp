//! What a drive does when its claim is gone: a lost lease, and a run someone
//! else advanced past.
//!
//! C03 separates a lease from the effect it covered. A lease that expired (or
//! was taken over) removes this owner's permission to keep starting work; it is
//! not evidence about the effect, which may already have happened. That is why
//! neither test here expects the effect to be settled as failed, retried, or
//! reported as never having run.

use std::sync::Arc;

use licoup_workflow::{CommandStatus, ReducerEvent, StrategyRunStatus};
use licoup_workflow_runtime::driver::DriverLimits;
use licoup_workflow_runtime::ports::StatePort;

use crate::fixture::{Fixture, RUN, Script, drive_in_background, driver, limits};

#[test]
fn a_lost_lease_stops_the_drive_without_settling_the_effect() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    // A short lease with a shorter wait, so the drive renews while it waits.
    let driver = driver(
        &fixture,
        DriverLimits {
            max_in_flight: 1,
            lease_millis: 120,
            wait_millis: 20,
            ..DriverLimits::default()
        },
    );
    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("a invoked", |probe| probe.invoked("a"));

    // The claim is taken away while the effect is still running: the next
    // renewal is refused, which is what a stale claimant sees.
    fixture.lose_lease("a");
    let error = driving.failure();
    assert!(error.contains("fixture_lease_not_held"), "{error}");

    // The effect may already have happened, so nothing is settled: no outcome
    // was committed, the durable marker still stands, and the command is neither
    // failed nor retried. The in-doubt marker is the only fact recovery reads.
    assert_eq!(fixture.command_status("a"), CommandStatus::Running);
    assert_eq!(fixture.result_ref("a"), None);
    assert_eq!(
        fixture.probe().invocations,
        vec!["a"],
        "the effect ran once"
    );
    assert_eq!(fixture.claims().len(), 1, "no second claim was taken");
    hold.open();
}

#[test]
fn a_stale_view_cannot_commit_an_outcome() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    let driver = driver(&fixture, limits(1));
    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("a invoked", |probe| probe.invoked("a"));

    // Another owner advances the run while this drive is in flight. This is the
    // fact the committed sequence guards: a decision taken from an older view
    // must not be applied to a newer one.
    fixture
        .commit(RUN, fixture.sequence(), ReducerEvent::CancelRequested)
        .expect("an external commit advances the run");
    assert_eq!(fixture.command_status("a"), CommandStatus::CancelRequested);

    hold.open();
    let error = driving.failure();
    assert!(error.contains("fixture_stale_sequence"), "{error}");

    // The success the adapter reported was not written over the newer fact, and
    // no result was recorded for it.
    assert_eq!(fixture.status(), StrategyRunStatus::CancelRequested);
    assert_eq!(fixture.result_ref("a"), None);
}
