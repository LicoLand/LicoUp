//! Effect recovery: what a durable attempt is, and what recovery may conclude.
//!
//! The vocabulary here is C03's, stated as values so a store cannot quietly
//! substitute a different question. Two rules are the reason it looks the way
//! it does:
//!
//! * **Recovery reads the marker, not the clock.** A decision is derived from
//!   [`EffectBoundary`], which is the durable claimed/started fact, and from an
//!   [`EffectObservation`], which is a fact some owner of the effect reported.
//!   A lapsed lease, a silent observation, and a caller's claim that a writer
//!   looks stopped are all [`UnconfirmedReason`]s: they are absence of evidence
//!   and never evidence of absence. The single general re-dispatch proof is
//!   [`NotReachedProof::MarkerAbsent`] — the drive commits the possible-effect
//!   marker before it invokes anything, so an attempt that never got the marker
//!   provably never reached its effect — and a confirmed
//!   [`NotReachedProof::OwnerReportedNotExecuted`] from the effect's own owner.
//! * **An unknown stays unknown.** [`RecoveryDecision::Hold`] performs no write;
//!   the run keeps the attempt as it is. [`RecoveryDecision::SettleUnknown`] is
//!   reserved for a caller that supplies its own evidence that one owner is
//!   gone, because only then is it true that no late outcome can still arrive.
//!   Neither path re-dispatches anything, and neither creates authority for
//!   anyone.
//!
//! The durable codes are constants rather than literals so the store, the tests,
//! and any operator query agree on the exact strings a recovery wrote.

use anyhow::Result;
use licoup_workflow::ReducerEvent;
use serde::{Deserialize, Serialize};

/// The durable code for a claim that never reached its effect.
pub const LEASE_EXPIRED_BEFORE_START: &str = "lease_expired_before_start";
/// The durable code for an attempt whose owner is declared lost: it may have
/// executed, so the run records that its position is unknown.
pub const HOST_RUNTIME_LOST: &str = "host_runtime_lost";
/// The durable code for an attempt whose effect owner confirmed it did not run.
pub const EFFECT_NOT_EXECUTED: &str = "effect_not_executed";

/// Where one durable attempt stands against the possible-effect boundary.
///
/// The two names that matter are `Claimed` and `Started`: they are the difference
/// between an attempt that provably never reached its effect and one that may
/// already exist outside this process.
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EffectBoundary {
    /// Nothing was claimed and no marker exists: this is queued work.
    NotStarted,
    /// A claim exists and the possible-effect marker was never committed. A
    /// drive commits that marker before it invokes the effect, so this attempt
    /// provably never reached it — a late marker from the old claim cannot land
    /// on the replacement, because the machine's retry mints a new identity.
    Claimed,
    /// The marker is durable: the effect may already exist in the outside world.
    Started,
    /// An outcome is committed; nothing in recovery re-opens it.
    Settled,
}

impl EffectBoundary {
    /// Whether the effect may already have happened.
    pub fn may_have_executed(self) -> bool {
        matches!(self, Self::Started)
    }

    /// The durable status names this boundary is derived from, for diagnostics.
    pub fn wire(self) -> &'static str {
        match self {
            Self::NotStarted => "not-started",
            Self::Claimed => "claimed",
            Self::Started => "started",
            Self::Settled => "settled",
        }
    }
}

/// What the durable claim says about one attempt.
///
/// Deliberately separate from [`EffectBoundary`]: a claim with time left is not
/// a statement about the effect, and a claim without time left is not a
/// statement about the owner's process.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ClaimStanding {
    /// No attempt row ever claimed it.
    Unclaimed,
    /// A claim with time left: some owner may still be working on it.
    Held { owner: String, until_unix_ms: i64 },
    /// A claim whose time ran out. The owner is not proven gone, and the effect
    /// is not proven unexecuted.
    Lapsed { owner: String, until_unix_ms: i64 },
}

impl ClaimStanding {
    pub fn owner(&self) -> Option<&str> {
        match self {
            Self::Unclaimed => None,
            Self::Held { owner, .. } | Self::Lapsed { owner, .. } => Some(owner),
        }
    }

    /// Whether the claim still has time left at `now_unix_ms`.
    pub fn is_live_at(&self, now_unix_ms: i64) -> bool {
        matches!(self, Self::Held { until_unix_ms, .. } if *until_unix_ms > now_unix_ms)
    }
}

/// One durable attempt that has not reached a settled outcome.
///
/// Every field is a fact the store read from its own rows. The node visit is
/// carried so a decision can name exactly which visit it is about; a decision
/// that named only a node would be usable against a different visit.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutstandingEffect {
    pub run_id: String,
    pub command_id: String,
    pub attempt_token: String,
    pub node_id: String,
    pub node_visit: u64,
    pub boundary: EffectBoundary,
    pub claim: ClaimStanding,
    /// The committed output digest when one exists, so recovery can tell a
    /// settled attempt from one that only reported.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_digest: Option<String>,
}

/// Why a recovery pass is being run.
///
/// The cause is a caller's statement, not something recovery infers. A lease
/// lapse is observable by anyone; a lost host is a conclusion that requires the
/// caller's own evidence (a host record, a supervised process fact, an operator
/// decision), and recovery will not manufacture it from a clock or a directory.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RecoveryCause {
    /// Claim time simply passed. It states nothing about any owner's process.
    LeaseLapsed,
    /// A caller with its own evidence declares one owner's process lost. The
    /// owner is the exact fence value (`owner#generation`), so a declaration
    /// can never be read as covering a newer owner of the same name.
    HostDeclaredLost { owner: String, source: String },
}

/// The proof that a general re-dispatch is safe, carried by every retry.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NotReachedProof {
    /// The attempt never crossed the possible-effect boundary.
    MarkerAbsent,
    /// The effect's own owner confirmed the effect did not happen.
    OwnerReportedNotExecuted { source: String },
}

/// Why an observation produced no fact.
///
/// These mirror the effect owner's own reasons: a missing read-back channel and
/// a missing record are different answers from "the effect failed", and both
/// leave the attempt unknown.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EffectSilence {
    /// The adapter holds no read-back channel in this process.
    NoReadBackChannel,
    /// The adapter was asked and holds no record of this attempt.
    NoRecordedResult,
}

impl EffectSilence {
    pub fn wire(self) -> &'static str {
        match self {
            Self::NoReadBackChannel => "no_read_back_channel",
            Self::NoRecordedResult => "no_recorded_result",
        }
    }
}

/// Why an attempt stays unknown.
///
/// Every variant is an absence of evidence. None of them may be turned into a
/// re-dispatch, and none of them is a statement that the effect did not run.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum UnconfirmedReason {
    /// Another owner holds a live claim: it may be working on this attempt, so
    /// recovery holds rather than stealing it.
    LeaseHeld { owner: String },
    /// The claim's time ran out. The owner is not proven gone.
    LeaseLapsed { owner: String },
    /// The caller declared one owner lost, but this attempt's claim names a
    /// different owner, so the declaration does not cover it.
    DeclaredOwnerMismatch {
        claim_owner: String,
        declared: String,
    },
    /// The effect was observed and produced no fact.
    ObservationSilent { reason: EffectSilence },
    /// A caller declared exactly this attempt's owner lost, and the attempt may
    /// have executed, so the run records it as unknown.
    OwnerDeclaredLost { owner: String, source: String },
}

impl UnconfirmedReason {
    /// A short durable token for the reason, safe to store and to query.
    pub fn wire(&self) -> &'static str {
        match self {
            Self::LeaseHeld { .. } => "lease_held",
            Self::LeaseLapsed { .. } => "lease_lapsed",
            Self::DeclaredOwnerMismatch { .. } => "declared_owner_mismatch",
            Self::ObservationSilent { reason } => reason.wire(),
            Self::OwnerDeclaredLost { .. } => "owner_declared_lost",
        }
    }
}

/// What recovery concluded for one outstanding attempt.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "decision")]
pub enum RecoveryDecision {
    /// Nothing for recovery to do: the attempt is queued work a drive claims,
    /// or it already settled.
    Queued,
    /// Safe to dispatch again, and only for the proof carried here. The store
    /// schedules the retry through the machine, so the replacement attempt has
    /// a new identity and the old one can only settle as cancelled.
    Retry { proof: NotReachedProof },
    /// The attempt stays unknown. No write, no re-dispatch, no new authority.
    Hold { reason: UnconfirmedReason },
    /// A declared-lost owner's started attempt is recorded as unknown, because
    /// no late outcome can arrive from a process that is gone. This is the only
    /// path that changes a started attempt's durable state, and it needs the
    /// caller's declaration to exist at all.
    SettleUnknown { reason: UnconfirmedReason },
}

/// One recovery pass and what caused it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryRequest {
    pub run_id: String,
    pub cause: RecoveryCause,
    pub now_unix_ms: i64,
}

/// What recovery concluded for one attempt, as a pure function of the durable
/// facts and the declared cause.
///
/// This is the policy in one place, so a host can ask what recovery would do
/// without touching the database, and the store cannot invent a conclusion the
/// contract does not have. Two rules are visible in the shape:
///
/// * A claim with time left is never taken, whatever the cause. Another owner
///   may be working on it, and a declaration covers only the owner it names.
/// * A started attempt is never retried. Only [`EffectBoundary::Claimed`] —
///   the durable proof that the possible-effect marker was never committed —
///   yields a general re-dispatch.
pub fn decide(effect: &OutstandingEffect, request: &RecoveryRequest) -> RecoveryDecision {
    let declared = match &request.cause {
        RecoveryCause::LeaseLapsed => None,
        RecoveryCause::HostDeclaredLost { owner, source } => Some((owner, source)),
    };
    if effect.claim.is_live_at(request.now_unix_ms) {
        let owner = effect.claim.owner().unwrap_or("unclaimed").to_owned();
        return match declared {
            Some((declared_owner, _)) if declared_owner != &owner => RecoveryDecision::Hold {
                reason: UnconfirmedReason::DeclaredOwnerMismatch {
                    claim_owner: owner,
                    declared: declared_owner.clone(),
                },
            },
            _ => RecoveryDecision::Hold {
                reason: UnconfirmedReason::LeaseHeld { owner },
            },
        };
    }
    match effect.boundary {
        EffectBoundary::NotStarted | EffectBoundary::Settled => RecoveryDecision::Queued,
        // The marker was never committed, so the effect provably did not run.
        // The replacement gets a new identity, which is what makes a late
        // marker from the old claim harmless.
        EffectBoundary::Claimed => RecoveryDecision::Retry {
            proof: NotReachedProof::MarkerAbsent,
        },
        EffectBoundary::Started => {
            let started_owner = effect.claim.owner().map(str::to_owned);
            match declared {
                Some((declared_owner, source)) => match started_owner {
                    Some(owner) if owner != *declared_owner => RecoveryDecision::Hold {
                        reason: UnconfirmedReason::DeclaredOwnerMismatch {
                            claim_owner: owner,
                            declared: declared_owner.clone(),
                        },
                    },
                    _ => RecoveryDecision::SettleUnknown {
                        reason: UnconfirmedReason::OwnerDeclaredLost {
                            owner: declared_owner.clone(),
                            source: source.clone(),
                        },
                    },
                },
                // A lease lapse is not evidence that the owner's process is
                // gone, so the attempt is held exactly as it is.
                None => RecoveryDecision::Hold {
                    reason: UnconfirmedReason::LeaseLapsed {
                        owner: started_owner.unwrap_or_else(|| "unclaimed".to_owned()),
                    },
                },
            }
        }
    }
}

/// One attempt recovery scheduled a replacement for.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetriedAttempt {
    pub command_id: String,
    pub attempt_token: String,
    /// The replacement attempt the machine scheduled, if the run's retry policy
    /// accepted it. `None` means the attempt was durably rejected instead and
    /// nothing became dispatchable from this retry.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub replacement: Option<String>,
    pub proof: NotReachedProof,
}

/// One attempt recovery tried to settle and the machine refused.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RefusedAttempt {
    pub command_id: String,
    pub code: String,
}

/// One attempt recovery held, with the reason it did.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HeldAttempt {
    pub command_id: String,
    pub attempt_token: String,
    pub reason: UnconfirmedReason,
}

/// What one recovery pass did.
///
/// The three list fields are disjoint and ordered: an attempt appears in
/// exactly one of them. `stale` reports that the facts the pass was deciding
/// from changed under it, which aborts further action rather than rebasing it;
/// the pass is safe to run again, and everything it had already committed is a
/// durable fact.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryReport {
    pub run_id: String,
    /// Outstanding attempts the pass looked at.
    pub considered: usize,
    /// Attempts whose replacement the machine scheduled. The identifiers are the
    /// *old* attempts: they are cancelled, and the replacement is a new attempt.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retried: Vec<RetriedAttempt>,
    /// Attempts left exactly as they were, with the reason.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub held: Vec<HeldAttempt>,
    /// Started attempts recorded as unknown because their owner was declared
    /// lost.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub settled_unknown: Vec<String>,
    /// Attempts the machine refused to settle, with its own code.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refusals: Vec<RefusedAttempt>,
    /// The facts changed under the pass; nothing further was attempted.
    #[serde(default)]
    pub stale: bool,
    /// The checkpoint admitted no recovery at all. `None` means the pass ran.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub block: Option<CheckpointAdmission>,
}

/// Whether a checkpoint this build read may be advanced here at all.
///
/// The causal-input contract allows exactly three continuations for an older
/// run: a compatible interpreter, a tested migration, or the previous instance
/// until a safe handoff point. "Advance" is the compatible interpreter; the
/// other two are named handoffs, and a checkpoint that cannot be *read* with its
/// causal state intact is a handoff rather than a default.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "admission")]
pub enum CheckpointAdmission {
    /// This build may advance the run.
    Advance,
    /// This build must not advance the run; one of the three permitted
    /// continuations applies.
    Handoff { reason: CheckpointHandoff },
    /// The checkpoint is malformed in a way no continuation fixes.
    Refused { code: String },
}

/// Why a checkpoint is handed off instead of advanced.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckpointHandoff {
    /// The checkpoint predates the causal state (join ledgers, bindings, the
    /// input plan). Advancing it would mean assuming an empty ledger, which is
    /// indistinguishable from losing the arrivals it never wrote.
    CausalStateMissing,
    /// The run was projected by an input adapter this build does not execute.
    InputAdapterMismatch,
    /// No definition the run names is present, so no input projection exists.
    DefinitionMissing,
}

impl CheckpointHandoff {
    pub fn wire(self) -> &'static str {
        match self {
            Self::CausalStateMissing => "checkpoint_causal_state_missing",
            Self::InputAdapterMismatch => "checkpoint_input_adapter_mismatch",
            Self::DefinitionMissing => "checkpoint_definition_missing",
        }
    }
}

/// One fact an effect's owner reported about an in-doubt attempt.
///
/// `Outcome` carries a machine event rather than a payload: the reconciliation
/// path settles a command with the same authenticated event the drive would
/// have committed, and the store checks that event's identity against the
/// attempt before it applies. An observation that produces no fact is
/// [`EffectSilence`] and never a settlement.
#[derive(Clone, Debug, PartialEq)]
pub enum EffectObservation {
    /// A confirmed outcome for exactly this command and attempt.
    Outcome { event: ReducerEvent },
    /// The effect owner confirmed the effect did not happen. This is the only
    /// observation that unlocks a safe re-dispatch after started.
    NotExecuted { source: String },
    /// The owner was asked and produced no fact.
    Silent { reason: EffectSilence },
}

/// What a reconciliation committed.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReconcileSettlement {
    Succeeded,
    Failed,
    Cancelled,
    /// The confirmed not-executed fact scheduled a replacement attempt.
    RetryScheduled,
    /// The fact was recorded but the run's state could not move: the attempt was
    /// already settled (for instance as unknown after a lost host), so reopening
    /// it would rewrite a history another owner is entitled to. The confirmed
    /// fact is still readable from the reconciliation record.
    Recorded,
}

/// The answer to one reconciliation.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "outcome")]
pub enum ReconcileOutcome {
    /// The observation was applied through the machine, so the run's own state
    /// now records it.
    Settled {
        command_id: String,
        attempt_token: String,
        settlement: ReconcileSettlement,
    },
    /// The confirmed fact is durable, but the run's state could not move: the
    /// attempt was already settled (for instance as unknown after a lost host),
    /// so reopening it would rewrite a history another owner is entitled to.
    /// The confirmed fact is readable from the reconciliation record.
    Recorded {
        command_id: String,
        attempt_token: String,
        settlement: ReconcileSettlement,
    },
    /// No confirmed fact: the attempt stays unknown and nothing is dispatched.
    Held { reason: UnconfirmedReason },
    /// The observation contradicts durable facts and was not applied.
    Refused { reason: ReconcileRefusal },
}

/// Why a reconciliation was refused.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReconcileRefusal {
    /// No command with this identity exists in the run's checkpoint.
    UnknownCommand { command_id: String },
    /// The command exists, but under a different attempt token: a late result
    /// from an older attempt may not settle a newer one.
    AttemptMismatch { command_id: String },
    /// The machine refused the event for its own reason.
    Rejected { code: String },
    /// A confirmed fact conflicts with the recorded outcome of the same attempt.
    ConflictingSettlement { command_id: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn effect(boundary: EffectBoundary, claim: ClaimStanding) -> OutstandingEffect {
        OutstandingEffect {
            run_id: "run-1".into(),
            command_id: "command-1".into(),
            attempt_token: "attempt-1".into(),
            node_id: "work".into(),
            node_visit: 1,
            boundary,
            claim,
            output_digest: None,
        }
    }

    fn recovery_request(cause: RecoveryCause) -> RecoveryRequest {
        RecoveryRequest {
            run_id: "run-1".into(),
            cause,
            now_unix_ms: 1_000,
        }
    }

    fn held(owner: &str) -> ClaimStanding {
        ClaimStanding::Held {
            owner: owner.into(),
            until_unix_ms: 2_000,
        }
    }

    fn lapsed(owner: &str) -> ClaimStanding {
        ClaimStanding::Lapsed {
            owner: owner.into(),
            until_unix_ms: 500,
        }
    }

    #[test]
    fn a_live_claim_is_never_taken() {
        let request = recovery_request(RecoveryCause::LeaseLapsed);
        for boundary in [EffectBoundary::Claimed, EffectBoundary::Started] {
            let decision = decide(&effect(boundary, held("host-a#1")), &request);
            assert_eq!(
                decision,
                RecoveryDecision::Hold {
                    reason: UnconfirmedReason::LeaseHeld {
                        owner: "host-a#1".into()
                    }
                }
            );
        }
        // Even a declaration does not cover a claim it does not name.
        let decision = decide(
            &effect(EffectBoundary::Started, held("host-a#1")),
            &recovery_request(RecoveryCause::HostDeclaredLost {
                owner: "host-b#2".into(),
                source: "host-record".into(),
            }),
        );
        assert_eq!(
            decision,
            RecoveryDecision::Hold {
                reason: UnconfirmedReason::DeclaredOwnerMismatch {
                    claim_owner: "host-a#1".into(),
                    declared: "host-b#2".into(),
                }
            }
        );
    }

    #[test]
    fn only_a_missing_marker_unlocks_a_retry() {
        let decision = decide(
            &effect(EffectBoundary::Claimed, lapsed("host-a#1")),
            &recovery_request(RecoveryCause::LeaseLapsed),
        );
        assert_eq!(
            decision,
            RecoveryDecision::Retry {
                proof: NotReachedProof::MarkerAbsent
            }
        );
        // A started attempt stays held: the lease says nothing about the effect.
        let decision = decide(
            &effect(EffectBoundary::Started, lapsed("host-a#1")),
            &recovery_request(RecoveryCause::LeaseLapsed),
        );
        assert_eq!(
            decision,
            RecoveryDecision::Hold {
                reason: UnconfirmedReason::LeaseLapsed {
                    owner: "host-a#1".into()
                }
            }
        );
    }

    #[test]
    fn a_declared_lost_owner_settles_only_its_own_started_attempt() {
        let declared = RecoveryCause::HostDeclaredLost {
            owner: "host-a#1".into(),
            source: "host-record".into(),
        };
        let decision = decide(
            &effect(EffectBoundary::Started, lapsed("host-a#1")),
            &recovery_request(declared.clone()),
        );
        assert_eq!(
            decision,
            RecoveryDecision::SettleUnknown {
                reason: UnconfirmedReason::OwnerDeclaredLost {
                    owner: "host-a#1".into(),
                    source: "host-record".into(),
                }
            }
        );
        // A claim that never reached its marker is still retried on the marker
        // proof, whichever owner the declaration names.
        let decision = decide(
            &effect(EffectBoundary::Claimed, lapsed("host-z#9")),
            &recovery_request(declared),
        );
        assert_eq!(
            decision,
            RecoveryDecision::Retry {
                proof: NotReachedProof::MarkerAbsent
            }
        );
    }

    #[test]
    fn queued_work_is_left_to_a_drive() {
        let request = recovery_request(RecoveryCause::LeaseLapsed);
        assert_eq!(
            decide(
                &effect(EffectBoundary::NotStarted, ClaimStanding::Unclaimed),
                &request
            ),
            RecoveryDecision::Queued
        );
        assert_eq!(
            decide(
                &effect(EffectBoundary::Settled, ClaimStanding::Unclaimed),
                &request
            ),
            RecoveryDecision::Queued
        );
    }

    #[test]
    fn a_claim_is_live_only_while_its_time_is_in_the_future() {
        assert!(held("host-a#1").is_live_at(1_999));
        assert!(
            !held("host-a#1").is_live_at(2_000),
            "exactly at its deadline a claim is no longer live"
        );
        assert!(!lapsed("host-a#1").is_live_at(0));
        assert!(!ClaimStanding::Unclaimed.is_live_at(0));
    }
}

/// The recovery surface a host uses against durable state.
///
/// The store implements it; the host calls it at boot and when a run has
/// outstanding work nobody is driving. Nothing here re-dispatches an effect
/// directly: [`RecoveryPort::sweep`] commits decisions, and the machine's retry
/// path is what makes a replacement attempt claimable.
pub trait RecoveryPort: Send + Sync {
    /// Whether this build may advance the run's active checkpoint.
    fn checkpoint_admission(&self, run_id: &str) -> Result<CheckpointAdmission>;

    /// The attempts of one run that have not settled.
    fn outstanding(&self, run_id: &str) -> Result<Vec<OutstandingEffect>>;

    /// Classify every outstanding attempt and commit the decisions that are
    /// safe, leaving everything else exactly as it was.
    fn sweep(&self, request: &RecoveryRequest) -> Result<RecoveryReport>;

    /// Hand one confirmed observation about an in-doubt attempt back to the run.
    fn reconcile(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
        observation: &EffectObservation,
    ) -> Result<ReconcileOutcome>;
}
