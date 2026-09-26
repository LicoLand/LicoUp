//! Effect recovery: the claimed/started boundary, the sweep, and the
//! reconciliation exit.
//!
//! Every test here runs against a real database file through the assembled
//! ports. The question each one asks is the same: given durable facts, does
//! recovery dispatch anything a started effect left in doubt, and does it hold
//! when the evidence is only a clock, a silence, or a state that is not about
//! the effect at all?

use anyhow::Result;
use licoup_workflow::StrategyRunStatus;
use licoup_workflow_runtime::successor::recovery::{
    CheckpointAdmission, EFFECT_NOT_EXECUTED, EffectObservation, EffectSilence, HOST_RUNTIME_LOST,
    LEASE_EXPIRED_BEFORE_START, NotReachedProof, ReconcileOutcome, ReconcileRefusal,
    ReconcileSettlement, RecoveryCause, RecoveryPort, RecoveryRequest, UnconfirmedReason,
};
use serde_json::json;

use crate::support;

use crate::support::{Fixture, claim, future_ms, now_ms, past_ms, settle_command, start_command};

fn sweep(run_id: &str, cause: RecoveryCause) -> RecoveryRequest {
    RecoveryRequest {
        run_id: run_id.to_owned(),
        cause,
        now_unix_ms: now_ms(),
    }
}

/// The smallest stage: one actor command, claimed but never marked started.
fn claimed_before_start(label: &str) -> Result<(Fixture, licoup_workflow::RunCommand)> {
    let fixture = Fixture::with_definition(label, "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    let command = claim(&fixture.port(), "run-1", "work", "host-a#1", future_ms())?;
    support::expire_lease(&fixture, &command.id, past_ms())?;
    Ok((fixture, command))
}

/// A claimed command whose possible-effect marker is durable.
fn started(
    label: &str,
    lease_until_unix_ms: i64,
) -> Result<(Fixture, licoup_workflow::RunCommand)> {
    let fixture = Fixture::with_definition(label, "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    let command = claim(&fixture.port(), "run-1", "work", "host-a#1", future_ms())?;
    if lease_until_unix_ms < now_ms() {
        support::expire_lease(&fixture, &command.id, lease_until_unix_ms)?;
    }
    start_command(&fixture.port(), "run-1", &command)?;
    Ok((fixture, command))
}

#[test]
fn a_claim_that_never_reached_its_marker_is_retried_with_a_new_identity() -> Result<()> {
    let (fixture, command) = claimed_before_start("retry-claim")?;
    let recovery = fixture.recovery();
    let report = recovery.sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;

    assert_eq!(report.considered, 1);
    assert_eq!(report.retried.len(), 1, "the claim provably never ran");
    let retried = &report.retried[0];
    assert_eq!(retried.command_id, command.id);
    assert_eq!(retried.proof, NotReachedProof::MarkerAbsent);
    let replacement = retried
        .replacement
        .clone()
        .expect("the machine scheduled a replacement");
    assert_ne!(replacement, command.id, "a retry is a new identity");
    assert!(report.held.is_empty() && report.settled_unknown.is_empty());

    assert_eq!(fixture.command_row(&command.id)?.status, "cancelled");
    let replacement_row = fixture.command_row(&replacement)?;
    assert_eq!(replacement_row.status, "pending");
    assert_eq!(replacement_row.node_id, "work");
    assert_ne!(replacement_row.attempt_token, command.attempt_token);
    assert_eq!(
        fixture.snapshot("run-1")?.status,
        StrategyRunStatus::Running
    );
    Ok(())
}

#[test]
fn a_replayed_sweep_finds_nothing_left_to_retry() -> Result<()> {
    let (fixture, command) = claimed_before_start("retry-twice")?;
    let recovery = fixture.recovery();
    let first = recovery.sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;
    let replacement = first.retried[0].replacement.clone().expect("a replacement");

    let second = recovery.sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;
    assert!(
        second.retried.is_empty(),
        "the old attempt is cancelled, not outstanding"
    );
    assert!(!second.stale);
    assert_eq!(fixture.command_row(&command.id)?.status, "cancelled");
    assert_eq!(fixture.command_row(&replacement)?.status, "pending");
    assert_eq!(
        fixture.snapshot("run-1")?.status,
        StrategyRunStatus::Running
    );
    Ok(())
}

#[test]
fn a_started_attempt_is_held_after_its_lease_lapses() -> Result<()> {
    let (fixture, command) = started("started-lapsed", past_ms())?;
    let counter = support::DispatchCounter::new("started-lapsed");
    counter.record(&command.id);

    let before = fixture.snapshot_json("run-1")?;
    let report = fixture
        .recovery()
        .sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;

    assert_eq!(report.considered, 1);
    assert!(
        report.retried.is_empty(),
        "a started effect is never retried"
    );
    assert!(
        report.settled_unknown.is_empty(),
        "a clock is not a lost host"
    );
    assert_eq!(
        report.held[0].reason,
        UnconfirmedReason::LeaseLapsed {
            owner: "host-a#1".into()
        }
    );
    // The durable state is exactly what it was: same checkpoint, same claim,
    // one dispatch.
    assert_eq!(fixture.snapshot_json("run-1")?, before);
    let row = fixture.command_row(&command.id)?;
    assert_eq!(row.status, "running");
    assert_eq!(row.attempt_token, command.attempt_token);
    assert_eq!(counter.count(), 1);
    Ok(())
}

#[test]
fn a_lease_that_still_holds_is_not_stolen_from_its_owner() -> Result<()> {
    let (fixture, command) = started("started-live", future_ms())?;
    let report = fixture
        .recovery()
        .sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;

    assert!(report.retried.is_empty());
    assert_eq!(
        report.held[0].reason,
        UnconfirmedReason::LeaseHeld {
            owner: "host-a#1".into()
        },
        "another owner holds a live claim and may be working on it"
    );
    assert_eq!(fixture.command_row(&command.id)?.status, "running");
    Ok(())
}

#[test]
fn a_declared_lost_owner_records_its_started_attempt_as_unknown() -> Result<()> {
    let (fixture, command) = started("declared-lost", past_ms())?;
    let counter = support::DispatchCounter::new("declared-lost");
    counter.record(&command.id);
    let before = fixture.command_ids("run-1")?;

    let report = fixture.recovery().sweep(&sweep(
        "run-1",
        RecoveryCause::HostDeclaredLost {
            owner: "host-a#1".into(),
            source: "host-record".into(),
        },
    ))?;

    assert_eq!(report.settled_unknown, vec![command.id.clone()]);
    assert!(report.retried.is_empty(), "unknown is never re-dispatched");
    let row = fixture.command_row(&command.id)?;
    assert_eq!(row.status, "in-doubt");
    assert_eq!(
        fixture.snapshot("run-1")?.status,
        StrategyRunStatus::CancelInDoubt
    );
    assert_eq!(
        fixture.command_ids("run-1")?,
        before,
        "no replacement attempt was minted"
    );
    assert_eq!(counter.count(), 1);
    assert_eq!(
        fixture.recovery().outstanding("run-1")?.len(),
        0,
        "an in-doubt attempt is not outstanding work"
    );
    Ok(())
}

#[test]
fn a_declaration_does_not_cover_a_different_owners_attempt() -> Result<()> {
    let (fixture, command) = started("declared-other", past_ms())?;
    let before = fixture.snapshot_json("run-1")?;

    let report = fixture.recovery().sweep(&sweep(
        "run-1",
        RecoveryCause::HostDeclaredLost {
            owner: "host-b#2".into(),
            source: "host-record".into(),
        },
    ))?;

    assert!(report.settled_unknown.is_empty());
    assert_eq!(fixture.snapshot_json("run-1")?, before);
    let row = fixture.command_row(&command.id)?;
    assert_eq!(row.status, "running");
    assert_eq!(
        report.held[0].reason,
        UnconfirmedReason::DeclaredOwnerMismatch {
            claim_owner: "host-a#1".into(),
            declared: "host-b#2".into(),
        }
    );
    Ok(())
}

#[test]
fn a_lapsed_claim_is_retried_even_when_the_declaration_names_another_owner() -> Result<()> {
    // The proof is that the marker is absent, which does not depend on whose
    // process is gone; the declaration only decides what happens to a started
    // attempt, and there is none.
    let (fixture, command) = claimed_before_start("declared-claim")?;
    let report = fixture.recovery().sweep(&sweep(
        "run-1",
        RecoveryCause::HostDeclaredLost {
            owner: "host-b#2".into(),
            source: "host-record".into(),
        },
    ))?;
    assert_eq!(report.retried.len(), 1);
    assert_eq!(report.retried[0].command_id, command.id);
    assert_eq!(fixture.command_row(&command.id)?.status, "cancelled");
    Ok(())
}

#[test]
fn the_recovery_cause_set_has_no_variant_for_a_stopped_looking_writer() -> Result<()> {
    // The point is the absence of a cause, so it is asserted as an exhaustive
    // match rather than as prose: a directory that says "stopped", a missing
    // process, or a supervisor's assumption cannot be handed to recovery,
    // because there is no value to hand it.
    let cause = RecoveryCause::LeaseLapsed;
    let described = match cause {
        RecoveryCause::LeaseLapsed => "a clock",
        RecoveryCause::HostDeclaredLost { .. } => "a caller's declaration",
    };
    assert_eq!(described, "a clock");

    // And the behavior that follows: a started attempt with a lapsed lease is
    // held, not settled, no matter how the caller read a directory.
    let (fixture, command) = started("no-cause", past_ms())?;
    let report = fixture
        .recovery()
        .sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;
    assert!(report.settled_unknown.is_empty());
    assert_eq!(fixture.command_row(&command.id)?.status, "running");
    Ok(())
}

#[test]
fn a_confirmed_not_executed_observation_schedules_a_retry_for_a_started_attempt() -> Result<()> {
    let (fixture, command) = started("reconcile-not-executed", past_ms())?;
    let outcome = fixture.recovery().reconcile(
        "run-1",
        &command.id,
        &command.attempt_token,
        &EffectObservation::NotExecuted {
            source: "adapter".into(),
        },
    )?;

    let ReconcileOutcome::Settled {
        settlement,
        command_id,
        ..
    } = outcome
    else {
        panic!("the confirmed fact settles the attempt: {outcome:?}");
    };
    assert_eq!(command_id, command.id);
    assert_eq!(settlement, ReconcileSettlement::RetryScheduled);
    assert_eq!(fixture.command_row(&command.id)?.status, "cancelled");
    let receipts = fixture.receipts("run-1")?;
    assert_eq!(receipts.len(), 1);
    assert_eq!(receipts[0].2, "not_executed");
    assert_eq!(receipts[0].1, command.attempt_token);
    // The replacement is a real, claimable attempt for the same node and visit.
    let pending = fixture
        .snapshot("run-1")?
        .commands
        .values()
        .filter(|candidate| candidate.status == licoup_workflow::CommandStatus::Pending)
        .count();
    assert_eq!(pending, 1, "exactly one attempt is dispatchable");
    Ok(())
}

#[test]
fn a_silent_observation_holds_and_the_silence_is_recorded_as_unknown() -> Result<()> {
    let (fixture, command) = started("reconcile-silent", future_ms())?;
    let before = fixture.snapshot_json("run-1")?;
    let outcome = fixture.recovery().reconcile(
        "run-1",
        &command.id,
        &command.attempt_token,
        &EffectObservation::Silent {
            reason: EffectSilence::NoReadBackChannel,
        },
    )?;

    assert_eq!(
        outcome,
        ReconcileOutcome::Held {
            reason: UnconfirmedReason::ObservationSilent {
                reason: EffectSilence::NoReadBackChannel
            }
        }
    );
    assert_eq!(fixture.snapshot_json("run-1")?, before);
    assert_eq!(fixture.command_row(&command.id)?.status, "running");
    let receipts = fixture.receipts("run-1")?;
    assert_eq!(receipts.len(), 1);
    assert_eq!(receipts[0].2, "unknown");
    assert_eq!(receipts[0].3, None);
    Ok(())
}

#[test]
fn a_confirmed_outcome_settles_exactly_that_attempt() -> Result<()> {
    let (fixture, command) = started("reconcile-outcome", past_ms())?;
    let outcome = fixture.recovery().reconcile(
        "run-1",
        &command.id,
        &command.attempt_token,
        &EffectObservation::Outcome {
            event: licoup_workflow::ReducerEvent::CommandSucceeded {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                output: json!({"value": "observed"}),
            },
        },
    )?;

    assert_eq!(
        outcome,
        ReconcileOutcome::Settled {
            command_id: command.id.clone(),
            attempt_token: command.attempt_token.clone(),
            settlement: ReconcileSettlement::Succeeded,
        }
    );
    assert_eq!(fixture.command_row(&command.id)?.status, "succeeded");
    assert_eq!(
        fixture.snapshot("run-1")?.status,
        StrategyRunStatus::Completed
    );
    let receipts = fixture.receipts("run-1")?;
    assert_eq!(receipts[0].2, "executed");
    assert!(
        receipts[0].3.is_some(),
        "the observed result is recorded by digest"
    );
    Ok(())
}

#[test]
fn an_outcome_for_a_different_attempt_is_refused() -> Result<()> {
    let (fixture, command) = started("reconcile-stale", past_ms())?;
    let before = fixture.snapshot_json("run-1")?;
    let outcome = fixture.recovery().reconcile(
        "run-1",
        &command.id,
        &command.attempt_token,
        &EffectObservation::Outcome {
            event: licoup_workflow::ReducerEvent::CommandSucceeded {
                command_id: command.id.clone(),
                attempt_token: "attempt-from-another-host".into(),
                output: json!({"value": "late"}),
            },
        },
    )?;
    assert_eq!(
        outcome,
        ReconcileOutcome::Refused {
            reason: ReconcileRefusal::AttemptMismatch {
                command_id: command.id.clone()
            }
        }
    );
    assert_eq!(fixture.snapshot_json("run-1")?, before);
    Ok(())
}

#[test]
fn an_outcome_for_an_unknown_command_is_refused() -> Result<()> {
    let (fixture, _) = started("reconcile-unknown", past_ms())?;
    let outcome = fixture.recovery().reconcile(
        "run-1",
        "command-that-never-existed",
        "attempt",
        &EffectObservation::Silent {
            reason: EffectSilence::NoRecordedResult,
        },
    )?;
    assert_eq!(
        outcome,
        ReconcileOutcome::Refused {
            reason: ReconcileRefusal::UnknownCommand {
                command_id: "command-that-never-existed".into()
            }
        }
    );
    Ok(())
}

#[test]
fn a_late_outcome_after_a_lost_host_is_recorded_not_substituted() -> Result<()> {
    let (fixture, command) = started("reconcile-late", past_ms())?;
    let report = fixture.recovery().sweep(&sweep(
        "run-1",
        RecoveryCause::HostDeclaredLost {
            owner: "host-a#1".into(),
            source: "host-record".into(),
        },
    ))?;
    assert_eq!(report.settled_unknown, vec![command.id.clone()]);
    let settled = fixture.snapshot_json("run-1")?;

    let outcome = fixture.recovery().reconcile(
        "run-1",
        &command.id,
        &command.attempt_token,
        &EffectObservation::Outcome {
            event: licoup_workflow::ReducerEvent::CommandSucceeded {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                output: json!({"value": "really-happened"}),
            },
        },
    )?;

    assert_eq!(
        outcome,
        ReconcileOutcome::Recorded {
            command_id: command.id.clone(),
            attempt_token: command.attempt_token.clone(),
            settlement: ReconcileSettlement::Recorded,
        },
        "the run's settled history is not reopened; the fact is recorded"
    );
    assert_eq!(
        fixture.snapshot_json("run-1")?,
        settled,
        "the unknown settlement is not rewritten"
    );
    assert_eq!(fixture.command_row(&command.id)?.status, "in-doubt");
    let receipts = fixture.receipts("run-1")?;
    assert_eq!(receipts[0].2, "executed");
    assert!(
        receipts[0].3.is_none(),
        "a settlement the run recorded as unknown has no engine digest, and recovery does not mint one"
    );
    Ok(())
}

#[test]
fn a_confirmed_fact_that_contradicts_a_settled_outcome_is_refused() -> Result<()> {
    let fixture =
        Fixture::with_definition("reconcile-conflict", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    let port = fixture.port();
    let command = claim(&port, "run-1", "work", "host-a#1", future_ms())?;
    start_command(&port, "run-1", &command)?;
    settle_command(&port, "run-1", &command, json!({"value": "first"}))?;
    let settled = fixture.snapshot_json("run-1")?;

    let outcome = fixture.recovery().reconcile(
        "run-1",
        &command.id,
        &command.attempt_token,
        &EffectObservation::Outcome {
            event: licoup_workflow::ReducerEvent::CommandSucceeded {
                command_id: command.id.clone(),
                attempt_token: command.attempt_token.clone(),
                output: json!({"value": "second"}),
            },
        },
    )?;
    assert_eq!(
        outcome,
        ReconcileOutcome::Refused {
            reason: ReconcileRefusal::ConflictingSettlement {
                command_id: command.id.clone()
            }
        }
    );
    assert_eq!(fixture.snapshot_json("run-1")?, settled);
    Ok(())
}

#[test]
fn the_durable_codes_are_the_ones_the_contract_names() {
    assert_eq!(LEASE_EXPIRED_BEFORE_START, "lease_expired_before_start");
    assert_eq!(HOST_RUNTIME_LOST, "host_runtime_lost");
    assert_eq!(EFFECT_NOT_EXECUTED, "effect_not_executed");
}

#[test]
fn a_checkpoint_this_build_may_not_advance_blocks_the_sweep_without_error() -> Result<()> {
    let fixture = Fixture::with_definition("blocked-sweep", "run-1", &support::single_actor())?;
    fixture.start("run-1")?;
    // A checkpoint from before the causal state existed: the ledger fields are
    // absent, so advancing it would mean assuming an empty ledger.
    fixture.rewrite_snapshot("run-1", |value| {
        let removed = value
            .as_object_mut()
            .expect("the checkpoint is an object")
            .remove("joinArrivals");
        removed.is_some()
    })?;
    let before = fixture.snapshot_json("run-1")?;

    let recovery = fixture.recovery();
    assert_eq!(
        recovery.checkpoint_admission("run-1")?,
        CheckpointAdmission::Handoff {
            reason:
                licoup_workflow_runtime::successor::recovery::CheckpointHandoff::CausalStateMissing
        }
    );
    let report = recovery.sweep(&sweep("run-1", RecoveryCause::LeaseLapsed))?;
    assert_eq!(report.considered, 0);
    assert_eq!(
        report.block,
        Some(CheckpointAdmission::Handoff {
            reason:
                licoup_workflow_runtime::successor::recovery::CheckpointHandoff::CausalStateMissing
        })
    );
    let outcome = recovery.reconcile(
        "run-1",
        "any",
        "any",
        &EffectObservation::Silent {
            reason: EffectSilence::NoReadBackChannel,
        },
    )?;
    assert!(matches!(
        outcome,
        ReconcileOutcome::Refused {
            reason: ReconcileRefusal::Rejected { .. }
        }
    ));
    assert_eq!(fixture.snapshot_json("run-1")?, before);
    Ok(())
}

#[test]
fn a_mixed_epoch_ledger_survives_recovery_writing_around_it() -> Result<()> {
    let fixture =
        Fixture::with_definition("mixed-epoch", "run-1", &support::mixed_epoch_fork_join())?;
    let live = support::stage_mixed_epoch(&fixture)?;

    let staged = fixture.snapshot("run-1")?;
    assert_eq!(
        staged.status,
        StrategyRunStatus::Waiting,
        "a mixed epoch does not satisfy the join"
    );
    assert_eq!(
        staged.diagnostic_code.as_deref(),
        Some("strategy_join_waiting")
    );
    let ledger = &staged.join_arrivals["join"];
    assert_eq!(ledger.arrivals["branch-a"].node_visit, 2);
    assert_eq!(ledger.arrivals["branch-b"].node_visit, 1);
    assert_eq!(ledger.arrivals["branch-c"].node_visit, 1);

    let report = fixture.recovery().sweep(&sweep(
        "run-1",
        RecoveryCause::HostDeclaredLost {
            owner: "host-a#1".into(),
            source: "host-record".into(),
        },
    ))?;
    assert_eq!(report.settled_unknown, vec![live.id.clone()]);

    // The write recovery made did not touch the causal ledger: both visits are
    // still there, the join still has not fired, and the old visit was not
    // promoted to the newer one.
    let after = fixture.snapshot("run-1")?;
    assert_eq!(
        after.state_visits.get("join").copied(),
        None,
        "the join never fired on a mixed epoch"
    );
    let ledger = &after.join_arrivals["join"];
    assert_eq!(ledger.arrivals["branch-a"].node_visit, 2);
    assert_eq!(ledger.arrivals["branch-b"].node_visit, 1);
    assert_eq!(ledger.arrivals["branch-c"].node_visit, 1);
    assert_eq!(fixture.command_row(&live.id)?.status, "in-doubt");
    Ok(())
}
