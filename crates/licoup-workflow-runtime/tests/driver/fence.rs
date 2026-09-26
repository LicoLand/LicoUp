//! Stop and pause: what a fence blocks, what it must not change, and what
//! outlives the call that handled the instruction.
//!
//! The acceptance case is the race in A08: a pause arrives while a predecessor
//! is still in flight, so the successor its settlement would have enabled must
//! not start. The other half of the same case is that the in-flight effect is
//! *not* cancelled: a pause stops starting new work, and the authenticated
//! result of what already ran still settles.

use std::sync::Arc;

use licoup_workflow::{CommandStatus, StrategyRunStatus};
use licoup_workflow_runtime::admission::{BarrierKind, BarrierScope};
use licoup_workflow_runtime::driver::{ControlRequest, ControlTarget, DriveStop};

use crate::fixture::{
    Fixture, RUN, Script, drive_in_background, driver_with_barrier, limits, node_of,
};

#[test]
fn a_run_pause_fences_the_successor_its_predecessor_enabled() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("c", &["a"]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    let driver = driver_with_barrier(&fixture, limits(2));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a invoked", |probe| probe.invoked("a"));
    driver
        .control(
            RUN,
            ControlRequest::pause("pause-1", ControlTarget::Run, "user paused the run"),
        )
        .expect("the pause is accepted");
    // The barrier is published while the instruction is handled, which is where
    // admission is fenced from. A is still in flight here.
    fixture.wait_for_barrier("the pause is published", |requests| !requests.is_empty());
    assert!(
        !fixture.probe().returned("a"),
        "the in-flight effect must not have been touched by the pause"
    );

    hold.open();
    let report = driving.report();

    // The instruction froze exactly what was in flight, and the barrier carries
    // the same recipients in the same write.
    let request = fixture
        .barrier_requests()
        .first()
        .cloned()
        .expect("one barrier was published");
    assert_eq!(request.kind, BarrierKind::Pause);
    assert_eq!(request.scope, BarrierScope::Run(RUN.to_owned()));
    assert_eq!(request.recipients, vec![node_of("a")]);
    let receipt = report
        .trace
        .controls()
        .find(|receipt| receipt.request_id == "pause-1")
        .expect("the pause was handled")
        .clone();
    assert_eq!(receipt.kind.to_string(), "pause");
    assert_eq!(receipt.frozen.commands, vec!["a".to_owned()]);
    let barrier = receipt.barrier.clone().expect("a barrier was published");
    assert_eq!(barrier.kind, BarrierKind::Pause);
    assert!(barrier.froze(&node_of("a")));
    // The effect that was in flight when the pause was handled settles by its
    // own authenticated outcome: a pause is not a cancellation, and the result
    // is recorded rather than erased.
    assert!(
        !fixture
            .cancels()
            .iter()
            .any(|(_, command_id)| command_id == "a"),
        "a pause is not a cancellation"
    );
    assert_eq!(fixture.command_status("a"), CommandStatus::Succeeded);
    assert_eq!(fixture.result_ref("a"), Some("result-a".to_owned()));
    assert_eq!(fixture.status(), StrategyRunStatus::Running);
    // A pause writes a barrier, not a cancellation: the run's own event stream
    // never saw a cancel request, and the successor was never cancelled — it is
    // still pending behind the fence.
    assert!(
        !fixture.order().iter().any(|step| matches!(
            step,
            crate::fixture::Step::Committed {
                event: "cancel_requested",
                ..
            }
        )),
        "a pause must not be committed as a cancel"
    );
    assert_eq!(fixture.command_status("c"), CommandStatus::Pending);

    // The successor its settlement enabled never started, and the drive said
    // why instead of reporting that it ran out of work.
    assert!(
        !fixture.probe().invoked("c"),
        "c must not start under the fence"
    );
    assert_eq!(report.effects.succeeded, 1);
    assert_eq!(
        report.stop,
        DriveStop::Fenced {
            kind: BarrierKind::Pause
        }
    );

    // The fence outlives the call that handled it: a later drive reads the
    // barrier and admits nothing, so quiescence cannot be mistaken for a run
    // that is merely out of work.
    let second = driver.drive(RUN).expect("a second drive reads the fence");
    assert_eq!(second.effects.claimed, 0);
    assert_eq!(
        second.stop,
        DriveStop::Fenced {
            kind: BarrierKind::Pause
        }
    );
    assert_eq!(
        fixture.claims().len(),
        1,
        "only the first call claimed work"
    );
}

#[test]
fn a_node_scoped_pause_does_not_fence_a_new_visit() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("c", &["a"]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    let driver = driver_with_barrier(&fixture, limits(2));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a invoked", |probe| probe.invoked("a"));
    driver
        .control(
            RUN,
            ControlRequest::pause(
                "pause-1",
                ControlTarget::Node(node_of("a")),
                "this one effect, briefly",
            ),
        )
        .expect("the pause is accepted");
    fixture.wait_for_barrier("the node barrier is published", |requests| {
        !requests.is_empty()
    });
    hold.open();
    let report = driving.report();

    // The node scope acted on its frozen recipient and wrote a node barrier;
    // C03 gives the new-start fence to the run scope only, so the successor of
    // the settled predecessor still runs.
    let request = fixture
        .barrier_requests()
        .first()
        .cloned()
        .expect("one publish");
    assert_eq!(request.scope, BarrierScope::Node(node_of("a")));
    assert!(
        !request.recipients.is_empty(),
        "the frozen recipient travels with the barrier"
    );
    assert!(
        fixture.probe().invoked("c"),
        "a node-scoped pause fences nothing new"
    );
    assert_eq!(fixture.command_status("c"), CommandStatus::Succeeded);
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
}

#[test]
fn a_barrier_published_before_the_drive_stops_new_visits() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("c", &["a"]);
    // An operator stopped the scope before this drive was called: nothing here
    // handled the instruction, so the only fact that can fence it is the
    // barrier owner's answer at the admission boundary.
    fixture.publish_barrier(
        BarrierScope::Run(RUN.to_owned()),
        BarrierKind::Stop,
        "operator stop",
    );
    let report = driver_with_barrier(&fixture, limits(2))
        .drive(RUN)
        .expect("drive");

    assert_eq!(report.effects.claimed, 0);
    assert!(fixture.claims().is_empty());
    assert!(fixture.probe().invocations.is_empty());
    assert_eq!(
        report.stop,
        DriveStop::Fenced {
            kind: BarrierKind::Stop
        }
    );
    // Reading the barrier did not clear it: the fence is still in force.
    assert!(
        fixture
            .barrier_in_force(&BarrierScope::Run(RUN.to_owned()))
            .is_some()
    );
}
