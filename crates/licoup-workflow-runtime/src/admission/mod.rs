//! Admission: the boundary an effect passes before it can run.
//!
//! C01's flow puts three things at one boundary — resolve the caller's
//! authority, recheck it against what is true now, and reserve what the effect
//! needs — and C03 adds a fourth: a scope barrier that stops a new node visit
//! from starting at all. This module is that boundary as a value-returning
//! gate, and it is written so that each of the four is visible in a type rather
//! than in a comment:
//!
//! | fact | where it is enforced |
//! |---|---|
//! | the authority a caller acts under | [`AdmissionAuthority`]: private fields, no serde, minted only by resolution through [`crate::ports::AuthorityPort`] |
//! | `principal`/`effectId`/`authorized`/`stateRoot` | [`is_authority_field`]: a free-form attribute naming one is refused by name |
//! | resource state | [`ResourceState`]: availability, counts and revision, recorded as they were |
//! | a pause or stop fence | [`ScopeBarrierPort::publish`]: the barrier and the recipients it froze, in one write, keyed by the run the effect belongs to |
//! | revocation ordering | [`on_revocation`]: the next effect is refused, in-flight work is never reported as undone |
//!
//! Two properties of the shape are worth stating because they are what a test
//! cannot show:
//!
//! * [`AdmissionRequest`] is deserializable on purpose. A request carries
//!   everything about an effect *except* its authority — the revision, the
//!   claims, and the caller's free-form attributes — so a payload can describe
//!   work without being able to authorize it. It also cannot choose which
//!   fence applies to it: the graph barrier is read for the run the effect
//!   belongs to, never for a scope the request names, because a fence a caller
//!   can relabel is not a fence.
//! * [`AdmissionAuthority`] is not. No payload, tool argument or extension
//!   attribute can carry one, and no public constructor accepts digests, so the
//!   only authority in play is the one the port resolved.
//!
//! What the gate deliberately does *not* do: it does not commit the
//! possible-effect marker, does not invoke an adapter, and does not settle
//! anything. Commit-before-invoke stays with the driver (V7-R1), which is the
//! order recovery depends on; admission only answers what was true when it was
//! asked.

mod authority;
mod barrier;
mod ordering;
mod resources;

use std::collections::BTreeMap;
use std::fmt::{Display, Formatter};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::node::NodeVisitKey;
use crate::ports::{AuthorityPort, AuthorityRecheck};

pub use authority::{
    AUTHORITY_FIELDS, AdmissionAuthority, AuthorityEvidence, AuthoritySource, GrantBinding,
    VerifiedCaller, is_authority_field,
};
pub use barrier::{
    AdmissionBarrier, BarrierKind, BarrierRequest, BarrierScope, PauseState, ScopeBarrierPort,
    ScopeStatus, scope_status,
};
pub use ordering::{
    AdmittedEffect, CancelInstruction, CancelSupport, Ingress, RevocationOrdering,
    consults_current_authority, on_revocation,
};
pub use resources::{
    EffectPosition, ReservationDenial, ReservationOutcome, ReservationRef, ReservationRequest,
    ReservationSettlement, ResourceClaim, ResourcePort, ResourceRequest, ResourceState,
    ResourceWaiting, settlement_for,
};

use authority::reserved_attribute;

/// Why an admission call could not answer at all.
///
/// A refusal is an answer and travels in [`AdmissionDecision`]; this type is for
/// the two cases where no answer exists: a fact a trusted surface handed over
/// that this crate will not accept, and a port call that failed.
#[derive(Debug)]
pub enum AdmissionError {
    /// A trusted surface supplied a fact in a shape this crate refuses.
    Malformed {
        field: &'static str,
        reason: &'static str,
    },
    /// A port call failed. The operation is named so the failure is locatable
    /// without reading the message.
    Port {
        operation: &'static str,
        source: anyhow::Error,
    },
}

impl AdmissionError {
    pub(super) fn malformed(field: &'static str, reason: &'static str) -> Self {
        Self::Malformed { field, reason }
    }

    pub(super) fn port(operation: &'static str, source: anyhow::Error) -> Self {
        Self::Port { operation, source }
    }
}

impl Display for AdmissionError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed { field, reason } => {
                write!(formatter, "admission_malformed: {field} {reason}")
            }
            Self::Port { operation, source } => {
                write!(formatter, "admission_port_failed: {operation}: {source}")
            }
        }
    }
}

impl std::error::Error for AdmissionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Malformed { .. } => None,
            Self::Port { source, .. } => source.source(),
        }
    }
}

/// One effect asking to be admitted.
///
/// Everything here is data about the work. The authority is not a field: see
/// [`AdmissionGate::admit_effect`] for the call that resolves it, and
/// [`AdmissionGate::admit`] for the call that takes an already-resolved one.
///
/// The run, node and revision are the host's binding of a committed intent
/// (C02's input binding), not a description the boundary accepts as identity:
/// the fence is the run named here, and the authority recheck resolves that
/// run's revision through the port. A caller assembling this from an untrusted
/// payload must therefore take the identity from the committed intent.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdmissionRequest {
    pub run_id: String,
    /// The effect identity (C01's `effectId`): stable across attempts.
    pub effect_id: String,
    /// The attempt this admission is for. A receipt carries it so a replayed
    /// callback is recognisable as a repeat rather than as new work.
    pub attempt_token: String,
    pub node: NodeVisitKey,
    /// The definition revision the caller decided against. The resolved
    /// authority must be the one for this revision.
    pub revision_digest: String,
    /// The state root the effect is bound to, when it is bound to one.
    ///
    /// Typed, and never an attribute: C05 reserves `stateRoot`, because a
    /// caller that could move an effect to another state root through a
    /// free-form attribute would be choosing which state it acts on.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub state_root: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub resource_claims: Vec<ResourceClaim>,
    /// What the caller asserts about itself. Namespaced attributes live here;
    /// the four authority fields are refused by name.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub attributes: BTreeMap<String, String>,
}

impl AdmissionRequest {
    /// A request for one effect of one run, with nothing claimed yet.
    pub fn new(
        run_id: impl Into<String>,
        effect_id: impl Into<String>,
        attempt_token: impl Into<String>,
        node: NodeVisitKey,
        revision_digest: impl Into<String>,
    ) -> Self {
        let run_id = run_id.into();
        Self {
            run_id,
            effect_id: effect_id.into(),
            attempt_token: attempt_token.into(),
            node,
            revision_digest: revision_digest.into(),
            state_root: None,
            resource_claims: Vec::new(),
            attributes: BTreeMap::new(),
        }
    }

    pub fn with_state_root(mut self, state_root: impl Into<String>) -> Self {
        self.state_root = Some(state_root.into());
        self
    }

    pub fn with_resource_claim(mut self, claim: ResourceClaim) -> Self {
        self.resource_claims.push(claim);
        self
    }

    pub fn with_attribute(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.attributes.insert(name.into(), value.into());
        self
    }
}

/// What admission answered.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "decision")]
pub enum AdmissionDecision {
    /// The receipt is boxed: it carries every observed fact, and an enum whose
    /// refused variant is small must not pay for that on every construction.
    Admitted(Box<AdmissionReceipt>),
    Refused(AdmissionRefusal),
}

impl AdmissionDecision {
    pub fn receipt(&self) -> Option<&AdmissionReceipt> {
        match self {
            Self::Admitted(receipt) => Some(receipt),
            Self::Refused(_) => None,
        }
    }

    pub fn refusal(&self) -> Option<&AdmissionRefusal> {
        match self {
            Self::Refused(refusal) => Some(refusal),
            Self::Admitted(_) => None,
        }
    }

    pub fn is_admitted(&self) -> bool {
        matches!(self, Self::Admitted(_))
    }
}

/// What was actually true when an effect was admitted.
///
/// Every field is an observation or an identity, and none of them is a promise
/// that the effect will succeed. The receipt is what a "why did this run?"
/// question is answered from, so it carries what was refused as well as what
/// was held: the resource states, the reservations (including the explicit
/// "not configured"), and the barrier that was in force.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdmissionReceipt {
    pub run_id: String,
    pub effect_id: String,
    pub attempt_token: String,
    pub node: NodeVisitKey,
    pub revision_digest: String,
    pub authority: AuthorityEvidence,
    /// The state of each claimed resource, as its owner reported it.
    pub resources: Vec<ResourceState>,
    /// One answer per claim, in claim order. `NotConfigured` is an answer.
    pub reservations: Vec<ReservationOutcome>,
    /// The barrier in force for this scope at admission, if one was.
    pub barrier: Option<AdmissionBarrier>,
    pub state_root: Option<String>,
    /// The attributes the caller asserted, carried back unchanged. The host's
    /// own facts are not among them, because they were never read from here.
    pub attributes: BTreeMap<String, String>,
}

/// Why an effect was not admitted, naming what was missing.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "refusal")]
pub enum AdmissionRefusal {
    /// A free-form attribute named a field only the host may set (C05).
    ReservedAttribute {
        /// The attribute as the caller wrote it.
        name: String,
        /// The authority field it named.
        field: String,
    },
    /// No grant is in force for the revision this effect was decided against.
    /// There is no implicit administrator here: an unresolved authority is a
    /// refusal, not a default.
    AuthorityMissing { revision_digest: String },
    /// The grant in force at the admission boundary is not the one the effect
    /// was decided under: the next effect is refused (C01).
    AuthorityNotCovered {
        effect_id: String,
        /// The digest the effect was admitted under.
        expected: String,
        /// What the authority port reports now, when it reports anything.
        observed: Option<String>,
    },
    /// The authority was resolved for a different revision than the effect
    /// names, so it cannot admit this effect.
    RevisionMismatch {
        effect_id: String,
        authority_revision: String,
        request_revision: String,
    },
    /// A barrier is in force for the run this effect belongs to: no new visit
    /// starts here.
    ScopeBarrier(AdmissionBarrier),
    /// The resource owner answered that this effect does not fit, with the
    /// state it answered from.
    ResourceUnavailable {
        claim: ResourceClaim,
        observed: ResourceState,
    },
    /// The resource owner will not hold capacity now: exhausted, contended by
    /// another writer, or rate-limited upstream. A wait answer rather than a
    /// failure — nothing was held for this effect and nothing ran, so the
    /// caller retries later and work in flight keeps running.
    ///
    /// A claim earlier in the same admission may have been reserved before a
    /// later claim waited; the refused effect provably never started, so
    /// reconciliation releases those orphaned reservations by effect id (C01).
    ResourceWaiting {
        claim: ResourceClaim,
        waiting: ResourceWaiting,
    },
    /// The resource moved past the revision the caller decided against. The
    /// caller re-reads and retries; nothing was reserved.
    ResourceRevisionMoved {
        resource_id: String,
        expected: u64,
        observed: u64,
    },
}

/// The admission boundary, over the ports its owners implement.
pub struct AdmissionGate {
    authority: Arc<dyn AuthorityPort>,
    resources: Arc<dyn ResourcePort>,
    barriers: Arc<dyn ScopeBarrierPort>,
}

impl std::fmt::Debug for AdmissionGate {
    /// The composition, not the ports: a debug form must not be a way to reach
    /// a store handle.
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AdmissionGate")
            .finish_non_exhaustive()
    }
}

impl AdmissionGate {
    pub fn new(
        authority: Arc<dyn AuthorityPort>,
        resources: Arc<dyn ResourcePort>,
        barriers: Arc<dyn ScopeBarrierPort>,
    ) -> Self {
        Self {
            authority,
            resources,
            barriers,
        }
    }

    /// Resolve the authority for one revision, for one verified caller.
    ///
    /// `Ok(None)` means no grant is in force for that revision: an answer, not
    /// an error, and the caller must not act on it. This is the only way to
    /// obtain an [`AdmissionAuthority`].
    pub fn authority_for(
        &self,
        caller: VerifiedCaller,
        revision_digest: &str,
    ) -> Result<Option<AdmissionAuthority>, AdmissionError> {
        authority::resolve(self.authority.as_ref(), caller, revision_digest)
    }

    /// Resolve the authority for the request's revision and admit it.
    ///
    /// The two steps are one call here because C01's order puts resolution
    /// before the boundary; a caller that needs to decide between the two — to
    /// ask the user, or to re-read state — calls them separately.
    pub fn admit_effect(
        &self,
        caller: VerifiedCaller,
        request: &AdmissionRequest,
    ) -> Result<AdmissionDecision, AdmissionError> {
        let resolved = self.authority_for(caller, &request.revision_digest)?;
        match resolved {
            None => Ok(AdmissionDecision::Refused(
                AdmissionRefusal::AuthorityMissing {
                    revision_digest: request.revision_digest.clone(),
                },
            )),
            Some(resolved) => self.admit(&resolved, request),
        }
    }

    /// Admit one effect under an already-resolved authority.
    ///
    /// The order is the one C01 and C03 state, and each step can only refuse:
    ///
    /// 1. authority fields are not a caller's to set,
    /// 2. the authority must be the one resolved for this revision,
    /// 3. the grant is rechecked at the boundary — the linearization point a
    ///    revocation takes effect at,
    /// 4. the barrier in force for the run stops a new visit before anything is
    ///    reserved, and no field of the request can point the fence elsewhere,
    /// 5. each claimed resource is observed, checked against the revision the
    ///    caller decided against, and only then reserved by effect id.
    pub fn admit(
        &self,
        authority: &AdmissionAuthority,
        request: &AdmissionRequest,
    ) -> Result<AdmissionDecision, AdmissionError> {
        if let Some((name, field)) = reserved_attribute(&request.attributes) {
            return Ok(AdmissionDecision::Refused(
                AdmissionRefusal::ReservedAttribute { name, field },
            ));
        }

        let binding = authority.binding();
        if binding.revision_digest() != request.revision_digest {
            return Ok(AdmissionDecision::Refused(
                AdmissionRefusal::RevisionMismatch {
                    effect_id: request.effect_id.clone(),
                    authority_revision: binding.revision_digest().to_owned(),
                    request_revision: request.revision_digest.clone(),
                },
            ));
        }

        let recheck = AuthorityRecheck {
            run_id: request.run_id.clone(),
            command_id: request.effect_id.clone(),
            expected_authorization_digest: binding.authorization_digest().to_owned(),
            expected_semantics_digest: binding.semantics_digest().to_owned(),
        };
        let covered = self
            .authority
            .recheck(&recheck)
            .map_err(|error| AdmissionError::port("recheck", error))?;
        if !covered {
            let observed = self
                .authority
                .active_authorization(&request.revision_digest)
                .map_err(|error| AdmissionError::port("active_authorization", error))?
                .map(|reference| reference.authorization_digest);
            return Ok(AdmissionDecision::Refused(
                AdmissionRefusal::AuthorityNotCovered {
                    effect_id: request.effect_id.clone(),
                    expected: binding.authorization_digest().to_owned(),
                    observed,
                },
            ));
        }

        // The fence is keyed by the run the effect belongs to, which is the run
        // its graph barrier is written for. The request has no scope field: a
        // payload cannot describe itself out of a pause by naming a scope no
        // barrier was written for.
        let barrier = self
            .barriers
            .barrier(&BarrierScope::Run(request.run_id.clone()))
            .map_err(|error| AdmissionError::port("barrier", error))?;
        if let Some(barrier) = &barrier
            && barrier.blocks_new_visits()
        {
            return Ok(AdmissionDecision::Refused(AdmissionRefusal::ScopeBarrier(
                barrier.clone(),
            )));
        }

        let mut observed = Vec::with_capacity(request.resource_claims.len());
        for claim in &request.resource_claims {
            let state = self
                .resources
                .observe(&ResourceRequest {
                    resource_id: claim.resource_id.clone(),
                    run_id: request.run_id.clone(),
                    effect_id: request.effect_id.clone(),
                })
                .map_err(|error| AdmissionError::port("observe", error))?;
            // The revision the caller decided against is checked before
            // capacity: a claim decided against an older state of the resource
            // is not a claim about this one.
            if let Some(expected) = claim.expected_revision
                && state.revision != expected
            {
                return Ok(AdmissionDecision::Refused(
                    AdmissionRefusal::ResourceRevisionMoved {
                        resource_id: claim.resource_id.clone(),
                        expected,
                        observed: state.revision,
                    },
                ));
            }
            if !state.admits(claim) {
                return Ok(AdmissionDecision::Refused(
                    AdmissionRefusal::ResourceUnavailable {
                        claim: claim.clone(),
                        observed: state,
                    },
                ));
            }
            observed.push(state);
        }

        let mut reservations = Vec::with_capacity(request.resource_claims.len());
        for claim in &request.resource_claims {
            let reservation = self
                .resources
                .reserve(&ReservationRequest {
                    effect_id: request.effect_id.clone(),
                    attempt_token: request.attempt_token.clone(),
                    resource_id: claim.resource_id.clone(),
                    slots: claim.slots,
                })
                .map_err(|error| AdmissionError::port("reserve", error))?;
            if let ReservationOutcome::Waiting(waiting) = &reservation {
                return Ok(AdmissionDecision::Refused(
                    AdmissionRefusal::ResourceWaiting {
                        claim: claim.clone(),
                        waiting: waiting.clone(),
                    },
                ));
            }
            reservations.push(reservation);
        }

        Ok(AdmissionDecision::Admitted(Box::new(AdmissionReceipt {
            run_id: request.run_id.clone(),
            effect_id: request.effect_id.clone(),
            attempt_token: request.attempt_token.clone(),
            node: request.node.clone(),
            revision_digest: request.revision_digest.clone(),
            authority: authority.evidence(),
            resources: observed,
            reservations,
            barrier,
            state_root: request.state_root.clone(),
            attributes: request.attributes.clone(),
        })))
    }
}
