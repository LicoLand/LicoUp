use licoup_conversation::continuity::{
    ASSISTANT_TURN_INVALID_ERROR, ContextCompositionPort, ContinuityAgreement,
    ContinuityAgreementOrigin, ContinuityAgreementScope, ContinuityAssistantTurnResponse,
    ContinuityClosureAuthorityKind, ContinuityCommitPort, ContinuityContextCompositionRequest,
    ContinuityEffectStatus, ContinuityFailureCode, ContinuityFollowThroughKind,
    ContinuityGoalCompletionTransition, ContinuityGoalControl, ContinuityGoalEvent,
    ContinuityGoalLifecycle, ContinuityInterpretationProposal, ContinuityInterrupt,
    ContinuityParentContextGrant, ContinuityParentGrantStatus, ContinuityReadPort,
    ContinuitySourceOwnerKind, ContinuitySourceRef, ContinuitySourceValidity, ContinuitySpeechAct,
    ContinuityTaskChildAdmission, ContinuityVisibilityScope, INGRESS_USER_POSTED_DESIGNATION,
    TRUSTED_RESPONSE_MODE_ASSISTANT_TURN, UnavailableContextComposition, accept_completion,
    ack_completion_notices, apply_goal_control, commit_user_posted_proposal, consume_logical_wake,
    derived_live_count, ingress_execution_recorded, list_due_goals,
    list_pending_completion_notices, parse_continuity_value, put_agreement, put_derived,
    put_effect, put_grant, read_agreements, read_goal, read_pending_outbox,
    read_relation_for_child, record_settlement_applied, record_settlement_pending, replay_effect,
    resolve_completion_notice, revoke_source, schedule_goal_due, set_continuity_interrupt,
    settlement_applied,
};
use licoup_conversation::{
    ConversationStore, DispatchState, EventKind, EventPartKind, MembershipAccess, NewEventPart,
    Principal, PrincipalKind,
};
use rusqlite;

fn human() -> Principal {
    Principal {
        id: "principal:human".into(),
        kind: PrincipalKind::Human,
        display_name: "Human".into(),
        agent_id: None,
        created_at_unix_ms: 1,
    }
}

fn agent() -> Principal {
    Principal {
        id: "principal:agent".into(),
        kind: PrincipalKind::Agent,
        display_name: "Agent".into(),
        agent_id: Some("agent:local".into()),
        created_at_unix_ms: 1,
    }
}

fn source_ref(event_id: &str, revision: i64) -> ContinuitySourceRef {
    ContinuitySourceRef {
        owner_kind: ContinuitySourceOwnerKind::Event,
        opaque_id: event_id.to_owned(),
        part_id: None,
        span: None,
        source_revision: revision,
        digest: format!("card:{event_id}"),
        visibility_scope: ContinuityVisibilityScope::Conversation,
        validity: ContinuitySourceValidity::Current,
    }
}

struct Harness {
    store: ConversationStore,
    conversation_id: String,
    owner_membership_id: String,
    event_id: String,
    revision: i64,
    epoch: i64,
}

impl Harness {
    fn new(title: &str) -> Self {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation(title, human()).unwrap();
        let owner = conversation
            .memberships
            .iter()
            .find(|membership| membership.access == MembershipAccess::Owner)
            .unwrap()
            .id
            .clone();
        let event = store
            .append_event(
                &conversation.id,
                Some(&owner),
                EventKind::Message,
                &[NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Text,
                    content: "delegate notes".into(),
                }],
                None,
                None,
                true,
            )
            .unwrap();
        let basis = store.continuity_commit_basis(&conversation.id).unwrap();
        Self {
            store,
            conversation_id: conversation.id,
            owner_membership_id: owner,
            event_id: event.id,
            revision: basis.revision,
            epoch: basis.designation_epoch,
        }
    }

    fn refresh(&mut self) {
        let basis = self
            .store
            .continuity_commit_basis(&self.conversation_id)
            .unwrap();
        self.revision = basis.revision;
        self.epoch = basis.designation_epoch;
    }

    fn proposal(
        &self,
        request_id: &str,
        goal_id: &str,
        matter_id: &str,
        with_child: bool,
    ) -> ContinuityInterpretationProposal {
        ContinuityInterpretationProposal {
            envelope: licoup_conversation::continuity::ContinuityWriteEnvelope {
                conversation_id: self.conversation_id.clone(),
                source_event_refs: vec![source_ref(&self.event_id, 1)],
                observed_revision: self.revision,
                designation_epoch: self.epoch,
                request_id: request_id.to_owned(),
            },
            matter_associations: vec![
                licoup_conversation::continuity::ContinuityMatterAssociation {
                    matter_id: matter_id.to_owned(),
                    source_ref: source_ref(&self.event_id, 1),
                    association_revision: 1,
                    proposed_by: self.owner_membership_id.clone(),
                    reason_code: "user-delegation".into(),
                    supersedes: None,
                },
            ],
            speech_act: ContinuitySpeechAct::Delegation,
            commitment_proposals: vec![
                licoup_conversation::continuity::ContinuityCommitmentProposal {
                    matter_id: Some(matter_id.to_owned()),
                    subject: licoup_conversation::continuity::ContinuityMatterSubject::New,
                    expected_result: "Draft the notes".into(),
                    criteria: Vec::new(),
                    create_goal: true,
                },
            ],
            agreement_proposals: Vec::new(),
            capability_needs: vec!["writing".into()],
            uncertainty_reasons: Vec::new(),
            requested_reads: Vec::new(),
            task_child_admission: with_child.then(|| ContinuityTaskChildAdmission {
                goal_id: goal_id.to_owned(),
                parent_conversation_id: self.conversation_id.clone(),
                speech_act: ContinuitySpeechAct::Delegation,
                follow_through_kind: ContinuityFollowThroughKind::Durable,
                observed_child_conversation_id: None,
                observed_card_anchor: None,
                request_id: format!("admit:{request_id}"),
            }),
        }
    }
}

#[test]
fn migrate_does_not_synthesize_goals_or_revive_summaries() {
    let harness = Harness::new("legacy chat");
    let before = read_goal(&harness.store, "goal:missing").unwrap();
    assert!(before.is_none());
    let second = harness
        .store
        .continuity_commit_basis(&harness.conversation_id);
    assert!(second.is_ok());
    assert!(read_goal(&harness.store, "goal:missing").unwrap().is_none());
    assert_eq!(
        derived_live_count(&harness.store, &harness.conversation_id).unwrap(),
        0
    );
}

#[test]
fn commit_is_atomic_for_state_cursor_and_outbox() {
    let mut harness = Harness::new("atomic");
    let proposal = harness.proposal("request:atomic", "goal:notes", "matter:notes", false);
    harness.store.commit(&proposal).unwrap();
    harness.refresh();
    let progress = read_goal(&harness.store, "goal:notes").unwrap().unwrap();
    assert_eq!(progress.lifecycle, ContinuityGoalLifecycle::Active);
    assert!(progress.next_attention.is_some());
    assert_eq!(
        read_pending_outbox(&harness.store, &harness.conversation_id).unwrap(),
        1
    );
    let matters = harness
        .store
        .list_matters(&harness.conversation_id, None, 20)
        .unwrap();
    assert_eq!(matters.len(), 1);
}

#[test]
fn interrupt_boundaries_leave_no_orphan_goal() {
    for point in [
        ContinuityInterrupt::BeforeFirstWrite,
        ContinuityInterrupt::AfterStateWrite,
        ContinuityInterrupt::BeforeCommit,
    ] {
        let harness = Harness::new("interrupt");
        set_continuity_interrupt(Some(point));
        let proposal = harness.proposal("request:int", "goal:notes", "matter:notes", false);
        assert!(harness.store.commit(&proposal).is_err());
        set_continuity_interrupt(None);
        assert!(read_goal(&harness.store, "goal:notes").unwrap().is_none());
        assert_eq!(
            read_pending_outbox(&harness.store, &harness.conversation_id).unwrap(),
            0
        );
    }

    let mut harness = Harness::new("after-commit");
    set_continuity_interrupt(Some(ContinuityInterrupt::AfterCommit));
    let proposal = harness.proposal("request:after", "goal:notes", "matter:notes", false);
    harness.store.commit(&proposal).unwrap();
    set_continuity_interrupt(None);
    assert!(read_goal(&harness.store, "goal:notes").unwrap().is_some());
    assert_eq!(
        read_pending_outbox(&harness.store, &harness.conversation_id).unwrap(),
        1
    );
    assert!(consume_logical_wake(&harness.store, "wake:goal:notes:1").unwrap());
    assert!(!consume_logical_wake(&harness.store, "wake:goal:notes:1").unwrap());
    harness.refresh();
}

#[test]
fn cas_and_idempotency_reject_stale_and_conflicts() {
    let mut harness = Harness::new("cas");
    let first = harness.proposal("request:one", "goal:notes", "matter:notes", false);
    harness.store.commit(&first).unwrap();
    let stale = harness.proposal("request:two", "goal:notes", "matter:notes", false);
    assert_eq!(
        harness.store.commit(&stale).unwrap_err().code,
        ContinuityFailureCode::StaleRevision
    );
    harness.refresh();
    let again = harness.proposal("request:one", "goal:notes", "matter:notes", false);
    let first_revision = harness.store.commit(&again).unwrap().revision;
    let after = harness
        .store
        .continuity_commit_basis(&harness.conversation_id)
        .unwrap();
    assert_eq!(first_revision, after.revision);

    let mut conflict = harness.proposal("request:one", "goal:other", "matter:other", false);
    conflict.envelope.observed_revision = after.revision;
    assert_eq!(
        harness.store.commit(&conflict).unwrap_err().code,
        ContinuityFailureCode::IdempotencyConflict
    );
}

#[test]
fn designation_epoch_advances_on_real_assignment_change() {
    let mut harness = Harness::new("epoch");
    let member = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    harness.refresh();
    harness
        .store
        .set_conversation_assistant(
            &harness.conversation_id,
            &harness.owner_membership_id,
            harness.revision,
            Some(&member.id),
        )
        .unwrap();
    harness.refresh();
    let first_epoch = harness.epoch;
    assert!(first_epoch >= 1);
    let second = harness
        .store
        .add_member(
            &harness.conversation_id,
            Principal {
                id: "principal:agent-b".into(),
                kind: PrincipalKind::Agent,
                display_name: "Agent B".into(),
                agent_id: Some("agent:b".into()),
                created_at_unix_ms: 1,
            },
            MembershipAccess::Member,
        )
        .unwrap();
    harness.refresh();
    harness
        .store
        .set_conversation_assistant(
            &harness.conversation_id,
            &harness.owner_membership_id,
            harness.revision,
            Some(&second.id),
        )
        .unwrap();
    harness.refresh();
    let second_epoch = harness.epoch;
    assert!(second_epoch > first_epoch);
    harness
        .store
        .set_conversation_assistant(
            &harness.conversation_id,
            &harness.owner_membership_id,
            harness.revision,
            Some(&member.id),
        )
        .unwrap();
    harness.refresh();
    assert!(harness.epoch > second_epoch);
    let after_return = harness.epoch;
    harness
        .store
        .set_conversation_assistant(
            &harness.conversation_id,
            &harness.owner_membership_id,
            harness.revision,
            Some(&member.id),
        )
        .unwrap();
    harness.refresh();
    assert_eq!(harness.epoch, after_return);
    let mut stale_epoch = harness.proposal("request:epoch", "goal:notes", "matter:notes", false);
    stale_epoch.envelope.designation_epoch = first_epoch;
    stale_epoch.envelope.observed_revision = harness.revision;
    assert_eq!(
        harness.store.commit(&stale_epoch).unwrap_err().code,
        ContinuityFailureCode::DesignationChanged
    );
}

#[test]
fn leave_member_clearing_assistant_advances_epoch() {
    let mut harness = Harness::new("leave-epoch");
    let member = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    harness.refresh();
    harness
        .store
        .set_conversation_assistant(
            &harness.conversation_id,
            &harness.owner_membership_id,
            harness.revision,
            Some(&member.id),
        )
        .unwrap();
    harness.refresh();
    let assigned = harness.epoch;
    assert!(assigned >= 1);
    harness
        .store
        .leave_member(&harness.conversation_id, &member.id)
        .unwrap();
    harness.refresh();
    assert!(harness.epoch > assigned);
    let conversation = harness.store.get(&harness.conversation_id).unwrap();
    assert!(conversation.assistant_membership_id.is_none());
}

#[test]
fn pause_and_cancel_are_orthogonal_and_cancel_blocks_new_work() {
    let mut harness = Harness::new("control");
    harness
        .store
        .commit(&harness.proposal("request:c", "goal:notes", "matter:notes", false))
        .unwrap();
    let paused = apply_goal_control(
        &harness.store,
        &harness.conversation_id,
        "goal:notes",
        ContinuityGoalEvent::Pause,
    )
    .unwrap();
    assert_eq!(paused.lifecycle, ContinuityGoalLifecycle::Active);
    assert_eq!(paused.control, ContinuityGoalControl::Paused);
    apply_goal_control(
        &harness.store,
        &harness.conversation_id,
        "goal:notes",
        ContinuityGoalEvent::Resume,
    )
    .unwrap();
    let canceling = apply_goal_control(
        &harness.store,
        &harness.conversation_id,
        "goal:notes",
        ContinuityGoalEvent::CancelRequest,
    )
    .unwrap();
    assert_eq!(canceling.control, ContinuityGoalControl::CancelRequested);
    harness.refresh();
    let blocked = harness.proposal("request:more", "goal:notes", "matter:notes", false);
    assert_eq!(
        harness.store.commit(&blocked).unwrap_err().code,
        ContinuityFailureCode::InvalidRequest
    );
    let cancelled = apply_goal_control(
        &harness.store,
        &harness.conversation_id,
        "goal:notes",
        ContinuityGoalEvent::CancelSettled,
    )
    .unwrap();
    assert_eq!(cancelled.lifecycle, ContinuityGoalLifecycle::Cancelled);
    assert!(
        apply_goal_control(
            &harness.store,
            &harness.conversation_id,
            "goal:notes",
            ContinuityGoalEvent::Resume,
        )
        .is_err()
    );
}

#[test]
fn unknown_effect_requires_reconciliation_not_replay() {
    let harness = Harness::new("effects");
    harness
        .store
        .commit(&harness.proposal("request:e", "goal:notes", "matter:notes", false))
        .unwrap();
    put_effect(
        &harness.store,
        &harness.conversation_id,
        Some("goal:notes"),
        "effect:one",
        ContinuityEffectStatus::Unknown,
    )
    .unwrap();
    assert_eq!(
        replay_effect(&harness.store, "effect:one")
            .unwrap_err()
            .code,
        ContinuityFailureCode::ReconciliationRequired
    );
    put_effect(
        &harness.store,
        &harness.conversation_id,
        Some("goal:notes"),
        "effect:one",
        ContinuityEffectStatus::Executed,
    )
    .unwrap();
    assert_eq!(
        replay_effect(&harness.store, "effect:one")
            .unwrap_err()
            .code,
        ContinuityFailureCode::InvalidRequest
    );
    let progress = read_goal(&harness.store, "goal:notes").unwrap().unwrap();
    assert_eq!(progress.lifecycle, ContinuityGoalLifecycle::Active);
}

#[test]
fn revocation_and_agreement_replacement_invalidate_derivations() {
    let mut harness = Harness::new("revoke");
    harness
        .store
        .commit(&harness.proposal("request:r", "goal:notes", "matter:notes", false))
        .unwrap();
    put_derived(
        &harness.store,
        &harness.conversation_id,
        "summary",
        &harness.event_id,
        "old-summary",
    )
    .unwrap();
    assert_eq!(
        derived_live_count(&harness.store, &harness.conversation_id).unwrap(),
        1
    );
    revoke_source(
        &harness.store,
        &harness.conversation_id,
        &harness.event_id,
        true,
    )
    .unwrap();
    assert_eq!(
        derived_live_count(&harness.store, &harness.conversation_id).unwrap(),
        0
    );
    harness.refresh();
    let replay = harness.proposal("request:replay", "goal:notes", "matter:notes", false);
    assert_eq!(
        harness.store.commit(&replay).unwrap_err().code,
        ContinuityFailureCode::SourceRevoked
    );
    put_agreement(
        &harness.store,
        &harness.conversation_id,
        &ContinuityAgreement {
            id: "agreement:one".into(),
            scope: ContinuityAgreementScope::Conversation,
            statement_ref: source_ref(&harness.event_id, 1),
            origin: ContinuityAgreementOrigin::UserExplicit,
            effective_revision: 1,
            supersedes: None,
            valid_from: 1,
            valid_until: None,
            revocation_generation: 0,
        },
    )
    .unwrap();
    put_agreement(
        &harness.store,
        &harness.conversation_id,
        &ContinuityAgreement {
            id: "agreement:two".into(),
            scope: ContinuityAgreementScope::Conversation,
            statement_ref: source_ref(&harness.event_id, 1),
            origin: ContinuityAgreementOrigin::UserExplicit,
            effective_revision: 2,
            supersedes: Some(1),
            valid_from: 2,
            valid_until: None,
            revocation_generation: 1,
        },
    )
    .unwrap();
    let current = read_agreements(&harness.store, &harness.conversation_id).unwrap();
    assert_eq!(current.len(), 1);
    assert_eq!(current[0].id, "agreement:two");
}

#[test]
fn child_relation_is_atomic_idempotent_and_ordered() {
    let mut harness = Harness::new("children");
    let first = harness.proposal("request:a", "goal:a", "matter:a", true);
    harness.store.commit(&first).unwrap();
    let relation_a = harness.store.relation_for_goal("goal:a").unwrap();
    let child = harness
        .store
        .get(&relation_a.child_conversation_id)
        .unwrap();
    assert!(!child.memberships.is_empty());
    assert_ne!(child.id, harness.conversation_id);
    harness.refresh();
    let retry = harness.proposal("request:a", "goal:a", "matter:a", true);
    harness.store.commit(&retry).unwrap();
    let again = harness.store.relation_for_goal("goal:a").unwrap();
    assert_eq!(
        again.child_conversation_id,
        relation_a.child_conversation_id
    );
    assert_eq!(again.card_anchor.event_id, relation_a.card_anchor.event_id);
    assert_eq!(again.card_anchor.sequence, relation_a.card_anchor.sequence);

    harness
        .store
        .append_event(
            &harness.conversation_id,
            Some(&harness.owner_membership_id),
            EventKind::Message,
            &[NewEventPart {
                id: String::new(),
                kind: EventPartKind::Text,
                content: "ordinary chat".into(),
            }],
            None,
            None,
            true,
        )
        .unwrap();
    harness.refresh();
    let second = harness.proposal("request:b", "goal:b", "matter:b", true);
    harness.store.commit(&second).unwrap();
    let relation_b = harness.store.relation_for_goal("goal:b").unwrap();
    assert!(relation_a.card_anchor.sequence < relation_b.card_anchor.sequence);
    assert_ne!(
        relation_a.child_conversation_id,
        relation_b.child_conversation_id
    );

    complete_goal(&harness, "goal:b", 1);
    complete_goal(&harness, "goal:a", 1);
    let listed = harness
        .store
        .list_child_relations(&harness.conversation_id, None, 20)
        .unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed[0].goal_id, "goal:a");
    assert_eq!(listed[1].goal_id, "goal:b");
    assert_eq!(
        listed[0].card_anchor.sequence,
        relation_a.card_anchor.sequence
    );
    assert_eq!(
        listed[1].card_anchor.sequence,
        relation_b.card_anchor.sequence
    );
}

fn complete_goal(harness: &Harness, goal_id: &str, revision: i64) {
    let progress = licoup_conversation::continuity::ContinuityGoalProgress {
        goal_id: goal_id.to_owned(),
        revision,
        lifecycle: ContinuityGoalLifecycle::Achieved,
        control: ContinuityGoalControl::Enabled,
        criterion_evidence_refs: Vec::new(),
        active_execution_refs: Vec::new(),
        blockers: Vec::new(),
        next_attention: None,
        closure_ref: None,
    };
    let transition = ContinuityGoalCompletionTransition {
        transition_id: format!("transition:{goal_id}"),
        goal_id: goal_id.to_owned(),
        from_lifecycle: ContinuityGoalLifecycle::Active,
        to_lifecycle: ContinuityGoalLifecycle::Achieved,
        goal_revision: revision,
        authority_kind: ContinuityClosureAuthorityKind::GoalEvaluation,
        evaluation_ref: ContinuitySourceRef {
            owner_kind: ContinuitySourceOwnerKind::Goal,
            opaque_id: goal_id.to_owned(),
            part_id: None,
            span: None,
            source_revision: revision,
            digest: format!("goal:{goal_id}"),
            visibility_scope: ContinuityVisibilityScope::Goal,
            validity: ContinuitySourceValidity::Current,
        },
        notification_id: format!("notice:{goal_id}"),
    };
    assert!(
        accept_completion(
            &harness.store,
            &harness.conversation_id,
            &transition,
            &progress,
        )
        .unwrap()
    );
    assert!(
        !accept_completion(
            &harness.store,
            &harness.conversation_id,
            &transition,
            &progress,
        )
        .unwrap()
    );
    assert_eq!(
        read_goal(&harness.store, goal_id)
            .unwrap()
            .unwrap()
            .lifecycle,
        ContinuityGoalLifecycle::Achieved
    );
}

#[test]
fn worker_exit_does_not_complete_goal_and_notice_is_consumed_once() {
    let harness = Harness::new("notice");
    harness
        .store
        .commit(&harness.proposal("request:n", "goal:notes", "matter:notes", true))
        .unwrap();
    put_effect(
        &harness.store,
        &harness.conversation_id,
        Some("goal:notes"),
        "effect:worker",
        ContinuityEffectStatus::Executed,
    )
    .unwrap();
    let still = read_goal(&harness.store, "goal:notes").unwrap().unwrap();
    assert_eq!(still.lifecycle, ContinuityGoalLifecycle::Active);
    complete_goal(&harness, "goal:notes", 3);
}

#[test]
fn grants_are_recipient_scoped_and_compose_authorized_is_the_only_entry() {
    let harness = Harness::new("grants");
    harness
        .store
        .commit(&harness.proposal("request:g", "goal:notes", "matter:notes", true))
        .unwrap();
    let relation = harness.store.relation_for_goal("goal:notes").unwrap();
    let grant = ContinuityParentContextGrant {
        grant_id: "grant:one".into(),
        source_conversation_id: harness.conversation_id.clone(),
        recipient_conversation_id: relation.child_conversation_id.clone(),
        recipient_membership_id: "membership:child".into(),
        source_refs: vec![source_ref(&harness.event_id, 1)],
        authorized_scopes: vec![ContinuityVisibilityScope::Conversation],
        status: ContinuityParentGrantStatus::Admitted,
        request_id: "request:grant".into(),
        revocation_generation: 0,
    };
    put_grant(&harness.store, &grant).unwrap();
    let listed = harness
        .store
        .list_parent_grants(
            &relation.child_conversation_id,
            "membership:child",
            None,
            20,
        )
        .unwrap();
    assert_eq!(listed.len(), 1);
    assert!(
        harness
            .store
            .list_parent_grants(&harness.conversation_id, "membership:child", None, 20)
            .unwrap()
            .is_empty()
    );
    let request: ContinuityContextCompositionRequest = parse_continuity_value(&serde_json::json!({
        "conversationId": relation.child_conversation_id,
        "recipientMembershipId": "membership:child",
        "authorizedScopes": ["conversation"],
        "revocationGeneration": 0,
        "limit": 20
    }))
    .unwrap();
    assert_eq!(
        UnavailableContextComposition
            .compose_authorized(&request)
            .unwrap_err()
            .code,
        ContinuityFailureCode::UnsupportedCapability
    );
}

#[test]
fn missing_fixture_conversation_is_no_effect_scope_denial() {
    let store = ConversationStore::open_in_memory().unwrap();
    let conversation = store.create_conversation("other", human()).unwrap();
    let before = store.get(&conversation.id).unwrap();
    let fixture: ContinuityInterpretationProposal = parse_continuity_value(&serde_json::json!({
        "envelope": {
            "conversationId": "conversation:group",
            "sourceEventRefs": [{
                "ownerKind": "event",
                "opaqueId": "event:fixture-one",
                "sourceRevision": 1,
                "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "visibilityScope": "conversation",
                "validity": "current"
            }],
            "observedRevision": 4,
            "designationEpoch": 0,
            "requestId": "request:interpret-1"
        },
        "matterAssociations": [],
        "speechAct": "delegation",
        "commitmentProposals": [],
        "agreementProposals": [],
        "capabilityNeeds": [],
        "uncertaintyReasons": [],
        "requestedReads": []
    }))
    .unwrap();
    let error = store.commit(&fixture).unwrap_err();
    assert_eq!(error.code, ContinuityFailureCode::ScopeDenied);
    assert_eq!(
        error.effect_class,
        licoup_conversation::continuity::ContinuityEffectClass::None
    );
    let after = store.get(&conversation.id).unwrap();
    assert_eq!(after.revision, before.revision);
    assert_eq!(after.event_count, before.event_count);
}

#[test]
fn ten_thousand_production_store_sequences_preserve_invariants() {
    let store = ConversationStore::open_in_memory().unwrap();
    let mut passed = 0u32;
    for seed in 0u64..10_000 {
        run_seeded_sequence(&store, seed);
        passed += 1;
    }
    assert_eq!(passed, 10_000);
}

fn run_seeded_sequence(store: &ConversationStore, seed: u64) {
    let conversation = store
        .create_conversation(&format!("seq-{seed}"), human())
        .unwrap();
    let owner = conversation.memberships[0].id.clone();
    let event = store
        .append_event(
            &conversation.id,
            Some(&owner),
            EventKind::Message,
            &[NewEventPart {
                id: String::new(),
                kind: EventPartKind::Text,
                content: format!("seq {seed}"),
            }],
            None,
            None,
            true,
        )
        .unwrap();
    let basis = store.continuity_commit_basis(&conversation.id).unwrap();
    let matter_id = format!("m{seed}");
    let goal_id = format!("goal:m{seed}");
    let request_id = format!("request:{seed}");
    let proposal = ContinuityInterpretationProposal {
        envelope: licoup_conversation::continuity::ContinuityWriteEnvelope {
            conversation_id: conversation.id.clone(),
            source_event_refs: vec![source_ref(&event.id, 1)],
            observed_revision: basis.revision,
            designation_epoch: basis.designation_epoch,
            request_id,
        },
        matter_associations: Vec::new(),
        speech_act: ContinuitySpeechAct::Delegation,
        commitment_proposals: vec![
            licoup_conversation::continuity::ContinuityCommitmentProposal {
                matter_id: Some(matter_id.clone()),
                subject: licoup_conversation::continuity::ContinuityMatterSubject::New,
                expected_result: "seq".into(),
                criteria: Vec::new(),
                create_goal: true,
            },
        ],
        agreement_proposals: Vec::new(),
        capability_needs: Vec::new(),
        uncertainty_reasons: Vec::new(),
        requested_reads: Vec::new(),
        task_child_admission: (seed % 7 == 0).then(|| ContinuityTaskChildAdmission {
            goal_id: goal_id.clone(),
            parent_conversation_id: conversation.id.clone(),
            speech_act: ContinuitySpeechAct::Delegation,
            follow_through_kind: ContinuityFollowThroughKind::Durable,
            observed_child_conversation_id: None,
            observed_card_anchor: None,
            request_id: format!("admit:{seed}"),
        }),
    };
    if seed % 11 == 0 {
        set_continuity_interrupt(Some(ContinuityInterrupt::BeforeCommit));
        let _ = store.commit(&proposal);
        set_continuity_interrupt(None);
        assert!(read_goal(store, &goal_id).unwrap().is_none());
        return;
    }
    store.commit(&proposal).unwrap();
    let progress = read_goal(store, &goal_id).unwrap().unwrap();
    assert!(
        progress.next_attention.is_some() || progress.control != ContinuityGoalControl::Enabled
    );
    match seed % 5 {
        1 => {
            let paused = apply_goal_control(
                store,
                &conversation.id,
                &goal_id,
                ContinuityGoalEvent::Pause,
            )
            .unwrap();
            assert_eq!(paused.lifecycle, ContinuityGoalLifecycle::Active);
        }
        2 => {
            apply_goal_control(
                store,
                &conversation.id,
                &goal_id,
                ContinuityGoalEvent::CancelRequest,
            )
            .unwrap();
            let cancelled = apply_goal_control(
                store,
                &conversation.id,
                &goal_id,
                ContinuityGoalEvent::CancelSettled,
            )
            .unwrap();
            assert_eq!(cancelled.lifecycle, ContinuityGoalLifecycle::Cancelled);
        }
        3 => {
            put_effect(
                store,
                &conversation.id,
                Some(&goal_id),
                &format!("effect:{seed}"),
                ContinuityEffectStatus::Unknown,
            )
            .unwrap();
            assert_eq!(
                replay_effect(store, &format!("effect:{seed}"))
                    .unwrap_err()
                    .code,
                ContinuityFailureCode::ReconciliationRequired
            );
        }
        4 => {
            revoke_source(store, &conversation.id, &event.id, true).unwrap();
            assert_eq!(derived_live_count(store, &conversation.id).unwrap(), 0);
        }
        _ => {
            assert_eq!(progress.lifecycle, ContinuityGoalLifecycle::Active);
        }
    }
    if seed % 7 == 0 {
        let relation = store.relation_for_goal(&goal_id).unwrap();
        assert_ne!(relation.child_conversation_id, conversation.id);
        let _ = store.get(&relation.child_conversation_id).unwrap();
    }
}

#[test]
fn natural_language_pause_targets_only_associated_goal() {
    let mut harness = Harness::new("f1-scope");
    harness
        .store
        .commit(&harness.proposal("request:a", "goal:a", "matter:a", false))
        .unwrap();
    harness.refresh();
    harness
        .store
        .commit(&harness.proposal("request:b", "goal:b", "matter:b", false))
        .unwrap();
    harness.refresh();
    harness
        .store
        .commit(&harness.proposal("request:c", "goal:c", "matter:c", false))
        .unwrap();
    let revision_c = read_goal(&harness.store, "goal:c")
        .unwrap()
        .unwrap()
        .revision;
    complete_goal(&harness, "goal:c", revision_c);
    harness.refresh();

    let mut pause_a = harness.proposal("request:pause-a", "goal:a", "matter:a", false);
    pause_a.speech_act = ContinuitySpeechAct::Pause;
    pause_a.commitment_proposals[0].create_goal = false;
    harness.store.commit(&pause_a).unwrap();

    assert_eq!(
        read_goal(&harness.store, "goal:a")
            .unwrap()
            .unwrap()
            .control,
        ContinuityGoalControl::Paused
    );
    assert_eq!(
        read_goal(&harness.store, "goal:b")
            .unwrap()
            .unwrap()
            .control,
        ContinuityGoalControl::Enabled
    );
    assert_eq!(
        read_goal(&harness.store, "goal:c")
            .unwrap()
            .unwrap()
            .lifecycle,
        ContinuityGoalLifecycle::Achieved
    );

    harness.refresh();
    let mut ambiguous = harness.proposal("request:pause-all", "goal:a", "matter:a", false);
    ambiguous.speech_act = ContinuitySpeechAct::Pause;
    ambiguous.matter_associations.clear();
    ambiguous.commitment_proposals.clear();
    ambiguous.task_child_admission = None;
    harness.store.commit(&ambiguous).unwrap();
    assert_eq!(
        read_goal(&harness.store, "goal:b")
            .unwrap()
            .unwrap()
            .control,
        ContinuityGoalControl::Enabled
    );
}

#[test]
fn first_ever_failed_commit_does_not_persist_partial_business() {
    let store = ConversationStore::open_in_memory().unwrap();
    let conversation = store.create_conversation("f2-fresh", human()).unwrap();
    let owner = conversation.memberships[0].id.clone();
    let event = store
        .append_event(
            &conversation.id,
            Some(&owner),
            EventKind::Message,
            &[NewEventPart {
                id: String::new(),
                kind: EventPartKind::Text,
                content: "delegate notes".into(),
            }],
            None,
            None,
            true,
        )
        .unwrap();
    let loaded = store.get(&conversation.id).unwrap();
    let proposal = ContinuityInterpretationProposal {
        envelope: licoup_conversation::continuity::ContinuityWriteEnvelope {
            conversation_id: conversation.id.clone(),
            source_event_refs: vec![source_ref(&event.id, 1)],
            observed_revision: loaded.revision,
            designation_epoch: 0,
            request_id: "request:f2-fail".into(),
        },
        matter_associations: vec![
            licoup_conversation::continuity::ContinuityMatterAssociation {
                matter_id: "matter:f2".into(),
                source_ref: source_ref(&event.id, 1),
                association_revision: 1,
                proposed_by: owner,
                reason_code: "user-delegation".into(),
                supersedes: None,
            },
        ],
        speech_act: ContinuitySpeechAct::Delegation,
        commitment_proposals: vec![
            licoup_conversation::continuity::ContinuityCommitmentProposal {
                matter_id: Some("matter:f2".into()),
                subject: licoup_conversation::continuity::ContinuityMatterSubject::New,
                expected_result: "Draft".into(),
                criteria: Vec::new(),
                create_goal: true,
            },
        ],
        agreement_proposals: Vec::new(),
        capability_needs: Vec::new(),
        uncertainty_reasons: Vec::new(),
        requested_reads: Vec::new(),
        task_child_admission: Some(ContinuityTaskChildAdmission {
            goal_id: "goal:f2".into(),
            parent_conversation_id: "conversation:other-parent".into(),
            speech_act: ContinuitySpeechAct::Delegation,
            follow_through_kind: ContinuityFollowThroughKind::Durable,
            observed_child_conversation_id: None,
            observed_card_anchor: None,
            request_id: "request:admit:f2".into(),
        }),
    };
    let error = store.commit(&proposal).unwrap_err();
    assert_eq!(error.code, ContinuityFailureCode::ScopeDenied);
    store.ensure_continuity_migrated().unwrap();
    assert!(read_goal(&store, "goal:f2").unwrap().is_none());
    assert_eq!(read_pending_outbox(&store, &conversation.id).unwrap(), 0);
    assert!(
        store
            .list_matters(&conversation.id, None, 20)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn user_posted_applied_marker_rolls_back_with_before_commit_interrupt() {
    let mut harness = Harness::new("atomic-ingress");
    let agent = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    harness.refresh();
    let proposal = harness.proposal(
        "request:atomic-ingress",
        "goal:atomic",
        "matter:atomic",
        true,
    );
    set_continuity_interrupt(Some(ContinuityInterrupt::BeforeCommit));
    let error =
        commit_user_posted_proposal(&harness.store, &proposal, &harness.event_id, &agent.id)
            .unwrap_err();
    set_continuity_interrupt(None);
    assert_eq!(error.code, ContinuityFailureCode::InvalidRequest);
    assert!(read_goal(&harness.store, "goal:atomic").unwrap().is_none());
    assert!(
        !ingress_execution_recorded(
            &harness.store,
            &harness.conversation_id,
            &harness.event_id,
            &agent.id,
            INGRESS_USER_POSTED_DESIGNATION,
        )
        .unwrap()
    );
    commit_user_posted_proposal(&harness.store, &proposal, &harness.event_id, &agent.id).unwrap();
    assert!(read_goal(&harness.store, "goal:atomic").unwrap().is_some());
    assert!(
        ingress_execution_recorded(
            &harness.store,
            &harness.conversation_id,
            &harness.event_id,
            &agent.id,
            INGRESS_USER_POSTED_DESIGNATION,
        )
        .unwrap()
    );
    assert_eq!(
        harness
            .store
            .list_child_relations(&harness.conversation_id, None, 8)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn canonical_child_designates_parent_assistant() {
    let mut harness = Harness::new("child-assistant");
    let agent = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    harness.refresh();
    harness
        .store
        .set_conversation_assistant(
            &harness.conversation_id,
            &harness.owner_membership_id,
            harness.revision,
            Some(&agent.id),
        )
        .unwrap();
    harness.refresh();
    let proposal = harness.proposal(
        "request:child-asst",
        "goal:child-asst",
        "matter:child-asst",
        true,
    );
    harness.store.commit(&proposal).unwrap();
    let relation = harness.store.relation_for_goal("goal:child-asst").unwrap();
    let child = harness.store.get(&relation.child_conversation_id).unwrap();
    assert!(
        child.assistant_membership_id.is_some(),
        "canonical child must designate the admitted assistant"
    );
    let assistant = child
        .memberships
        .iter()
        .find(|membership| child.assistant_membership_id.as_deref() == Some(membership.id.as_str()))
        .expect("designated child assistant membership");
    assert_eq!(assistant.principal.kind, PrincipalKind::Agent);
    assert_eq!(
        read_relation_for_child(&harness.store, &relation.child_conversation_id)
            .unwrap()
            .map(|item| item.goal_id),
        Some("goal:child-asst".into())
    );
    let intent = licoup_conversation::continuity::read_child_work_intent(
        &harness.store,
        &harness.conversation_id,
        "goal:child-asst",
        1,
    )
    .unwrap()
    .expect("child work obligation is written in the parent commit unit");
    assert_eq!(
        intent["operationId"],
        licoup_conversation::continuity::child_work_operation_id("goal:child-asst", 1)
    );
    assert_eq!(
        intent["childConversationId"],
        relation.child_conversation_id
    );
}

#[test]
fn due_index_and_settlement_cursors_are_bounded() {
    let harness = Harness::new("due-index");
    let proposal = harness.proposal("request:due", "goal:due", "matter:due", true);
    harness.store.commit(&proposal).unwrap();
    schedule_goal_due(
        &harness.store,
        &harness.conversation_id,
        "goal:due",
        1_000,
        "review-due",
        "host",
    )
    .unwrap();
    let due = list_due_goals(&harness.store, 2_000).unwrap();
    assert!(
        due.iter().any(|(goal_id, conversation_id, next_due)| {
            goal_id == "goal:due"
                && conversation_id == &harness.conversation_id
                && *next_due == 1_000
        }),
        "due goals must come from next_due index: {due:?}"
    );
    assert!(list_due_goals(&harness.store, 500).unwrap().is_empty());
    record_settlement_pending(
        &harness.store,
        &harness.conversation_id,
        "dispatch:one",
        &serde_json::json!({"output": "pending-body"}),
    )
    .unwrap();
    assert!(!settlement_applied(&harness.store, &harness.conversation_id, "dispatch:one").unwrap());
    record_settlement_applied(
        &harness.store,
        &harness.conversation_id,
        "dispatch:one",
        &serde_json::json!({"output": "applied-body"}),
    )
    .unwrap();
    assert!(settlement_applied(&harness.store, &harness.conversation_id, "dispatch:one").unwrap());
}

#[test]
fn child_work_intent_accepted_and_started_are_separate_units() {
    use licoup_conversation::continuity::{
        child_work_accepted, child_work_started, list_unacked_child_work,
        record_child_work_accepted, record_child_work_intent, record_child_work_started,
    };
    let harness = Harness::new("child-work-cursors");
    record_child_work_intent(
        &harness.store,
        &harness.conversation_id,
        "goal:due",
        1,
        &serde_json::json!({
            "kind": "child-work-intent",
            "goalId": "goal:due",
            "revision": 1,
        }),
    )
    .unwrap();
    let unacked = list_unacked_child_work(&harness.store).unwrap();
    assert_eq!(unacked.len(), 1);
    assert_eq!(unacked[0].1, "goal:due");
    assert!(!child_work_accepted(&harness.store, &harness.conversation_id, "goal:due", 1).unwrap());
    record_child_work_accepted(
        &harness.store,
        &harness.conversation_id,
        "goal:due",
        1,
        &serde_json::json!({
            "kind": "child-work-accepted",
            "dispatchId": "dispatch:accepted",
            "revision": 1,
        }),
    )
    .unwrap();
    assert!(child_work_accepted(&harness.store, &harness.conversation_id, "goal:due", 1).unwrap());
    assert_eq!(list_unacked_child_work(&harness.store).unwrap().len(), 1);
    record_child_work_started(&harness.store, &harness.conversation_id, "goal:due", 1).unwrap();
    assert!(child_work_started(&harness.store, &harness.conversation_id, "goal:due", 1).unwrap());
    assert!(list_unacked_child_work(&harness.store).unwrap().is_empty());
}

#[test]
fn child_work_and_settlement_lists_are_pending_only_anti_joins() {
    use licoup_conversation::continuity::{
        child_work_operation_id, list_unacked_child_work, list_unapplied_settlements,
        read_child_work_intent, record_child_work_intent, record_child_work_started,
        record_settlement_applied, record_settlement_pending,
    };
    let harness = Harness::new("bounded-pending-lists");
    for revision in 1..=3 {
        record_child_work_intent(
            &harness.store,
            &harness.conversation_id,
            "goal:due",
            revision,
            &serde_json::json!({
                "kind": "child-work-intent",
                "goalId": "goal:due",
                "revision": revision,
                "operationId": child_work_operation_id("goal:due", revision),
            }),
        )
        .unwrap();
    }
    record_child_work_started(&harness.store, &harness.conversation_id, "goal:due", 1).unwrap();
    record_child_work_started(&harness.store, &harness.conversation_id, "goal:due", 2).unwrap();
    let unacked = list_unacked_child_work(&harness.store).unwrap();
    assert_eq!(unacked.len(), 1);
    assert_eq!(unacked[0].2, 3);
    assert_eq!(
        unacked[0].3["operationId"],
        child_work_operation_id("goal:due", 3)
    );
    let intent = read_child_work_intent(&harness.store, &harness.conversation_id, "goal:due", 3)
        .unwrap()
        .expect("durable intent");
    assert_eq!(
        intent["operationId"],
        child_work_operation_id("goal:due", 3)
    );

    record_settlement_pending(
        &harness.store,
        &harness.conversation_id,
        "dispatch:one",
        &serde_json::json!({"output": "pending-one"}),
    )
    .unwrap();
    record_settlement_pending(
        &harness.store,
        &harness.conversation_id,
        "dispatch:two",
        &serde_json::json!({"output": "pending-two"}),
    )
    .unwrap();
    record_settlement_applied(
        &harness.store,
        &harness.conversation_id,
        "dispatch:one",
        &serde_json::json!({"output": "applied-one"}),
    )
    .unwrap();
    let pending = list_unapplied_settlements(&harness.store).unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].1, "dispatch:two");
}

#[test]
fn pending_obligation_pages_and_scan_ignore_growing_acked_history() {
    use licoup_conversation::continuity::{
        PENDING_OBLIGATION_PAGE_SIZE, child_work_operation_id, list_unacked_child_work,
        list_unacked_child_work_page, pending_obligation_scan_evidence, read_child_work_intent,
        read_child_work_live, record_child_work_intent, record_child_work_live,
        record_child_work_started,
    };
    let harness = Harness::new("pending-scan-evidence");
    for revision in 1..=12 {
        record_child_work_intent(
            &harness.store,
            &harness.conversation_id,
            "goal:history",
            revision,
            &serde_json::json!({
                "kind": "child-work-intent",
                "goalId": "goal:history",
                "revision": revision,
                "admittedRevision": revision,
                "workGeneration": revision,
                "operationId": child_work_operation_id("goal:history", revision),
            }),
        )
        .unwrap();
        record_child_work_started(
            &harness.store,
            &harness.conversation_id,
            "goal:history",
            revision,
        )
        .unwrap();
    }
    record_child_work_intent(
        &harness.store,
        &harness.conversation_id,
        "goal:live",
        1,
        &serde_json::json!({
            "kind": "child-work-intent",
            "goalId": "goal:live",
            "revision": 1,
            "admittedRevision": 1,
            "workGeneration": 1,
            "operationId": child_work_operation_id("goal:live", 1),
        }),
    )
    .unwrap();
    let (work_plan, settlement_plan, pending, historical, decoded) =
        pending_obligation_scan_evidence(&harness.store).unwrap();
    assert_eq!(pending, 1);
    assert_eq!(historical, 13);
    assert_eq!(decoded, 1);
    let work_plan_text = work_plan.join("\n");
    let settlement_plan_text = settlement_plan.join("\n");
    assert!(
        work_plan_text.contains("outstanding_work"),
        "pending work scan must use the outstanding-work index: {work_plan_text}"
    );
    assert!(
        settlement_plan_text.contains("outstanding_settlement"),
        "pending settlement scan must use the outstanding-settlement index: {settlement_plan_text}"
    );
    for revision in 13..=24 {
        record_child_work_intent(
            &harness.store,
            &harness.conversation_id,
            "goal:history",
            revision,
            &serde_json::json!({
                "kind": "child-work-intent",
                "goalId": "goal:history",
                "revision": revision,
                "admittedRevision": revision,
                "operationId": child_work_operation_id("goal:history", revision),
            }),
        )
        .unwrap();
        record_child_work_started(
            &harness.store,
            &harness.conversation_id,
            "goal:history",
            revision,
        )
        .unwrap();
    }
    let (_, _, pending_after, historical_after, decoded_after) =
        pending_obligation_scan_evidence(&harness.store).unwrap();
    assert_eq!(pending_after, 1, "acked history must not grow pending rows");
    assert_eq!(historical_after, 25);
    assert_eq!(decoded_after, 1, "poll decode must stay on pending rows");
    assert!(
        read_child_work_intent(&harness.store, &harness.conversation_id, "goal:history", 1)
            .unwrap()
            .is_some()
    );

    for index in 0..3 {
        record_child_work_intent(
            &harness.store,
            &harness.conversation_id,
            &format!("goal:page-{index}"),
            1,
            &serde_json::json!({
                "kind": "child-work-intent",
                "goalId": format!("goal:page-{index}"),
                "revision": 1,
                "admittedRevision": 1,
                "operationId": child_work_operation_id(&format!("goal:page-{index}"), 1),
            }),
        )
        .unwrap();
    }
    let first = list_unacked_child_work_page(&harness.store, None, None, None, 2).unwrap();
    assert_eq!(first.len(), 2);
    let last = first.last().unwrap();
    let rest = list_unacked_child_work_page(
        &harness.store,
        Some(&last.0),
        Some(&last.1),
        Some(&format!("work:{}:{}:child-work-pending", last.1, last.2)),
        2,
    )
    .unwrap();
    assert!(!rest.is_empty());
    assert!(
        rest.iter()
            .all(|row| !first.iter().any(|seen| seen.1 == row.1))
    );
    assert!(list_unacked_child_work(&harness.store).unwrap().len() >= 4);
    assert!(PENDING_OBLIGATION_PAGE_SIZE >= 2);

    record_child_work_live(
        &harness.store,
        &harness.conversation_id,
        "goal:live",
        &serde_json::json!({
            "kind": "child-work-live",
            "goalId": "goal:live",
            "operationId": child_work_operation_id("goal:live", 1),
            "admittedRevision": 1,
            "workGeneration": 1,
            "childConversationId": "conversation:child",
            "membershipId": "membership:child",
            "parentConversationId": harness.conversation_id,
            "dispatchId": "turn:live",
        }),
    )
    .unwrap();
    assert_eq!(
        read_child_work_live(&harness.store, &harness.conversation_id, "goal:live")
            .unwrap()
            .unwrap()["dispatchId"],
        "turn:live"
    );
}

#[test]
fn file_backed_pending_and_accepted_facts_survive_reopen() {
    use licoup_conversation::continuity::{
        child_work_operation_id, list_unacked_child_work, read_child_work_accepted,
        read_child_work_intent, record_child_work_accepted, record_child_work_intent,
        record_child_work_started,
    };
    let root = std::env::temp_dir().join(format!(
        "lico-ca-pending-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let conversation_id;
    {
        let store = ConversationStore::open(&root).unwrap();
        let harness_conversation = store
            .create_conversation("reopen-pending", human())
            .unwrap();
        conversation_id = harness_conversation.id.clone();
        record_child_work_intent(
            &store,
            &conversation_id,
            "goal:reopen",
            1,
            &serde_json::json!({
                "kind": "child-work-intent",
                "goalId": "goal:reopen",
                "revision": 1,
                "admittedRevision": 1,
                "workGeneration": 1,
                "operationId": child_work_operation_id("goal:reopen", 1),
            }),
        )
        .unwrap();
        record_child_work_accepted(
            &store,
            &conversation_id,
            "goal:reopen",
            1,
            &serde_json::json!({
                "kind": "child-work-accepted",
                "goalId": "goal:reopen",
                "revision": 1,
                "admittedRevision": 1,
                "workGeneration": 1,
                "operationId": child_work_operation_id("goal:reopen", 1),
                "dispatchId": "turn:reopen",
                "childConversationId": "conversation:child",
                "membershipId": "membership:child",
                "parentConversationId": conversation_id,
            }),
        )
        .unwrap();
        assert_eq!(list_unacked_child_work(&store).unwrap().len(), 1);
    }
    let reopened = ConversationStore::open(&root).unwrap();
    assert_eq!(list_unacked_child_work(&reopened).unwrap().len(), 1);
    assert!(
        read_child_work_intent(&reopened, &conversation_id, "goal:reopen", 1)
            .unwrap()
            .is_some()
    );
    assert_eq!(
        read_child_work_accepted(&reopened, &conversation_id, "goal:reopen", 1)
            .unwrap()
            .unwrap()["dispatchId"],
        "turn:reopen"
    );
    record_child_work_started(&reopened, &conversation_id, "goal:reopen", 1).unwrap();
    assert!(list_unacked_child_work(&reopened).unwrap().is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

fn visible_text(store: &ConversationStore, conversation_id: &str, event_id: &str) -> String {
    store
        .event(conversation_id, event_id)
        .unwrap()
        .unwrap()
        .parts
        .iter()
        .filter(|part| part.kind == EventPartKind::Text)
        .map(|part| part.content.as_str())
        .collect()
}

fn metadata_joined(store: &ConversationStore, conversation_id: &str, event_id: &str) -> String {
    store
        .event(conversation_id, event_id)
        .unwrap()
        .unwrap()
        .parts
        .iter()
        .filter(|part| part.kind == EventPartKind::Metadata)
        .map(|part| part.content.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

fn assistant_envelope_json(harness: &Harness, reply: &str) -> String {
    serde_json::to_string(&ContinuityAssistantTurnResponse {
        reply_text: reply.to_owned(),
        interpretation_proposal: harness.proposal(
            "request:store-envelope",
            "goal:store",
            "matter:store",
            false,
        ),
    })
    .unwrap()
}

#[test]
fn admitted_envelope_buffers_chunks_and_publishes_reply_once() {
    let harness = Harness::new("visible reply");
    let member = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    let scope = harness
        .store
        .prepare_runtime_dispatch(
            "agent:local",
            "",
            "ordinary question",
            Some(&harness.conversation_id),
            Some(&member.id),
            None,
            None,
        )
        .unwrap();
    harness
        .store
        .admit_runtime_response_mode(&scope, TRUSTED_RESPONSE_MODE_ASSISTANT_TURN)
        .unwrap();
    let reply = "均值为 0，方差为 1。 He said \"use {\\\"ok\\\":true}\".";
    let envelope = assistant_envelope_json(&harness, reply);
    let mid = envelope.len() / 2;
    harness
        .store
        .append_runtime_frame(
            &scope,
            1,
            &serde_json::json!({
                "event": "agent.message.chunk",
                "payload": {"text": &envelope[..mid]},
            }),
        )
        .unwrap();
    assert!(
        visible_text(&harness.store, &harness.conversation_id, &scope.event_id).is_empty(),
        "admitted chunks must not publish envelope bytes as Text"
    );
    harness
        .store
        .append_runtime_frame(
            &scope,
            2,
            &serde_json::json!({
                "event": "agent.message.completed",
                "payload": {"text": envelope},
            }),
        )
        .unwrap();
    assert_eq!(
        visible_text(&harness.store, &harness.conversation_id, &scope.event_id),
        reply
    );
    let state = harness
        .store
        .finish_runtime_dispatch(
            &scope,
            &serde_json::json!({"output": envelope}),
            DispatchState::Completed,
            None,
        )
        .unwrap();
    assert_eq!(state, DispatchState::Completed);
    assert_eq!(
        visible_text(&harness.store, &harness.conversation_id, &scope.event_id),
        reply
    );
    let metadata = metadata_joined(&harness.store, &harness.conversation_id, &scope.event_id);
    assert!(metadata.contains("trustedResponseMode"));
    assert!(metadata.contains("speechAct"));
    assert!(
        !visible_text(&harness.store, &harness.conversation_id, &scope.event_id)
            .contains("speechAct")
    );
}

#[test]
fn unadmitted_chat_preserves_proposal_looking_json_and_trailing_prose() {
    let harness = Harness::new("unadmitted chat");
    let member = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    let scope = harness
        .store
        .prepare_runtime_dispatch(
            "agent:local",
            "",
            "ordinary question",
            Some(&harness.conversation_id),
            Some(&member.id),
            None,
            None,
        )
        .unwrap();
    let exact = r#"{"speechAct":"question","envelope":{"conversationId":"conversation:one"},"commitmentProposals":[]} trailing prose stays."#;
    harness
        .store
        .append_runtime_frame(
            &scope,
            1,
            &serde_json::json!({
                "event": "agent.message.chunk",
                "payload": {"text": exact},
            }),
        )
        .unwrap();
    let state = harness
        .store
        .finish_runtime_dispatch(
            &scope,
            &serde_json::json!({"output": exact}),
            DispatchState::Completed,
            None,
        )
        .unwrap();
    assert_eq!(state, DispatchState::Completed);
    assert_eq!(
        visible_text(&harness.store, &harness.conversation_id, &scope.event_id),
        exact
    );
}

#[test]
fn admitted_malformed_output_is_failed_not_completed_silence() {
    let harness = Harness::new("malformed envelope");
    let member = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    let scope = harness
        .store
        .prepare_runtime_dispatch(
            "agent:local",
            "",
            "ordinary question",
            Some(&harness.conversation_id),
            Some(&member.id),
            None,
            None,
        )
        .unwrap();
    harness
        .store
        .admit_runtime_response_mode(&scope, TRUSTED_RESPONSE_MODE_ASSISTANT_TURN)
        .unwrap();
    let private_only = serde_json::to_string(&harness.proposal(
        "request:private-only",
        "goal:private",
        "matter:private",
        false,
    ))
    .unwrap();
    let state = harness
        .store
        .finish_runtime_dispatch(
            &scope,
            &serde_json::json!({"output": private_only}),
            DispatchState::Completed,
            None,
        )
        .unwrap();
    assert_eq!(state, DispatchState::Failed);
    assert!(
        visible_text(&harness.store, &harness.conversation_id, &scope.event_id).is_empty(),
        "private-only output must not become a successful reply"
    );
    let event = harness
        .store
        .event(&harness.conversation_id, &scope.event_id)
        .unwrap()
        .unwrap();
    assert!(
        event.parts.iter().any(|part| {
            part.kind == EventPartKind::Diagnostic
                && part.content.contains(ASSISTANT_TURN_INVALID_ERROR)
        }),
        "malformed admitted output must persist a typed diagnostic"
    );
}

#[test]
fn pending_completion_notices_filter_before_limit_and_ack_is_idempotent() {
    let harness = Harness::new("pending-index");
    harness
        .store
        .commit(&harness.proposal(
            "request:authorized",
            "goal:authorized",
            "matter:authorized",
            true,
        ))
        .unwrap();
    harness
        .store
        .with_continuity_unit_of_work(|unit| {
            for index in 0..50 {
                unit.execute(
                    "INSERT INTO continuity_completion_transitions(
                       notification_id, goal_id, transition, consumed, created_at
                     ) VALUES (?1, ?2, '{}', 0, ?3)",
                    rusqlite::params![
                        format!("notice:foreign:{index}"),
                        format!("goal:foreign:{index}"),
                        index as i64
                    ],
                )?;
            }
            unit.request_commit();
            Ok(())
        })
        .unwrap();
    complete_goal(&harness, "goal:authorized", 1);

    let pending = list_pending_completion_notices(
        &harness.store,
        &harness.conversation_id,
        &harness.owner_membership_id,
    )
    .unwrap();
    assert_eq!(
        pending.len(),
        1,
        "qualified pending must be selected before LIMIT so 50 foreign rows cannot starve it"
    );
    assert_eq!(pending[0].notification_id, "notice:goal:authorized");
    assert_eq!(pending[0].goal_id, "goal:authorized");

    let agent = harness
        .store
        .add_member(&harness.conversation_id, agent(), MembershipAccess::Member)
        .unwrap();
    let denied =
        list_pending_completion_notices(&harness.store, &harness.conversation_id, &agent.id);
    assert_eq!(denied.unwrap_err().code, ContinuityFailureCode::ScopeDenied);

    let first = ack_completion_notices(
        &harness.store,
        &harness.conversation_id,
        &harness.owner_membership_id,
        &["notice:goal:authorized".into(), "notice:foreign:0".into()],
    )
    .unwrap();
    assert_eq!(first, vec!["notice:goal:authorized".to_string()]);
    let repeat = ack_completion_notices(
        &harness.store,
        &harness.conversation_id,
        &harness.owner_membership_id,
        &["notice:goal:authorized".into()],
    )
    .unwrap();
    assert_eq!(repeat, vec!["notice:goal:authorized".to_string()]);
    assert!(
        list_pending_completion_notices(
            &harness.store,
            &harness.conversation_id,
            &harness.owner_membership_id,
        )
        .unwrap()
        .is_empty()
    );
    let resolved = resolve_completion_notice(
        &harness.store,
        &harness.conversation_id,
        &harness.owner_membership_id,
        "notice:goal:authorized",
    )
    .unwrap();
    assert_eq!(resolved.parent_conversation_id, harness.conversation_id);
    assert_eq!(resolved.card_event_id.is_empty(), false);
}
