//! Control: handled ahead of results, on recipients frozen when it arrives, and
//! never confused with the completion that settles what it asked about.

use std::sync::{Arc, Mutex};

use licoup_workflow::CommandStatus;
use licoup_workflow_runtime::driver::{
    CancelConfirmation, ControlRequest, ControlTarget, DriveStop, DriverError,
};
use licoup_workflow_runtime::node::NodeOutcomeKind;

use crate::fixture::{Fixture, RUN, Script, drive_in_background, driver, limits, wait_for_queue};

#[test]
fn control_is_handled_while_the_result_path_is_backed_up() {
    let fixture = Fixture::new();
    for command_id in ["a", "b", "c"] {
        fixture.declare(command_id, &[]);
    }
    // The store holds the first commit, which parks the drive loop with its
    // result path filling up behind it.
    let commit_gate = fixture.gate("commit:a");
    let commit_b = fixture.gate("commit:b");
    let commit_c = fixture.gate("commit:c");
    let driver = driver(&fixture, limits(3));
    let driving = drive_in_background(Arc::clone(&driver));

    // Two effects finished behind the blocked commit: a result path with work in
    // it is exactly the state the control path must not queue behind. Waiting on
    // the depths themselves (rather than on a guess about timing) is what makes
    // the interleaving deterministic.
    let queued = wait_for_queue(&driver, "two completions parked", |queued| {
        queued.results == 2
    });
    assert_eq!(queued.control, 0);

    let accepted = driver
        .control(RUN, ControlRequest::cancel("control-1"))
        .expect("control is accepted on its own channel");
    assert_eq!(accepted.request_id, "control-1");
    assert_eq!(driver.queued(RUN).expect("registered").control, 1);

    commit_gate.open();
    commit_b.open();
    commit_c.open();
    let report = driving.report();

    let control = report
        .trace
        .controls()
        .find(|receipt| receipt.request_id == "control-1")
        .expect("control was handled")
        .clone();
    // The evidence: the receipt was taken while two completions were still
    // waiting, and the first settlement after it is the queued result, not the
    // control.
    assert_eq!(control.results_pending, 2);
    assert_eq!(control.kind.to_string(), "cancel");
    let control_at = report.trace.index_of_control("control-1").expect("handled");
    let first_result_after = report
        .trace
        .settlements()
        .filter_map(|settlement| report.trace.index_of_settlement(&settlement.command_id))
        .filter(|index| *index > control_at)
        .min()
        .expect("the parked results are settled after the control");
    assert!(control_at < first_result_after);
    assert!(
        fixture.violations().is_empty(),
        "{:?}",
        fixture.violations()
    );
}

#[test]
fn a_cancelled_run_settles_as_what_the_effect_port_confirmed() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &["a"]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    fixture.confirm_cancel("a", CancelConfirmation::Acknowledged);
    let driver = driver(&fixture, limits(1));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a invoked", |probe| probe.invoked("a"));
    driver
        .control("run-1", ControlRequest::cancel("control-1"))
        .expect("cancel is accepted");
    hold.open();
    let report = driving.report();

    // The request asked the effect to stop, and the effect port confirmed it; the
    // completion that followed is settled as a cancellation, not as a success.
    assert_eq!(
        fixture.cancels(),
        vec![("control-1".to_owned(), "a".to_owned())]
    );
    assert_eq!(fixture.command_status("a"), CommandStatus::Cancelled);
    assert_eq!(
        fixture.status(),
        licoup_workflow::StrategyRunStatus::Cancelled,
        "the run's own status follows the acknowledged cancellation"
    );
    assert_eq!(report.effects.cancelled, 1);
    assert_eq!(report.effects.succeeded, 0);
    assert_eq!(
        report.stop,
        DriveStop::Terminal {
            status: licoup_workflow::StrategyRunStatus::Cancelled
        }
    );
    // b was never started: the run's cancel event cancelled what had not started,
    // and this drive admits nothing new after it.
    assert_eq!(fixture.command_status("b"), CommandStatus::Cancelled);
    assert_eq!(fixture.probe().invocations, vec!["a"]);
}

#[test]
fn an_unconfirmed_cancellation_is_recorded_as_unknown_not_as_cancelled() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    // The default answer an adapter gives is `Unsupported`: it cannot cancel what
    // it started, and pretending otherwise would be a lie in durable state.
    let driver = driver(&fixture, limits(1));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a invoked", |probe| probe.invoked("a"));
    driver
        .control("run-1", ControlRequest::cancel("control-1"))
        .expect("cancel is accepted");
    hold.open();
    let report = driving.report();

    assert_eq!(fixture.command_status("a"), CommandStatus::InDoubt);
    assert_eq!(report.effects.unknown, 1);
    assert_eq!(report.effects.cancelled, 0);
    // A late success is reported, never re-read as a cancellation.
    assert!(report.trace.events().iter().any(|event| matches!(
        event,
        licoup_workflow_runtime::driver::DriveEvent::LateOutcome {
            observed: NodeOutcomeKind::Succeeded,
            settled: NodeOutcomeKind::Unknown,
            ..
        }
    )));
    assert_eq!(
        report.stop,
        DriveStop::Terminal {
            status: licoup_workflow::StrategyRunStatus::CancelInDoubt
        }
    );
}

#[test]
fn a_steer_reaches_the_frozen_recipients_and_settles_nothing() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &[]);
    let hold_a = fixture.gate("hold:a");
    let hold_b = fixture.gate("hold:b");
    fixture.script("a", Script::Hold(Arc::clone(&hold_a)));
    fixture.script("b", Script::Hold(Arc::clone(&hold_b)));
    let driver = driver(&fixture, limits(2));
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("a and b invoked", |probe| probe.invocations.len() == 2);
    driver
        .control(
            RUN,
            ControlRequest::steer("steer-1", ControlTarget::Run, "keep going, briefly"),
        )
        .expect("steer is accepted");
    // The recipients are the effects in flight when it was handled, and the
    // frozen set is named in the trace.
    fixture.wait_for("both recipients steered", |probe| probe.steers.len() == 2);
    hold_a.open();
    hold_b.open();
    let report = driving.report();

    let mut steered = fixture
        .steers()
        .iter()
        .map(|(request_id, command_id)| (request_id.clone(), command_id.clone()))
        .collect::<Vec<_>>();
    steered.sort();
    assert_eq!(
        steered,
        vec![
            ("steer-1".to_owned(), "a".to_owned()),
            ("steer-1".to_owned(), "b".to_owned())
        ]
    );
    let receipt = report
        .trace
        .controls()
        .find(|receipt| receipt.request_id == "steer-1")
        .expect("steer was handled")
        .clone();
    assert_eq!(receipt.frozen.len(), 2);
    assert!(receipt.confirmations.is_empty(), "a steer confirms nothing");
    assert_eq!(receipt.in_flight, 2);
    // Nothing was settled by the steer: both effects still succeeded.
    assert_eq!(report.effects.succeeded, 2);
    assert_eq!(
        report.stop,
        DriveStop::Quiescent {
            budget_exhausted: false
        }
    );
    assert!(
        report
            .trace
            .settlements()
            .all(|settlement| settlement.outcome == NodeOutcomeKind::Succeeded)
    );
}

#[test]
fn a_control_for_a_run_nobody_is_driving_is_refused() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let driver = driver(&fixture, limits(1));

    // Before the drive: nothing to take the request, and saying so is more
    // honest than queueing it into the void.
    let error = driver
        .control("run-1", ControlRequest::cancel("control-1"))
        .expect_err("no drive is running");
    assert!(matches!(error, DriverError::NotDriven { .. }));
    assert!(driver.queued("run-1").is_none());

    let report = driver.drive("run-1").expect("drive");
    assert_eq!(report.effects.succeeded, 1);
    // After the drive: the run is released, because driving is what the control
    // path addresses.
    assert!(driver.queued("run-1").is_none());
}

#[test]
fn a_full_control_channel_refuses_rather_than_dropping() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let commit_gate = fixture.gate("commit:a");
    let driver = driver(
        &fixture,
        licoup_workflow_runtime::driver::DriverLimits {
            max_in_flight: 1,
            control_capacity: 1,
            ..licoup_workflow_runtime::driver::DriverLimits::default()
        },
    );
    let driving = drive_in_background(Arc::clone(&driver));

    fixture.wait_for("the commit is held", |probe| {
        probe.commits_entered.iter().any(|id| id == "a")
    });
    driver
        .control("run-1", ControlRequest::cancel("control-1"))
        .expect("the first request fits");
    let error = driver
        .control("run-1", ControlRequest::cancel("control-2"))
        .expect_err("the second must be refused while the first waits");
    assert!(matches!(
        error,
        DriverError::ControlSaturated {
            capacity: 1,
            pending: 1,
            ..
        }
    ));
    commit_gate.open();
    let report = driving.report();

    assert_eq!(report.trace.controls().count(), 1, "one request was taken");
    let receipt = report.trace.controls().next().expect("handled").clone();
    assert_eq!(receipt.request_id, "control-1");
    // The effect had already settled by the time the request was handled, so the
    // frozen set is empty: a request acts on the recipients it finds, and this
    // one found none. It was still handled, not dropped.
    assert!(receipt.frozen.is_empty());
    assert!(receipt.confirmations.is_empty());
    // Nothing was in flight, so the run's cancel is complete at once.
    assert_eq!(
        report.stop,
        DriveStop::Terminal {
            status: licoup_workflow::StrategyRunStatus::Cancelled
        }
    );
}

#[test]
fn a_control_request_runs_adapter_code_with_no_lock_held() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    fixture.confirm_cancel("a", CancelConfirmation::Acknowledged);
    let driver = driver(&fixture, limits(1));

    // The fixture asks the driver for its own queue depths from inside `cancel`.
    // The control path runs on the drive loop's own thread, so if the loop held
    // the queue's lock while calling the adapter, this would block and the
    // bounded collect below would fail the test rather than hang it.
    let reached = Arc::new(Mutex::new(Vec::new()));
    let weak = Arc::downgrade(&driver);
    let recorder = Arc::clone(&reached);
    fixture.set_adapter_hook(Arc::new(move |operation, _command_id| {
        if operation != "cancel" {
            return;
        }
        let reachable = weak
            .upgrade()
            .is_some_and(|driver| driver.queued(RUN).is_some());
        recorder
            .lock()
            .expect("recorder")
            .push((operation.to_owned(), reachable));
    }));

    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("a invoked", |probe| probe.invoked("a"));
    driver
        .control(RUN, ControlRequest::cancel("control-1"))
        .expect("cancel is accepted");
    hold.open();
    let report = driving.report();

    assert_eq!(
        *reached.lock().expect("recorder"),
        vec![("cancel".to_owned(), true)],
        "the adapter ran without the drive holding its own lock"
    );
    assert_eq!(report.effects.cancelled, 1);
}

#[test]
fn a_cancel_that_arrives_with_nothing_in_flight_is_still_taken() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &[]);
    let commit_gate = fixture.gate("commit:a");
    // One effect per call, so b is claimable but never admitted: the drive is
    // quiescent with work left that it is not allowed to start.
    let driver = driver(
        &fixture,
        licoup_workflow_runtime::driver::DriverLimits {
            max_in_flight: 1,
            max_effects_per_drive: 1,
            ..licoup_workflow_runtime::driver::DriverLimits::default()
        },
    );
    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("the commit is held", |probe| {
        probe.commits_entered.iter().any(|id| id == "a")
    });
    driver
        .control(RUN, ControlRequest::cancel("control-1"))
        .expect("cancel is accepted");
    commit_gate.open();
    let report = driving.report();

    // Control is not conditioned on effects being in flight: the request was
    // taken before the drive ended, and what had not started is cancelled.
    assert_eq!(report.trace.controls().count(), 1);
    assert_eq!(fixture.command_status("b"), CommandStatus::Cancelled);
    assert_eq!(
        report.stop,
        DriveStop::Terminal {
            status: licoup_workflow::StrategyRunStatus::Cancelled
        }
    );
}
