//! Recovery over the shared workflow database: effect reconciliation and
//! successor handoff.
//!
//! This module is the durable side of
//! [`licoup_workflow_runtime::successor`]: the runtime declares what may be
//! concluded and which comparisons a handoff must make, and this is where the
//! conclusions are read from real rows and committed as real facts. It runs on
//! the same file, in the same format, as the transaction adapter — same
//! checkpoint, same event history, same command rows — so recovery never needs
//! a second copy of the run's state to reason about.
//!
//! ## What recovery is allowed to conclude
//!
//! One boundary decides everything:
//!
//! ```text
//!   command status        what it proves                     what recovery does
//!   ──────────────────    ──────────────────────────────     ─────────────────────────
//!   claimed               the possible-effect marker was     retry through the machine,
//!                         never committed, so the effect     which mints a new attempt
//!                         provably did not run               identity for the replacement
//!   running /             the marker is durable: the         hold; settle as unknown only
//!   cancel-requested      effect may already exist           when a caller declares that
//!                                                             owner lost
//! ```
//!
//! A lapsed lease and a directory that looks stopped appear nowhere in that
//! table. They are facts about a claim and about a filesystem, not about an
//! effect, and this module never turns them into a re-dispatch. The same rule
//! runs through [`StoreRecovery::reconcile`]: only a confirmed observation
//! moves an in-doubt attempt, and a silent one leaves it exactly where it is.
//!
//! ## What recovery never rewrites
//!
//! Nothing here edits a command row, a checkpoint, or an event. Every state
//! change goes through [`licoup_workflow::reduce`] and the store's own
//! compare-and-set commit, so recovery produces *new* events in the same history
//! the drive writes: a started attempt stays started, a settled outcome stays
//! settled, and a late confirmed fact is recorded as a fact rather than
//! substituted for history. The same applies to handoff: transferring a run
//! appends a successor record, it does not rewrite the work the old owner did.
//!
//! ## Assembly
//!
//! [`RecoveryAssembly::assemble`] is the only route to either port: it validates
//! the shared columns recovery reads and adds the two tables this module owns
//! ([`schema`]), so holding an assembly is the proof that the facts below can be
//! served. [`RecoveryAssembly::fenced_state`] wraps the store's `StatePort` with
//! the successor claim fence, which is how a host retires an old owner's ability
//! to start new work without touching the work it already started.

mod effects;
mod schema;
mod successor;

use std::sync::Arc;

use anyhow::Result;

use crate::transactions::{StoreStatePort, WorkflowDatabase};

pub use effects::StoreRecovery;
pub use successor::{FencedState, StoreSuccessor};

/// The recovery side of one database, assembled and validated.
pub struct RecoveryAssembly {
    database: Arc<WorkflowDatabase>,
}

impl RecoveryAssembly {
    /// Validate what recovery reads, add what it owns, and return the handle.
    ///
    /// Additive and idempotent for the shared format: an existing file keeps
    /// every row it had, and this module adds only its own two tables.
    pub fn assemble(database: Arc<WorkflowDatabase>) -> Result<Self> {
        database.read(|connection| schema::validate(connection))?;
        database.write(|transaction, _| schema::install(transaction))?;
        Ok(Self { database })
    }

    /// The effect-recovery port.
    pub fn recovery(&self) -> StoreRecovery {
        StoreRecovery::new(self.database.clone())
    }

    /// The successor-handoff port.
    pub fn successor(&self) -> StoreSuccessor {
        StoreSuccessor::new(self.database.clone())
    }

    /// The store's state port with the successor claim fence applied.
    ///
    /// Reads, commits, settlements and renewals are delegated unchanged: the
    /// fence is about *new* work only. An owner whose handoff is superseded can
    /// still settle what it started, and cannot start anything else.
    pub fn fenced_state(&self) -> FencedState {
        FencedState::new(StoreStatePort::new(self.database.clone()), self.successor())
    }

    /// The database this assembly serves.
    pub fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }
}
