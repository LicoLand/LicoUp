//! Control requests: changing what running effects do, off the result path.
//!
//! A control request travels its own bounded queue, is taken before results, and
//! acts on the recipients that were in flight when it was handled. That last
//! part is C03's rule, and it is visible in [`ControlReceipt::frozen`]: the set
//! is taken once, so an effect admitted after the request is not retroactively a
//! recipient of it.
//!
//! Three instructions exist, and the third is deliberately not the first:
//!
//! * [`ControlKind::Cancel`] is a durable cancellation of the run: what had not
//!   started is cancelled, and each in-flight effect settles as what its port
//!   confirms.
//! * [`ControlKind::Steer`] delivers a message to frozen recipients and settles
//!   nothing.
//! * [`ControlKind::Fence`] stops new work from starting in a scope without
//!   cancelling anything: the run-scoped form is C03's pause/stop instruction,
//!   its recipients are frozen in the same write as the barrier, and an effect
//!   already in flight still settles by its own authenticated outcome. Writing a
//!   pause as a cancel would erase exactly that distinction.
//!
//! Three things this module deliberately does *not* own:
//!
//! * The durable queue, its cursors, and fairness between control, result and
//!   bulk across hosts belong to V7-R3's `routing`. What is here is the in-drive
//!   hand-off: a control request must not wait behind the completions it is
//!   running against.
//! * The admission barrier itself belongs to V7-R2's `admission`; this module
//!   carries the request and the receipt, and [`ControlReceipt::barrier`] is the
//!   published barrier when a barrier owner is wired.
//! * The authority and resource recheck at the admission boundary is V7-R2's
//!   gate and is not performed here. This module stops new starts after a fence
//!   *this drive handled*, and reports the barrier it published; it does not
//!   claim that an effect's authority was checked.

use serde::{Deserialize, Serialize};

use crate::admission::{AdmissionBarrier, BarrierKind};
use crate::node::FrozenRecipients;

pub use super::effect::CancelConfirmation;
pub use crate::node::ControlTarget;

use std::fmt::{Display, Formatter};

/// One control request addressed to a run.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlRequest {
    /// Stable identity of the request, so a re-delivered control is recognisable
    /// as a repeat rather than as a second instruction.
    pub request_id: String,
    pub kind: ControlKind,
}

impl ControlRequest {
    pub fn cancel(request_id: impl Into<String>) -> Self {
        Self {
            request_id: request_id.into(),
            kind: ControlKind::Cancel,
        }
    }

    pub fn steer(
        request_id: impl Into<String>,
        target: ControlTarget,
        instruction: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            kind: ControlKind::Steer {
                target,
                instruction: instruction.into(),
            },
        }
    }

    /// Stop starting new work in `target`; in-flight work keeps running and
    /// settles by its own outcome. A run-scoped pause is clearable by a later
    /// resume; a run-scoped stop is not.
    pub fn pause(
        request_id: impl Into<String>,
        target: ControlTarget,
        reason: impl Into<String>,
    ) -> Self {
        Self::fence(request_id, target, BarrierKind::Pause, reason)
    }

    /// Stop the scope: monotonic, and not cleared by a later resume.
    pub fn stop(
        request_id: impl Into<String>,
        target: ControlTarget,
        reason: impl Into<String>,
    ) -> Self {
        Self::fence(request_id, target, BarrierKind::Stop, reason)
    }

    fn fence(
        request_id: impl Into<String>,
        target: ControlTarget,
        kind: BarrierKind,
        reason: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            kind: ControlKind::Fence {
                target,
                kind,
                reason: reason.into(),
            },
        }
    }

    pub fn tag(&self) -> ControlTag {
        self.kind.tag()
    }
}

/// What a control request asks for.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "control")]
pub enum ControlKind {
    /// Stop starting new effects, record the durable request, and ask the
    /// effects already in flight to stop. The request is not the confirmation:
    /// each in-flight effect still settles through its own completion.
    Cancel,
    /// Deliver a message to the effects in flight for the target. A steer
    /// settles nothing.
    Steer {
        target: ControlTarget,
        instruction: String,
    },
    /// Stop starting new work in the target's scope, and freeze the recipients
    /// that were in flight in the same write as the barrier.
    ///
    /// This is not a cancellation: nothing in flight is settled by it. A
    /// run-scoped fence stops a new node visit from starting (C03), a
    /// node-scoped fence does not.
    Fence {
        target: ControlTarget,
        kind: BarrierKind,
        reason: String,
    },
}

impl ControlKind {
    pub fn tag(&self) -> ControlTag {
        match self {
            Self::Cancel => ControlTag::Cancel,
            Self::Steer { .. } => ControlTag::Steer,
            Self::Fence { kind, .. } => ControlTag::Fence(*kind),
        }
    }
}

/// A control kind without its payload, for records and traces.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ControlTag {
    Cancel,
    Steer,
    Fence(BarrierKind),
}

impl Display for ControlTag {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Cancel => "cancel",
            Self::Steer => "steer",
            Self::Fence(BarrierKind::Pause) => "pause",
            Self::Fence(BarrierKind::Stop) => "stop",
        })
    }
}

/// A control request that was taken by the drive loop.
#[derive(Clone, Debug, PartialEq)]
pub struct ControlReceipt {
    pub request_id: String,
    pub kind: ControlTag,
    /// The recipients this request acted on, frozen when it was handled.
    pub frozen: FrozenRecipients,
    /// What the effect port said about each cancellation it was asked for, in
    /// the order the requests were sent.
    pub confirmations: Vec<(String, CancelConfirmation)>,
    /// The barrier this instruction published, when a barrier owner was wired
    /// for the drive. `None` on a request that writes no barrier, and on a
    /// fence handled by a driver that has no barrier owner: that fence stopped
    /// new starts inside this call, but no durable barrier was written.
    pub barrier: Option<AdmissionBarrier>,
    /// How many completions were waiting when the control was handled. A
    /// non-zero value here is the evidence that control did not queue behind
    /// the result path.
    pub results_pending: usize,
    pub in_flight: usize,
}

/// A control request the driver accepted for a running drive.
///
/// Acceptance means the request is in the drive's control queue, not that it has
/// been acted on yet; the receipt of the action is in the drive's trace.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ControlAccepted {
    pub request_id: String,
}
