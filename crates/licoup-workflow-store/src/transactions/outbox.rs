//! Delivery intent: the facts a run owes a downstream owner, and their
//! durable acceptance.
//!
//! ## Intent is not delivery
//!
//! A notice intent is committed in the same transaction as the fact it is
//! about, so there is no window in which a fact exists and the obligation to
//! deliver it does not. The intent is then *pending* until some owner has it
//! durably, and pending intents are readable through a bounded query. That is
//! the order the plan requires: state and intent first, reconciliation after.
//!
//! ## Identity, not retries
//!
//! A notice's identity is derived from the fact it is about — the run, the
//! sequence, the recipient, and the kind — never from the attempt that carried
//! it. So a notice that is carried twice is recognisably the same notice, and a
//! caller cannot mint a second identity for a fact it already sent. That is
//! what stops a retry from becoming a second piece of paid work, and it is
//! enforced here rather than trusted: [`WorkflowDatabase::accept_notice`]
//! refuses a notice whose id does not match its own contents.
//!
//! ## What "accepted" means here, and what it does not
//!
//! [`DurableNoticeSink`]'s downstream owner is a ledger row in this database.
//! A successful `accept` therefore means the fact is recoverable after a
//! restart — the property the port asks for — and a repeated acceptance is
//! recorded as a repeat (`accept_count` rising) rather than as new work. It is
//! **not** a claim that some other process, and certainly not some external
//! paid provider, has acted. An owner living elsewhere must be a sink that
//! persists there; nothing in storage can make that true for it.

use anyhow::{Result, ensure};
use licoup_workflow_runtime::ports::{Notice, NoticeSink};
use rusqlite::params;
use std::sync::Arc;

use super::{WorkflowDatabase, now_unix_ms, validate_notice_id, validate_opaque_id};

/// The most intents one reconciliation pass may read.
///
/// A bound is the point: a reconciliation that can ask for "everything" will
/// eventually do exactly that, on the database that is already the bottleneck.
/// A pass reads at most this many, acknowledges them, and comes back for the
/// rest, so its cost is a property of the pass rather than of how far behind
/// the outbox has fallen. A caller asking for more than this is refused rather
/// than quietly handed a shorter page, because a truncated page that looks
/// complete is how a backlog gets mistaken for a drained queue.
pub const MAX_OUTBOX_BATCH: usize = 256;

/// One downstream owner that must accept one committed fact.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoticeRequest {
    pub recipient: String,
    pub kind: String,
}

/// A committed fact owed to one owner, addressed by reference.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoticeIntent {
    pub notice_id: String,
    pub run_id: String,
    /// The run sequence this fact was committed at. Together with `run_id` this
    /// is the address of the committed body in `strategy_run_events`, which is
    /// why the intent needs no copy of it.
    pub sequence: u64,
    pub recipient: String,
    pub kind: String,
    pub created_at_unix_ms: i64,
}

impl NoticeIntent {
    /// The intent for one fact, or an error if the owner's vocabulary is not
    /// storable.
    pub(crate) fn for_fact(
        run_id: &str,
        sequence: u64,
        request: &NoticeRequest,
        now_unix_ms: i64,
    ) -> Result<Self> {
        validate_opaque_id(&request.recipient, "workflow_notice_invalid: recipient")?;
        validate_opaque_id(&request.kind, "workflow_notice_invalid: kind")?;
        Ok(Self {
            notice_id: notice_id(run_id, sequence, &request.recipient, &request.kind),
            run_id: run_id.to_owned(),
            sequence,
            recipient: request.recipient.clone(),
            kind: request.kind.clone(),
            created_at_unix_ms: now_unix_ms,
        })
    }
}

/// What one acceptance did.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NoticeAcceptance {
    pub notice_id: String,
    /// How many times this notice has now been accepted, including this one.
    pub accept_count: u64,
    /// False when this was a repeat of an acceptance already recorded — the
    /// same logical notice arriving again, which must not become new work.
    pub first_acceptance: bool,
}

/// The stable identity of a notice: same fact, same recipient, same kind.
///
/// Length-prefixed rather than colon-joined, so two different facts cannot
/// collide by moving a separator across a field boundary.
pub fn notice_id(run_id: &str, sequence: u64, recipient: &str, kind: &str) -> String {
    format!(
        "{}:{run_id}:{}:{recipient}:{sequence}:{kind}",
        run_id.len(),
        recipient.len()
    )
}

impl WorkflowDatabase {
    /// Read at most `limit` pending intents, oldest first.
    ///
    /// The order is fully covered by `workflow_notice_intents_pending_idx`, so
    /// this is a bounded index scan that stops at `limit` rather than a sort of
    /// every pending row.
    pub fn pending_notice_intents(&self, limit: usize) -> Result<Vec<NoticeIntent>> {
        ensure!(
            limit > 0 && limit <= MAX_OUTBOX_BATCH,
            "workflow_outbox_limit_invalid: 1..={MAX_OUTBOX_BATCH}, requested {limit}"
        );
        self.read(|connection| {
            let mut statement = connection.prepare(
                "SELECT notice_id, run_id, sequence, recipient, kind, created_at
                 FROM workflow_notice_intents
                 WHERE status='pending'
                 ORDER BY created_at ASC, run_id ASC, sequence ASC, notice_id ASC
                 LIMIT ?1",
            )?;
            let rows = statement.query_map(params![limit as i64], |row| {
                Ok(NoticeIntent {
                    notice_id: row.get(0)?,
                    run_id: row.get(1)?,
                    sequence: row.get::<_, i64>(2)?.max(0) as u64,
                    recipient: row.get(3)?,
                    kind: row.get(4)?,
                    created_at_unix_ms: row.get(5)?,
                })
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
                .map_err(anyhow::Error::from)
        })
    }

    /// Close one intent, and only one that is still pending.
    ///
    /// An intent that is missing or already accepted is an error: a caller that
    /// believes it just completed a delivery should learn that it did not
    /// complete *this* one, rather than have the belief confirmed.
    pub fn acknowledge_notice(&self, notice_id: &str) -> Result<()> {
        validate_notice_id(notice_id)?;
        let (changed, _) = self.write(|transaction, _| {
            Ok(transaction.execute(
                "UPDATE workflow_notice_intents SET status='accepted', accepted_at=?2
                 WHERE notice_id=?1 AND status='pending'",
                params![notice_id, now_unix_ms()],
            )?)
        })?;
        ensure!(changed == 1, "workflow_notice_intent_missing: {notice_id}");
        Ok(())
    }

    /// Record durable acceptance of one committed fact.
    ///
    /// One transaction: the acceptance ledger gains a row (or records a
    /// repeat), and the intent for the same fact closes if it was pending.
    pub fn accept_notice(&self, notice: &Notice) -> Result<NoticeAcceptance> {
        let now = now_unix_ms();
        let intent = NoticeIntent::for_fact(
            &notice.run_id,
            notice.sequence,
            &NoticeRequest {
                recipient: notice.recipient.clone(),
                kind: notice.kind.clone(),
            },
            now,
        )?;
        ensure!(
            intent.notice_id == notice.notice_id,
            "workflow_notice_identity_invalid: {notice_id} is not the identity of the fact it names",
            notice_id = notice.notice_id
        );
        let (accept_count, _) = self.write(|transaction, _| {
            let accept_count: i64 = transaction.query_row(
                "INSERT INTO workflow_notice_acceptances(
                   notice_id, run_id, sequence, recipient, kind,
                   accept_count, first_accepted_at, last_accepted_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?6)
                 ON CONFLICT(notice_id) DO UPDATE SET
                   accept_count = workflow_notice_acceptances.accept_count + 1,
                   last_accepted_at = excluded.last_accepted_at
                 RETURNING accept_count",
                params![
                    notice.notice_id,
                    notice.run_id,
                    notice.sequence as i64,
                    notice.recipient,
                    notice.kind,
                    now
                ],
                |row| row.get(0),
            )?;
            transaction.execute(
                "UPDATE workflow_notice_intents SET status='accepted', accepted_at=?2
                 WHERE notice_id=?1 AND status='pending'",
                params![notice.notice_id, now],
            )?;
            Ok(accept_count)
        })?;
        let accept_count = accept_count.max(0) as u64;
        Ok(NoticeAcceptance {
            notice_id: notice.notice_id.clone(),
            accept_count,
            first_acceptance: accept_count == 1,
        })
    }
}

/// A `NoticeSink` whose owner is this database's acceptance ledger.
#[derive(Clone, Debug)]
pub struct DurableNoticeSink {
    database: Arc<WorkflowDatabase>,
}

impl DurableNoticeSink {
    pub fn new(database: Arc<WorkflowDatabase>) -> Self {
        Self { database }
    }

    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }
}

impl NoticeSink for DurableNoticeSink {
    fn accept(&self, notice: &Notice) -> Result<()> {
        self.database.accept_notice(notice).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_identity_cannot_be_moved_across_a_field_boundary() {
        let left = notice_id("a:1", 2, "x", "y");
        let right = notice_id("a", 1, "x:2", "y");
        assert_ne!(left, right, "different facts must not share an identity");
    }
}
