//! Recovery and successor handoff: what a second host may do with a run it did
//! not start.
//!
//! A drive holds a run only while it runs. When it stops — cleanly, by crash, or
//! because another host takes over — the durable facts it left behind are the
//! only account of what may already have happened outside this process. This
//! module is the consumer-owned vocabulary for reading that account and for
//! transferring a run to a successor without inventing authority.
//!
//! Two boundaries carry the whole contract, and both are explicit rather than
//! derived:
//!
//! ```text
//!   claimed            started
//!   ── claim taken ──► ── possible-effect marker committed ──► effect may exist
//!     provably not         recovery treats the attempt as unknown and never
//!     executed             re-dispatches it on lease or observation alone
//! ```
//!
//! * The *claimed/started* boundary is a durable fact, not an inference. A
//!   lease running out says how long a claim was valid; it does not say the
//!   effect never ran, that the OS writer exited, or that a directory state of
//!   "stopped" proves anything about a process. Recovery therefore reads the
//!   marker, never the clock: [`EffectBoundary::Claimed`] is the only boundary
//!   that yields a general safe re-dispatch, and even then only through the
//!   machine's own retry path, which mints a new attempt identity so a late
//!   marker from the old attempt cannot land on the new one.
//! * The *successor* boundary is a compare-and-set on the facts the handoff was
//!   built from: the run revision, the owner fence, and the exact visit set
//!   that had started before the boundary. A CAS that does not match refuses
//!   whole: nothing is transferred partially, started work stays with the owner
//!   that started it, and boundary results are *references* the successor may
//!   cite — never a read grant it did not receive.
//!
//! What lives here is the vocabulary and the ports; the durable implementation
//! is the store's (`licoup-workflow-store::recovery`), and the production
//! wiring is the host's (V7-I1). Declaring the shapes in the consumer crate is
//! what keeps a store replaceable: the store implements these traits, it does
//! not define them.
//!
//! No payload crosses this module by value. A confirmed outcome travels inside
//! the machine's own event ([`recovery::EffectObservation::Outcome`]), exactly
//! as it does on the drive's effect port, so the reconciliation path cannot
//! become a second way to settle a command with a payload nobody authenticated.

pub mod handoff;
pub mod recovery;

pub use handoff::{
    BoundaryManifest, ClaimAdmission, HandoffOutcome, HandoffReceipt, HandoffRefusal, LiveAttempt,
    ReadGrant, SuccessorManifest, SuccessorPort, SuccessorRecord, UnstartedIntent,
};
pub use recovery::{
    CheckpointAdmission, CheckpointHandoff, ClaimStanding, EFFECT_NOT_EXECUTED, EffectBoundary,
    EffectObservation, EffectSilence, HOST_RUNTIME_LOST, LEASE_EXPIRED_BEFORE_START,
    NotReachedProof, OutstandingEffect, ReconcileOutcome, ReconcileRefusal, ReconcileSettlement,
    RecoveryCause, RecoveryDecision, RecoveryPort, RecoveryReport, RecoveryRequest, RefusedAttempt,
    RetriedAttempt, UnconfirmedReason, decide,
};
