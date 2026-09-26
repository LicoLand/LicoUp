//! Authority: what a caller can and cannot supply.
//!
//! These tests pin the half of non-forgeability that is expressible in code —
//! that the digests an admission records come from the authority port's answer
//! and from nowhere else, that an authority resolved for one revision cannot
//! admit another's effect, and that a free-form attribute naming one of C05's
//! four authority fields is refused by name.
//!
//! What they do **not** prove is the structural half: that
//! `AdmissionAuthority` has no `Serialize`/`Deserialize` impl and no public
//! constructor taking digests. Nothing in a test can show the absence of a
//! conversion; what a reviewer checks is the type's declaration and its single
//! mint path through `AdmissionGate::authority_for`. There is also no
//! compile-fail fixture for it: this crate has no `trybuild` dependency, and
//! adding one is not this leaf's to do.

use std::sync::Arc;

use licoup_workflow_runtime::admission::{
    AdmissionRefusal, AdmissionRequest, AuthoritySource, ResourceClaim, VerifiedCaller,
    is_authority_field,
};

use crate::fixture::{
    AuthorityOwner, BarrierOwner, GRANT, REVISION, RUN, ResourceOwner, admitted, caller, gate,
    refused, visit,
};

fn request(effect_id: &str, state_id: &str) -> AdmissionRequest {
    AdmissionRequest::new(RUN, effect_id, "attempt-1", visit(state_id), REVISION)
}

#[test]
fn the_authority_a_receipt_records_is_the_one_the_port_resolved() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(Arc::clone(&authority), Arc::clone(&resources), barriers);

    let resolved = gate
        .authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("the run's revision is granted");
    assert_eq!(resolved.binding().authorization_digest(), GRANT);
    assert_eq!(resolved.binding().revision_digest(), REVISION);
    assert_eq!(resolved.caller().source(), AuthoritySource::ResolvedSession);

    let receipt = admitted(
        gate.admit(&resolved, &request("effect-1", "a"))
            .expect("admission answers"),
    );
    // The receipt reports the port's answer, not anything the request carried:
    // the request has no field for a digest at all.
    assert_eq!(receipt.authority.authorization_digest, GRANT);
    assert_eq!(receipt.authority.revision_digest, REVISION);
    assert_eq!(receipt.authority.principal, "owner-1");
    // The boundary asked before it admitted, with exactly the resolved grant.
    let rechecks = authority.rechecks();
    assert_eq!(rechecks.len(), 1);
    assert_eq!(rechecks[0].command_id, "effect-1");
    assert_eq!(rechecks[0].expected_authorization_digest, GRANT);
}

#[test]
fn without_a_grant_there_is_no_implicit_administrator_and_nothing_is_touched() {
    let authority = AuthorityOwner::empty();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    let decision = gate
        .admit_effect(
            caller("local-admin"),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers");
    match refused(decision) {
        AdmissionRefusal::AuthorityMissing { revision_digest } => {
            assert_eq!(revision_digest, REVISION);
        }
        other => panic!("expected AuthorityMissing, got {other:?}"),
    }
    // A caller named "local-admin" is still just a principal: the queue grants
    // nothing implicitly, so no resource was observed, nothing was reserved, and
    // no barrier was read for a run that is not authorized.
    assert!(resources.observations().is_empty());
    assert!(resources.reservations().is_empty());
    assert_eq!(barriers.transactions(), 0);
    assert!(authority.rechecks().is_empty());
}

#[test]
fn an_authority_resolved_for_one_revision_cannot_admit_another_revisions_effect() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barrier = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barrier),
    );

    let resolved = gate
        .authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted");
    let elsewhere = AdmissionRequest::new(RUN, "effect-2", "attempt-1", visit("b"), "revision-2");
    match refused(
        gate.admit(&resolved, &elsewhere)
            .expect("admission answers"),
    ) {
        AdmissionRefusal::RevisionMismatch {
            authority_revision,
            request_revision,
            ..
        } => {
            assert_eq!(authority_revision, REVISION);
            assert_eq!(request_revision, "revision-2");
        }
        other => panic!("expected RevisionMismatch, got {other:?}"),
    }
    // The mismatch was refused before the boundary rechecked anything.
    assert!(authority.rechecks().is_empty());
}

#[test]
fn a_free_form_attribute_cannot_name_an_authority_field_in_any_spelling() {
    for spelling in [
        "principal",
        "Principal",
        "PRINCIPAL",
        "effectId",
        "effect_id",
        "EFFECTID",
        "authorized",
        "stateRoot",
        "state_root",
    ] {
        assert!(
            is_authority_field(spelling),
            "{spelling} must be recognised as an authority field"
        );
    }
    assert!(!is_authority_field("licoup.quota.tokens"));
    assert!(!is_authority_field("effect"));

    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );
    let resolved = gate
        .authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted");

    let decision = gate
        .admit(
            &resolved,
            &request("effect-1", "a")
                .with_attribute("effect_id", "some-other-effect")
                .with_attribute("authorized", "true"),
        )
        .expect("admission answers");
    match refused(decision) {
        // C05's own field order decides which of two offending attributes is
        // reported, so the answer does not depend on the caller's map order.
        AdmissionRefusal::ReservedAttribute { name, field } => {
            assert_eq!(name, "effect_id");
            assert_eq!(field, "effectId");
        }
        other => panic!("expected ReservedAttribute, got {other:?}"),
    }

    match refused(
        gate.admit(
            &resolved,
            &request("effect-1", "a").with_attribute("principal", "someone-else"),
        )
        .expect("admission answers"),
    ) {
        AdmissionRefusal::ReservedAttribute { name, field } => {
            assert_eq!(name, "principal");
            assert_eq!(field, "principal");
        }
        other => panic!("expected ReservedAttribute, got {other:?}"),
    }
}

#[test]
fn a_namespaced_attribute_is_carried_through_and_host_facts_are_not_read_from_it() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );
    let resolved = gate
        .authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted");

    let receipt = admitted(
        gate.admit(
            &resolved,
            &request("effect-1", "a")
                .with_state_root("root-7")
                .with_attribute("licoup.render", "compact"),
        )
        .expect("admission answers"),
    );
    assert_eq!(
        receipt.attributes.get("licoup.render").map(String::as_str),
        Some("compact")
    );
    // The identity, grant and state root come from the typed fields: the
    // attribute map cannot move any of them.
    assert_eq!(receipt.effect_id, "effect-1");
    assert_eq!(receipt.state_root.as_deref(), Some("root-7"));
    assert_eq!(receipt.authority.authorization_digest, GRANT);
}

#[test]
fn a_caller_identifier_must_be_a_usable_identifier() {
    for rejected in ["", "  owner-1", "owner-1\n", "owner\u{0}-1"] {
        let built = VerifiedCaller::from_verified_source(rejected, AuthoritySource::LocalOwner);
        assert!(built.is_err(), "{rejected:?} must not be accepted");
    }
    assert!(
        VerifiedCaller::from_verified_source("owner-1", AuthoritySource::AdmittedAdapter).is_ok()
    );
}

#[test]
fn a_decision_names_the_effect_it_answered_for() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );
    let resolved = gate
        .authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted");

    let decision = gate
        .admit(&resolved, &request("effect-9", "z"))
        .expect("admission answers");
    assert!(decision.is_admitted());
    assert_eq!(
        decision.receipt().map(|receipt| receipt.effect_id.as_str()),
        Some("effect-9")
    );
    assert!(decision.refusal().is_none());
}
