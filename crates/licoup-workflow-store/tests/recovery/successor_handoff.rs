//! Successor handoff: the compare-and-set, what stays with the old owner, and
//! what a boundary result does and does not grant.
//!
//! The fixture stages a run at exactly the boundary the contract is about: one
//! settled branch (a result to name), one live attempt (started, and staying
//! with the owner that started it), and one queued intent (the successor's to
//! start, exactly once). Each test then changes one fact the manifest was built
//! from and asserts the handoff refuses whole.

use anyhow::{Result, anyhow};
use licoup_workflow::compile::RecordedPlanKey;
use licoup_workflow::{CommandStatus, ResultRef, RunCommand};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_runtime::successor::handoff::{
    ClaimAdmission, HandoffOutcome, HandoffRefusal, LiveAttempt, SuccessorManifest, SuccessorPort,
    UnstartedIntent,
};
use licoup_workflow_runtime::successor::recovery::EffectBoundary;
use serde_json::json;

use crate::support;

use crate::support::{Fixture, future_ms, settle_command, start_command};

/// A run staged at a handoff boundary.
struct Boundary {
    fixture: Fixture,
    started: RunCommand,
    queued: RunCommand,
    settled: RunCommand,
    revision: u64,
    settled_result: ResultRef,
}

impl Boundary {
    fn stage(label: &str) -> Result<Self> {
        let fixture = Fixture::with_definition(label, "run-1", &support::three_branch_fork_join())?;
        fixture.start("run-1")?;
        let port = fixture.port();

        // The store's claim path decides which branch comes back first, so the
        // boundary is staged by role: one attempt starts and stays live, one
        // settles (which records the result the boundary may name), and one
        // stays queued for the successor.
        let started = support::claim_next(&port, "run-1", "host-a#1", future_ms())?;
        start_command(&port, "run-1", &started)?;
        let settled = support::claim_next(&port, "run-1", "host-a#1", future_ms())?;
        settle_command(&port, "run-1", &settled, json!({"value": "settled"}))?;
        let pending = support::pending_commands(&fixture, "run-1")?;
        let queued = pending
            .first()
            .cloned()
            .ok_or_else(|| anyhow!("one branch stays queued"))?;

        let snapshot = fixture.snapshot("run-1")?;
        let settled_result = snapshot.join_arrivals["join"].arrivals[&settled.state_id]
            .result
            .clone();
        Ok(Self {
            fixture,
            started,
            queued,
            settled,
            revision: snapshot.sequence,
            settled_result,
        })
    }

    fn manifest(&self, handoff_id: &str) -> SuccessorManifest {
        SuccessorManifest {
            handoff_id: handoff_id.to_owned(),
            run_id: "run-1".to_owned(),
            expected_revision: self.revision,
            old_owner: "host-a#1".to_owned(),
            new_owner: "host-b#2".to_owned(),
            old_binding: self.fixture.binding(),
            new_owner_profile: self.fixture.profile(),
            unstarted: vec![UnstartedIntent {
                command_id: self.queued.id.clone(),
                attempt_token: self.queued.attempt_token.clone(),
                node_id: self.queued.state_id.clone(),
                node_visit: self.queued.state_visit,
            }],
            started: vec![LiveAttempt {
                command_id: self.started.id.clone(),
                attempt_token: self.started.attempt_token.clone(),
                node_id: self.started.state_id.clone(),
                node_visit: self.started.state_visit,
                phase: EffectBoundary::Started,
            }],
        }
    }

    fn refuse(outcome: HandoffOutcome) -> HandoffRefusal {
        match outcome {
            HandoffOutcome::Refused { refusal } => refusal,
            other => panic!("expected a refusal, got {other:?}"),
        }
    }
}

#[test]
fn a_matching_manifest_transfers_the_unstarted_set_once() -> Result<()> {
    let boundary = Boundary::stage("handoff-ok")?;
    let before_started = boundary.fixture.command_row(&boundary.started.id)?;
    let before_settled = boundary.fixture.command_row(&boundary.settled.id)?;
    let commands_before = boundary.fixture.command_ids("run-1")?;
    let status_before = boundary.fixture.snapshot("run-1")?.status;

    let outcome = boundary
        .fixture
        .successor()
        .handoff(&boundary.manifest("handoff-1"))?;
    let HandoffOutcome::Committed { receipt } = outcome else {
        panic!("the matching manifest commits: {outcome:?}");
    };

    assert_eq!(receipt.handoff_id, "handoff-1");
    assert_eq!(receipt.revision, boundary.revision);
    assert_eq!(receipt.migrated.len(), 1);
    assert_eq!(receipt.migrated[0].command_id, boundary.queued.id);
    assert_eq!(receipt.started.len(), 1);
    assert_eq!(receipt.started[0].command_id, boundary.started.id);
    assert!(
        receipt.boundary.results.contains(&boundary.settled_result),
        "the settled branch's result is named at the boundary"
    );
    assert!(
        receipt
            .boundary
            .results
            .iter()
            .all(|result| result.run_id == "run-1"),
        "only this run's own committed results are named"
    );
    assert!(
        !receipt.boundary.may_read(&boundary.settled_result),
        "a boundary result is a reference, never an implicit read grant"
    );
    assert!(receipt.boundary.grants.is_empty());

    // The record is readable afterwards and names the same facts.
    let record = boundary
        .fixture
        .successor()
        .successor_of("run-1")?
        .ok_or_else(|| anyhow!("the handoff is durable"))?;
    assert_eq!(record.handoff_id, "handoff-1");
    assert_eq!(record.boundary.results, receipt.boundary.results);
    assert_eq!(record.migrated, receipt.migrated);
    assert_eq!(record.started, receipt.started);

    // Nothing was rewritten: the live attempt and the settled result are the
    // same rows, and no attempt was minted for the started visit.
    assert_eq!(
        boundary.fixture.command_row(&boundary.started.id)?.status,
        before_started.status
    );
    assert_eq!(
        boundary.fixture.command_row(&boundary.settled.id)?.status,
        before_settled.status
    );
    assert_eq!(boundary.fixture.command_ids("run-1")?, commands_before);
    assert_eq!(
        boundary.fixture.snapshot("run-1")?.status,
        status_before,
        "a handoff moves the work, not the run's own state"
    );
    Ok(())
}

#[test]
fn the_handoff_fences_the_old_owner_and_admits_the_new_one() -> Result<()> {
    let boundary = Boundary::stage("handoff-fence")?;
    let successor = boundary.fixture.successor();

    assert_eq!(
        successor.claim_admission("run-1", "host-a#1")?,
        ClaimAdmission::Admitted,
        "no handoff yet: the owner is admitted"
    );
    let outcome = successor.handoff(&boundary.manifest("handoff-fence"))?;
    assert!(matches!(outcome, HandoffOutcome::Committed { .. }));

    let fenced = successor.claim_admission("run-1", "host-a#1")?;
    assert!(
        matches!(fenced, ClaimAdmission::Fenced { ref new_owner, .. } if new_owner == "host-b#2"),
        "the old fence may not start new work: {fenced:?}"
    );
    assert_eq!(
        successor.claim_admission("run-1", "host-b#2")?,
        ClaimAdmission::Admitted
    );
    assert_eq!(
        successor.claim_admission("run-1", "host-c#3")?,
        successor.claim_admission("run-1", "host-a#1")?,
        "any owner but the successor is fenced"
    );

    // Through the fenced state port: the old owner gets no new work, the
    // successor gets the queued intent, and the started attempt is untouched.
    let fenced_state = boundary.fixture.fenced_state();
    assert!(
        fenced_state
            .claim_next("run-1", "host-a#1", future_ms())?
            .is_none(),
        "a fenced owner is told there is no work"
    );
    let claimed = fenced_state
        .claim_next("run-1", "host-b#2", future_ms())?
        .ok_or_else(|| anyhow!("the successor claims the migrated intent"))?;
    assert_eq!(claimed.id, boundary.queued.id);
    let started = boundary.fixture.command_row(&boundary.started.id)?;
    assert_eq!(started.status, "running");
    assert_eq!(started.lease_owner.as_deref(), Some("host-a#1"));
    Ok(())
}

#[test]
fn the_old_owner_may_still_settle_what_it_started_after_the_handoff() -> Result<()> {
    let boundary = Boundary::stage("handoff-settle")?;
    let outcome = boundary
        .fixture
        .successor()
        .handoff(&boundary.manifest("handoff-settle"))?;
    assert!(matches!(outcome, HandoffOutcome::Committed { .. }));

    // Settling is not starting: the same owner commits the outcome of its own
    // attempt through the fenced port.
    let fenced_state = boundary.fixture.fenced_state();
    let sequence = fenced_state.checkpoint("run-1")?.sequence;
    let settled = fenced_state.commit(
        "run-1",
        sequence,
        licoup_workflow::ReducerEvent::CommandSucceeded {
            command_id: boundary.started.id.clone(),
            attempt_token: boundary.started.attempt_token.clone(),
            output: json!({"value": "from-a"}),
        },
    )?;
    assert_eq!(
        settled
            .commands
            .get(&boundary.started.id)
            .map(|command| command.status),
        Some(CommandStatus::Succeeded)
    );
    assert_eq!(
        settled
            .commands
            .get(&boundary.queued.id)
            .map(|command| command.status),
        Some(CommandStatus::Pending),
        "the migrated intent is still queued, not replaced"
    );
    Ok(())
}

#[test]
fn a_second_handoff_is_refused_with_the_identity_of_the_first() -> Result<()> {
    let boundary = Boundary::stage("handoff-second")?;
    let successor = boundary.fixture.successor();
    let first = successor.handoff(&boundary.manifest("handoff-first"))?;
    assert!(matches!(first, HandoffOutcome::Committed { .. }));

    let second = successor.handoff(&boundary.manifest("handoff-second"))?;
    assert_eq!(
        Boundary::refuse(second),
        HandoffRefusal::AlreadyHandedOff {
            handoff_id: "handoff-first".into()
        }
    );
    assert_eq!(
        boundary
            .fixture
            .count("workflow_successor_handoffs", "run_id='run-1'"),
        1,
        "one handoff per run is a constraint, not a convention"
    );
    Ok(())
}

#[test]
fn a_revision_that_moved_refuses_the_handoff() -> Result<()> {
    let boundary = Boundary::stage("handoff-revision")?;
    // A concurrent writer advances the run after the manifest was built.
    let port = boundary.fixture.port();
    let command = support::claim_next(&port, "run-1", "host-a#1", future_ms())?;
    start_command(&port, "run-1", &command)?;
    settle_command(&port, "run-1", &command, json!({"value": "advanced"}))?;
    assert_ne!(
        boundary.fixture.snapshot("run-1")?.sequence,
        boundary.revision
    );

    let outcome = boundary
        .fixture
        .successor()
        .handoff(&boundary.manifest("handoff-revision"))?;
    let HandoffRefusal::RevisionMoved { expected, current } = Boundary::refuse(outcome) else {
        panic!("a moved revision must refuse");
    };
    assert_eq!(expected, boundary.revision);
    assert_ne!(current, boundary.revision);
    assert_eq!(
        boundary
            .fixture
            .count("workflow_successor_handoffs", "run_id='run-1'"),
        0,
        "a refusal transfers nothing"
    );
    Ok(())
}

#[test]
fn a_live_claim_by_another_owner_refuses_the_handoff() -> Result<()> {
    let boundary = Boundary::stage("handoff-owner")?;
    let mut manifest = boundary.manifest("handoff-owner");
    manifest.old_owner = "host-z#9".to_owned();

    let outcome = boundary.fixture.successor().handoff(&manifest)?;
    let HandoffRefusal::OwnerMoved { expected, current } = Boundary::refuse(outcome) else {
        panic!("a foreign live claim must refuse");
    };
    assert_eq!(expected, "host-z#9");
    assert_eq!(current.as_deref(), Some("host-a#1"));
    assert_eq!(
        boundary
            .fixture
            .count("workflow_successor_handoffs", "run_id='run-1'"),
        0
    );
    Ok(())
}

#[test]
fn a_started_attempt_may_not_be_listed_as_unstarted() -> Result<()> {
    let boundary = Boundary::stage("handoff-unstarted")?;
    let mut manifest = boundary.manifest("handoff-unstarted");
    // The claim that a started attempt is queued work.
    manifest.unstarted.push(UnstartedIntent {
        command_id: boundary.started.id.clone(),
        attempt_token: boundary.started.attempt_token.clone(),
        node_id: boundary.started.state_id.clone(),
        node_visit: boundary.started.state_visit,
    });
    manifest.started.clear();

    let outcome = boundary.fixture.successor().handoff(&manifest)?;
    let refusal = Boundary::refuse(outcome);
    assert!(
        matches!(
            refusal,
            HandoffRefusal::UnstartedSetMoved { ref command_id, in_store: false }
                if *command_id == boundary.started.id
        ),
        "a started attempt is not in the store's unstarted set: {refusal:?}"
    );
    assert_eq!(
        boundary
            .fixture
            .count("workflow_successor_handoffs", "run_id='run-1'"),
        0,
        "no partial transfer"
    );
    // And the live attempt is exactly where it was.
    assert_eq!(
        boundary.fixture.command_row(&boundary.started.id)?.status,
        "running"
    );
    Ok(())
}

#[test]
fn a_started_attempt_omitted_from_the_manifest_refuses_the_handoff() -> Result<()> {
    let boundary = Boundary::stage("handoff-omitted")?;
    let mut manifest = boundary.manifest("handoff-omitted");
    manifest.started.clear();

    let outcome = boundary.fixture.successor().handoff(&manifest)?;
    let refusal = Boundary::refuse(outcome);
    assert!(
        matches!(
            refusal,
            HandoffRefusal::StartedSetMoved { ref command_id, in_store: true }
                if *command_id == boundary.started.id
        ),
        "unexpected refusal: {refusal:?}"
    );
    Ok(())
}

#[test]
fn an_attempt_that_started_after_the_manifest_refuses_with_phase_moved() -> Result<()> {
    let fixture =
        Fixture::with_definition("handoff-phase", "run-1", &support::three_branch_fork_join())?;
    fixture.start("run-1")?;
    let port = fixture.port();
    let command = support::claim_next(&port, "run-1", "host-a#1", future_ms())?;
    // The manifest is built while the attempt is only claimed.
    let manifest =
        support::manifest_from(&fixture, "run-1", "handoff-phase", "host-a#1", "host-b#2")?;
    assert_eq!(manifest.started.len(), 1);
    assert_eq!(manifest.started[0].command_id, command.id);
    let mut manifest = SuccessorManifest {
        started: vec![LiveAttempt {
            phase: EffectBoundary::Claimed,
            ..manifest.started[0].clone()
        }],
        ..manifest
    };
    // Then it starts, which is exactly the window the phase comparison exists
    // for: the command identity did not change, the fact did. The revision is
    // re-read, as a caller that retried the handoff would, so the comparison
    // under test is the visit set rather than the revision.
    start_command(&port, "run-1", &command)?;
    manifest.expected_revision = fixture.snapshot("run-1")?.sequence;

    let outcome = fixture.successor().handoff(&manifest)?;
    assert_eq!(
        Boundary::refuse(outcome),
        HandoffRefusal::PhaseMoved {
            command_id: command.id.clone(),
            manifest: EffectBoundary::Claimed,
            current: EffectBoundary::Started,
        }
    );
    assert_eq!(
        fixture.count("workflow_successor_handoffs", "run_id='run-1'"),
        0
    );
    Ok(())
}

#[test]
fn a_binding_this_build_cannot_prove_is_handed_off() -> Result<()> {
    let boundary = Boundary::stage("handoff-semantics")?;
    let mut manifest = boundary.manifest("handoff-semantics");
    manifest.old_binding = RecordedPlanKey {
        definition_revision: boundary.fixture.revision_digest().to_owned(),
        compiler_semantics: "compiler-semantics-from-a-future-line".into(),
        engine_semantics: licoup_workflow::compile::EngineSemantics::CURRENT.wire(),
        lowering_capabilities: Vec::new(),
    };

    let outcome = boundary.fixture.successor().handoff(&manifest)?;
    let refusal = Boundary::refuse(outcome);
    assert!(
        matches!(
            refusal,
            HandoffRefusal::SemanticsHandoff {
                reason: licoup_workflow_runtime::successor::handoff::SemanticsHandoffReason::UnprovenSemantics
            }
        ),
        "an unprovable binding is handed off, not reinterpreted: {refusal:?}"
    );
    assert_eq!(
        boundary
            .fixture
            .count("workflow_successor_handoffs", "run_id='run-1'"),
        0
    );
    Ok(())
}

#[test]
fn a_binding_that_names_another_revision_refuses_the_handoff() -> Result<()> {
    let boundary = Boundary::stage("handoff-binding")?;
    let mut manifest = boundary.manifest("handoff-binding");
    manifest.old_binding = RecordedPlanKey {
        definition_revision: "revision-that-is-not-this-run".into(),
        ..boundary.fixture.binding()
    };

    let outcome = boundary.fixture.successor().handoff(&manifest)?;
    assert!(matches!(
        Boundary::refuse(outcome),
        HandoffRefusal::BindingMismatch { .. }
    ));
    Ok(())
}

#[test]
fn an_old_checkpoint_is_not_transferred() -> Result<()> {
    let boundary = Boundary::stage("handoff-old")?;
    boundary.fixture.rewrite_snapshot("run-1", |value| {
        value
            .as_object_mut()
            .expect("the checkpoint is an object")
            .remove("inputPlan")
            .is_some()
    })?;

    let outcome = boundary
        .fixture
        .successor()
        .handoff(&boundary.manifest("handoff-old"))?;
    let refusal = Boundary::refuse(outcome);
    assert!(
        matches!(
            refusal,
            HandoffRefusal::Checkpoint {
                reason: licoup_workflow_runtime::successor::recovery::CheckpointHandoff::CausalStateMissing
            }
        ),
        "unexpected refusal: {refusal:?}"
    );
    assert_eq!(
        boundary
            .fixture
            .count("workflow_successor_handoffs", "run_id='run-1'"),
        0
    );
    Ok(())
}

#[test]
fn a_manifest_for_an_unknown_run_refuses() -> Result<()> {
    let boundary = Boundary::stage("handoff-missing")?;
    let mut manifest = boundary.manifest("handoff-missing");
    manifest.run_id = "run-that-never-existed".to_owned();
    manifest.expected_revision = 0;
    manifest.unstarted.clear();
    manifest.started.clear();

    let outcome = boundary.fixture.successor().handoff(&manifest)?;
    assert_eq!(
        Boundary::refuse(outcome),
        HandoffRefusal::RunNotFound {
            run_id: "run-that-never-existed".into()
        }
    );
    Ok(())
}

#[test]
fn a_mixed_epoch_boundary_names_the_visit_each_result_came_from() -> Result<()> {
    let fixture =
        Fixture::with_definition("handoff-mixed", "run-1", &support::mixed_epoch_fork_join())?;
    support::stage_mixed_epoch(&fixture)?;

    let snapshot = fixture.snapshot("run-1")?;
    assert_eq!(snapshot.state_visits.get("join").copied(), None);
    let manifest =
        support::manifest_from(&fixture, "run-1", "handoff-mixed", "host-a#1", "host-b#2")?;
    let outcome = fixture.successor().handoff(&manifest)?;
    let HandoffOutcome::Committed { receipt } = outcome else {
        panic!("the boundary commits: {outcome:?}");
    };
    let visits: Vec<(&str, u64)> = receipt
        .boundary
        .results
        .iter()
        .map(|result| (result.node_id.as_str(), result.node_visit))
        .collect();
    assert!(
        visits.contains(&("branch-a", 2)),
        "the newer visit is named as the newer visit: {visits:?}"
    );
    assert!(
        visits
            .iter()
            .all(|(node, visit)| *node != "branch-a" || *visit == 2),
        "the old visit is never promoted to a newer one: {visits:?}"
    );
    assert!(
        receipt
            .boundary
            .results
            .iter()
            .all(|result| !receipt.boundary.may_read(result)),
        "no result is readable through the boundary"
    );
    let after = fixture.snapshot("run-1")?;
    assert_eq!(after.state_visits.get("join").copied(), None);
    assert_eq!(
        after.join_arrivals["join"].arrivals["branch-a"].node_visit,
        2
    );
    assert_eq!(
        after.join_arrivals["join"].arrivals["branch-b"].node_visit,
        1
    );
    Ok(())
}
