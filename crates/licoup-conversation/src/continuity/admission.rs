//! Deterministic admission for continuity writes.
//!
//! UTF-8 span checks use `str::is_char_boundary`, the same well-formedness
//! test used by rustc and encoding_rs. Spans are UTF-8 byte ranges, not
//! UTF-16 indexes or Python code-point indexes.

use super::generated::{
    CONTINUITY_MAX_PAGE_SIZE, ContinuityClosureAuthorityKind, ContinuityCommitBasis,
    ContinuityContextCompositionRequest, ContinuityDecisionLayer, ContinuityEffectClass,
    ContinuityEvidenceRef, ContinuityEvidenceResult, ContinuityFailure, ContinuityFailureCode,
    ContinuityFailureStage, ContinuityFollowThroughKind, ContinuityGoalCompletionTransition,
    ContinuityGoalContract, ContinuityGoalControl, ContinuityGoalLifecycle, ContinuityGoalProgress,
    ContinuityParentCardAnchor, ContinuityParentContextGrant, ContinuityParentGrantBasis,
    ContinuityParentGrantStatus, ContinuityRecoveryClass, ContinuitySourceOwnerKind,
    ContinuitySourceRef, ContinuitySourceValidity, ContinuitySpeechAct,
    ContinuityTaskChildAdmission, ContinuityTaskConversationRelation, ContinuityTaskListingKind,
    ContinuityUtf8ByteSpan, ContinuityVisibilityScope, ContinuityWriteEnvelope,
};
use serde_json::Value;

fn failure(code: ContinuityFailureCode, stage: ContinuityFailureStage) -> ContinuityFailure {
    let recovery = match code {
        ContinuityFailureCode::StaleRevision | ContinuityFailureCode::DesignationChanged => {
            ContinuityRecoveryClass::RecomputeProposal
        }
        ContinuityFailureCode::ReconciliationRequired | ContinuityFailureCode::PrematureClosure => {
            ContinuityRecoveryClass::ReconcileEffects
        }
        ContinuityFailureCode::ApprovalRequired => ContinuityRecoveryClass::ObtainApproval,
        ContinuityFailureCode::UnsupportedCapability
        | ContinuityFailureCode::SourceUnavailable
        | ContinuityFailureCode::WriterBusy => ContinuityRecoveryClass::ReviewOrWait,
        _ => ContinuityRecoveryClass::CorrectRequest,
    };
    ContinuityFailure {
        code,
        stage,
        recovery,
        effect_class: ContinuityEffectClass::None,
        decision_layer: ContinuityDecisionLayer::Admission,
        retryable: false,
    }
}

pub fn admit_utf8_span(
    text: &str,
    start_byte: u64,
    end_byte: u64,
) -> Result<(), ContinuityFailure> {
    let start = usize::try_from(start_byte).map_err(|_| {
        failure(
            ContinuityFailureCode::InvalidSpan,
            ContinuityFailureStage::ContinuityParse,
        )
    })?;
    let end = usize::try_from(end_byte).map_err(|_| {
        failure(
            ContinuityFailureCode::InvalidSpan,
            ContinuityFailureStage::ContinuityParse,
        )
    })?;
    if end < start
        || end > text.len()
        || !text.is_char_boundary(start)
        || !text.is_char_boundary(end)
    {
        return Err(failure(
            ContinuityFailureCode::InvalidSpan,
            ContinuityFailureStage::ContinuityParse,
        ));
    }
    Ok(())
}

pub fn admit_source_ref(
    authorized_scopes: &[ContinuityVisibilityScope],
    source: &ContinuitySourceRef,
) -> Result<(), ContinuityFailure> {
    if source.validity == ContinuitySourceValidity::Revoked {
        return Err(failure(
            ContinuityFailureCode::SourceRevoked,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if !authorized_scopes.contains(&source.visibility_scope) {
        return Err(failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

pub fn admit_versions(
    basis: &ContinuityCommitBasis,
    envelope: &ContinuityWriteEnvelope,
) -> Result<(), ContinuityFailure> {
    if envelope.conversation_id != basis.conversation_id {
        return Err(failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if envelope.observed_revision != basis.revision {
        return Err(failure(
            ContinuityFailureCode::StaleRevision,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if envelope.designation_epoch != basis.designation_epoch {
        return Err(failure(
            ContinuityFailureCode::DesignationChanged,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

fn request_id_value(value: &Value) -> Option<&Value> {
    value.get("requestId").or_else(|| {
        value
            .get("envelope")
            .and_then(|envelope| envelope.get("requestId"))
    })
}

fn comparable_idempotency_body(value: &Value) -> Value {
    let mut body = value.clone();
    if let Some(object) = body.as_object_mut() {
        object.remove("requestId");
        if let Some(envelope) = object
            .get_mut("envelope")
            .and_then(|envelope| envelope.as_object_mut())
        {
            envelope.remove("requestId");
            envelope.remove("observedRevision");
            envelope.remove("designationEpoch");
        }
    }
    body
}

/// Same `requestId` must carry the same business payload. Comparison uses JSON
/// value equality after removing the idempotency key and CAS cursor fields so
/// a retry after a committed revision bump is not a conflict.
pub fn admit_idempotency(previous: &Value, current: &Value) -> Result<(), ContinuityFailure> {
    match (request_id_value(previous), request_id_value(current)) {
        (None, None) => {}
        (Some(previous_key), Some(current_key)) if previous_key == current_key => {}
        (Some(_), Some(_)) => return Ok(()),
        _ => {
            return Err(failure(
                ContinuityFailureCode::InvalidRequest,
                ContinuityFailureStage::ContinuityParse,
            ));
        }
    }
    if comparable_idempotency_body(previous) != comparable_idempotency_body(current) {
        return Err(failure(
            ContinuityFailureCode::IdempotencyConflict,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

pub fn admit_goal_progress(progress: &ContinuityGoalProgress) -> Result<(), ContinuityFailure> {
    let terminal = matches!(
        progress.lifecycle,
        ContinuityGoalLifecycle::Achieved
            | ContinuityGoalLifecycle::Cancelled
            | ContinuityGoalLifecycle::Superseded
    );
    if terminal && progress.control != ContinuityGoalControl::Enabled {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if terminal && (progress.next_attention.is_some() || !progress.active_execution_refs.is_empty())
    {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    let needs_attention = !terminal
        && progress.control == ContinuityGoalControl::Enabled
        && progress.next_attention.is_none();
    if needs_attention {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

fn is_terminal(lifecycle: ContinuityGoalLifecycle) -> bool {
    matches!(
        lifecycle,
        ContinuityGoalLifecycle::Achieved
            | ContinuityGoalLifecycle::Cancelled
            | ContinuityGoalLifecycle::Superseded
    )
}

fn granted_span_covers(
    allowed: Option<&ContinuityUtf8ByteSpan>,
    requested: Option<&ContinuityUtf8ByteSpan>,
) -> bool {
    match (allowed, requested) {
        (None, _) => true,
        (Some(_), None) => false,
        (Some(allowed), Some(requested)) => {
            requested.end_byte >= requested.start_byte
                && requested.start_byte >= allowed.start_byte
                && requested.end_byte <= allowed.end_byte
        }
    }
}

/// Trusted grant refs decide identity and provenance. Requested validity
/// cannot upgrade or replace that basis.
fn granted_source_covers(allowed: &ContinuitySourceRef, requested: &ContinuitySourceRef) -> bool {
    allowed.validity != ContinuitySourceValidity::Revoked
        && allowed.owner_kind == requested.owner_kind
        && allowed.opaque_id == requested.opaque_id
        && allowed.part_id == requested.part_id
        && allowed.source_revision == requested.source_revision
        && allowed.digest == requested.digest
        && allowed.visibility_scope == requested.visibility_scope
        && granted_span_covers(allowed.span.as_ref(), requested.span.as_ref())
}

/// Simple chat and immediate work never force a Canonical child Conversation.
/// Only admitted durable follow-through with a delegation speech act may.
pub fn admit_task_child_admission(
    admission: &ContinuityTaskChildAdmission,
) -> Result<(), ContinuityFailure> {
    if admission.follow_through_kind != ContinuityFollowThroughKind::Durable
        || admission.speech_act != ContinuitySpeechAct::Delegation
    {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if let Some(anchor) = &admission.observed_card_anchor {
        admit_card_anchor(anchor)?;
        if anchor.parent_conversation_id != admission.parent_conversation_id {
            return Err(failure(
                ContinuityFailureCode::IdentityConflict,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        }
    }
    Ok(())
}

pub fn admit_card_anchor(anchor: &ContinuityParentCardAnchor) -> Result<(), ContinuityFailure> {
    if anchor.sequence < 0 || anchor.parent_conversation_id.is_empty() || anchor.event_id.is_empty()
    {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

/// Two long-running children in one parent keep distinct Event identities
/// and sequences. Completion must not swap or collide those anchors.
pub fn admit_sibling_card_order(
    left: &ContinuityParentCardAnchor,
    right: &ContinuityParentCardAnchor,
) -> Result<(), ContinuityFailure> {
    admit_card_anchor(left)?;
    admit_card_anchor(right)?;
    if left.parent_conversation_id != right.parent_conversation_id
        || left.event_id == right.event_id
        || left.sequence == right.sequence
    {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

pub fn admit_card_identity_stable(
    previous: &ContinuityParentCardAnchor,
    next: &ContinuityParentCardAnchor,
) -> Result<(), ContinuityFailure> {
    admit_card_anchor(previous)?;
    admit_card_anchor(next)?;
    if previous.parent_conversation_id != next.parent_conversation_id
        || previous.event_id != next.event_id
        || previous.sequence != next.sequence
        || previous.part_id != next.part_id
    {
        return Err(failure(
            ContinuityFailureCode::IdentityConflict,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

pub fn admit_task_relation(
    relation: &ContinuityTaskConversationRelation,
    previous: Option<&ContinuityTaskConversationRelation>,
) -> Result<(), ContinuityFailure> {
    if relation.follow_through_kind != ContinuityFollowThroughKind::Durable
        || relation.listing_kind != ContinuityTaskListingKind::ChildTask
        || relation.parent_conversation_id == relation.child_conversation_id
        || relation.card_anchor.parent_conversation_id != relation.parent_conversation_id
        || relation.created_event.owner_kind != ContinuitySourceOwnerKind::Event
        || relation.created_event.opaque_id != relation.card_anchor.event_id
        || relation.created_event.part_id != relation.card_anchor.part_id
    {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    admit_card_anchor(&relation.card_anchor)?;
    if let Some(transition) = &relation.completion_transition {
        if transition.goal_id != relation.goal_id
            || !is_terminal(transition.to_lifecycle)
            || is_terminal(transition.from_lifecycle)
        {
            return Err(failure(
                ContinuityFailureCode::InvalidRequest,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        }
    }
    if let Some(previous) = previous {
        if previous.goal_id != relation.goal_id
            || previous.parent_conversation_id != relation.parent_conversation_id
            || previous.child_conversation_id != relation.child_conversation_id
        {
            return Err(failure(
                ContinuityFailureCode::IdentityConflict,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        }
        admit_card_identity_stable(&previous.card_anchor, &relation.card_anchor)?;
    }
    Ok(())
}

/// Structural check that the intended transition and caller snapshot are
/// well-formed. A worker or PersistentTurn exit is not a closure authority.
/// Stored Goal identity, revision, lifecycle, and required current evidence are
/// admitted separately against the persisted record.
pub fn admit_completion_transition(
    transition: &ContinuityGoalCompletionTransition,
    progress: &ContinuityGoalProgress,
) -> Result<(), ContinuityFailure> {
    if !matches!(
        transition.authority_kind,
        ContinuityClosureAuthorityKind::GoalEvaluation
            | ContinuityClosureAuthorityKind::UserAcceptance
    ) || !is_terminal(transition.to_lifecycle)
        || is_terminal(transition.from_lifecycle)
        || transition.goal_id != progress.goal_id
    {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if progress.lifecycle != transition.to_lifecycle
        || progress.revision != transition.goal_revision
        || transition.evaluation_ref.validity == ContinuitySourceValidity::Revoked
    {
        return Err(failure(
            ContinuityFailureCode::PrematureClosure,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    admit_goal_progress(progress)?;
    Ok(())
}

pub(super) fn admit_completion_against_current(
    transition: &ContinuityGoalCompletionTransition,
    current: &ContinuityGoalProgress,
) -> Result<(), ContinuityFailure> {
    if transition.goal_id != current.goal_id {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if transition.goal_revision != current.revision {
        return Err(failure(
            ContinuityFailureCode::StaleRevision,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if transition.from_lifecycle != current.lifecycle {
        return Err(failure(
            ContinuityFailureCode::PrematureClosure,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

fn current_subject_version(progress: &ContinuityGoalProgress, criterion_id: &str) -> Option<i64> {
    progress
        .criterion_evidence_refs
        .iter()
        .filter(|item| item.criterion_id == criterion_id)
        .map(|item| item.subject_version)
        .max()
}

fn evidence_is_current_valid_pass(item: &ContinuityEvidenceRef) -> bool {
    item.validity == ContinuitySourceValidity::Current
        && item.source.validity == ContinuitySourceValidity::Current
        && item.result == ContinuityEvidenceResult::Pass
}

fn evaluation_refers_to_evidence(
    evaluation_ref: &ContinuitySourceRef,
    evidence: &ContinuityEvidenceRef,
) -> bool {
    evaluation_ref.opaque_id == evidence.source.opaque_id
        && evaluation_ref.source_revision == evidence.source.source_revision
        && match (&evaluation_ref.part_id, &evidence.source.part_id) {
            (Some(left), Some(right)) => left == right,
            _ => true,
        }
}

pub(super) fn current_required_evidence<'a>(
    contract: &'a ContinuityGoalContract,
    progress: &'a ContinuityGoalProgress,
) -> Vec<&'a ContinuityEvidenceRef> {
    contract
        .criteria
        .iter()
        .filter(|criterion| criterion.required)
        .flat_map(|criterion| {
            let version = current_subject_version(progress, &criterion.id);
            progress.criterion_evidence_refs.iter().filter(move |item| {
                item.criterion_id == criterion.id && Some(item.subject_version) == version
            })
        })
        .collect()
}

pub(super) fn admit_achieved_required_current_evidence(
    transition: &ContinuityGoalCompletionTransition,
    contract: &ContinuityGoalContract,
    current: &ContinuityGoalProgress,
) -> Result<(), ContinuityFailure> {
    if transition.to_lifecycle != ContinuityGoalLifecycle::Achieved {
        return Ok(());
    }
    if transition.evaluation_ref.validity != ContinuitySourceValidity::Current {
        return Err(failure(
            ContinuityFailureCode::PrematureClosure,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    for criterion in contract.criteria.iter().filter(|item| item.required) {
        let Some(version) = current_subject_version(current, &criterion.id) else {
            return Err(failure(
                ContinuityFailureCode::PrematureClosure,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        };
        let current_items: Vec<&ContinuityEvidenceRef> = current
            .criterion_evidence_refs
            .iter()
            .filter(|item| item.criterion_id == criterion.id && item.subject_version == version)
            .collect();
        if current_items.is_empty()
            || !current_items
                .iter()
                .all(|item| evidence_is_current_valid_pass(item))
        {
            return Err(failure(
                ContinuityFailureCode::PrematureClosure,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        }
    }
    admit_evaluation_ref_against_required_current(transition, contract, current)
}

fn admit_evaluation_ref_against_required_current(
    transition: &ContinuityGoalCompletionTransition,
    contract: &ContinuityGoalContract,
    current: &ContinuityGoalProgress,
) -> Result<(), ContinuityFailure> {
    let required: Vec<_> = contract
        .criteria
        .iter()
        .filter(|item| item.required)
        .collect();
    if required.is_empty() {
        return Ok(());
    }
    if transition.evaluation_ref.owner_kind == ContinuitySourceOwnerKind::Goal
        && transition.evaluation_ref.opaque_id == transition.goal_id
        && transition.evaluation_ref.source_revision == current.revision
    {
        return Ok(());
    }
    let matched: Vec<&ContinuityEvidenceRef> = current
        .criterion_evidence_refs
        .iter()
        .filter(|item| {
            required
                .iter()
                .any(|criterion| criterion.id == item.criterion_id)
                && evaluation_refers_to_evidence(&transition.evaluation_ref, item)
        })
        .collect();
    if matched.is_empty() {
        return Err(failure(
            ContinuityFailureCode::PrematureClosure,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if matched.iter().any(|item| {
        current_subject_version(current, &item.criterion_id) != Some(item.subject_version)
            || !evidence_is_current_valid_pass(item)
    }) {
        return Err(failure(
            ContinuityFailureCode::PrematureClosure,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

/// Parent Event/Part/span disclosure into a child requires an admitted grant
/// whose trusted recipient, membership and revocation generation match the
/// current store basis. Requested validity cannot widen that basis.
pub fn admit_parent_context_grant(
    grant: &ContinuityParentContextGrant,
    requested: &ContinuitySourceRef,
    basis: &ContinuityParentGrantBasis,
) -> Result<(), ContinuityFailure> {
    if grant.status != ContinuityParentGrantStatus::Admitted
        || grant.source_conversation_id == grant.recipient_conversation_id
        || grant.recipient_conversation_id != basis.recipient_conversation_id
        || grant.recipient_membership_id != basis.recipient_membership_id
    {
        return Err(failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if grant.revocation_generation != basis.revocation_generation {
        return Err(failure(
            ContinuityFailureCode::StaleRevision,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    let Some(allowed) = grant
        .source_refs
        .iter()
        .find(|candidate| granted_source_covers(candidate, requested))
    else {
        return Err(failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    };
    admit_source_ref(&grant.authorized_scopes, allowed)
}

pub fn admit_page_limit(limit: u64) -> Result<usize, ContinuityFailure> {
    if limit == 0 || limit > CONTINUITY_MAX_PAGE_SIZE as u64 {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    usize::try_from(limit).map_err(|_| {
        failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        )
    })
}

pub fn admit_composition_request(
    request: &ContinuityContextCompositionRequest,
) -> Result<(), ContinuityFailure> {
    if request.conversation_id.is_empty() || request.recipient_membership_id.is_empty() {
        return Err(failure(
            ContinuityFailureCode::InvalidRequest,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    admit_page_limit(request.limit)?;
    Ok(())
}
