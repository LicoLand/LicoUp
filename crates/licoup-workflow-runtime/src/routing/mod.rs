//! Routing: which committed fact is carried next, to which owner, and when it
//! is settled.
//!
//! The driver already keeps control off the result path *inside one call*
//! ([`crate::driver::control`]); what it deliberately does not own is the
//! durable side — the queue that survives a restart, the fairness between the
//! classes of work, and the cursors a subscriber resumes from. That is this
//! module. Its three parts answer three separate questions:
//!
//! ```text
//!   lane         which lane is served next, and what it may not starve
//!   acceptance   what one committed fact still owes, and when it is settled
//!   subscription what a subscriber has already been told, and where it resumes
//! ```
//!
//! ## Consumer-owned, storage-free
//!
//! Nothing here names a table, a connection, or a column. A lane is chosen from
//! counts and a position; an acceptance is decided from a set of owners; a
//! cursor is advanced by a number. The durable implementations live in
//! `licoup-workflow-store::deliveries`, which imports these types and is the
//! crate that knows about SQLite. Keeping the rules here means the fairness and
//! settlement rules are testable without a database, and that a second storage
//! implementation would inherit them instead of re-deriving them.
//!
//! ## What is not claimed here
//!
//! A lane is a *service* order, not a capacity guarantee: this module does not
//! claim bounded memory, per-graph parallel database writes, or that a busy
//! system cannot be behind. What it claims is narrower and testable — the
//! class that carries control is served before the class that carries bulk, a
//! bulk flood cannot take that turn away, and a lane that carries nothing is
//! skipped rather than counted.

pub mod acceptance;
pub mod lane;
pub mod subscription;

pub use acceptance::{
    AcceptanceOutcome, AcceptancePlan, NoticeAcceptance, NoticeDisposition, PendingAcceptances,
};
pub use lane::{LaneCounts, LanePolicy, LanePosition, LaneStep, LaneWeights, QueueClass};
pub use subscription::{
    ActivationRule, AdvanceOutcome, ScopeAddress, SubscriptionCursor, SubscriptionPredicate,
    SubscriptionScope,
};
