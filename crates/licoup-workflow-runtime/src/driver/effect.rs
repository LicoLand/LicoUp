//! The effect side of a drive: the port an adapter implements.
//!
//! This is C01's `EffectPort`, declared by the consumer that calls it. Three
//! properties of the declaration are deliberate:
//!
//! * [`EffectRequest`] carries data only. There is no driver handle, no
//!   ownership registry and no port reference in it, so an adapter cannot reach
//!   the drive loop through its inputs; and driving again anyway — from a
//!   handle the composition root wired by mistake — is refused by the run's
//!   ownership fence (see [`super::owner`]).
//! * The port is synchronous and returns a *verdict*. The driver calls `submit`
//!   on a worker thread and never under a lock, so a slow adapter occupies its
//!   own thread and nothing else.
//! * `cancel` and `steer` are control, not completion. They must not block until
//!   the effect finishes: the effect's own completion still arrives through
//!   `submit`'s return, which is what keeps C03's split between a cancellation
//!   *request* and a cancellation *confirmation* honest.
//!
//! **On payloads.** An effect's success payload is JSON, and this crate has no
//! JSON dependency (it depends on `anyhow`, `serde` and the pure machine, and
//! adding a substrate crate here would be a contract change, not a detail). So
//! the payload crosses the port *inside the machine's own success event*
//! ([`EffectOutcome::Succeeded`]), the one type in the dependency set that can
//! carry it. The driver never re-derives the payload, and it never trusts the
//! identity the adapter put beside it: it refuses an event that is not a success
//! for exactly the command and attempt it dispatched, and commits the event
//! rebuilt with its own identity. A steering instruction is text for the same
//! reason: a structured steer envelope belongs to the control owner that
//! defines its schema (V7-R3 routing, V7-R4 adapters).
//!
//! C01 also lists `observe` and `reconcile` on this port. They are not declared
//! here: they are called by the recovery leaves that own in-doubt effects
//! (V7-S2, V7-I1). Declaring a method nothing calls would fix a signature nobody
//! has implemented, which is the opposite of what this crate is for.

use anyhow::Result;
use licoup_workflow::{FailureClass, ReducerEvent, RunCommand};
use serde::{Deserialize, Serialize};

use crate::node::NodeVisitKey;

/// One effect the driver asks an adapter to perform.
///
/// The whole claimed command travels, because the adapter's own contract is
/// written against it: the effect identity (`command.id`), the attempt identity
/// (`command.attempt_token`), the node visit, the binding and the input all come
/// from the store's claim rather than from anything the driver re-invents.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EffectRequest {
    pub run_id: String,
    /// The claim as the store handed it to this drive.
    pub command: RunCommand,
}

impl EffectRequest {
    /// The exact request for one claimed command.
    pub fn from_command(run_id: &str, command: &RunCommand) -> Self {
        Self {
            run_id: run_id.to_owned(),
            command: command.clone(),
        }
    }

    pub fn command_id(&self) -> &str {
        &self.command.id
    }

    pub fn attempt_token(&self) -> &str {
        &self.command.attempt_token
    }

    pub fn node(&self) -> NodeVisitKey {
        NodeVisitKey::from_command(&self.command)
    }
}

/// What an adapter reports for one completed effect.
///
/// The adapter picks the failure class, because it is the only party that knows
/// whether the effect executed: `Transient` for a known-not-executed effect,
/// `Permanent` for an executed failure, `InDoubt` only when it cannot tell.
/// `Unknown` is the last of those and is deliberately not a class: it is a
/// statement that no verdict exists, and the driver records it as in doubt
/// rather than letting it be retried as a failure.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "status")]
pub enum EffectOutcome {
    /// The effect happened, and this is the machine event that records it.
    ///
    /// It must be `CommandSucceeded` for exactly the command and attempt the
    /// adapter was given; anything else is refused and the drive stops, because
    /// an adapter that cannot state the settlement of the command it was given
    /// has left that command in doubt rather than settled.
    Succeeded { result: ReducerEvent },
    /// The effect was attempted and failed in the named way.
    Failed { class: FailureClass, code: String },
    /// The adapter cannot say what happened (host lost, transport gone).
    Unknown { code: String },
}

/// One request to stop an effect that is already in flight.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CancelRequest {
    /// The control request this came from, so a repeated delivery is
    /// recognisable as a repeat.
    pub control_request_id: String,
    pub run_id: String,
    pub command_id: String,
    pub attempt_token: String,
}

/// What an adapter says about a cancellation it was asked for.
///
/// Four answers, because three of them are not each other: "it will not produce
/// an outcome", "I saw the request and declined it", "I cannot cancel what I
/// started" and "I cannot say". A single boolean would collapse the last three
/// into one and lose the only fact recovery needs.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "confirmation")]
pub enum CancelConfirmation {
    /// The effect will not produce an outcome; the request was honoured.
    Acknowledged,
    /// The adapter saw the request and declined it, with a code saying why.
    Refused { code: String },
    /// This adapter cannot cancel effects it has already started.
    Unsupported,
    /// The adapter cannot say whether the effect stopped.
    Unknown,
}

/// One steering message for effects that are already in flight.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SteerRequest {
    pub control_request_id: String,
    pub run_id: String,
    pub command_id: String,
    pub attempt_token: String,
    /// What the running effect should do differently. Text, not an envelope: the
    /// driver does not interpret it.
    pub instruction: String,
}

/// Making effects happen, and asking in-flight effects to change course.
///
/// Implementations are owned by whoever owns the underlying effect (V7-R4 for
/// the existing native adapters). The driver holds this trait object behind an
/// `Arc` and calls it from a worker thread; nothing in the trait lets an
/// implementation call back into the drive loop.
pub trait EffectPort: Send + Sync {
    /// Perform one effect and report its verdict.
    fn submit(&self, request: &EffectRequest) -> Result<EffectOutcome>;

    /// Ask an in-flight effect to stop.
    ///
    /// Must not block until the effect finishes: the answer is the adapter's
    /// position on the request, not the effect's completion.
    fn cancel(&self, request: &CancelRequest) -> Result<CancelConfirmation>;

    /// Deliver a steering message to an in-flight effect.
    fn steer(&self, request: &SteerRequest) -> Result<()>;
}
