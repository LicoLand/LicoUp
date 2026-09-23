//! The storage side of the workflow ports: short write transactions over the
//! database the production store already writes.
//!
//! ## Where the work is split, and why
//!
//! A transition costs two very different kinds of work, and the plan requires
//! that they not happen in the same place:
//!
//! ```text
//!   read + compile + reduce          │  one short write transaction
//!   (no lock held, no database open  │  (the single SQLite writer, held for
//!    for writing)                    │   the duration of the statements)
//! ```
//!
//! Compilation and reduction are CPU work over a definition and a snapshot.
//! They are deliberately *outside* every write transaction: a database write
//! lock held across a compile is a lock held across the slowest thing in the
//! system, and every other graph would wait behind it. [`state`] computes a
//! reduction; [`write`] records one, and `write` cannot compile anything
//! because it has no compiler to call — the module's imports are the type
//! system's copy of that rule, and `tests/transactions/atomic_intent.rs` holds
//! it there by reading these files. The same rule covers external effects: no
//! effect port is reachable from a write transaction either, because the
//! boundary the recovery contract rests on is a *durable marker committed
//! before* an effect is invoked, never a call made during a commit.
//!
//! ## One writer, short transactions, and the fairness that is actually claimed
//!
//! A SQLite database has one writer at a time. This crate does not claim
//! otherwise: every write goes through [`FairWriteGate`], which serializes them
//! in first-come-first-served ticket order. What that buys is that a graph
//! asking for writes in a tight loop cannot starve a graph asking for one,
//! because a caller holding a ticket is admitted before every caller that takes
//! a ticket later. What it does not buy is per-graph parallel writes, per-graph
//! round-robin turns, or any ordering between separate handles on the same
//! file — that order is SQLite's own lock, which this crate cannot see.

mod database;
mod gate;
mod outbox;
mod state;
mod write;

use anyhow::{Result, ensure};

pub use database::{WorkflowDatabase, WriteStats};
pub use gate::{FairWriteGate, WriteTicket};
pub use outbox::{
    DurableNoticeSink, MAX_OUTBOX_BATCH, NoticeAcceptance, NoticeIntent, NoticeRequest, notice_id,
};
pub use state::{CommittedState, StoreStatePort};

/// Wall-clock milliseconds, the unit every stored timestamp in this format uses.
///
/// A clock that cannot be read yields `0` rather than an error: these
/// timestamps order rows for reconciliation and are never an authorization or
/// an idempotency decision, so a failed clock read must not stop a run.
pub(crate) fn now_unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}

/// The longest identity this format stores for one opaque field.
pub(crate) const MAX_OPAQUE_ID_LEN: usize = 160;

/// The longest composed notice identity: three opaque fields, their length
/// prefixes, a sequence, and the separators between them.
pub(crate) const MAX_NOTICE_ID_LEN: usize = 3 * MAX_OPAQUE_ID_LEN + 64;

/// Validate a caller-supplied identity (a claimant, a recipient, a notice kind)
/// before it reaches a column this format stores as opaque text.
pub(crate) fn validate_opaque_id(value: &str, code: &'static str) -> Result<()> {
    validate_text(value, MAX_OPAQUE_ID_LEN, code)
}

/// Validate a notice's composed identity.
///
/// It is longer than any field it is built from, so it cannot be held to the
/// single-field limit: `run_id`, `recipient`, and `kind` may each be at their
/// own maximum.
pub(crate) fn validate_notice_id(value: &str) -> Result<()> {
    validate_text(
        value,
        MAX_NOTICE_ID_LEN,
        "workflow_notice_invalid: noticeId",
    )
}

fn validate_text(value: &str, max_len: usize, code: &'static str) -> Result<()> {
    ensure!(
        value == value.trim()
            && !value.is_empty()
            && value.len() <= max_len
            && !value.chars().any(char::is_control),
        "{code}"
    );
    Ok(())
}
