//! What an adapter cannot do: drive the run again, or find a driver lock held.

use std::sync::{Arc, Mutex};

use licoup_workflow_runtime::driver::DriverError;

use crate::fixture::{Fixture, RUN, Script, drive_in_background, driver, limits};

/// What the hook saw, written from inside adapter code.
#[derive(Clone, Debug, PartialEq)]
struct Seen {
    operation: String,
    /// What a re-entrant drive call answered.
    reentry: String,
    /// Whether the drive's own observability was reachable from here.
    queued: bool,
    /// Whether the ownership registry was reachable from here.
    holder: bool,
}

#[test]
fn an_adapter_that_tries_to_drive_again_is_refused() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    fixture.declare("b", &["a"]);
    let driver = driver(&fixture, limits(1));

    // A composition root that wired the driver into its own adapter: the mistake
    // this test is about. Nothing in the port makes it possible — the request
    // carries data only — so the handle is supplied out of band, deliberately.
    let seen = Arc::new(Mutex::new(Vec::<Seen>::new()));
    let weak = Arc::downgrade(&driver);
    let recorder = Arc::clone(&seen);
    fixture.set_adapter_hook(Arc::new(move |operation, _command_id| {
        let queued = weak.upgrade().is_some_and(|driver| {
            // Asked from inside adapter code. If the drive held its own lock while
            // running an adapter, this would block and the test's bounded wait
            // would fail instead of hanging.
            let reachable = driver.queued(RUN).is_some();
            let holder = driver.ownership().holder(RUN).is_some();
            let reentry = driver
                .drive(RUN)
                .map(|_| "accepted".to_owned())
                .unwrap_or_else(|error| error.to_string());
            recorder.lock().expect("recorder").push(Seen {
                operation: operation.to_owned(),
                reentry,
                queued: reachable,
                holder,
            });
            true
        });
        let _ = queued;
    }));

    let report = drive_in_background(Arc::clone(&driver)).report();
    let seen = seen.lock().expect("recorder").clone();

    assert_eq!(seen.len(), 2, "one hook per submitted effect: {seen:?}");
    for entry in &seen {
        assert_eq!(entry.operation, "submit");
        // The refusal is the same fence that gives the run one owner, and it is
        // named: a second drive of a run this driver owns is refused, not
        // interleaved.
        assert!(
            entry.reentry.contains("run_already_owned"),
            "{entry:?} was not refused"
        );
        assert!(entry.queued, "the drive's own queues are reachable");
        assert!(entry.holder, "the ownership registry is reachable");
    }
    // The refused call changed nothing: each effect ran exactly once, and the
    // outer drive finished.
    assert_eq!(fixture.probe().invocations, vec!["a", "b"]);
    assert_eq!(report.effects.succeeded, 2);
}

#[test]
fn a_second_host_cannot_hold_the_run_the_first_is_driving() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));

    // Two drivers sharing one registry are two hosts in one process. The second
    // gets the same refusal a second process gets from the durable claimant.
    let ownership = Arc::new(licoup_workflow_runtime::driver::RunOwnership::new());
    let first = Arc::new(
        licoup_workflow_runtime::driver::Driver::with_ownership(
            Arc::new(fixture.clone()),
            Arc::new(fixture.clone()),
            licoup_workflow_runtime::driver::OwnerId::new("host-a"),
            limits(1),
            Arc::clone(&ownership),
        )
        .expect("first driver"),
    );
    let second = licoup_workflow_runtime::driver::Driver::with_ownership(
        Arc::new(fixture.clone()),
        Arc::new(fixture.clone()),
        licoup_workflow_runtime::driver::OwnerId::new("host-b"),
        limits(1),
        Arc::clone(&ownership),
    )
    .expect("second driver");

    let driving = drive_in_background(Arc::clone(&first));
    fixture.wait_for("a invoked", |probe| probe.invoked("a"));

    let error = second
        .drive(RUN)
        .expect_err("the run is held by the first host");
    match error {
        DriverError::RunAlreadyOwned { holder, run_id } => {
            assert_eq!(holder.as_str(), "host-a");
            assert_eq!(run_id, RUN);
        }
        other => panic!("expected an ownership refusal, got {other}"),
    }
    assert_eq!(
        ownership.holder(RUN).map(|owner| owner.as_str().to_owned()),
        Some("host-a".to_owned())
    );
    assert_eq!(second.active_runs(), Vec::<String>::new());

    hold.open();
    let report = driving.report();
    assert_eq!(report.effects.succeeded, 1);
    // The first host released the run when its drive returned, and the second may
    // take it with a newer generation.
    assert!(ownership.holder(RUN).is_none());
    let second_report = second.drive(RUN).expect("the run is free again");
    assert_eq!(second_report.effects.claimed, 0, "its work is already done");
}

#[test]
fn a_stale_fence_cannot_renew_a_claim() {
    use licoup_workflow_runtime::ports::StatePort;

    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let first_hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&first_hold)));
    let driver = driver(&fixture, limits(1));

    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("a invoked", |probe| probe.invoked("a"));
    first_hold.open();
    let first = driving.report();
    assert_eq!(first.claimant, "host-a#1");
    assert_eq!(fixture.claimant_of("a").as_deref(), Some("host-a#1"));

    // A second command, claimed by a second drive call, is claimed under a newer
    // generation: that is the fence a late host runs into.
    fixture.declare("b", &[]);
    let second_hold = fixture.gate("hold:b");
    fixture.script("b", Script::Hold(Arc::clone(&second_hold)));
    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("b invoked", |probe| probe.invoked("b"));
    let live = driver
        .ownership()
        .holder(RUN)
        .map(|owner| format!("{}#{}", owner.as_str(), 2))
        .expect("the run is held again");

    // The owner that took the claim can renew it; the previous generation's
    // claimant cannot, which is what makes the fence a check rather than a
    // convention.
    assert!(
        fixture.renew_lease("b", &live, 0).is_ok(),
        "the owning claimant renews its claim"
    );
    let error = fixture
        .renew_lease("b", &first.claimant, 0)
        .expect_err("a stale fence must not renew the claim");
    assert!(
        error.to_string().contains("fixture_lease_not_held"),
        "{error}"
    );

    second_hold.open();
    let second = driving.report();
    assert_eq!(second.claimant, "host-a#2");
    assert_ne!(second.claimant, first.claimant);
}

#[test]
fn driving_twice_at_once_does_not_interleave() {
    let fixture = Fixture::new();
    fixture.declare("a", &[]);
    let hold = fixture.gate("hold:a");
    fixture.script("a", Script::Hold(Arc::clone(&hold)));
    let driver = driver(&fixture, limits(1));
    let driving = drive_in_background(Arc::clone(&driver));
    fixture.wait_for("a invoked", |probe| probe.invoked("a"));

    // A second drive of the same run from another thread is refused while the
    // first holds it, and the effects are not run twice.
    let error = driver.drive(RUN).expect_err("refused");
    assert!(matches!(error, DriverError::RunAlreadyOwned { .. }));
    assert_eq!(fixture.claims().len(), 1);

    hold.open();
    let report = driving.report();
    assert_eq!(report.effects.claimed, 1);
    assert_eq!(fixture.probe().invocations, vec!["a"]);
}
