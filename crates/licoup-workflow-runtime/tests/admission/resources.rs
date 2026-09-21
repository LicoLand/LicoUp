//! Resource state: what admission records, and what a refusal says.
//!
//! The plan's requirement is that admission answers with what was actually
//! true, so the tests read the receipt rather than a boolean: the counts and the
//! owner's revision have to be in it, an unconfigured budget has to be reported
//! as unconfigured instead of becoming a gate, and a refusal has to name the
//! resource with the state it was refused from.

use std::sync::Arc;

use licoup_workflow_runtime::admission::{
    AdmissionRefusal, AdmissionRequest, EffectPosition, ReservationDenial, ReservationOutcome,
    ReservationRequest, ReservationSettlement, ResourceClaim, ResourceState, settlement_for,
};

use crate::fixture::{
    AuthorityOwner, BarrierOwner, REVISION, RUN, ResourceOwner, admitted, caller, gate, refused,
    visit,
};

fn request(effect_id: &str, state_id: &str) -> AdmissionRequest {
    AdmissionRequest::new(RUN, effect_id, "attempt-1", visit(state_id), REVISION)
}

/// The same effect admitted again: a retry carries a new attempt token but the
/// same effect identity.
fn retry(effect_id: &str, attempt_token: &str, state_id: &str) -> AdmissionRequest {
    AdmissionRequest::new(RUN, effect_id, attempt_token, visit(state_id), REVISION)
}

fn resolved(
    gate: &licoup_workflow_runtime::admission::AdmissionGate,
) -> licoup_workflow_runtime::admission::AdmissionAuthority {
    gate.authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted")
}

#[test]
fn an_admitted_receipt_carries_the_state_it_was_admitted_against() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.configure_budget(false);
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    let receipt = admitted(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a")
                .with_resource_claim(ResourceClaim::new("workers", 2))
                // What the caller claims about its own cost is a description,
                // carried back in the receipt and never read as the budget.
                .with_attribute("licoup.quota.tokens", "999999")
                .with_attribute("vendor.example/cost.tokens", "0"),
        )
        .expect("admission answers"),
    );
    assert_eq!(
        receipt.resources,
        vec![ResourceState {
            resource_id: "workers".to_owned(),
            available: true,
            active: 0,
            capacity: 4,
            revision: 7,
        }]
    );
    assert_eq!(
        receipt
            .attributes
            .get("licoup.quota.tokens")
            .map(String::as_str),
        Some("999999")
    );
    // The observation is read against the effect and the run, not against a
    // cache keyed by nothing.
    let observed = resources.observations();
    assert_eq!(observed.len(), 1);
    assert_eq!(observed[0].effect_id, "effect-1");
    assert_eq!(observed[0].run_id, RUN);
    // No budget is configured, so nothing is held — and that is reported, not
    // silently turned into a limit.
    assert_eq!(
        receipt.reservations,
        vec![ReservationOutcome::NotConfigured]
    );
    assert!(resources.reservations().is_empty());
}

#[test]
fn a_configured_budget_is_reserved_by_effect_id() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.configure_budget(true);
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    let receipt = admitted(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 2)),
        )
        .expect("admission answers"),
    );
    let reservation = receipt
        .reservations
        .first()
        .and_then(ReservationOutcome::reserved)
        .expect("a configured budget reserves");
    assert_eq!(reservation.effect_id, "effect-1");
    assert_eq!(reservation.slots, 2);
    assert_eq!(resources.reservations(), vec![reservation.clone()]);
}

#[test]
fn a_refused_effect_names_the_resource_and_the_state_it_was_refused_from() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.state(ResourceState {
        resource_id: "workers".to_owned(),
        available: true,
        active: 4,
        capacity: 4,
        revision: 11,
    });
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    match refused(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers"),
    ) {
        AdmissionRefusal::ResourceUnavailable { claim, observed } => {
            assert_eq!(claim.resource_id, "workers");
            assert_eq!(claim.slots, 1);
            assert_eq!(observed.active, 4);
            assert_eq!(observed.capacity, 4);
            assert_eq!(observed.revision, 11);
            assert_eq!(observed.free_slots(), 0);
        }
        other => panic!("expected ResourceUnavailable, got {other:?}"),
    }
    // A refused effect holds nothing.
    assert!(resources.reservations().is_empty());
}

#[test]
fn an_unavailable_resource_is_distinguishable_from_a_full_one() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.state(ResourceState {
        resource_id: "workers".to_owned(),
        available: false,
        active: 0,
        capacity: 4,
        revision: 3,
    });
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    match refused(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers"),
    ) {
        // Free capacity exists and the resource still refuses the effect: the
        // two facts are not collapsed into "full".
        AdmissionRefusal::ResourceUnavailable { observed, .. } => {
            assert!(!observed.available);
            assert_eq!(observed.free_slots(), 4);
        }
        other => panic!("expected ResourceUnavailable, got {other:?}"),
    }
}

#[test]
fn a_moved_resource_revision_is_not_a_capacity_refusal() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    match refused(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a")
                .with_resource_claim(ResourceClaim::new("workers", 1).with_expected_revision(2)),
        )
        .expect("admission answers"),
    ) {
        AdmissionRefusal::ResourceRevisionMoved {
            resource_id,
            expected,
            observed,
        } => {
            assert_eq!(resource_id, "workers");
            assert_eq!(expected, 2);
            assert_eq!(observed, 7);
        }
        other => panic!("expected ResourceRevisionMoved, got {other:?}"),
    }
    assert!(resources.reservations().is_empty());
}

#[test]
fn a_reservation_is_held_until_started_or_unknown_work_is_reconciled() {
    assert_eq!(
        settlement_for(EffectPosition::NotStarted),
        ReservationSettlement::Release
    );
    assert_eq!(
        settlement_for(EffectPosition::Settled),
        ReservationSettlement::Release
    );
    // C03: an effect that may have run keeps its capacity. Releasing early
    // would hand the same slot to a second effect while the first is spending.
    assert_eq!(
        settlement_for(EffectPosition::Started),
        ReservationSettlement::HoldUntilReconciled
    );
    assert_eq!(
        settlement_for(EffectPosition::Unknown),
        ReservationSettlement::HoldUntilReconciled
    );
}

#[test]
fn a_retry_for_the_same_effect_reuses_its_reservation_instead_of_booking_twice() {
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
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 2)),
        )
        .expect("admission answers"),
    );
    // The same effect, admitted again: the identity is stable across attempts,
    // and the attempt token only guards the receipt against a replayed callback.
    let replayed = admitted(
        gate.admit(
            &resolved(&gate),
            &retry("effect-1", "attempt-2", "a")
                .with_resource_claim(ResourceClaim::new("workers", 2)),
        )
        .expect("admission answers"),
    );

    let held = first
        .reservations
        .first()
        .and_then(ReservationOutcome::reserved)
        .expect("the first admission reserved");
    let reused = replayed
        .reservations
        .first()
        .and_then(ReservationOutcome::reserved)
        .expect("the retry reserved");
    assert!(!held.reused);
    assert!(
        reused.reused,
        "the retry must report the reservation it reused"
    );
    assert_eq!(reused.reservation_id, held.reservation_id);
    assert_eq!(replayed.attempt_token, "attempt-2");
    // One effect, one reservation: the retry did not book capacity twice.
    assert_eq!(resources.reservations().len(), 1);
}

#[test]
fn the_owner_enforces_its_own_cap_at_reservation_time() {
    let resources = ResourceOwner::new();
    resources.configure_budget(true);
    let reserve = |effect_id: &str, slots: u32| {
        licoup_workflow_runtime::admission::ResourcePort::reserve(
            resources.as_ref(),
            &ReservationRequest {
                effect_id: effect_id.to_owned(),
                attempt_token: "attempt-1".to_owned(),
                resource_id: "workers".to_owned(),
                slots,
            },
        )
        .expect("reserve answers")
    };

    assert!(reserve("effect-1", 4).reserved().is_some());
    // The cap is the owner's and it is enforced where capacity is promised: an
    // effect that no longer fits waits instead of failing.
    match reserve("effect-2", 1) {
        ReservationOutcome::Waiting(waiting) => {
            assert_eq!(waiting.denial, ReservationDenial::Exhausted);
            assert_eq!(waiting.available_slots, Some(0));
            assert_eq!(waiting.effect_id, "effect-2");
        }
        other => panic!("expected a wait, got {other:?}"),
    }
    assert_eq!(resources.reservations().len(), 1);
}

#[test]
fn a_contended_owner_answers_a_wait_and_the_boundary_reports_it_as_one() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.configure_budget(true);
    // Another writer, or an upstream rate limit, holds the resource.
    resources.deny_reservations(Some(ReservationDenial::Contended));
    let barriers = BarrierOwner::new();
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    match refused(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers"),
    ) {
        AdmissionRefusal::ResourceWaiting { claim, waiting } => {
            assert_eq!(claim.resource_id, "workers");
            assert_eq!(waiting.effect_id, "effect-1");
            assert_eq!(waiting.denial, ReservationDenial::Contended);
            assert_eq!(waiting.available_slots, Some(4));
        }
        other => panic!("expected ResourceWaiting, got {other:?}"),
    }
    // A wait holds nothing and is not a failure: nothing was reserved and the
    // same request is admitted once the contention clears.
    assert!(resources.reservations().is_empty());
    resources.deny_reservations(None);
    let receipt = admitted(
        gate.admit(
            &resolved(&gate),
            &request("effect-1", "a").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers"),
    );
    assert!(
        receipt
            .reservations
            .first()
            .and_then(ReservationOutcome::reserved)
            .is_some()
    );
}

#[test]
fn release_is_idempotent_so_a_retried_reconcile_cannot_fail_on_its_own_success() {
    let resources = ResourceOwner::new();
    resources.configure_budget(true);
    let reservation = match licoup_workflow_runtime::admission::ResourcePort::reserve(
        resources.as_ref(),
        &licoup_workflow_runtime::admission::ReservationRequest {
            effect_id: "effect-1".to_owned(),
            attempt_token: "attempt-1".to_owned(),
            resource_id: "workers".to_owned(),
            slots: 1,
        },
    )
    .expect("reserve answers")
    {
        ReservationOutcome::Reserved(reservation) => reservation,
        other => panic!("a configured budget with free capacity must reserve, got {other:?}"),
    };
    for _ in 0..2 {
        licoup_workflow_runtime::admission::ResourcePort::release(resources.as_ref(), &reservation)
            .expect("release is idempotent");
    }
    assert_eq!(resources.releases(), 2);
}
