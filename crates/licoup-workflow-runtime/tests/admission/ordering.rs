//! The order a revocation takes effect in — C01's linearization rule.
//!
//! The rule is not "there is no race". It is that the boundary has one order: an
//! effect admitted under a grant keeps its binding, a revocation prevents the
//! *next* effect, and a cancellation the adapter supports may be requested for
//! what is in flight while nothing claims the revocation undid it.
//!
//! These tests hold all three, and the fourth thing they hold is the one that is
//! easiest to get wrong: a settlement of an effect that was already admitted is
//! not gated on the authority in force now. A run whose grant was revoked
//! mid-flight must still be able to record what its running effect did —
//! otherwise the run becomes unreconcilable exactly when it is in doubt.

use std::sync::Arc;

use licoup_workflow_runtime::admission::{
    AdmissionRefusal, AdmissionRequest, AdmittedEffect, CancelSupport, Ingress, ResourceClaim,
    consults_current_authority, on_revocation,
};

use crate::fixture::{
    AuthorityOwner, BarrierOwner, GRANT, REVISION, RUN, ResourceOwner, admitted, caller, gate,
    refused, visit,
};

fn request(effect_id: &str, state_id: &str) -> AdmissionRequest {
    AdmissionRequest::new(RUN, effect_id, "attempt-1", visit(state_id), REVISION)
}

fn resolved(
    gate: &licoup_workflow_runtime::admission::AdmissionGate,
) -> licoup_workflow_runtime::admission::AdmissionAuthority {
    gate.authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted before the revocation")
}

#[test]
fn a_revocation_blocks_the_next_effect_and_keeps_what_was_admitted() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.configure_budget(true);
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    let first = admitted(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers"),
    );
    let admitted_effect = AdmittedEffect {
        effect_id: first.effect_id.clone(),
        attempt_token: first.attempt_token.clone(),
        node: first.node.clone(),
        authorization_digest: first.authority.authorization_digest.clone(),
    };

    // The revocation happens after the first effect was admitted.
    authority.revoke(REVISION);

    // The next effect is refused, and the refusal names what the port reports
    // now: an absence, not the old grant.
    let fresh = gate
        .authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure");
    assert!(
        fresh.is_none(),
        "a revoked grant must stop resolving to an authority"
    );

    // Its binding was not rewritten by the revocation.
    assert_eq!(admitted_effect.authorization_digest, GRANT);

    let ordering = on_revocation(std::slice::from_ref(&admitted_effect), true);
    assert!(ordering.blocks_next);
    assert!(!ordering.undoes_in_flight());
    assert_eq!(
        ordering.digests_kept(),
        vec![("effect-1", GRANT)],
        "the admitted effect keeps the grant it was admitted under"
    );
    match &ordering.cancel {
        CancelSupport::Requested { effects } => {
            assert_eq!(effects.len(), 1);
            assert_eq!(effects[0].effect_id, "effect-1");
            assert_eq!(effects[0].attempt_token, "attempt-1");
        }
        other => panic!("expected a cancellation request, got {other:?}"),
    }
}

#[test]
fn a_grant_replaced_by_another_grant_refuses_the_next_effect_and_names_both() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    let resolved = resolved(&gate);
    // The definition is re-authorized: a different grant is in force for the
    // same revision, so the older authority no longer covers the next effect.
    authority.grant(REVISION, "grant-2");

    match refused(
        gate.admit(&resolved, &request("effect-2", "b"))
            .expect("admission answers"),
    ) {
        AdmissionRefusal::AuthorityNotCovered {
            effect_id,
            expected,
            observed,
        } => {
            assert_eq!(effect_id, "effect-2");
            assert_eq!(expected, GRANT);
            assert_eq!(observed.as_deref(), Some("grant-2"));
        }
        other => panic!("expected AuthorityNotCovered, got {other:?}"),
    }
    // The recheck refused before the boundary looked at any resource: an effect
    // that lost its authority holds nothing and never reaches an owner.
    assert!(resources.observations().is_empty());
    assert!(resources.reservations().is_empty());
}

#[test]
fn a_settlement_is_not_gated_on_the_authority_in_force_now() {
    let authority = AuthorityOwner::granted();
    let admitted_effect = AdmittedEffect {
        effect_id: "effect-1".to_owned(),
        attempt_token: "attempt-1".to_owned(),
        node: visit("a"),
        authorization_digest: GRANT.to_owned(),
    };
    authority.revoke(REVISION);
    assert!(
        licoup_workflow_runtime::ports::AuthorityPort::active_authorization(
            authority.as_ref(),
            REVISION
        )
        .expect("the port answers")
        .is_none(),
        "the contrast is against a real revocation, not a hypothetical one"
    );

    assert!(consults_current_authority(Ingress::NewEffect));
    assert!(
        !consults_current_authority(Ingress::SettlementOf(&admitted_effect)),
        "the outcome of an admitted effect is evidence, not an authorization"
    );
}

#[test]
fn an_adapter_that_cannot_cancel_is_not_asked_to() {
    let admitted_effect = AdmittedEffect {
        effect_id: "effect-1".to_owned(),
        attempt_token: "attempt-1".to_owned(),
        node: visit("a"),
        authorization_digest: GRANT.to_owned(),
    };
    assert_eq!(
        on_revocation(std::slice::from_ref(&admitted_effect), false).cancel,
        CancelSupport::Unsupported
    );
    // Nothing in flight: there is nothing to ask about.
    assert_eq!(on_revocation(&[], true).cancel, CancelSupport::Unsupported);
    assert!(on_revocation(&[], true).blocks_next);
    // A cancellation the adapter cannot support changes nothing else: the
    // admitted effect is still named as admitted.
    assert_eq!(
        on_revocation(std::slice::from_ref(&admitted_effect), false)
            .admitted_before
            .len(),
        1
    );
}
