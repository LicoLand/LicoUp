//! Effect recovery over the command rows: classification, the recovery sweep,
//! and the reconciliation exit.
//!
//! Everything in this file reads durable facts and — when it acts — commits
//! through the same reducer and the same compare-and-set the drive uses. The
//! decision itself is the runtime's ([`decide`]), so a host that wants to know
//! what recovery *would* do can ask without touching the database, and the
//! store cannot invent a conclusion the contract does not have.

use std::sync::Arc;

use anyhow::{Result, anyhow};
use licoup_workflow::{
    CommandStatus, FailureClass, INPUT_ADAPTER_VERSION, ReducerEvent, RunCommand, RunSnapshot,
};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_runtime::successor::recovery::{
    CheckpointAdmission, CheckpointHandoff, ClaimStanding, EFFECT_NOT_EXECUTED, EffectBoundary,
    EffectObservation, HOST_RUNTIME_LOST, HeldAttempt, LEASE_EXPIRED_BEFORE_START,
    OutstandingEffect, ReconcileOutcome, ReconcileRefusal, ReconcileSettlement, RecoveryDecision,
    RecoveryPort, RecoveryReport, RecoveryRequest, RefusedAttempt, RetriedAttempt,
    UnconfirmedReason, decide,
};
use rusqlite::{Connection, OptionalExtension, params};

use crate::transactions::{StoreStatePort, WorkflowDatabase, now_unix_ms};

/// The effect-recovery port over one workflow database.
pub struct StoreRecovery {
    database: Arc<WorkflowDatabase>,
    state: StoreStatePort,
}

impl StoreRecovery {
    pub(super) fn new(database: Arc<WorkflowDatabase>) -> Self {
        Self {
            state: StoreStatePort::new(database.clone()),
            database,
        }
    }

    /// Whether this build may advance the run's checkpoint, with the reason.
    fn admission(&self, run_id: &str) -> Result<CheckpointAdmission> {
        self.database.read(|connection| {
            let Some((snapshot_json, revision_digest, semantics_digest)) =
                run_row(connection, run_id)?
            else {
                return Ok(CheckpointAdmission::Refused {
                    code: "workflow_run_not_found".to_owned(),
                });
            };
            let definition = definition_semantics(connection, &revision_digest)?;
            Ok(admission_of(
                &snapshot_json,
                &semantics_digest,
                definition.as_deref(),
            ))
        })
    }

    /// One attempt, re-read so a decision is always made from current facts.
    fn attempt(
        &self,
        run_id: &str,
        command_id: &str,
        now_unix_ms: i64,
    ) -> Result<Option<OutstandingEffect>> {
        self.database
            .read(|connection| outstanding_attempt(connection, run_id, command_id, now_unix_ms))
    }

    /// Commit one reducer event with the caller's expected sequence.
    fn commit(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
    ) -> Result<CommitAttempt> {
        match self.state.commit(run_id, expected_sequence, event) {
            Ok(snapshot) => Ok(CommitAttempt::Applied(Box::new(snapshot))),
            Err(error) => {
                let code = leading_code(&error);
                if code == "workflow_state_sequence_stale" {
                    Ok(CommitAttempt::Stale)
                } else {
                    Ok(CommitAttempt::Refused(code))
                }
            }
        }
    }

    /// Record one reconciliation fact. Returns whether the store accepted it.
    ///
    /// A silent observation may be upgraded by a confirmed one — silence is not
    /// a fact about the effect. A confirmed fact is never overwritten: a second,
    /// differing confirmation is a conflict.
    fn record_reconciliation(
        &self,
        effect: &OutstandingEffect,
        outcome: &str,
        evidence: &str,
        result_digest: Option<&str>,
        observed_at: i64,
    ) -> Result<RecordOutcome> {
        let (recorded, _) = self.database.write(|transaction, _| {
            let existing: Option<(String, Option<String>)> = transaction
                .query_row(
                    "SELECT outcome, result_digest FROM workflow_effect_reconciliations
                     WHERE run_id=?1 AND command_id=?2 AND attempt_token=?3",
                    params![effect.run_id, effect.command_id, effect.attempt_token],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            match existing {
                None => {
                    transaction.execute(
                        "INSERT INTO workflow_effect_reconciliations(
                           run_id, command_id, attempt_token, node_id, node_visit, outcome,
                           evidence, result_digest, observed_at
                         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                        params![
                            effect.run_id,
                            effect.command_id,
                            effect.attempt_token,
                            effect.node_id,
                            effect.node_visit as i64,
                            outcome,
                            evidence,
                            result_digest,
                            observed_at
                        ],
                    )?;
                    Ok(RecordOutcome::Recorded)
                }
                Some((recorded, recorded_digest)) => {
                    if recorded == outcome && recorded_digest.as_deref() == result_digest {
                        return Ok(RecordOutcome::Unchanged);
                    }
                    if recorded == "unknown" {
                        transaction.execute(
                            "UPDATE workflow_effect_reconciliations
                             SET outcome=?4, evidence=?5, result_digest=?6, observed_at=?7
                             WHERE run_id=?1 AND command_id=?2 AND attempt_token=?3",
                            params![
                                effect.run_id,
                                effect.command_id,
                                effect.attempt_token,
                                outcome,
                                evidence,
                                result_digest,
                                observed_at
                            ],
                        )?;
                        return Ok(RecordOutcome::Recorded);
                    }
                    Ok(RecordOutcome::Conflict)
                }
            }
        })?;
        Ok(recorded)
    }
}

impl RecoveryPort for StoreRecovery {
    fn checkpoint_admission(&self, run_id: &str) -> Result<CheckpointAdmission> {
        self.admission(run_id)
    }

    fn outstanding(&self, run_id: &str) -> Result<Vec<OutstandingEffect>> {
        let now = now_unix_ms();
        self.database.read(|connection| {
            let mut statement = connection.prepare(
                "SELECT command_id FROM strategy_commands
                 WHERE run_id=?1 AND status IN ('pending', 'claimed', 'running',
                                                'retryable', 'cancel-requested')
                 ORDER BY command_id ASC",
            )?;
            let ids = statement
                .query_map(params![run_id], |row| row.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let mut effects = Vec::new();
            for command_id in ids {
                if let Some(effect) = outstanding_attempt(connection, run_id, &command_id, now)? {
                    effects.push(effect);
                }
            }
            Ok(effects)
        })
    }

    fn sweep(&self, request: &RecoveryRequest) -> Result<RecoveryReport> {
        let mut report = RecoveryReport {
            run_id: request.run_id.clone(),
            ..RecoveryReport::default()
        };
        let admission = self.admission(&request.run_id)?;
        if !matches!(admission, CheckpointAdmission::Advance) {
            // A checkpoint this build may not advance is not a recovery error:
            // it is the handoff the causal-input contract requires.
            report.block = Some(admission);
            return Ok(report);
        }
        let outstanding = self.outstanding(&request.run_id)?;
        report.considered = outstanding.len();
        for effect in outstanding {
            // Re-read: every decision below is made from the row as it is now,
            // and every commit re-checks its sequence. A pass interrupted by
            // another writer keeps what it committed and reports `stale`.
            let Some(effect) =
                self.attempt(&request.run_id, &effect.command_id, request.now_unix_ms)?
            else {
                continue;
            };
            match decide(&effect, request) {
                RecoveryDecision::Queued => {}
                RecoveryDecision::Hold { reason } => report.held.push(HeldAttempt {
                    command_id: effect.command_id.clone(),
                    attempt_token: effect.attempt_token.clone(),
                    reason,
                }),
                RecoveryDecision::Retry { proof } => match self.schedule_retry(&effect)? {
                    RetryAttempt::Scheduled { replacement } => {
                        report.retried.push(RetriedAttempt {
                            command_id: effect.command_id,
                            attempt_token: effect.attempt_token,
                            replacement: Some(replacement),
                            proof,
                        })
                    }
                    RetryAttempt::SettledWithoutReplacement => {
                        report.retried.push(RetriedAttempt {
                            command_id: effect.command_id,
                            attempt_token: effect.attempt_token,
                            replacement: None,
                            proof,
                        });
                    }
                    RetryAttempt::NotOutstanding => report.stale = true,
                    RetryAttempt::Stale => report.stale = true,
                    RetryAttempt::Refused(code) => report.refusals.push(RefusedAttempt {
                        command_id: effect.command_id,
                        code,
                    }),
                },
                RecoveryDecision::SettleUnknown { .. } => {
                    match self.settle_unknown(&effect, HOST_RUNTIME_LOST)? {
                        SettleAttempt::Settled => report.settled_unknown.push(effect.command_id),
                        SettleAttempt::NotOutstanding | SettleAttempt::Stale => report.stale = true,
                        SettleAttempt::Refused(code) => {
                            report.refusals.push(RefusedAttempt {
                                command_id: effect.command_id,
                                code,
                            });
                        }
                    }
                }
            }
        }
        Ok(report)
    }

    fn reconcile(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
        observation: &EffectObservation,
    ) -> Result<ReconcileOutcome> {
        match self.admission(run_id)? {
            CheckpointAdmission::Advance => {}
            CheckpointAdmission::Handoff { reason } => {
                return Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::Rejected {
                        code: reason.wire().to_owned(),
                    },
                });
            }
            CheckpointAdmission::Refused { code } => {
                return Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::Rejected { code },
                });
            }
        }
        let snapshot = self.state.checkpoint(run_id)?;
        let command = match snapshot.commands.get(command_id) {
            None => {
                return Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::UnknownCommand {
                        command_id: command_id.to_owned(),
                    },
                });
            }
            Some(command) if command.attempt_token != attempt_token => {
                return Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::AttemptMismatch {
                        command_id: command_id.to_owned(),
                    },
                });
            }
            Some(command) => command.clone(),
        };
        let effect = OutstandingEffect {
            run_id: run_id.to_owned(),
            command_id: command_id.to_owned(),
            attempt_token: attempt_token.to_owned(),
            node_id: command.state_id.clone(),
            node_visit: command.state_visit,
            boundary: boundary_of(command.status),
            claim: ClaimStanding::Unclaimed,
            output_digest: command.output_digest.clone(),
        };
        let now = now_unix_ms();
        match observation {
            EffectObservation::Silent { reason } => {
                match self.record_reconciliation(&effect, "unknown", reason.wire(), None, now)? {
                    RecordOutcome::Conflict => Ok(ReconcileOutcome::Refused {
                        reason: ReconcileRefusal::ConflictingSettlement {
                            command_id: command_id.to_owned(),
                        },
                    }),
                    _ => Ok(ReconcileOutcome::Held {
                        reason: UnconfirmedReason::ObservationSilent { reason: *reason },
                    }),
                }
            }
            EffectObservation::NotExecuted { source } => {
                self.apply_not_executed(&effect, source, &snapshot, now)
            }
            EffectObservation::Outcome { event } => {
                self.apply_outcome(&effect, event, &snapshot, now)
            }
        }
    }
}

impl StoreRecovery {
    /// A confirmed not-executed fact: the one observation that unlocks a retry.
    fn apply_not_executed(
        &self,
        effect: &OutstandingEffect,
        source: &str,
        snapshot: &RunSnapshot,
        now: i64,
    ) -> Result<ReconcileOutcome> {
        if effect.boundary == EffectBoundary::Settled {
            return match self.record_reconciliation(effect, "not_executed", source, None, now)? {
                RecordOutcome::Conflict => Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::ConflictingSettlement {
                        command_id: effect.command_id.clone(),
                    },
                }),
                _ => Ok(ReconcileOutcome::Recorded {
                    command_id: effect.command_id.clone(),
                    attempt_token: effect.attempt_token.clone(),
                    settlement: ReconcileSettlement::Recorded,
                }),
            };
        }
        let failure = ReducerEvent::CommandFailed {
            command_id: effect.command_id.clone(),
            attempt_token: effect.attempt_token.clone(),
            class: FailureClass::Transient,
            code: EFFECT_NOT_EXECUTED.to_owned(),
        };
        let failed = match self.commit(&effect.run_id, snapshot.sequence, failure)? {
            CommitAttempt::Applied(failed) => failed,
            other => return self.refused_from(other),
        };
        let retryable = failed
            .commands
            .get(&effect.command_id)
            .is_some_and(|command| command.status == CommandStatus::Retryable);
        let settlement = if retryable {
            match self.commit(
                &effect.run_id,
                failed.sequence,
                ReducerEvent::RetryRequested {
                    command_id: effect.command_id.clone(),
                },
            )? {
                CommitAttempt::Applied(_) => ReconcileSettlement::RetryScheduled,
                // The first half is durable; a later pass reaches the same
                // decision from the retryable state.
                CommitAttempt::Stale | CommitAttempt::Refused(_) => ReconcileSettlement::Recorded,
            }
        } else {
            ReconcileSettlement::Recorded
        };
        self.record_reconciliation(effect, "not_executed", source, None, now)?;
        Ok(ReconcileOutcome::Settled {
            command_id: effect.command_id.clone(),
            attempt_token: effect.attempt_token.clone(),
            settlement,
        })
    }

    /// A confirmed outcome event, applied only for exactly this attempt.
    fn apply_outcome(
        &self,
        effect: &OutstandingEffect,
        event: &ReducerEvent,
        snapshot: &RunSnapshot,
        now: i64,
    ) -> Result<ReconcileOutcome> {
        let (event_command, event_token) = match event {
            ReducerEvent::CommandSucceeded {
                command_id,
                attempt_token,
                ..
            }
            | ReducerEvent::CommandFailed {
                command_id,
                attempt_token,
                ..
            }
            | ReducerEvent::CancellationAcknowledged {
                command_id,
                attempt_token,
            }
            | ReducerEvent::CancellationUnknown {
                command_id,
                attempt_token,
            } => (command_id, attempt_token),
            _ => {
                return Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::Rejected {
                        code: "recovery_observation_not_an_outcome".to_owned(),
                    },
                });
            }
        };
        if event_command != &effect.command_id || event_token != &effect.attempt_token {
            return Ok(ReconcileOutcome::Refused {
                reason: ReconcileRefusal::AttemptMismatch {
                    command_id: effect.command_id.clone(),
                },
            });
        }
        if effect.boundary == EffectBoundary::Settled {
            let settled = snapshot.commands.get(&effect.command_id).cloned();
            if settled
                .as_ref()
                .is_some_and(|command| command.status == CommandStatus::InDoubt)
            {
                // The run's settlement says "unknown". A confirmed outcome is
                // new information about it, so it is recorded rather than
                // applied: reopening a settlement another owner is entitled to
                // would rewrite the history that settlement is.
                return self.record_late_fact(effect, None, now);
            }
            // A definite settlement is the authority on its own attempt, and
            // the machine answers for it: a repeat of the same outcome comes
            // back as not-applied, a contradiction as a callback conflict.
            let existing_digest = settled.and_then(|command| command.output_digest);
            return match self.commit(&effect.run_id, snapshot.sequence, event.clone())? {
                CommitAttempt::Applied(_) => self.record_late_fact(effect, existing_digest, now),
                CommitAttempt::Stale => Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::Rejected {
                        code: "workflow_state_sequence_stale".to_owned(),
                    },
                }),
                CommitAttempt::Refused(code) if code == "workflow_event_not_applied" => {
                    self.record_late_fact(effect, existing_digest, now)
                }
                CommitAttempt::Refused(code) if code == "strategy_callback_conflict" => {
                    Ok(ReconcileOutcome::Refused {
                        reason: ReconcileRefusal::ConflictingSettlement {
                            command_id: effect.command_id.clone(),
                        },
                    })
                }
                CommitAttempt::Refused(code) => Ok(ReconcileOutcome::Refused {
                    reason: ReconcileRefusal::Rejected { code },
                }),
            };
        }
        let settled = match self.commit(&effect.run_id, snapshot.sequence, event.clone())? {
            CommitAttempt::Applied(settled) => settled,
            other => return self.refused_from(other),
        };
        let command = settled
            .commands
            .get(&effect.command_id)
            .ok_or_else(|| anyhow!("workflow_run_checkpoint_invalid"))?;
        let settlement = match command.status {
            CommandStatus::Succeeded => ReconcileSettlement::Succeeded,
            CommandStatus::Failed => ReconcileSettlement::Failed,
            CommandStatus::Retryable => ReconcileSettlement::RetryScheduled,
            CommandStatus::Cancelled => ReconcileSettlement::Cancelled,
            CommandStatus::InDoubt => ReconcileSettlement::Recorded,
            _ => ReconcileSettlement::Recorded,
        };
        let digest = command.output_digest.clone();
        self.record_reconciliation(effect, "executed", "late_outcome", digest.as_deref(), now)?;
        Ok(ReconcileOutcome::Settled {
            command_id: effect.command_id.clone(),
            attempt_token: effect.attempt_token.clone(),
            settlement,
        })
    }

    /// Record a confirmed fact whose settlement the run already holds.
    ///
    /// The result identity is present only when the engine minted one: a run
    /// whose attempt settled as unknown has no digest, and this module does not
    /// invent one, because the digest is the engine's statement about the
    /// payload rather than a hash anyone may recompute.
    fn record_late_fact(
        &self,
        effect: &OutstandingEffect,
        result_digest: Option<String>,
        now: i64,
    ) -> Result<ReconcileOutcome> {
        match self.record_reconciliation(
            effect,
            "executed",
            "late_outcome",
            result_digest.as_deref(),
            now,
        )? {
            RecordOutcome::Conflict => Ok(ReconcileOutcome::Refused {
                reason: ReconcileRefusal::ConflictingSettlement {
                    command_id: effect.command_id.clone(),
                },
            }),
            _ => Ok(ReconcileOutcome::Recorded {
                command_id: effect.command_id.clone(),
                attempt_token: effect.attempt_token.clone(),
                settlement: ReconcileSettlement::Recorded,
            }),
        }
    }

    /// Schedule a replacement attempt for one claim that provably never ran.
    fn schedule_retry(&self, effect: &OutstandingEffect) -> Result<RetryAttempt> {
        let snapshot = self.state.checkpoint(&effect.run_id)?;
        let claimable = snapshot
            .commands
            .get(&effect.command_id)
            .is_some_and(|command| {
                command.attempt_token == effect.attempt_token
                    && boundary_of(command.status) == EffectBoundary::Claimed
            });
        if !claimable {
            return Ok(RetryAttempt::NotOutstanding);
        }
        let failure = ReducerEvent::CommandFailed {
            command_id: effect.command_id.clone(),
            attempt_token: effect.attempt_token.clone(),
            class: FailureClass::Transient,
            code: LEASE_EXPIRED_BEFORE_START.to_owned(),
        };
        let failed = match self.commit(&effect.run_id, snapshot.sequence, failure)? {
            CommitAttempt::Applied(failed) => failed,
            CommitAttempt::Stale => return Ok(RetryAttempt::Stale),
            CommitAttempt::Refused(code) => return Ok(RetryAttempt::Refused(code)),
        };
        let retryable = failed
            .commands
            .get(&effect.command_id)
            .is_some_and(|command| command.status == CommandStatus::Retryable);
        if !retryable {
            // The run's own retry policy refused the retry; the attempt is
            // durably settled and nothing became dispatchable from it.
            return Ok(RetryAttempt::SettledWithoutReplacement);
        }
        match self.commit(
            &effect.run_id,
            failed.sequence,
            ReducerEvent::RetryRequested {
                command_id: effect.command_id.clone(),
            },
        )? {
            CommitAttempt::Applied(retried) => {
                let replacement = retried
                    .commands
                    .iter()
                    .find(|(id, command)| {
                        **id != effect.command_id
                            && command.state_id == effect.node_id
                            && command.state_visit == effect.node_visit
                            && command.status == CommandStatus::Pending
                    })
                    .map(|(id, _)| id.clone());
                Ok(match replacement {
                    Some(replacement) => RetryAttempt::Scheduled { replacement },
                    None => RetryAttempt::SettledWithoutReplacement,
                })
            }
            CommitAttempt::Stale => Ok(RetryAttempt::Stale),
            CommitAttempt::Refused(_) => Ok(RetryAttempt::SettledWithoutReplacement),
        }
    }

    /// Record a started attempt as unknown because its owner was declared lost.
    fn settle_unknown(&self, effect: &OutstandingEffect, code: &str) -> Result<SettleAttempt> {
        let snapshot = self.state.checkpoint(&effect.run_id)?;
        let settleable = snapshot
            .commands
            .get(&effect.command_id)
            .is_some_and(|command| {
                command.attempt_token == effect.attempt_token
                    && matches!(
                        command.status,
                        CommandStatus::Claimed
                            | CommandStatus::Running
                            | CommandStatus::CancelRequested
                    )
            });
        if !settleable {
            return Ok(SettleAttempt::NotOutstanding);
        }
        let failure = ReducerEvent::CommandFailed {
            command_id: effect.command_id.clone(),
            attempt_token: effect.attempt_token.clone(),
            class: FailureClass::InDoubt,
            code: code.to_owned(),
        };
        match self.commit(&effect.run_id, snapshot.sequence, failure)? {
            CommitAttempt::Applied(_) => Ok(SettleAttempt::Settled),
            CommitAttempt::Stale => Ok(SettleAttempt::Stale),
            CommitAttempt::Refused(code) => Ok(SettleAttempt::Refused(code)),
        }
    }

    fn refused_from(&self, attempt: CommitAttempt) -> Result<ReconcileOutcome> {
        Ok(match attempt {
            CommitAttempt::Stale => ReconcileOutcome::Refused {
                reason: ReconcileRefusal::Rejected {
                    code: "workflow_state_sequence_stale".to_owned(),
                },
            },
            CommitAttempt::Refused(code) => ReconcileOutcome::Refused {
                reason: ReconcileRefusal::Rejected { code },
            },
            CommitAttempt::Applied(_) => ReconcileOutcome::Held {
                reason: UnconfirmedReason::LeaseLapsed {
                    owner: "unclaimed".to_owned(),
                },
            },
        })
    }
}

/// What one commit attempt did.
enum CommitAttempt {
    Applied(Box<RunSnapshot>),
    Stale,
    Refused(String),
}

/// What scheduling a retry produced.
enum RetryAttempt {
    Scheduled { replacement: String },
    SettledWithoutReplacement,
    NotOutstanding,
    Stale,
    Refused(String),
}

/// What settling an attempt as unknown produced.
enum SettleAttempt {
    Settled,
    NotOutstanding,
    Stale,
    Refused(String),
}

/// What recording a reconciliation fact produced.
enum RecordOutcome {
    Recorded,
    Unchanged,
    Conflict,
}

/// The run row recovery needs: the checkpoint and the identities beside it.
pub(crate) fn run_row(
    connection: &Connection,
    run_id: &str,
) -> Result<Option<(String, String, String)>> {
    Ok(connection
        .query_row(
            "SELECT snapshot_json, revision_digest, semantics_digest
             FROM strategy_runs WHERE run_id=?1",
            params![run_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?)
}

pub(crate) fn definition_semantics(
    connection: &Connection,
    revision_digest: &str,
) -> Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT semantics_digest FROM strategy_definitions WHERE revision_digest=?1",
            params![revision_digest],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

/// Whether a checkpoint may be advanced, from the bytes the file holds.
///
/// The causal fields are checked by presence before parsing: a checkpoint that
/// predates them cannot be advanced by assuming an empty ledger, because an
/// empty ledger and a missing one would then read the same — and the first is a
/// fact about a run that had no arrivals, while the second is one whose causal
/// state was never written.
pub(crate) fn admission_of(
    snapshot_json: &str,
    run_semantics: &str,
    definition_semantics: Option<&str>,
) -> CheckpointAdmission {
    let Some(definition_semantics) = definition_semantics else {
        return CheckpointAdmission::Handoff {
            reason: CheckpointHandoff::DefinitionMissing,
        };
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(snapshot_json) else {
        return CheckpointAdmission::Refused {
            code: "workflow_run_checkpoint_invalid".to_owned(),
        };
    };
    let causal_present = ["joinArrivals", "stateVisits", "inputPlan"]
        .iter()
        .all(|field| value.get(*field).is_some());
    if !causal_present {
        return CheckpointAdmission::Handoff {
            reason: CheckpointHandoff::CausalStateMissing,
        };
    }
    let Ok(snapshot) = serde_json::from_value::<RunSnapshot>(value) else {
        return CheckpointAdmission::Refused {
            code: "workflow_run_checkpoint_invalid".to_owned(),
        };
    };
    if snapshot.input_plan.input_adapter_version != INPUT_ADAPTER_VERSION {
        return CheckpointAdmission::Handoff {
            reason: CheckpointHandoff::InputAdapterMismatch,
        };
    }
    if definition_semantics != run_semantics {
        // The definition the run names is not the semantics it was admitted
        // under; advancing it would silently rebind the run.
        return CheckpointAdmission::Refused {
            code: "workflow_checkpoint_semantics_mismatch".to_owned(),
        };
    }
    CheckpointAdmission::Advance
}

/// One attempt's durable facts, or `None` when it settled.
pub(crate) fn outstanding_attempt(
    connection: &Connection,
    run_id: &str,
    command_id: &str,
    now_unix_ms: i64,
) -> Result<Option<OutstandingEffect>> {
    let row: Option<(String, String, Option<String>, Option<i64>, String)> = connection
        .query_row(
            "SELECT status, attempt_token, lease_owner, lease_until, command_json
             FROM strategy_commands WHERE run_id=?1 AND command_id=?2",
            params![run_id, command_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()?;
    let Some((status, attempt_token, lease_owner, lease_until, command_json)) = row else {
        return Ok(None);
    };
    let command: RunCommand = serde_json::from_str(&command_json)?;
    // The projection column and the command body are written in one
    // transaction, so disagreement means the row is not one this module can
    // reason about. Refusing beats guessing which half is true.
    if command_status_wire(command.status)? != status {
        return Err(anyhow!("workflow_recovery_state_conflict: {command_id}"));
    }
    let boundary = boundary_of(command.status);
    if boundary == EffectBoundary::Settled {
        return Ok(None);
    }
    let claim = match (lease_owner, lease_until) {
        (Some(owner), Some(until)) if until > now_unix_ms => ClaimStanding::Held {
            owner,
            until_unix_ms: until,
        },
        (Some(owner), Some(until)) => ClaimStanding::Lapsed {
            owner,
            until_unix_ms: until,
        },
        _ => ClaimStanding::Unclaimed,
    };
    Ok(Some(OutstandingEffect {
        run_id: run_id.to_owned(),
        command_id: command_id.to_owned(),
        attempt_token,
        node_id: command.state_id.clone(),
        node_visit: command.state_visit,
        boundary,
        claim,
        output_digest: command.output_digest.clone(),
    }))
}

/// The boundary one durable command status is at.
pub(crate) fn boundary_of(status: CommandStatus) -> EffectBoundary {
    match status {
        CommandStatus::Pending | CommandStatus::Retryable => EffectBoundary::NotStarted,
        CommandStatus::Claimed => EffectBoundary::Claimed,
        CommandStatus::Running | CommandStatus::CancelRequested => EffectBoundary::Started,
        CommandStatus::Succeeded
        | CommandStatus::Failed
        | CommandStatus::Cancelled
        | CommandStatus::InDoubt => EffectBoundary::Settled,
    }
}

/// The stored text for a command status, derived from the enum's own
/// serialization so a predicate cannot drift from what a write stores.
pub(crate) fn command_status_wire(status: CommandStatus) -> Result<String> {
    serde_json::to_value(status)?
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("workflow_enum_invalid"))
}

/// The leading code of one error, which is how this codebase names failures.
fn leading_code(error: &anyhow::Error) -> String {
    let text = error.to_string();
    let end = text
        .find(|character: char| character == ':' || character.is_whitespace())
        .unwrap_or(text.len());
    text[..end].to_owned()
}
