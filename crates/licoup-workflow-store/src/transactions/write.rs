//! The bodies that run inside one short write transaction.
//!
//! Every function here takes *already computed* values and records them. There
//! is no compiler and no effect port anywhere in this module's imports, and
//! `tests/transactions/atomic_intent.rs` reads this file to keep it that way: a
//! reduction is produced by [`super::state`], outside the write lock, and this
//! module's only job is to make the whole of it — the compare-and-set on the
//! sequence, the event, the checkpoint, the commands, and the notice intents —
//! either commit together or not at all.
//!
//! ## One transaction, one transition
//!
//! `commit_reduction` is the only path that advances a run, and it ends in one
//! `commit`. That is what makes the guarantees around it real rather than
//! sequential: recovery cannot observe a run that advanced without its event,
//! an intent cannot be missing for a fact that is committed, and a stale writer
//! cannot land a decision on a newer state, because the sequence it read is
//! re-checked inside the same transaction that would apply it.

use anyhow::{Result, ensure};
use licoup_workflow::{
    CommandKind, CommandStatus, ReducerEvent, RunCommand, RunSnapshot, StrategyRunStatus,
};
use rusqlite::{OptionalExtension, Transaction, params};
use std::collections::BTreeSet;

use super::WriteStats;
use super::outbox::{MAX_OUTBOX_BATCH, NoticeRequest};

/// A transition that was already computed outside the write lock.
///
/// Note what is *absent*: there is no `before` snapshot. The previous state is
/// not copied into a second table, because it is already the previous event's
/// committed fact and the checkpoint that preceded it is history the format
/// keeps once, not twice.
pub struct CommittedReduction {
    /// The reducer event that produced `after`.
    pub event: ReducerEvent,
    /// The state to commit as the run's active checkpoint.
    pub after: RunSnapshot,
    /// Commands the reduction emitted, which need rows of their own.
    pub emitted_commands: Vec<RunCommand>,
    /// Downstream owners that must durably accept this fact, if any.
    pub notices: Vec<NoticeRequest>,
}

/// Verify that the caller's decision still applies to the stored state.
///
/// A stale `expected_sequence` fails here rather than rebasing: the whole point
/// of an expected sequence is that a caller which decided something from an old
/// view must not have that decision applied to a newer one.
fn ensure_current_sequence(
    transaction: &Transaction<'_>,
    run_id: &str,
    expected_sequence: u64,
) -> Result<()> {
    let stored = stored_sequence(transaction, run_id)?;
    ensure!(
        stored == expected_sequence,
        "workflow_state_sequence_stale: expected {expected_sequence}, stored {stored}"
    );
    Ok(())
}

/// Read only the checkpoint's sequence.
///
/// This runs inside a write transaction, so it reads as little as possible: the
/// sequence is extracted by SQLite from the checkpoint column instead of
/// shipping the whole snapshot body across the boundary and parsing it here.
fn stored_sequence(transaction: &Transaction<'_>, run_id: &str) -> Result<u64> {
    let stored: Option<Option<i64>> = transaction
        .query_row(
            "SELECT json_extract(snapshot_json, '$.sequence') FROM strategy_runs WHERE run_id=?1",
            params![run_id],
            |row| row.get::<_, Option<i64>>(0),
        )
        .optional()?;
    let sequence = match stored {
        Some(Some(sequence)) => sequence,
        Some(None) => anyhow::bail!("workflow_run_checkpoint_invalid: {run_id}"),
        None => anyhow::bail!("workflow_run_not_found: {run_id}"),
    };
    ensure!(sequence >= 0, "workflow_run_checkpoint_invalid");
    Ok(sequence as u64)
}

/// Record a computed transition: event, checkpoint, commands, notice intents.
///
/// The compare-and-set, the event row, the checkpoint, the command rows, and
/// the delivery intents are one transaction. There is no order in which an
/// observer of this database can see one of them without the others.
pub fn commit_reduction(
    transaction: &Transaction<'_>,
    run_id: &str,
    expected_sequence: u64,
    reduction: &CommittedReduction,
    now_unix_ms: i64,
    stats: &mut WriteStats,
) -> Result<()> {
    ensure_current_sequence(transaction, run_id, expected_sequence)?;
    record_commit(
        transaction,
        run_id,
        expected_sequence,
        reduction,
        now_unix_ms,
        stats,
    )
}

/// Apply a transition whose sequence has already been checked.
fn record_commit(
    transaction: &Transaction<'_>,
    run_id: &str,
    expected_sequence: u64,
    reduction: &CommittedReduction,
    now_unix_ms: i64,
    stats: &mut WriteStats,
) -> Result<()> {
    let after = &reduction.after;
    ensure!(after.run_id == run_id, "workflow_reduction_run_mismatch");
    ensure!(
        after.sequence == expected_sequence + 1,
        "workflow_reduction_sequence_mismatch"
    );

    let event_json = serde_json::to_string(&reduction.event)?;
    transaction.execute(
        "INSERT INTO strategy_run_events(run_id, sequence, event_type, event_json, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            run_id,
            after.sequence as i64,
            event_type(&event_json),
            event_json,
            now_unix_ms
        ],
    )?;
    stats.bytes_written += event_json.len();

    let snapshot_json = serde_json::to_string(after)?;
    let updated = transaction.execute(
        "UPDATE strategy_runs SET snapshot_json=?2, conversation_id=?3, terminal=?4,
         updated_at=?5 WHERE run_id=?1",
        params![
            run_id,
            snapshot_json,
            after.conversation_id,
            i64::from(run_is_terminal(after.status)),
            now_unix_ms
        ],
    )?;
    ensure!(updated == 1, "workflow_run_not_found");
    stats.bytes_written += snapshot_json.len();

    for command in &reduction.emitted_commands {
        let command_json = serde_json::to_string(command)?;
        transaction.execute(
            "INSERT INTO strategy_commands(
               command_id, run_id, state_id, kind, status, attempt,
               attempt_token, command_json, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                command.id,
                run_id,
                command.state_id,
                command_kind_wire(command.kind)?,
                command_status_wire(command.status)?,
                command.attempt as i64,
                command.attempt_token,
                command_json,
                now_unix_ms
            ],
        )?;
        stats.bytes_written += command_json.len();
    }
    for command in after.commands.values() {
        let command_json = serde_json::to_string(command)?;
        transaction.execute(
            "UPDATE strategy_commands SET status=?2, command_json=?3, updated_at=?4
             WHERE command_id=?1",
            params![
                command.id,
                command_status_wire(command.status)?,
                command_json,
                now_unix_ms
            ],
        )?;
        stats.bytes_written += command_json.len();
    }

    write_notice_intents(
        transaction,
        run_id,
        after.sequence,
        &reduction.notices,
        now_unix_ms,
    )?;
    Ok(())
}

/// Claim the next dispatchable command under a lease, atomically with the
/// transition that records it.
///
/// Returns `false` when admission refuses the claim — the run is over, or it
/// already has as many live effects as it may, or the effect budget for the
/// whole database is full. That is "nothing dispatchable", not an error.
///
/// `max_parallelism` is passed in rather than read here because reading it
/// means compiling the definition, and compiling inside a write transaction is
/// the thing this module exists to avoid.
#[allow(clippy::too_many_arguments)]
pub fn claim_command(
    transaction: &Transaction<'_>,
    run_id: &str,
    expected_sequence: u64,
    reduction: &CommittedReduction,
    claim: ClaimWrite<'_>,
    max_parallelism: u8,
    max_active_effects: usize,
    stats: &mut WriteStats,
) -> Result<bool> {
    ensure!(
        claim.lease_until_unix_ms > claim.now_unix_ms,
        "workflow_lease_invalid"
    );
    ensure_current_sequence(transaction, run_id, expected_sequence)?;

    let active: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM strategy_commands
         WHERE status IN ('claimed', 'running') AND lease_until>?1",
        params![claim.now_unix_ms],
        |row| row.get(0),
    )?;
    let run_active: i64 = transaction.query_row(
        "SELECT COUNT(*) FROM strategy_commands
         WHERE run_id=?1 AND status IN ('claimed', 'running') AND lease_until>?2",
        params![run_id, claim.now_unix_ms],
        |row| row.get(0),
    )?;
    if active >= max_active_effects as i64 || run_active >= max_parallelism as i64 {
        return Ok(false);
    }

    let claimed = transaction.execute(
        "UPDATE strategy_commands SET status='claimed', lease_owner=?3, lease_until=?4,
         updated_at=?5
         WHERE command_id=?1 AND attempt_token=?2 AND run_id=?6 AND status='pending'",
        params![
            claim.command_id,
            claim.attempt_token,
            claim.claimant,
            claim.lease_until_unix_ms,
            claim.now_unix_ms,
            run_id
        ],
    )?;
    ensure!(claimed == 1, "workflow_command_not_claimable");

    record_commit(
        transaction,
        run_id,
        expected_sequence,
        reduction,
        claim.now_unix_ms,
        stats,
    )?;
    Ok(true)
}

/// The row-level half of a claim.
pub struct ClaimWrite<'a> {
    pub command_id: &'a str,
    pub attempt_token: &'a str,
    pub claimant: &'a str,
    pub lease_until_unix_ms: i64,
    pub now_unix_ms: i64,
}

/// Extend a held lease, refusing a caller whose lease is gone.
pub fn renew_lease(
    transaction: &Transaction<'_>,
    command_id: &str,
    claimant: &str,
    lease_until_unix_ms: i64,
    now_unix_ms: i64,
) -> Result<()> {
    ensure!(lease_until_unix_ms > now_unix_ms, "workflow_lease_invalid");
    let changed = transaction.execute(
        "UPDATE strategy_commands SET lease_until=?3, updated_at=?4
         WHERE command_id=?1 AND lease_owner=?2 AND status IN ('claimed', 'running')",
        params![command_id, claimant, lease_until_unix_ms, now_unix_ms],
    )?;
    ensure!(changed == 1, "workflow_lease_lost");
    Ok(())
}

/// Commit delivery intents for one committed fact.
///
/// An intent stores the notice's identity and the `(run_id, sequence)` address
/// of the fact it is about. It does not store a copy of the event or of any
/// message body: the body is already committed once, in the history row this
/// address names, and a downstream reader resolves it there.
///
/// The same logical notice requested twice in one commit is one intent. The
/// identity of a notice is the fact it is about, not the request that mentioned
/// it, so a repeated request cannot become a second piece of work.
fn write_notice_intents(
    transaction: &Transaction<'_>,
    run_id: &str,
    sequence: u64,
    notices: &[NoticeRequest],
    now_unix_ms: i64,
) -> Result<()> {
    ensure!(
        notices.len() <= MAX_OUTBOX_BATCH,
        "workflow_outbox_limit_invalid"
    );
    let mut written: BTreeSet<String> = BTreeSet::new();
    for notice in notices {
        let intent = super::outbox::NoticeIntent::for_fact(run_id, sequence, notice, now_unix_ms)?;
        if !written.insert(intent.notice_id.clone()) {
            continue;
        }
        transaction.execute(
            "INSERT INTO workflow_notice_intents(
               notice_id, run_id, sequence, recipient, kind, status, created_at, accepted_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, 'pending', ?6, NULL)",
            params![
                intent.notice_id,
                intent.run_id,
                intent.sequence as i64,
                intent.recipient,
                intent.kind,
                intent.created_at_unix_ms
            ],
        )?;
    }
    Ok(())
}

/// The event's wire tag, derived exactly the way the production store derives
/// it so a row written here reads back identically there: the tagged event
/// serializes as `{"type":"<tag>",...}`, and the fourth quote-delimited field
/// is the tag.
fn event_type(event_json: &str) -> String {
    event_json.split('"').nth(3).unwrap_or("event").to_owned()
}

/// The stored text for a machine enum.
///
/// Derived from the enum's own serialization rather than written out as a
/// literal, so a predicate like "status is pending" cannot drift away from the
/// value a write puts in the column. Written per enum rather than generically
/// because this crate depends on the pure machine's *values*, not on its
/// serialization machinery.
pub(crate) fn command_kind_wire(kind: CommandKind) -> Result<String> {
    wire_of(serde_json::to_value(kind)?)
}

pub(crate) fn command_status_wire(status: CommandStatus) -> Result<String> {
    wire_of(serde_json::to_value(status)?)
}

fn wire_of(value: serde_json::Value) -> Result<String> {
    value
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow::anyhow!("workflow_enum_invalid"))
}

/// A run is terminal once its outcome cannot change. Whether a run has ended is
/// a query column, not something a reader should have to parse the checkpoint
/// to answer.
pub(crate) fn run_is_terminal(status: StrategyRunStatus) -> bool {
    matches!(
        status,
        StrategyRunStatus::Completed
            | StrategyRunStatus::Failed
            | StrategyRunStatus::Cancelled
            | StrategyRunStatus::Blocked
            | StrategyRunStatus::CancelInDoubt
    )
}
