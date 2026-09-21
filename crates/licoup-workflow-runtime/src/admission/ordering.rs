//! The order a revocation takes effect in.
//!
//! C01 is explicit that "the recheck leaves no revocation race" is not a claim
//! this system can make by checking harder. What it makes instead is an
//! ordering, and this module is that ordering written as a value a test can
//! hold:
//!
//! 1. An effect that was **admitted** under a grant keeps its binding. A later
//!    revocation does not rewrite what was admitted, and does not retroactively
//!    make the running effect unauthorized.
//! 2. A revocation **prevents the next effect**: the next admission resolves no
//!    grant, or the recheck at the boundary refuses it.
//! 3. A revocation **may request a cancellation** where the adapter supports
//!    one. A request is not a confirmation and is not a rollback: the effect
//!    still settles on its own authenticated outcome, which may be a success
//!    that arrived after the request.
//!
//! Nothing here reports that revocation undoes work in flight, because that is
//! not true of any of the systems this runtime calls: an agent turn already
//! running, a payment already submitted, a file already written. A caller that
//! wants the opposite claim has to get it from the effect's own protocol, which
//! is exactly the distinction [`RevocationOrdering::cancel`] keeps.
//!
//! [`consults_current_authority`] exists so the second half of rule 1 is
//! pinned: a settlement of an admitted effect is *not* gated on the authority
//! in force now. A run whose grant was revoked mid-flight must still be able to
//! record the outcome of the effect it already started — otherwise the run
//! becomes unreconcilable exactly when it needs reconciling.

use crate::node::NodeVisitKey;

/// One effect that was admitted, with the authority it was admitted under.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AdmittedEffect {
    pub effect_id: String,
    pub attempt_token: String,
    pub node: NodeVisitKey,
    /// The grant digest the effect was admitted under. Recorded, not re-read:
    /// this is what rule 1 means in a field.
    pub authorization_digest: String,
}

/// A cancellation admission asks its adapter for, when it supports one.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CancelInstruction {
    pub effect_id: String,
    pub attempt_token: String,
}

/// What the adapter can be asked to do about work already in flight.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CancelSupport {
    /// The adapter negotiated no cancellation: the effects run to their own
    /// end, and their outcomes settle normally.
    Unsupported,
    /// The adapter supports cancellation for exactly these effects.
    Requested { effects: Vec<CancelInstruction> },
}

/// What a revocation does, in order.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RevocationOrdering {
    /// The effects admitted before the revocation. They are named, and they are
    /// not undone.
    pub admitted_before: Vec<AdmittedEffect>,
    /// The next effect under this grant is refused. Always true — a revocation
    /// that did not stop the next effect would not be a revocation.
    pub blocks_next: bool,
    /// The cancellation the adapter supports, if any.
    pub cancel: CancelSupport,
}

impl RevocationOrdering {
    /// Whether this ordering claims the revocation undid anything in flight.
    ///
    /// It never does, and the method exists so a caller cannot read the
    /// ordering as if it might: an effect that was admitted stays admitted.
    pub fn undoes_in_flight(&self) -> bool {
        false
    }

    /// The digest each admitted effect keeps, whatever the authority says now.
    pub fn digests_kept(&self) -> Vec<(&str, &str)> {
        self.admitted_before
            .iter()
            .map(|effect| {
                (
                    effect.effect_id.as_str(),
                    effect.authorization_digest.as_str(),
                )
            })
            .collect()
    }
}

/// What happens to work in flight when a grant is revoked.
///
/// `in_flight` is the set the caller admitted under that grant, in admission
/// order. `adapter_supports_cancel` is what the adapter negotiated — not what
/// the host would like: an adapter that cannot cancel must not be asked to.
pub fn on_revocation(
    in_flight: &[AdmittedEffect],
    adapter_supports_cancel: bool,
) -> RevocationOrdering {
    let cancel = if adapter_supports_cancel && !in_flight.is_empty() {
        CancelSupport::Requested {
            effects: in_flight
                .iter()
                .map(|effect| CancelInstruction {
                    effect_id: effect.effect_id.clone(),
                    attempt_token: effect.attempt_token.clone(),
                })
                .collect(),
        }
    } else {
        CancelSupport::Unsupported
    };
    RevocationOrdering {
        admitted_before: in_flight.to_vec(),
        blocks_next: true,
        cancel,
    }
}

/// Which path a fact travels into the run.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Ingress<'a> {
    /// A new effect: gated by the authority in force now.
    NewEffect,
    /// The outcome of an effect that was already admitted: gated by its own
    /// authenticated evidence.
    SettlementOf(&'a AdmittedEffect),
}

/// Whether the authority in force now is consulted for this ingress.
///
/// This is the linearization rule as a single boolean. A settlement is never
/// gated on current authority, because the effect it settles may already have
/// happened; a new effect always is, because that is the boundary revocation
/// takes effect at.
pub fn consults_current_authority(ingress: Ingress<'_>) -> bool {
    match ingress {
        Ingress::NewEffect => true,
        Ingress::SettlementOf(_) => false,
    }
}
