//! `StatePort` over the workflow database.
//!
//! ## The shape of one transition
//!
//! ```text
//!   checkpoint(run_id)              ── read, no lock
//!   compile(definition_revision)    ── CPU, no lock
//!   reduce(compiled, previous, ev)  ── CPU, no lock
//!   ─────────────────────────────── ── take the write gate
//!   commit: CAS + event + checkpoint + commands + intents, one transaction
//!   ─────────────────────────────── ── release
//! ```
//!
//! Everything above the gate is computation; everything below it is a handful
//! of statements. The compare-and-set is what makes the split safe: the
//! sequence read before the compile is re-checked inside the transaction that
//! would apply the result, so a decision taken from an older view fails instead
//! of landing on a newer state. Failing here is deliberate — the alternative,
//! rebasing onto the newer state, would apply a decision to a state its author
//! never saw.
//!
//! ## What is deliberately not here
//!
//! No effect is invoked and no authorization is resolved. `mark_started` only
//! *records* that an effect may already have happened; invoking anything is the
//! caller's business and happens after that record is durable, which is the
//! boundary the recovery contract rests on.

use anyhow::{Result, anyhow, ensure};
use licoup_workflow::{
    CommandKind, CommandStatus, CompiledWorkflow, MAX_ACTIVE_EFFECTS, ReducerEvent, RunCommand,
    RunSnapshot, StrategyRunStatus, compile_workflow, reduce,
};
use licoup_workflow_runtime::ports::StatePort;
use rusqlite::{OptionalExtension, params};
use std::sync::Arc;

use super::outbox::NoticeRequest;
use super::write::{self, ClaimWrite, CommittedReduction};
use super::{WorkflowDatabase, WriteStats, now_unix_ms, validate_opaque_id};

/// A run's state after one committed transition, and what the commit cost.
#[derive(Clone, Debug, PartialEq)]
pub struct CommittedState {
    pub snapshot: RunSnapshot,
    pub write: WriteStats,
}

/// The durable run state a drive reads and advances.
pub struct StoreStatePort {
    database: Arc<WorkflowDatabase>,
}

impl StoreStatePort {
    pub fn new(database: Arc<WorkflowDatabase>) -> Self {
        Self { database }
    }

    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }

    /// Commit one transition together with the delivery intents it owes.
    ///
    /// This is the port's `commit` with the part the port cannot express: which
    /// downstream owners must durably accept the fact. Both land in one
    /// transaction, so an intent can never be missing for a committed fact.
    pub fn commit_with_notices(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
        notices: &[NoticeRequest],
    ) -> Result<CommittedState> {
        let reduction = self.reduction(run_id, expected_sequence, event, notices)?;
        let (_, write) = self.database.write(|transaction, stats| {
            write::commit_reduction(
                transaction,
                run_id,
                expected_sequence,
                &reduction,
                now_unix_ms(),
                stats,
            )
        })?;
        Ok(CommittedState {
            snapshot: reduction.after,
            write,
        })
    }

    /// Read, compile, and reduce — all of it before the write gate is taken.
    fn reduction(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
        notices: &[NoticeRequest],
    ) -> Result<CommittedReduction> {
        let previous = self.checkpoint(run_id)?;
        ensure!(
            previous.sequence == expected_sequence,
            "workflow_state_sequence_stale: expected {expected_sequence}, read {}",
            previous.sequence
        );
        let compiled = self.compiled_for(&previous.definition_digest)?;
        let output = reduce(&compiled, &previous, event.clone())?;
        ensure!(output.applied, "workflow_event_not_applied");
        Ok(CommittedReduction {
            event,
            after: output.snapshot,
            emitted_commands: output.emitted_commands,
            notices: notices.to_vec(),
        })
    }

    /// The compiled definition a run is bound to.
    ///
    /// A run names its definition by revision digest; the revision is what is
    /// compiled, so a revision this database does not hold is a missing fact
    /// rather than an empty one.
    fn compiled_for(&self, revision_digest: &str) -> Result<CompiledWorkflow> {
        let workflow_json: Option<String> = self.database.read(|connection| {
            connection
                .query_row(
                    "SELECT workflow_json FROM strategy_definitions WHERE revision_digest=?1",
                    params![revision_digest],
                    |row| row.get(0),
                )
                .optional()
                .map_err(anyhow::Error::from)
        })?;
        let workflow_json =
            workflow_json.ok_or_else(|| anyhow!("workflow_definition_not_found"))?;
        compile_workflow(serde_json::from_str(&workflow_json)?).map_err(anyhow::Error::from)
    }

    /// The oldest command a drive may still take.
    ///
    /// Authorization commands are not claimable work: they are settled by the
    /// authorization path, so handing one to an effect dispatcher would start
    /// an effect for a decision nobody made.
    fn pending_command(&self, run_id: &str) -> Result<Option<RunCommand>> {
        let authorization = write::command_kind_wire(CommandKind::Authorization)?;
        let command_json: Option<String> = self.database.read(|connection| {
            connection
                .query_row(
                    "SELECT command_json FROM strategy_commands
                     WHERE run_id=?1 AND status='pending' AND kind!=?2
                     ORDER BY command_id ASC LIMIT 1",
                    params![run_id, authorization],
                    |row| row.get(0),
                )
                .optional()
                .map_err(anyhow::Error::from)
        })?;
        let Some(command_json) = command_json else {
            return Ok(None);
        };
        Ok(Some(serde_json::from_str(&command_json)?))
    }
}

impl StatePort for StoreStatePort {
    fn checkpoint(&self, run_id: &str) -> Result<RunSnapshot> {
        let snapshot_json: Option<String> = self.database.read(|connection| {
            connection
                .query_row(
                    "SELECT snapshot_json FROM strategy_runs WHERE run_id=?1",
                    params![run_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(anyhow::Error::from)
        })?;
        let snapshot_json =
            snapshot_json.ok_or_else(|| anyhow!("workflow_run_not_found: {run_id}"))?;
        Ok(serde_json::from_str(&snapshot_json)?)
    }

    fn commit(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
    ) -> Result<RunSnapshot> {
        Ok(self
            .commit_with_notices(run_id, expected_sequence, event, &[])?
            .snapshot)
    }

    fn claim_next(
        &self,
        run_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<Option<RunCommand>> {
        validate_opaque_id(claimant, "workflow_claimant_invalid")?;
        let now = now_unix_ms();
        ensure!(lease_until_unix_ms > now, "workflow_lease_invalid");
        let previous = self.checkpoint(run_id)?;
        if !matches!(
            previous.status,
            StrategyRunStatus::Running | StrategyRunStatus::Waiting | StrategyRunStatus::Retryable
        ) {
            return Ok(None);
        }
        let Some(command) = self.pending_command(run_id)? else {
            return Ok(None);
        };
        let compiled = self.compiled_for(&previous.definition_digest)?;
        let event = ReducerEvent::CommandClaimed {
            command_id: command.id.clone(),
            attempt_token: command.attempt_token.clone(),
        };
        let output = reduce(&compiled, &previous, event.clone())?;
        ensure!(output.applied, "workflow_command_not_claimable");
        let reduction = CommittedReduction {
            event,
            after: output.snapshot,
            emitted_commands: output.emitted_commands,
            notices: Vec::new(),
        };
        let claimed = reduction.after.commands.get(&command.id).cloned();
        let (admitted, _) = self.database.write(|transaction, stats| {
            write::claim_command(
                transaction,
                run_id,
                previous.sequence,
                &reduction,
                ClaimWrite {
                    command_id: &command.id,
                    attempt_token: &command.attempt_token,
                    claimant,
                    lease_until_unix_ms,
                    now_unix_ms: now,
                },
                compiled.definition().limits.max_parallelism,
                MAX_ACTIVE_EFFECTS,
                stats,
            )
        })?;
        Ok(if admitted { claimed } else { None })
    }

    fn renew_lease(
        &self,
        command_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<()> {
        validate_opaque_id(claimant, "workflow_claimant_invalid")?;
        self.database.write(|transaction, _| {
            write::renew_lease(
                transaction,
                command_id,
                claimant,
                lease_until_unix_ms,
                now_unix_ms(),
            )
        })?;
        Ok(())
    }

    fn mark_started(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
    ) -> Result<RunSnapshot> {
        let current = self.checkpoint(run_id)?;
        let command = current
            .commands
            .get(command_id)
            .filter(|command| command.attempt_token == attempt_token)
            .ok_or_else(|| anyhow!("workflow_callback_stale"))?;
        ensure!(
            matches!(
                command.status,
                CommandStatus::Pending | CommandStatus::Claimed
            ),
            "workflow_callback_conflict"
        );
        self.commit(
            run_id,
            current.sequence,
            ReducerEvent::CommandStarted {
                command_id: command_id.to_owned(),
                attempt_token: attempt_token.to_owned(),
            },
        )
    }

    fn result_ref(&self, run_id: &str, command_id: &str) -> Result<Option<String>> {
        let command_json: Option<String> = self.database.read(|connection| {
            connection
                .query_row(
                    "SELECT command_json FROM strategy_commands
                     WHERE run_id=?1 AND command_id=?2",
                    params![run_id, command_id],
                    |row| row.get(0),
                )
                .optional()
                .map_err(anyhow::Error::from)
        })?;
        let Some(command_json) = command_json else {
            // No row is no recorded outcome — the same answer as a row that
            // never got one, because "unknown" is what a reconciliation must
            // treat as unknown either way.
            return Ok(None);
        };
        let command: RunCommand = serde_json::from_str(&command_json)?;
        Ok(command.output_digest)
    }
}
