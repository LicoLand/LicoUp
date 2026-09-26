//! The pause/stop barrier: one write, one recipient set, and a state only the
//! facts may show.
//!
//! What these tests hold the implementation to:
//!
//! * the barrier and its frozen recipients are written in the *same*
//!   transaction — the fixture journals both facts under one transaction id, so
//!   an implementation that wrote them apart could not produce this journal;
//! * a run-scoped barrier stops a new node visit, and does so before anything is
//!   observed or reserved;
//! * a node-scoped instruction does not fence new visits, because C03 gives the
//!   new-start fence to the graph scope;
//! * `Paused` is only shown once nothing is in flight, and a terminal outcome
//!   survives a pause unchanged.

use std::sync::Arc;

use licoup_workflow_runtime::admission::{
    AdmissionRefusal, AdmissionRequest, BarrierKind, BarrierRequest, BarrierScope, PauseState,
    ResourceClaim, scope_status,
};
use licoup_workflow_runtime::node::NodeOutcomeKind;

use crate::fixture::{
    AuthorityOwner, BarrierOwner, JournalEntry, REVISION, RUN, ResourceOwner, admitted, caller,
    gate, refused, visit,
};

fn request(effect_id: &str, state_id: &str) -> AdmissionRequest {
    AdmissionRequest::new(RUN, effect_id, "attempt-1", visit(state_id), REVISION)
}

fn resolved(
    gate: &licoup_workflow_runtime::admission::AdmissionGate,
) -> licoup_workflow_runtime::admission::AdmissionAuthority {
    gate.authority_for(caller("owner-1"), REVISION)
        .expect("resolution is not a failure")
        .expect("granted")
}

#[test]
fn a_run_pause_writes_the_barrier_and_its_recipients_in_one_transaction() {
    let barriers = BarrierOwner::new();
    let in_flight = visit("a");
    barriers.live(in_flight.clone());

    let barrier = licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: BarrierScope::Run(RUN.to_owned()),
            kind: BarrierKind::Pause,
            reason: "operator paused the run".to_owned(),
            recipients: vec![in_flight.clone()],
        },
    )
    .expect("the barrier is written");

    assert_eq!(barrier.recipients, vec![in_flight.clone()]);
    assert!(barrier.blocks_new_visits());
    assert!(barrier.froze(&in_flight));
    // One transaction, and both facts are in it: the journal is the evidence a
    // two-transaction implementation could not produce.
    let transactions = barriers.barrier_transactions();
    assert_eq!(transactions.len(), 1);
    assert_eq!(transactions[0].0, barrier.written_at);
    assert_eq!(transactions[0].2, 1);
    assert!(
        barriers.violations().is_empty(),
        "{:?}",
        barriers.violations()
    );
    // The pause froze the in-flight visit and did not remove it: a barrier
    // stops new visits, it does not undo work already running.
    assert_eq!(barriers.live_visits(), [in_flight].into_iter().collect());
    assert!(matches!(
        barriers.journal().as_slice(),
        [JournalEntry::Barrier { .. }, JournalEntry::Recipient { .. }]
    ));
}

#[test]
fn a_new_visit_cannot_start_under_a_run_barrier_and_holds_nothing() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    resources.configure_budget(true);
    let barriers = BarrierOwner::new();
    let in_flight = visit("a");
    barriers.live(in_flight.clone());
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: BarrierScope::Run(RUN.to_owned()),
            kind: BarrierKind::Pause,
            reason: "operator paused the run".to_owned(),
            recipients: vec![in_flight],
        },
    )
    .expect("the barrier is written");

    match refused(
        gate.admit(
            &resolved(&gate),
            &request("effect-2", "b").with_resource_claim(ResourceClaim::new("workers", 1)),
        )
        .expect("admission answers"),
    ) {
        AdmissionRefusal::ScopeBarrier(barrier) => {
            assert_eq!(barrier.reason, "operator paused the run");
            assert_eq!(barrier.kind, BarrierKind::Pause);
            // The fence is the run the effect belongs to. There is no field in
            // the request that could point the lookup at a scope no barrier was
            // written for.
            assert_eq!(barrier.scope, BarrierScope::Run(RUN.to_owned()));
        }
        other => panic!("expected ScopeBarrier, got {other:?}"),
    }
    // The fence runs before the resource step: a new visit must not even look at
    // the resources it will never use.
    assert!(resources.observations().is_empty());
    assert!(resources.reservations().is_empty());
}

#[test]
fn a_run_barrier_fences_only_the_run_it_was_written_for() {
    let authority = AuthorityOwner::granted();
    authority.bind_run("run-2", REVISION);
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let in_flight = visit("a");
    barriers.live(in_flight.clone());
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: BarrierScope::Run(RUN.to_owned()),
            kind: BarrierKind::Pause,
            reason: "operator paused run-1".to_owned(),
            recipients: vec![in_flight],
        },
    )
    .expect("the barrier is written");

    // The paused run is fenced; the other run keeps starting work.
    match refused(
        gate.admit(&resolved(&gate), &request("effect-1", "a"))
            .expect("admission answers"),
    ) {
        AdmissionRefusal::ScopeBarrier(barrier) => {
            assert_eq!(barrier.scope, BarrierScope::Run(RUN.to_owned()));
        }
        other => panic!("expected ScopeBarrier, got {other:?}"),
    }
    let other_run = AdmissionRequest::new("run-2", "effect-2", "attempt-1", visit("b"), REVISION);
    let receipt = admitted(
        gate.admit(&resolved(&gate), &other_run)
            .expect("admission answers"),
    );
    assert_eq!(receipt.run_id, "run-2");
    assert_eq!(receipt.barrier, None);
}

#[test]
fn an_instruction_on_one_node_does_not_fence_a_new_visit() {
    let authority = AuthorityOwner::granted();
    let resources = ResourceOwner::new();
    let barriers = BarrierOwner::new();
    let frozen = visit("a");
    barriers.live(frozen.clone());
    let gate = gate(
        Arc::clone(&authority),
        Arc::clone(&resources),
        Arc::clone(&barriers),
    );

    let barrier = licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: BarrierScope::Node(frozen.clone()),
            kind: BarrierKind::Pause,
            reason: "drain this node".to_owned(),
            recipients: vec![frozen.clone()],
        },
    )
    .expect("the barrier is written");
    assert!(!barrier.blocks_new_visits());

    // A new visit of another node is not a recipient of that instruction, and
    // the node scope does not create a new-start fence.
    let receipt = admitted(
        gate.admit(&resolved(&gate), &request("effect-2", "b"))
            .expect("admission answers"),
    );
    assert_eq!(receipt.barrier.as_ref().map(|barrier| barrier.kind), None);
    assert_eq!(receipt.node, visit("b"));
}

#[test]
fn paused_is_shown_only_when_the_facts_support_it() {
    let barriers = BarrierOwner::new();
    let barrier = licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: BarrierScope::Run(RUN.to_owned()),
            kind: BarrierKind::Pause,
            reason: "operator paused the run".to_owned(),
            recipients: vec![],
        },
    )
    .expect("the barrier is written");

    // No barrier: nothing is paused, whatever else is true.
    let idle = scope_status(None, 0, Some(NodeOutcomeKind::Succeeded));
    assert_eq!(idle.pause, PauseState::NotPaused);
    assert_eq!(idle.terminal, Some(NodeOutcomeKind::Succeeded));

    // Barrier written, work still in flight: the run is still running, so the
    // honest state is "requested".
    let draining = scope_status(Some(&barrier), 2, Some(NodeOutcomeKind::Succeeded));
    assert_eq!(draining.pause, PauseState::PauseRequested);
    assert_eq!(draining.reason.as_deref(), Some("operator paused the run"));
    assert_eq!(draining.in_flight, 2);
    // The original terminal outcome is reported as it was: a pause does not
    // erase a result that already happened.
    assert_eq!(draining.terminal, Some(NodeOutcomeKind::Succeeded));

    // Nothing in flight: now the facts support showing it, and the outcome is
    // still the one that happened.
    let paused = scope_status(Some(&barrier), 0, Some(NodeOutcomeKind::Succeeded));
    assert_eq!(paused.pause, PauseState::Paused);
    assert_eq!(paused.terminal, Some(NodeOutcomeKind::Succeeded));
}

#[test]
fn a_stop_is_shown_as_stopped_and_is_not_cleared_by_a_later_pause() {
    let barriers = BarrierOwner::new();
    let scope = BarrierScope::Run(RUN.to_owned());
    let stop = licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: scope.clone(),
            kind: BarrierKind::Stop,
            reason: "operator stopped the run".to_owned(),
            recipients: vec![visit("a")],
        },
    )
    .expect("the barrier is written");
    let later_pause = licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: scope.clone(),
            kind: BarrierKind::Pause,
            reason: "a pause arrived afterwards".to_owned(),
            recipients: vec![],
        },
    )
    .expect("the barrier is written");

    assert_eq!(later_pause.kind, BarrierKind::Stop);
    assert_eq!(later_pause.reason, stop.reason);
    assert_eq!(
        licoup_workflow_runtime::admission::ScopeBarrierPort::barrier(barriers.as_ref(), &scope)
            .expect("the barrier is read")
            .map(|barrier| barrier.kind),
        Some(BarrierKind::Stop)
    );
    // A stop is not a drain: it is shown as stopped even with work in flight.
    let status = scope_status(Some(&stop), 3, Some(NodeOutcomeKind::Failed));
    assert_eq!(status.pause, PauseState::Stopped);
    assert_eq!(status.terminal, Some(NodeOutcomeKind::Failed));
}

#[test]
fn a_barrier_is_read_for_the_scope_it_was_written_for() {
    let barriers = BarrierOwner::new();
    let run = BarrierScope::Run(RUN.to_owned());
    let node = BarrierScope::Node(visit("a"));
    licoup_workflow_runtime::admission::ScopeBarrierPort::publish(
        barriers.as_ref(),
        &BarrierRequest {
            scope: node.clone(),
            kind: BarrierKind::Pause,
            reason: "drain this node".to_owned(),
            recipients: vec![],
        },
    )
    .expect("the barrier is written");

    assert!(
        licoup_workflow_runtime::admission::ScopeBarrierPort::barrier(barriers.as_ref(), &run)
            .expect("the barrier is read")
            .is_none()
    );
    assert!(
        licoup_workflow_runtime::admission::ScopeBarrierPort::barrier(barriers.as_ref(), &node)
            .expect("the barrier is read")
            .is_some()
    );
}
