//! Bounded orientation → scoped retrieval → refinement → dispatch recheck.
//!
//! Candidate ranking follows the same filter-then-score order used by
//! LlamaIndex exact-id lookup before similarity and by Elasticsearch
//! filter context before ranked query: exact SourceRef identity, then
//! granted parent refs, then current agreements, then entity overlap as
//! a clue only, then recency. Lexical clues never set speech act or Goal.

use std::sync::Arc;

use licoup_conversation::continuity::{
    CONTINUITY_MAX_ORIENTATION_ITEMS, CONTINUITY_MAX_REFS, ContextCompositionPort,
    ContinuityContextCompositionRequest, ContinuityContextManifest, ContinuityContextTransition,
    ContinuityFailure, ContinuityFailureCode, ContinuityFailureStage, ContinuityParentContextGrant,
    ContinuityParentGrantBasis, ContinuityParentGrantStatus, ContinuityReadPort,
    ContinuitySourceRef, ContinuitySourceValidity, PENDING_OBLIGATION_PAGE_SIZE,
    admit_composition_request, admit_parent_context_grant, admit_source_ref,
};

use super::super::cognition::{
    AssemblySnapshot, ContextRecord, InformationClass, continuity_failure, source_key,
};
use super::store::FrozenContextStore;
use super::workspace::{ContinuityWorkspace, invocation_id, replay_key};

pub struct UnavailableContextCompositionService {
    workspace: Arc<ContinuityWorkspace>,
}

impl UnavailableContextCompositionService {
    pub fn empty() -> Self {
        Self {
            workspace: ContinuityWorkspace::empty(),
        }
    }

    pub fn from_workspace(workspace: Arc<ContinuityWorkspace>) -> Self {
        Self { workspace }
    }

    pub fn refine_authorized(
        &self,
        request: &ContinuityContextCompositionRequest,
        prior: &licoup_conversation::continuity::ContinuityInterpretationProposal,
    ) -> Result<ContinuityContextManifest, ContinuityFailure> {
        admit_composition_request(request)?;
        let store = &self.workspace.store;
        let grants = listed_grants(store, request)?;
        let mut retrieved = Vec::new();
        let mut records = Vec::new();
        for wanted in &prior.requested_reads {
            scope_filter_before_read(store, request, wanted, &grants)?;
            let Some(record) = store
                .records()
                .into_iter()
                .find(|item| source_key(&item.source) == source_key(wanted))
            else {
                return Err(continuity_failure(
                    ContinuityFailureCode::SourceUnavailable,
                    ContinuityFailureStage::ContinuityAdmission,
                ));
            };
            recheck_record(request, &record, &grants)?;
            retrieved.push(wanted.clone());
            records.push(record);
        }
        let prior_id = invocation_id(
            request,
            prior
                .envelope
                .source_event_refs
                .first()
                .map(|source| source.opaque_id.as_str()),
            false,
        );
        let mut snapshot = self.workspace.merge_reads(&prior_id, retrieved, records)?;
        snapshot.invocation_id = invocation_id(
            request,
            snapshot
                .input_refs
                .first()
                .map(|source| source.opaque_id.as_str()),
            true,
        );
        self.workspace.remember_assembly(snapshot.clone());
        manifest_from(&snapshot, store, request)
    }

    pub fn recheck_dispatch(
        &self,
        manifest: &ContinuityContextManifest,
    ) -> Result<(), ContinuityFailure> {
        let snapshot = self.workspace.assembly_snapshot(&manifest.invocation_id)?;
        let store = &self.workspace.store;
        let current_generation = store.recipient_revocation(
            &snapshot.request.conversation_id,
            &snapshot.request.recipient_membership_id,
        );
        if current_generation != snapshot.request.revocation_generation
            || current_generation != manifest.revocation_generation
        {
            return Err(continuity_failure(
                ContinuityFailureCode::StaleRevision,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        }
        let grants = listed_grants(store, &snapshot.request)?;
        for source in &manifest.sources {
            let record = snapshot
                .records
                .iter()
                .find(|item| source_key(&item.source) == source_key(source))
                .ok_or_else(|| {
                    continuity_failure(
                        ContinuityFailureCode::SourceUnavailable,
                        ContinuityFailureStage::ContinuityAdmission,
                    )
                })?;
            recheck_record(&snapshot.request, record, &grants)?;
        }
        Ok(())
    }
}

impl ContextCompositionPort for UnavailableContextCompositionService {
    fn compose_authorized(
        &self,
        request: &ContinuityContextCompositionRequest,
    ) -> Result<ContinuityContextManifest, ContinuityFailure> {
        admit_composition_request(request)?;
        let store = &self.workspace.store;
        let basis = store.commit_basis(&request.conversation_id)?;
        let current_generation =
            store.recipient_revocation(&request.conversation_id, &request.recipient_membership_id);
        if request.revocation_generation != current_generation {
            return Err(continuity_failure(
                ContinuityFailureCode::StaleRevision,
                ContinuityFailureStage::ContinuityAdmission,
            ));
        }
        let grants = listed_grants(store, request)?;
        let all = store.records();
        let current_input = all
            .iter()
            .filter(|record| {
                record.conversation_id == request.conversation_id && record.is_current_input
            })
            .max_by_key(|record| record.recency);
        let attention = current_input
            .and_then(|record| record.matter_id.clone())
            .or_else(|| store.attention_matter(&request.conversation_id));

        let mut selected = Vec::new();
        let mut reasons = Vec::new();
        push_unique(
            &mut selected,
            &mut reasons,
            current_input.cloned(),
            "current-input",
        );

        // Exact references before fuzzy hints.
        if let Some(input) = current_input {
            for reference in &input.explicit_refs {
                match authorized_record(store, request, reference, &grants, &all) {
                    Ok(Some(record)) => {
                        push_unique(&mut selected, &mut reasons, Some(record), "exact-ref");
                    }
                    Ok(None) => {}
                    Err(err) if err.code == ContinuityFailureCode::ScopeDenied => {}
                    Err(err) => return Err(err),
                }
            }
        }

        for record in granted_parent_records(request, &grants, &all)? {
            push_unique(&mut selected, &mut reasons, Some(record), "parent-grant");
        }

        for record in all.iter().filter(|record| {
            record.class == InformationClass::Agreement
                && record_in_scope(request, record, &attention)
        }) {
            if latest_agreement(&all, record) {
                push_unique(
                    &mut selected,
                    &mut reasons,
                    Some(record.clone()),
                    "current-agreement",
                );
            }
        }

        for record in all.iter().filter(|record| {
            record.class == InformationClass::Responsibility
                && record_in_scope(request, record, &attention)
        }) {
            push_unique(
                &mut selected,
                &mut reasons,
                Some(record.clone()),
                "responsibility",
            );
        }

        let input_entities = current_input
            .map(|record| record.entities.as_slice())
            .unwrap_or(&[]);
        let mut lexical = all
            .iter()
            .filter(|record| {
                !record.is_current_input
                    && record_in_scope(request, record, &attention)
                    && !input_entities.is_empty()
                    && record
                        .entities
                        .iter()
                        .any(|entity| input_entities.contains(entity))
            })
            .cloned()
            .collect::<Vec<_>>();
        lexical.sort_by_key(|record| std::cmp::Reverse(record.recency));
        for record in lexical {
            if selected.len() >= CONTINUITY_MAX_ORIENTATION_ITEMS {
                break;
            }
            if record.class == InformationClass::Agreement && !latest_agreement(&all, &record) {
                continue;
            }
            push_unique(&mut selected, &mut reasons, Some(record), "lexical-hint");
        }

        let mut recent = all
            .iter()
            .filter(|record| {
                record.conversation_id == request.conversation_id
                    && record_in_scope(request, record, &attention)
                    && !record.is_current_input
            })
            .cloned()
            .collect::<Vec<_>>();
        recent.sort_by_key(|record| std::cmp::Reverse(record.recency));
        for record in recent {
            if selected.len() >= CONTINUITY_MAX_ORIENTATION_ITEMS {
                break;
            }
            if record.class == InformationClass::Agreement && !latest_agreement(&all, &record) {
                continue;
            }
            push_unique(&mut selected, &mut reasons, Some(record), "recency");
        }

        selected = apply_budget(selected, current_input);
        if selected.len() > CONTINUITY_MAX_REFS {
            selected.truncate(CONTINUITY_MAX_REFS);
        }
        for record in &selected {
            recheck_record(request, record, &grants)?;
        }

        let snapshot = AssemblySnapshot {
            invocation_id: invocation_id(
                request,
                current_input.map(|record| record.source.opaque_id.as_str()),
                false,
            ),
            conversation_id: request.conversation_id.clone(),
            request: request.clone(),
            records: selected.clone(),
            input_refs: current_input
                .map(|record| vec![record.source.clone()])
                .unwrap_or_default(),
            retrieved_reads: Vec::new(),
            replay_key: replay_key(
                request,
                current_input.map(|record| record.source.opaque_id.as_str()),
                current_input.map(|record| record.source.source_revision),
            ),
            observed_revision: basis.revision,
            designation_epoch: basis.designation_epoch,
        };
        self.workspace.remember_assembly(snapshot.clone());
        let mut manifest = manifest_from(&snapshot, store, request)?;
        manifest.selection_reason_codes = stable_reasons(&selected, &reasons);
        if store.prompt_cache_expired(&request.conversation_id)
            && manifest.context_transition == ContinuityContextTransition::Continue
        {
            manifest
                .selection_reason_codes
                .push("prompt-cache-expired".into());
        }
        Ok(manifest)
    }
}

fn listed_grants(
    store: &FrozenContextStore,
    request: &ContinuityContextCompositionRequest,
) -> Result<Vec<ContinuityParentContextGrant>, ContinuityFailure> {
    let mut grants = Vec::new();
    let mut after = request.after.clone();
    loop {
        let page = store.list_parent_grants(
            &request.conversation_id,
            &request.recipient_membership_id,
            after.as_deref(),
            PENDING_OBLIGATION_PAGE_SIZE as usize,
        )?;
        let page_len = page.len();
        after = page.last().map(|grant| grant.grant_id.clone());
        grants.extend(page);
        if page_len < PENDING_OBLIGATION_PAGE_SIZE as usize {
            return Ok(grants);
        }
    }
}

fn exact_grant_for_source<'a>(
    request: &ContinuityContextCompositionRequest,
    source_conversation_id: &str,
    requested: &ContinuitySourceRef,
    grants: &'a [ContinuityParentContextGrant],
) -> Option<&'a ContinuityParentContextGrant> {
    let basis = ContinuityParentGrantBasis {
        recipient_conversation_id: request.conversation_id.clone(),
        recipient_membership_id: request.recipient_membership_id.clone(),
        revocation_generation: request.revocation_generation,
    };
    grants.iter().find(|grant| {
        grant.source_conversation_id == source_conversation_id
            && admit_parent_context_grant(grant, requested, &basis).is_ok()
    })
}

fn authorized_record(
    store: &FrozenContextStore,
    request: &ContinuityContextCompositionRequest,
    reference: &ContinuitySourceRef,
    grants: &[licoup_conversation::continuity::ContinuityParentContextGrant],
    all: &[ContextRecord],
) -> Result<Option<ContextRecord>, ContinuityFailure> {
    scope_filter_before_read(store, request, reference, grants)?;
    if let Some(record) = all
        .iter()
        .find(|record| source_key(&record.source) == source_key(reference))
    {
        return Ok(Some(record.clone()));
    }
    Ok(all.iter().find_map(|record| {
        if record.source.opaque_id == reference.opaque_id
            && conversation_readable(request, record, grants)
        {
            let mut projected = record.clone();
            projected.source = reference.clone();
            Some(projected)
        } else {
            None
        }
    }))
}

fn scope_filter_before_read(
    store: &FrozenContextStore,
    request: &ContinuityContextCompositionRequest,
    reference: &ContinuitySourceRef,
    grants: &[licoup_conversation::continuity::ContinuityParentContextGrant],
) -> Result<(), ContinuityFailure> {
    let Some(record) = store.records().into_iter().find(|item| {
        source_key(&item.source) == source_key(reference)
            || item.source.opaque_id == reference.opaque_id
    }) else {
        return Err(continuity_failure(
            ContinuityFailureCode::SourceUnavailable,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    };
    if !conversation_readable(request, &record, grants) {
        return Err(continuity_failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if !request
        .authorized_scopes
        .contains(&record.source.visibility_scope)
        && record.conversation_id == request.conversation_id
    {
        return Err(continuity_failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

fn conversation_readable(
    request: &ContinuityContextCompositionRequest,
    record: &ContextRecord,
    grants: &[licoup_conversation::continuity::ContinuityParentContextGrant],
) -> bool {
    record.conversation_id == request.conversation_id
        || exact_grant_for_source(request, &record.conversation_id, &record.source, grants)
            .is_some()
}

fn granted_parent_records(
    request: &ContinuityContextCompositionRequest,
    grants: &[licoup_conversation::continuity::ContinuityParentContextGrant],
    all: &[ContextRecord],
) -> Result<Vec<ContextRecord>, ContinuityFailure> {
    let mut out = Vec::new();
    let basis = ContinuityParentGrantBasis {
        recipient_conversation_id: request.conversation_id.clone(),
        recipient_membership_id: request.recipient_membership_id.clone(),
        revocation_generation: request.revocation_generation,
    };
    for grant in grants {
        if grant.status != ContinuityParentGrantStatus::Admitted {
            continue;
        }
        for allowed in &grant.source_refs {
            match admit_parent_context_grant(grant, allowed, &basis) {
                Ok(()) => {}
                Err(err)
                    if matches!(
                        err.code,
                        ContinuityFailureCode::StaleRevision | ContinuityFailureCode::ScopeDenied
                    ) =>
                {
                    continue;
                }
                Err(err) => return Err(err),
            }
            if let Some(record) = all.iter().find(|item| {
                item.conversation_id == grant.source_conversation_id
                    && source_key(&item.source) == source_key(allowed)
            }) {
                out.push(record.clone());
            }
        }
    }
    Ok(out)
}

fn record_in_scope(
    request: &ContinuityContextCompositionRequest,
    record: &ContextRecord,
    attention: &Option<String>,
) -> bool {
    if record.conversation_id != request.conversation_id {
        return false;
    }
    if record.is_current_input {
        return true;
    }
    match (attention.as_deref(), record.matter_id.as_deref()) {
        (_, None) => record.conversation_level,
        (Some(matter), Some(record_matter)) => matter == record_matter,
        (None, Some(_)) => false,
    }
}

fn latest_agreement(all: &[ContextRecord], record: &ContextRecord) -> bool {
    let Some(agreement) = &record.agreement else {
        return false;
    };
    !all.iter().any(|other| {
        other.agreement.as_ref().is_some_and(|candidate| {
            candidate.id == agreement.id
                && candidate.effective_revision > agreement.effective_revision
        })
    })
}

fn recheck_record(
    request: &ContinuityContextCompositionRequest,
    record: &ContextRecord,
    grants: &[licoup_conversation::continuity::ContinuityParentContextGrant],
) -> Result<(), ContinuityFailure> {
    if record.source.validity == ContinuitySourceValidity::Revoked {
        return Err(continuity_failure(
            ContinuityFailureCode::SourceRevoked,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    if record.conversation_id == request.conversation_id {
        return admit_source_ref(&request.authorized_scopes, &record.source);
    }
    if exact_grant_for_source(request, &record.conversation_id, &record.source, grants).is_none() {
        return Err(continuity_failure(
            ContinuityFailureCode::ScopeDenied,
            ContinuityFailureStage::ContinuityAdmission,
        ));
    }
    Ok(())
}

fn apply_budget(
    selected: Vec<ContextRecord>,
    current_input: Option<&ContextRecord>,
) -> Vec<ContextRecord> {
    if selected.len() <= CONTINUITY_MAX_ORIENTATION_ITEMS {
        return order_stable_prefix(selected);
    }
    let mut kept = Vec::new();
    if let Some(input) = current_input {
        kept.push(input.clone());
    }
    for record in &selected {
        if record.class == InformationClass::Agreement
            || record.class == InformationClass::Responsibility
            || matches!(
                record.class,
                InformationClass::ConversationFact | InformationClass::CallbackFact
            ) && record.conversation_level
        {
            if !kept
                .iter()
                .any(|have| source_key(&have.source) == source_key(&record.source))
            {
                kept.push(record.clone());
            }
        }
    }
    for record in selected {
        if kept.len() >= CONTINUITY_MAX_ORIENTATION_ITEMS {
            break;
        }
        if record.class == InformationClass::WorkingNote {
            continue;
        }
        if !kept
            .iter()
            .any(|have| source_key(&have.source) == source_key(&record.source))
        {
            kept.push(record);
        }
    }
    order_stable_prefix(kept)
}

fn order_stable_prefix(mut selected: Vec<ContextRecord>) -> Vec<ContextRecord> {
    selected.sort_by_key(|record| class_rank(record));
    selected
}

fn class_rank(record: &ContextRecord) -> u8 {
    if record.is_current_input {
        return 0;
    }
    match record.class {
        InformationClass::Agreement => 1,
        InformationClass::Responsibility => 2,
        InformationClass::CallbackFact => 3,
        InformationClass::ConversationFact => 4,
        InformationClass::KnowledgeReference => 5,
        InformationClass::WorkingNote => 6,
    }
}

fn push_unique(
    selected: &mut Vec<ContextRecord>,
    reasons: &mut Vec<(String, String)>,
    record: Option<ContextRecord>,
    reason: &str,
) {
    let Some(record) = record else {
        return;
    };
    let key = source_key(&record.source);
    if selected.iter().any(|have| source_key(&have.source) == key) {
        return;
    }
    reasons.push((key, reason.into()));
    selected.push(record);
}

fn stable_reasons(selected: &[ContextRecord], reasons: &[(String, String)]) -> Vec<String> {
    let mut out = Vec::new();
    for record in selected {
        let key = source_key(&record.source);
        if let Some((_, reason)) = reasons.iter().find(|(item, _)| item == &key) {
            if !out.contains(reason) {
                out.push(reason.clone());
            }
        }
    }
    out
}

fn manifest_from(
    snapshot: &AssemblySnapshot,
    store: &FrozenContextStore,
    request: &ContinuityContextCompositionRequest,
) -> Result<ContinuityContextManifest, ContinuityFailure> {
    let attention = snapshot
        .records
        .iter()
        .find(|record| record.is_current_input)
        .and_then(|record| record.matter_id.clone())
        .or_else(|| store.attention_matter(&request.conversation_id));
    let previous = store.attention_matter(&request.conversation_id);
    let unrelated = match (attention.as_deref(), previous.as_deref()) {
        (Some(left), Some(right)) => left != right,
        _ => attention.is_some() && previous.is_some(),
    };
    let binding_usable = attention
        .as_deref()
        .map(|matter| store.binding_usable(&request.conversation_id, matter))
        .unwrap_or(true);
    let transition = if store.deliberate_fork(&request.conversation_id) {
        ContinuityContextTransition::Fork
    } else if unrelated {
        ContinuityContextTransition::New
    } else if !binding_usable {
        ContinuityContextTransition::Rehydrate
    } else {
        ContinuityContextTransition::Continue
    };
    let agreement_revisions = snapshot
        .records
        .iter()
        .filter_map(|record| {
            record
                .agreement
                .as_ref()
                .map(|agreement| agreement.effective_revision)
        })
        .collect();
    let token_estimate = snapshot
        .records
        .iter()
        .map(|record| record.text_bytes.div_ceil(4).max(1))
        .sum();
    Ok(ContinuityContextManifest {
        invocation_id: snapshot.invocation_id.clone(),
        sources: snapshot
            .records
            .iter()
            .map(|record| record.source.clone())
            .collect(),
        agreement_revisions,
        acl_generation: store.acl_generation(&request.conversation_id),
        revocation_generation: request.revocation_generation,
        recipient_binding: request.recipient_membership_id.clone(),
        token_estimate,
        selection_reason_codes: Vec::new(),
        context_transition: transition,
    })
}
