//! The drive's own account of what it did, in the order it did it.
//!
//! The ordering this records is the load-bearing part of the design, and it is
//! worth being able to read it back rather than infer it from a store dump:
//!
//! * a claim's possible-effect marker is committed *before* the effect is
//!   invoked (`Admitted.marker_sequence`), which is why recovery may treat a
//!   started command as in doubt;
//! * an outcome is committed *before* the next admission, and an admission that
//!   follows a settlement names it (`Admitted.after`), which is what "advance on
//!   each completion" means when written down;
//! * a control request records how many completions were waiting when it was
//!   handled (`Control.results_pending`), which is what "control is not starved
//!   by results" means when written down.
//!
//! The trace is in-process evidence. It is never durable state, and nothing in a
//! drive's correctness depends on it being read.

use licoup_workflow::StrategyRunStatus;

use super::control::ControlReceipt;
use crate::admission::BarrierKind;
use crate::node::{NodeOutcomeKind, NodeVisitKey};

/// One command that was claimed, marked, and dispatched.
#[derive(Clone, Debug, PartialEq)]
pub struct Admission {
    pub command_id: String,
    pub node: NodeVisitKey,
    pub claimant: String,
    /// The run sequence the possible-effect marker was committed at. It precedes
    /// the invocation that followed it.
    pub marker_sequence: u64,
    /// The command whose committed outcome allowed this admission to happen.
    /// `None` means the admission did not follow a settlement in this turn.
    pub after: Option<String>,
    /// Effects in flight, including this one, after admission.
    pub in_flight: usize,
}

/// One effect whose outcome was committed.
#[derive(Clone, Debug, PartialEq)]
pub struct Settlement {
    pub command_id: String,
    pub node: NodeVisitKey,
    pub outcome: NodeOutcomeKind,
    /// The run sequence the outcome was committed at.
    pub sequence: u64,
    /// Effects still in flight after this settlement.
    pub in_flight: usize,
}

/// One thing the drive did.
#[derive(Clone, Debug, PartialEq)]
pub enum DriveEvent {
    /// The run was taken under a fence.
    Owned {
        claimant: String,
    },
    Admitted(Admission),
    Settled(Settlement),
    /// A completion arrived for an effect whose cancellation had been requested.
    /// The observed outcome is recorded here because it is *not* what the run
    /// committed: a late result is reported, and the cancellation is settled as
    /// what the effect port actually confirmed.
    LateOutcome {
        command_id: String,
        observed: NodeOutcomeKind,
        settled: NodeOutcomeKind,
    },
    Control(ControlReceipt),
    /// An adapter call failed. The operation is named and the text is kept here
    /// and nowhere else: it is in-process evidence, not a durable fact.
    AdapterError {
        command_id: String,
        operation: &'static str,
        detail: String,
    },
    /// An admitted effect will never report: its thread ended without a verdict,
    /// or it never started.
    EffectLost {
        command_id: String,
        node: NodeVisitKey,
        detail: Option<String>,
    },
    Stopped(DriveStop),
}

/// Why a drive stopped.
#[derive(Clone, Debug, PartialEq)]
pub enum DriveStop {
    /// Nothing is dispatchable and nothing is in flight.
    ///
    /// `budget_exhausted` separates "there is no more work" from "this call's
    /// effect budget ran out", which is the difference between a finished run
    /// and one another `drive` call should continue.
    Quiescent { budget_exhausted: bool },
    /// The run reached a terminal status; no further effect may start.
    Terminal { status: StrategyRunStatus },
    /// The run needs authorization before another effect may start. Resolving it
    /// is not this crate's decision (V7-R2 owns admission).
    AwaitingAuthorization,
    /// A run-scope fence was in force: this drive may not start the work that
    /// exists. The kind says whether the fence was a pause (clearable) or a
    /// stop (monotonic). A node-scoped instruction does not fence a new visit,
    /// so it never produces this stop.
    Fenced { kind: BarrierKind },
}

/// The events of one drive.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DriveTrace {
    events: Vec<DriveEvent>,
}

impl DriveTrace {
    pub(crate) fn push(&mut self, event: DriveEvent) {
        self.events.push(event);
    }

    pub fn events(&self) -> &[DriveEvent] {
        &self.events
    }

    pub fn len(&self) -> usize {
        self.events.len()
    }

    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    pub fn admissions(&self) -> impl Iterator<Item = &Admission> {
        self.events.iter().filter_map(|event| match event {
            DriveEvent::Admitted(admission) => Some(admission),
            _ => None,
        })
    }

    pub fn settlements(&self) -> impl Iterator<Item = &Settlement> {
        self.events.iter().filter_map(|event| match event {
            DriveEvent::Settled(settlement) => Some(settlement),
            _ => None,
        })
    }

    pub fn controls(&self) -> impl Iterator<Item = &ControlReceipt> {
        self.events.iter().filter_map(|event| match event {
            DriveEvent::Control(receipt) => Some(receipt),
            _ => None,
        })
    }

    /// The effects whose threads ended without a verdict.
    pub fn lost(&self) -> impl Iterator<Item = (&str, &NodeVisitKey, Option<&str>)> {
        self.events.iter().filter_map(|event| match event {
            DriveEvent::EffectLost {
                command_id,
                node,
                detail,
            } => Some((command_id.as_str(), node, detail.as_deref())),
            _ => None,
        })
    }

    /// Where a command's outcome was committed.
    pub fn index_of_settlement(&self, command_id: &str) -> Option<usize> {
        self.events.iter().position(|event| {
            matches!(event, DriveEvent::Settled(settlement) if settlement.command_id == command_id)
        })
    }

    /// Where a command was admitted.
    pub fn index_of_admission(&self, command_id: &str) -> Option<usize> {
        self.events.iter().position(|event| {
            matches!(event, DriveEvent::Admitted(admission) if admission.command_id == command_id)
        })
    }

    /// Where a control request was handled.
    pub fn index_of_control(&self, request_id: &str) -> Option<usize> {
        self.events.iter().position(|event| {
            matches!(event, DriveEvent::Control(receipt) if receipt.request_id == request_id)
        })
    }

    pub fn stop(&self) -> Option<&DriveStop> {
        self.events.iter().find_map(|event| match event {
            DriveEvent::Stopped(stop) => Some(stop),
            _ => None,
        })
    }
}
