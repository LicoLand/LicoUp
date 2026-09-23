//! The scope admission barrier: what a pause or a stop writes so a new node
//! visit cannot start, and what may be shown once it has.
//!
//! C03 separates two things that are easy to collapse into one:
//!
//! * A **node-set instruction** acts on the recipients that were in flight when
//!   it was handled. That set is frozen once, and an effect admitted afterwards
//!   is not retroactively a recipient of an instruction that predates it.
//! * A **graph-scope pause** additionally writes a durable admission barrier, in
//!   the *same transaction* that freezes those recipients, and that barrier is
//!   what stops a new node visit from starting.
//!
//! Both live in one write here, behind [`ScopeBarrierPort::publish`], because
//! writing them apart has two distinct failure modes: a barrier without the
//! frozen set lets a control instruction be applied to recipients admitted
//! after it, and a freeze without the barrier lets a new visit start under a
//! paused scope. The receipt a publish returns carries the barrier and the
//! recipients it froze, so the two facts travel together where a caller can
//! compare them.
//!
//! Three further rules are values rather than prose:
//!
//! * [`BarrierScope::blocks_new_visits`] answers only for the graph scope. A
//!   node-scoped instruction does not fence new visits — C03 gives the new-start
//!   fence to the graph scope, and inventing a second one here would let a
//!   single node's pause stop work it never addressed.
//! * [`scope_status`] refuses to show `Paused` before the facts support it: with
//!   the barrier written and effects still in flight, the honest state is
//!   `PauseRequested` (the pause is negotiating a drain); `Paused` is reachable
//!   only once nothing is in flight.
//! * A terminal outcome is reported beside the pause state, never replaced by
//!   it. A run that finished does not become "paused" because a pause arrived,
//!   and a settled result does not disappear because a barrier was written.

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::node::{NodeOutcomeKind, NodeVisitKey};

/// Which scope a barrier fences, and which recipients an instruction addressed.
#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase", tag = "scope")]
pub enum BarrierScope {
    /// A whole run (the graph scope of a definition).
    Run(String),
    /// One node visit.
    Node(NodeVisitKey),
}

impl BarrierScope {
    /// Whether a barrier on this scope stops a new node visit from starting.
    ///
    /// Only the run scope does. A node-scoped instruction acts on the
    /// recipients frozen with it; a visit that starts afterwards is not one of
    /// them.
    pub fn blocks_new_visits(&self) -> bool {
        matches!(self, Self::Run(_))
    }

    /// The run this scope belongs to, for a node scope's visit.
    pub fn run_id(&self) -> Option<&str> {
        match self {
            Self::Run(run_id) => Some(run_id),
            Self::Node(_) => None,
        }
    }
}

/// What was asked of a scope.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum BarrierKind {
    /// Stop starting new work here; in-flight work drains or suspends according
    /// to what its adapter supports.
    Pause,
    /// Stop the scope: monotonic, and not cleared by a later resume.
    Stop,
}

/// A durable barrier, with the recipients it froze when it was written.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdmissionBarrier {
    pub scope: BarrierScope,
    pub kind: BarrierKind,
    /// Why the barrier was written. Carried so a refusal can quote it instead
    /// of reporting a bare "paused".
    pub reason: String,
    /// The recipients frozen in the same transaction, named by visit.
    pub recipients: Vec<NodeVisitKey>,
    /// The durable position the barrier and its recipients were written at.
    /// Both facts share this position by construction; a receipt whose barrier
    /// and recipients carried different positions would not be one write.
    pub written_at: u64,
}

impl AdmissionBarrier {
    /// Whether this barrier stops a new node visit from starting.
    pub fn blocks_new_visits(&self) -> bool {
        self.scope.blocks_new_visits()
    }

    /// Whether `visit` was one of the recipients frozen with this barrier.
    pub fn froze(&self, visit: &NodeVisitKey) -> bool {
        self.recipients.contains(visit)
    }
}

/// One barrier publication, as the caller asks for it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BarrierRequest {
    pub scope: BarrierScope,
    pub kind: BarrierKind,
    pub reason: String,
    /// The recipients the caller froze when it handled the instruction. For a
    /// run scope this is the set a driver's own ledger reports as in flight;
    /// the port does not resolve it, because only the handling owner knows what
    /// was in flight at that instant.
    pub recipients: Vec<NodeVisitKey>,
}

/// Writing the barrier and freezing its recipients as one decision.
///
/// The trait states the same-transaction rule because it is the contract a
/// store must satisfy, and it is checkable: an implementation that writes the
/// barrier in one transaction and the recipients in another has to be able to
/// answer with two different durable positions, which
/// [`AdmissionBarrier::written_at`] has no room for.
pub trait ScopeBarrierPort: Send + Sync {
    /// Write the barrier and freeze `request.recipients` in one transaction.
    fn publish(&self, request: &BarrierRequest) -> Result<AdmissionBarrier>;

    /// The barrier in force for a scope, if any.
    ///
    /// A cleared or never-written barrier answers `None`; a stop is never
    /// cleared, so a scope that was stopped keeps answering with it.
    fn barrier(&self, scope: &BarrierScope) -> Result<Option<AdmissionBarrier>>;
}

/// What a scope may honestly be shown as.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PauseState {
    /// No barrier is in force.
    NotPaused,
    /// A pause is in force and work is still draining. Shown as requested, not
    /// as paused: the run is still running.
    PauseRequested,
    /// The pause is in force and nothing is in flight, so the facts support
    /// showing it.
    Paused,
    /// The scope was stopped.
    Stopped,
}

impl PauseState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotPaused => "notPaused",
            Self::PauseRequested => "pauseRequested",
            Self::Paused => "paused",
            Self::Stopped => "stopped",
        }
    }
}

/// What a scope's pause state is shown from.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScopeStatus {
    pub pause: PauseState,
    /// Why, when a barrier is in force.
    pub reason: Option<String>,
    pub in_flight: usize,
    /// The scope's original terminal outcome, reported as it was.
    ///
    /// A pause writes a barrier; it does not rewrite an outcome that already
    /// happened. This field is copied through, never derived from the barrier.
    pub terminal: Option<NodeOutcomeKind>,
}

/// The pause state the facts support for one scope.
///
/// The rule is deliberately conservative: `Paused` requires a written barrier
/// *and* nothing in flight. Anything else would let a UI report a paused run
/// that is still producing effects.
pub fn scope_status(
    barrier: Option<&AdmissionBarrier>,
    in_flight: usize,
    terminal: Option<NodeOutcomeKind>,
) -> ScopeStatus {
    let (pause, reason) = match barrier {
        None => (PauseState::NotPaused, None),
        Some(barrier) => {
            let reason = Some(barrier.reason.clone());
            match barrier.kind {
                BarrierKind::Stop => (PauseState::Stopped, reason),
                BarrierKind::Pause if in_flight == 0 => (PauseState::Paused, reason),
                BarrierKind::Pause => (PauseState::PauseRequested, reason),
            }
        }
    };
    ScopeStatus {
        pause,
        reason,
        in_flight,
        terminal,
    }
}
