//! Successor handoff: moving a run to a new definition, owner, and boundary.
//!
//! A handoff is one compare-and-set over the facts the manifest was built from,
//! and it refuses whole rather than transferring partially:
//!
//! ```text
//!   manifest claims                        store verifies
//!   ────────────────────────────────────   ─────────────────────────────────
//!   expected_revision                      the run's active sequence
//!   old_owner (owner#generation fence)     every live claim's owner
//!   unstarted intents (visit-exact)        the run's pending/retryable set
//!   started attempts (visit-exact)         the run's claimed/started set
//!   old_binding                            the run's definition revision and,
//!                                          through the new owner's profile,
//!                                          whether that binding is admissible
//! ```
//!
//! Three properties follow and each is a test rather than a promise:
//!
//! * **Started work stays with the owner that started it.** The manifest lists
//!   the live attempts; a manifest that omits one, or lists a live attempt as
//!   unstarted, is refused. The new owner can never claim or re-dispatch an
//!   attempt that may already have an effect in the outside world.
//! * **A boundary result is a reference, not a grant.** [`BoundaryManifest`]
//!   carries the result identities a successor may cite and an explicit grant
//!   list that starts empty. [`BoundaryManifest::may_read`] consults only the
//!   grants, so citing a predecessor's result never becomes read authority over
//!   it.
//! * **One handoff per run.** The store keys the handoff by run, so a second
//!   attempt — even with a matching manifest — is refused with the identity of
//!   the transfer that already exists instead of creating a second successor.
//!
//! The unbinding of the old owner is not a rewrite of its work: it keeps every
//! claim it holds and may still settle it. What ends is its ability to *start*
//! new work, which [`SuccessorPort::claim_admission`] answers for a store that
//! consults it before handing out a claim.

use anyhow::Result;
use licoup_workflow::ResultRef;
use licoup_workflow::compile::{HandoffReason, InterpreterProfile, RecordedPlanKey};
use serde::{Deserialize, Serialize};

use super::recovery::{CheckpointHandoff, EffectBoundary};

/// One result a successor may cite at the boundary.
///
/// Only an explicit grant makes it readable elsewhere: the reference alone is
/// identity, not authority.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadGrant {
    /// The grant this read is issued under, owned by whoever issues grants.
    pub grant_id: String,
    pub result: ResultRef,
}

/// What the successor boundary looks like from the run's own committed facts.
///
/// The results are exactly the result identities the checkpoint recorded at the
/// boundary revision — the arrivals a join ledger or a node binding already
/// names — so the manifest cannot invent a result the run never produced.
/// Nothing here carries a payload.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BoundaryManifest {
    pub run_id: String,
    /// The sequence the boundary was taken at.
    pub revision: u64,
    #[serde(default)]
    pub results: Vec<ResultRef>,
    /// Explicit read grants. Empty unless an authority issued one; a successor
    /// that needs to read must obtain one, exactly like any other reader.
    #[serde(default)]
    pub grants: Vec<ReadGrant>,
}

impl BoundaryManifest {
    /// A boundary with no results yet.
    pub fn empty(run_id: impl Into<String>, revision: u64) -> Self {
        Self {
            run_id: run_id.into(),
            revision,
            results: Vec::new(),
            grants: Vec::new(),
        }
    }

    /// Whether a result may be read under this boundary. Citing a result does
    /// not grant it: only a matching grant does.
    pub fn may_read(&self, result: &ResultRef) -> bool {
        self.grants.iter().any(|grant| &grant.result == result)
    }
}

/// One declared intent that had not started when the boundary was taken.
#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UnstartedIntent {
    pub command_id: String,
    pub attempt_token: String,
    pub node_id: String,
    pub node_visit: u64,
}

/// One attempt that had already crossed its claim or its effect boundary.
///
/// A claimed attempt is included because its claim may become a marker at any
/// moment: it belongs to the owner that holds it, not to the successor.
#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LiveAttempt {
    pub command_id: String,
    pub attempt_token: String,
    pub node_id: String,
    pub node_visit: u64,
    /// [`EffectBoundary::Claimed`] or [`EffectBoundary::Started`].
    pub phase: EffectBoundary,
}

/// The facts a handoff is built from.
///
/// `old_binding` is what the caller believes the run is bound to. The store
/// checks the parts it can prove (the definition revision) and asks the new
/// owner's profile whether the binding is admissible; a binding whose semantics
/// this build cannot prove is handed off, never reinterpreted.
#[derive(Clone, Debug)]
pub struct SuccessorManifest {
    pub handoff_id: String,
    pub run_id: String,
    pub expected_revision: u64,
    /// The owner fence in force at the boundary (`owner#generation`).
    pub old_owner: String,
    /// The owner taking the successor.
    pub new_owner: String,
    pub old_binding: RecordedPlanKey,
    /// The semantics the new owner executes.
    pub new_owner_profile: InterpreterProfile,
    pub unstarted: Vec<UnstartedIntent>,
    pub started: Vec<LiveAttempt>,
}

/// Why a handoff was refused. Nothing was transferred in any variant.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "refusal")]
pub enum HandoffRefusal {
    /// No run with this identity exists.
    RunNotFound { run_id: String },
    /// The checkpoint cannot be read with its causal state intact; a handoff is
    /// not a way to advance something this build cannot read.
    Checkpoint { reason: CheckpointHandoff },
    /// The checkpoint is malformed in a way no handoff fixes.
    CheckpointRefused { code: String },
    /// The new owner's profile may not lower the run's binding because a
    /// declared lowering capability is missing.
    MissingCapability { capability: String },
    /// The run moved since the manifest was built.
    RevisionMoved { expected: u64, current: u64 },
    /// A live claim is held by an owner the manifest did not name. Another owner
    /// is working on the run, or the manifest names the wrong fence.
    OwnerMoved {
        expected: String,
        current: Option<String>,
    },
    /// The run's definition revision is not the one the manifest claims.
    BindingMismatch { expected: String, current: String },
    /// The new owner's profile may not advance the run's binding.
    SemanticsHandoff { reason: SemanticsHandoffReason },
    /// An unstarted intent of the manifest is not unstarted in the store.
    UnstartedSetMoved { command_id: String, in_store: bool },
    /// A live attempt of the manifest is not live in the store.
    StartedSetMoved { command_id: String, in_store: bool },
    /// An attempt moved between claimed and started after the manifest was
    /// built. Both are live, but the fact the manifest was built from changed.
    PhaseMoved {
        command_id: String,
        manifest: EffectBoundary,
        current: EffectBoundary,
    },
    /// A handoff already exists for this run. The identity of the existing
    /// transfer is reported so a caller can follow it instead of replacing it.
    AlreadyHandedOff { handoff_id: String },
}

/// Why a profile could not advance a run's binding, in a storable form.
///
/// The compiler's own [`HandoffReason`] is the source of these values; this is
/// the same answer as a durable token, because a refusal that is read back later
/// has to name the input that changed rather than a path someone chose.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SemanticsHandoffReason {
    /// The plan was lowered by compiler semantics this build does not implement.
    CompilerSemantics,
    /// The run was advanced under engine semantics this build does not execute.
    EngineSemantics,
    /// The recorded binding cannot be matched to a version this build declares.
    UnprovenSemantics,
}

impl From<HandoffReason> for SemanticsHandoffReason {
    fn from(reason: HandoffReason) -> Self {
        match reason {
            HandoffReason::CompilerSemantics => Self::CompilerSemantics,
            HandoffReason::EngineSemantics => Self::EngineSemantics,
            HandoffReason::UnprovenSemantics => Self::UnprovenSemantics,
        }
    }
}

impl SemanticsHandoffReason {
    pub fn wire(self) -> &'static str {
        match self {
            Self::CompilerSemantics => "compiler_semantics",
            Self::EngineSemantics => "engine_semantics",
            Self::UnprovenSemantics => "unproven_semantics",
        }
    }
}

/// What a committed handoff transferred, and the boundary it left behind.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HandoffReceipt {
    pub handoff_id: String,
    pub run_id: String,
    pub revision: u64,
    pub old_owner: String,
    pub new_owner: String,
    /// The unstarted intents the successor may start, exactly once.
    pub migrated: Vec<UnstartedIntent>,
    /// The attempts that stay with the old owner.
    pub started: Vec<LiveAttempt>,
    pub boundary: BoundaryManifest,
}

/// The durable record of one run's handoff, as a later reader sees it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SuccessorRecord {
    pub handoff_id: String,
    pub run_id: String,
    pub revision: u64,
    pub old_owner: String,
    pub new_owner: String,
    pub migrated: Vec<UnstartedIntent>,
    pub started: Vec<LiveAttempt>,
    pub boundary: BoundaryManifest,
    pub created_at_unix_ms: i64,
}

/// Whether an owner may take new work from a run.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "claim")]
pub enum ClaimAdmission {
    /// No successor exists, or the caller is the successor.
    Admitted,
    /// A handoff is in force and this owner is not it. The old fence may still
    /// settle the work it started; it may not start new work.
    Fenced {
        handoff_id: String,
        new_owner: String,
    },
}

/// The handoff surface a host uses.
///
/// The store implements it. `handoff` is the compare-and-set; `successor_of`
/// reads what a committed transfer left behind; `claim_admission` is what a
/// claim path consults before handing a run's work to an owner.
pub trait SuccessorPort: Send + Sync {
    fn handoff(&self, manifest: &SuccessorManifest) -> Result<HandoffOutcome>;

    fn successor_of(&self, run_id: &str) -> Result<Option<SuccessorRecord>>;

    fn claim_admission(&self, run_id: &str, claimant: &str) -> Result<ClaimAdmission>;
}

/// The answer to a handoff attempt.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "handoff")]
pub enum HandoffOutcome {
    Committed { receipt: Box<HandoffReceipt> },
    Refused { refusal: HandoffRefusal },
}
