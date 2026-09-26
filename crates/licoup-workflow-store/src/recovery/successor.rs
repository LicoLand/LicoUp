//! Successor handoff over the shared rows, and the fence it leaves behind.
//!
//! The compare-and-set is one write transaction over the production store's own
//! rows: the run's checkpoint, its command rows with their claims, and this
//! module's handoff table. Nothing is copied out of a checkpoint that the
//! checkpoint did not already name, and nothing is rewritten in one:
//!
//! ```text
//!   verify (all inside the transaction)             commit
//!   ─────────────────────────────────────────       ─────────────────────────
//!   checkpoint readable with causal state           one row per run, so a
//!   expected revision still current                 second handoff cannot exist
//!   definition revision matches the manifest
//!   the new owner's profile admits the binding
//!   every live claim is the manifest's old owner
//!   the unstarted and started visit sets match
//!   no handoff exists for this run
//! ```
//!
//! The fence is the other half: [`FencedState`] consults the handoff before it
//! hands out new work, so the old owner keeps every claim it already holds and
//! cannot start anything new. Reads, commits, settlements and renewals pass
//! through unchanged — an old owner must still be able to finish what it began,
//! which is exactly what "started stays with the old owner" means.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use anyhow::{Result, anyhow};
use licoup_workflow::compile::RunAdmission;
use licoup_workflow::{ReducerEvent, ResultRef, RunCommand, RunSnapshot};
use licoup_workflow_runtime::ports::StatePort;
use licoup_workflow_runtime::successor::handoff::{
    BoundaryManifest, ClaimAdmission, HandoffOutcome, HandoffReceipt, HandoffRefusal,
    SemanticsHandoffReason, SuccessorManifest, SuccessorPort, SuccessorRecord,
};
use licoup_workflow_runtime::successor::recovery::{CheckpointAdmission, EffectBoundary};
use rusqlite::{OptionalExtension, Transaction, params};

use crate::recovery::effects::{admission_of, command_status_wire};
use crate::transactions::{StoreStatePort, WorkflowDatabase, now_unix_ms};

/// The successor-handoff port over one workflow database.
pub struct StoreSuccessor {
    database: Arc<WorkflowDatabase>,
}

impl StoreSuccessor {
    pub(super) fn new(database: Arc<WorkflowDatabase>) -> Self {
        Self { database }
    }
}

impl SuccessorPort for StoreSuccessor {
    fn handoff(&self, manifest: &SuccessorManifest) -> Result<HandoffOutcome> {
        let now = now_unix_ms();
        let (outcome, _) = self.database.write(|transaction, _| {
            let Some((snapshot_json, revision_digest, semantics_digest)) = transaction
                .query_row(
                    "SELECT snapshot_json, revision_digest, semantics_digest
                     FROM strategy_runs WHERE run_id=?1",
                    params![manifest.run_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                        ))
                    },
                )
                .optional()?
            else {
                return Ok(HandoffOutcome::Refused {
                    refusal: HandoffRefusal::RunNotFound {
                        run_id: manifest.run_id.clone(),
                    },
                });
            };
            let definition: Option<String> = transaction
                .query_row(
                    "SELECT semantics_digest FROM strategy_definitions WHERE revision_digest=?1",
                    params![revision_digest],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            match admission_of(&snapshot_json, &semantics_digest, definition.as_deref()) {
                CheckpointAdmission::Advance => {}
                CheckpointAdmission::Handoff { reason } => {
                    return Ok(HandoffOutcome::Refused {
                        refusal: HandoffRefusal::Checkpoint { reason },
                    });
                }
                CheckpointAdmission::Refused { code } => {
                    return Ok(HandoffOutcome::Refused {
                        refusal: HandoffRefusal::CheckpointRefused { code },
                    });
                }
            }
            let snapshot: RunSnapshot = serde_json::from_str(&snapshot_json)?;
            if snapshot.sequence != manifest.expected_revision {
                return Ok(HandoffOutcome::Refused {
                    refusal: HandoffRefusal::RevisionMoved {
                        expected: manifest.expected_revision,
                        current: snapshot.sequence,
                    },
                });
            }
            // The manifest's binding must name the definition the run is on.
            if revision_digest != manifest.old_binding.definition_revision {
                return Ok(HandoffOutcome::Refused {
                    refusal: HandoffRefusal::BindingMismatch {
                        expected: manifest.old_binding.definition_revision.clone(),
                        current: revision_digest,
                    },
                });
            }
            // And the new owner must be able to advance it at all. A binding
            // this build cannot prove is handed off, never reinterpreted.
            match manifest
                .new_owner_profile
                .admit_recorded(&manifest.old_binding)
            {
                RunAdmission::Compatible => {}
                RunAdmission::MissingCapability { capability } => {
                    return Ok(HandoffOutcome::Refused {
                        refusal: HandoffRefusal::MissingCapability { capability },
                    });
                }
                RunAdmission::Handoff { reason } => {
                    return Ok(HandoffOutcome::Refused {
                        refusal: HandoffRefusal::SemanticsHandoff {
                            reason: SemanticsHandoffReason::from(reason),
                        },
                    });
                }
            }
            let commands = handoff_command_rows(transaction, &manifest.run_id)?;
            for row in commands.iter().filter(|row| row.is_live_at(now)) {
                if row.owner.as_deref() != Some(manifest.old_owner.as_str()) {
                    return Ok(HandoffOutcome::Refused {
                        refusal: HandoffRefusal::OwnerMoved {
                            expected: manifest.old_owner.clone(),
                            current: row.owner.clone(),
                        },
                    });
                }
            }
            let existing: Option<String> = transaction
                .query_row(
                    "SELECT handoff_id FROM workflow_successor_handoffs WHERE run_id=?1",
                    params![manifest.run_id],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(handoff_id) = existing {
                return Ok(HandoffOutcome::Refused {
                    refusal: HandoffRefusal::AlreadyHandedOff { handoff_id },
                });
            }
            if let Err(refusal) = compare_sets(&commands, manifest) {
                return Ok(HandoffOutcome::Refused { refusal: refusal });
            }
            let receipt = HandoffReceipt {
                handoff_id: manifest.handoff_id.clone(),
                run_id: manifest.run_id.clone(),
                revision: snapshot.sequence,
                old_owner: manifest.old_owner.clone(),
                new_owner: manifest.new_owner.clone(),
                migrated: manifest.unstarted.clone(),
                started: manifest.started.clone(),
                boundary: boundary_of_snapshot(&snapshot),
            };
            transaction.execute(
                "INSERT INTO workflow_successor_handoffs(
                   run_id, handoff_id, boundary_revision, old_owner, new_owner,
                   old_binding_json, migrated_json, started_json, boundary_json, created_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    manifest.run_id,
                    manifest.handoff_id,
                    snapshot.sequence as i64,
                    manifest.old_owner,
                    manifest.new_owner,
                    serde_json::to_string(&manifest.old_binding)?,
                    serde_json::to_string(&receipt.migrated)?,
                    serde_json::to_string(&receipt.started)?,
                    serde_json::to_string(&receipt.boundary)?,
                    now
                ],
            )?;
            Ok(HandoffOutcome::Committed {
                receipt: Box::new(receipt),
            })
        })?;
        Ok(outcome)
    }

    fn successor_of(&self, run_id: &str) -> Result<Option<SuccessorRecord>> {
        self.database.read(|connection| {
            let row: Option<(String, i64, String, String, String, String, String, i64)> =
                connection
                    .query_row(
                        "SELECT handoff_id, boundary_revision, old_owner, new_owner,
                                migrated_json, started_json, boundary_json, created_at
                         FROM workflow_successor_handoffs WHERE run_id=?1",
                        params![run_id],
                        |row| {
                            Ok((
                                row.get(0)?,
                                row.get(1)?,
                                row.get(2)?,
                                row.get(3)?,
                                row.get(4)?,
                                row.get(5)?,
                                row.get(6)?,
                                row.get(7)?,
                            ))
                        },
                    )
                    .optional()?;
            let Some((
                handoff_id,
                revision,
                old_owner,
                new_owner,
                migrated_json,
                started_json,
                boundary_json,
                created_at,
            )) = row
            else {
                return Ok(None);
            };
            Ok(Some(SuccessorRecord {
                handoff_id,
                run_id: run_id.to_owned(),
                revision: revision.max(0) as u64,
                old_owner,
                new_owner,
                migrated: serde_json::from_str(&migrated_json)?,
                started: serde_json::from_str(&started_json)?,
                boundary: serde_json::from_str(&boundary_json)?,
                created_at_unix_ms: created_at,
            }))
        })
    }

    fn claim_admission(&self, run_id: &str, claimant: &str) -> Result<ClaimAdmission> {
        self.database.read(|connection| {
            let row: Option<(String, String)> = connection
                .query_row(
                    "SELECT handoff_id, new_owner FROM workflow_successor_handoffs
                     WHERE run_id=?1",
                    params![run_id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            Ok(match row {
                None => ClaimAdmission::Admitted,
                Some((_, new_owner)) if new_owner == claimant => ClaimAdmission::Admitted,
                Some((handoff_id, new_owner)) => ClaimAdmission::Fenced {
                    handoff_id,
                    new_owner,
                },
            })
        })
    }
}

/// One command row as a handoff reads it.
struct HandoffCommand {
    command_id: String,
    attempt_token: String,
    node_id: String,
    node_visit: u64,
    phase: EffectBoundary,
    owner: Option<String>,
    lease_until: Option<i64>,
}

impl HandoffCommand {
    fn is_live_at(&self, now_unix_ms: i64) -> bool {
        self.lease_until.is_some_and(|until| until > now_unix_ms)
    }
}

fn handoff_command_rows(
    transaction: &Transaction<'_>,
    run_id: &str,
) -> Result<Vec<HandoffCommand>> {
    let mut statement = transaction.prepare(
        "SELECT command_id, attempt_token, status, command_json, lease_owner, lease_until
         FROM strategy_commands
         WHERE run_id=?1 AND status IN ('pending', 'claimed', 'running',
                                        'retryable', 'cancel-requested')
         ORDER BY command_id ASC",
    )?;
    let rows = statement
        .query_map(params![run_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<i64>>(5)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut commands = Vec::new();
    for (command_id, attempt_token, status, command_json, owner, lease_until) in rows {
        // The visit lives in the command body, not in a column. Reading it from
        // the body is also the consistency check: a projection column that
        // disagrees with the command it projects is not a row a handoff may
        // compare visit sets from.
        let command: licoup_workflow::RunCommand = serde_json::from_str(&command_json)?;
        if command_status_wire(command.status)? != status {
            return Err(anyhow!("workflow_recovery_state_conflict: {command_id}"));
        }
        let phase = match status.as_str() {
            "pending" | "retryable" => EffectBoundary::NotStarted,
            "claimed" => EffectBoundary::Claimed,
            "running" | "cancel-requested" => EffectBoundary::Started,
            other => return Err(anyhow!("workflow_recovery_state_conflict: {other}")),
        };
        commands.push(HandoffCommand {
            command_id,
            attempt_token,
            node_id: command.state_id,
            node_visit: command.state_visit,
            phase,
            owner,
            lease_until,
        });
    }
    Ok(commands)
}

/// Compare the durable visit sets with the manifest's, refusing on any move.
///
/// The comparison is by exact identity: command, attempt token, node, visit,
/// and — for live attempts — the phase. A manifest built before an attempt was
/// claimed and presented after it started is refused, because the fact it was
/// built from changed even though the command identity did not.
fn compare_sets(
    commands: &[HandoffCommand],
    manifest: &SuccessorManifest,
) -> std::result::Result<(), HandoffRefusal> {
    let unstarted: BTreeMap<&str, (&str, &str, u64)> = commands
        .iter()
        .filter(|command| command.phase == EffectBoundary::NotStarted)
        .map(|command| {
            (
                command.command_id.as_str(),
                (
                    command.attempt_token.as_str(),
                    command.node_id.as_str(),
                    command.node_visit,
                ),
            )
        })
        .collect();
    let manifest_unstarted: BTreeMap<&str, (&str, &str, u64)> = manifest
        .unstarted
        .iter()
        .map(|intent| {
            (
                intent.command_id.as_str(),
                (
                    intent.attempt_token.as_str(),
                    intent.node_id.as_str(),
                    intent.node_visit,
                ),
            )
        })
        .collect();
    for command_id in union_keys(&unstarted, &manifest_unstarted) {
        if unstarted.get(command_id) != manifest_unstarted.get(command_id) {
            return Err(HandoffRefusal::UnstartedSetMoved {
                command_id: command_id.to_owned(),
                in_store: unstarted.contains_key(command_id),
            });
        }
    }
    let live: BTreeMap<&str, (&str, &str, u64, EffectBoundary)> = commands
        .iter()
        .filter(|command| command.phase != EffectBoundary::NotStarted)
        .map(|command| {
            (
                command.command_id.as_str(),
                (
                    command.attempt_token.as_str(),
                    command.node_id.as_str(),
                    command.node_visit,
                    command.phase,
                ),
            )
        })
        .collect();
    let manifest_live: BTreeMap<&str, (&str, &str, u64, EffectBoundary)> = manifest
        .started
        .iter()
        .map(|attempt| {
            (
                attempt.command_id.as_str(),
                (
                    attempt.attempt_token.as_str(),
                    attempt.node_id.as_str(),
                    attempt.node_visit,
                    attempt.phase,
                ),
            )
        })
        .collect();
    for command_id in union_keys(&live, &manifest_live) {
        let durable = live.get(command_id).copied();
        let declared = manifest_live.get(command_id).copied();
        match (durable, declared) {
            (Some(durable), Some(declared))
                if durable.0 == declared.0 && durable.3 == declared.3 => {}
            (Some(durable), Some(declared)) if durable.3 != declared.3 => {
                return Err(HandoffRefusal::PhaseMoved {
                    command_id: command_id.to_owned(),
                    manifest: declared.3,
                    current: durable.3,
                });
            }
            _ => {
                return Err(HandoffRefusal::StartedSetMoved {
                    command_id: command_id.to_owned(),
                    in_store: durable.is_some(),
                });
            }
        }
    }
    Ok(())
}

fn union_keys<'a, T>(
    left: &'a BTreeMap<&'a str, T>,
    right: &'a BTreeMap<&'a str, T>,
) -> BTreeSet<&'a str> {
    left.keys().chain(right.keys()).copied().collect()
}

/// The boundary results a checkpoint records, as references only.
///
/// The identities come from facts the run already committed — the arrivals a
/// join ledger names and the predecessor inputs a node binding names — so a
/// manifest can never invent a result, and no payload is copied out. Grants
/// start empty: citing a result is not reading it.
fn boundary_of_snapshot(snapshot: &RunSnapshot) -> BoundaryManifest {
    let mut results: BTreeSet<ResultRef> = BTreeSet::new();
    for ledger in snapshot.join_arrivals.values() {
        for arrival in ledger.arrivals.values() {
            results.insert(arrival.result.clone());
        }
    }
    for binding in snapshot.bindings.values() {
        for predecessor in &binding.predecessors {
            results.insert(predecessor.result.clone());
        }
    }
    BoundaryManifest {
        run_id: snapshot.run_id.clone(),
        revision: snapshot.sequence,
        results: results.into_iter().collect(),
        grants: Vec::new(),
    }
}

/// The store's `StatePort` with the successor claim fence applied.
pub struct FencedState {
    inner: StoreStatePort,
    successor: StoreSuccessor,
}

impl FencedState {
    pub(super) fn new(inner: StoreStatePort, successor: StoreSuccessor) -> Self {
        Self { inner, successor }
    }

    /// Whether this owner may take new work from the run, with the fence named.
    pub fn admission(&self, run_id: &str, claimant: &str) -> Result<ClaimAdmission> {
        self.successor.claim_admission(run_id, claimant)
    }
}

impl StatePort for FencedState {
    fn checkpoint(&self, run_id: &str) -> Result<RunSnapshot> {
        self.inner.checkpoint(run_id)
    }

    fn commit(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
    ) -> Result<RunSnapshot> {
        self.inner.commit(run_id, expected_sequence, event)
    }

    /// Claim work for an owner the successor still admits.
    ///
    /// A fenced owner gets `None` — "there is no work for you" — rather than an
    /// error, because a drive that is settling its started work must keep
    /// running. The typed answer is [`FencedState::admission`].
    fn claim_next(
        &self,
        run_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<Option<RunCommand>> {
        match self.successor.claim_admission(run_id, claimant)? {
            ClaimAdmission::Fenced { .. } => Ok(None),
            ClaimAdmission::Admitted => {
                self.inner.claim_next(run_id, claimant, lease_until_unix_ms)
            }
        }
    }

    fn renew_lease(
        &self,
        command_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<()> {
        self.inner
            .renew_lease(command_id, claimant, lease_until_unix_ms)
    }

    fn mark_started(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
    ) -> Result<RunSnapshot> {
        self.inner.mark_started(run_id, command_id, attempt_token)
    }

    fn result_ref(&self, run_id: &str, command_id: &str) -> Result<Option<String>> {
        self.inner.result_ref(run_id, command_id)
    }
}
