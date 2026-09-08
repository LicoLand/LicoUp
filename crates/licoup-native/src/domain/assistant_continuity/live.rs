//! Populate the M1 composition workspace from live ConversationStore facts.

use licoup_conversation::continuity::{
    ContinuityReadPort, ContinuitySourceOwnerKind, ContinuitySourceRef, ContinuitySourceValidity,
    ContinuityVisibilityScope, PENDING_OBLIGATION_PAGE_SIZE, read_agreements,
};
use licoup_conversation::{ConversationStore, EventKind, EventPartKind, MembershipStatus};

use super::cognition::{ContextRecord, InformationClass};
use super::context::FrozenContextStore;

pub fn populate_live_store(
    store: &ConversationStore,
    conversation_id: &str,
    current_event_id: Option<&str>,
) -> FrozenContextStore {
    let live = FrozenContextStore::new();
    if let Ok(basis) = store.commit_basis(conversation_id) {
        live.set_commit_basis(basis);
    }
    if let Ok(matters) = store.list_matters(conversation_id, None, 50) {
        for matter in matters {
            live.insert_matter(matter);
        }
    }
    if let Ok(relations) = store.list_child_relations(conversation_id, None, 50) {
        for relation in relations {
            live.insert_relation(relation);
        }
    }
    if let Ok(conversation) = store.get(conversation_id) {
        for membership in conversation
            .memberships
            .iter()
            .filter(|membership| membership.status == MembershipStatus::Active)
        {
            let mut after: Option<String> = None;
            loop {
                let Ok(page) = store.list_parent_grants(
                    conversation_id,
                    &membership.id,
                    after.as_deref(),
                    PENDING_OBLIGATION_PAGE_SIZE as usize,
                ) else {
                    break;
                };
                let page_len = page.len();
                after = page.last().map(|grant| grant.grant_id.clone());
                for grant in page {
                    live.set_recipient_revocation(
                        conversation_id,
                        &membership.id,
                        grant.revocation_generation,
                    );
                    for source in &grant.source_refs {
                        let Ok(text) = store
                            .posted_event_text(&grant.source_conversation_id, &source.opaque_id)
                        else {
                            continue;
                        };
                        live.insert_record(ContextRecord {
                            conversation_id: grant.source_conversation_id.clone(),
                            matter_id: None,
                            class: InformationClass::ConversationFact,
                            source: source.clone(),
                            agreement: None,
                            membership_id: None,
                            recency: source.source_revision,
                            entities: Vec::new(),
                            text_bytes: text.len() as u64,
                            explicit_refs: Vec::new(),
                            conversation_level: true,
                            is_current_input: false,
                            is_malicious_data: false,
                            is_summary: false,
                            is_worker_or_turn_exit: false,
                            is_mcp_return: false,
                        });
                    }
                    live.insert_grant(grant);
                }
                if page_len < PENDING_OBLIGATION_PAGE_SIZE as usize {
                    break;
                }
            }
        }
    }
    if let Ok(agreements) = read_agreements(store, conversation_id) {
        for (index, agreement) in agreements.into_iter().enumerate() {
            live.insert_record(ContextRecord {
                conversation_id: conversation_id.to_owned(),
                matter_id: None,
                class: InformationClass::Agreement,
                source: agreement.statement_ref.clone(),
                agreement: Some(agreement),
                membership_id: None,
                recency: index as i64,
                entities: Vec::new(),
                text_bytes: 1,
                explicit_refs: Vec::new(),
                conversation_level: true,
                is_current_input: false,
                is_malicious_data: false,
                is_summary: false,
                is_worker_or_turn_exit: false,
                is_mcp_return: false,
            });
        }
    }
    if let Ok(page) = store.page_events(conversation_id, None, 50) {
        for event in page.events {
            if event.kind != EventKind::Message {
                continue;
            }
            let text = event
                .parts
                .iter()
                .filter(|part| part.kind == EventPartKind::Text)
                .map(|part| part.content.clone())
                .collect::<Vec<_>>()
                .join("\n");
            let source = ContinuitySourceRef {
                owner_kind: ContinuitySourceOwnerKind::Event,
                opaque_id: event.id.clone(),
                part_id: event.parts.first().map(|part| part.id.clone()),
                span: None,
                source_revision: event.sequence,
                digest: format!("event:{}", event.id),
                visibility_scope: ContinuityVisibilityScope::Conversation,
                validity: ContinuitySourceValidity::Current,
            };
            live.insert_record(ContextRecord {
                conversation_id: conversation_id.to_owned(),
                matter_id: None,
                class: InformationClass::ConversationFact,
                source,
                agreement: None,
                membership_id: event.author_membership_id.clone(),
                recency: event.sequence,
                entities: Vec::new(),
                text_bytes: text.len() as u64,
                explicit_refs: Vec::new(),
                conversation_level: true,
                is_current_input: current_event_id == Some(event.id.as_str()),
                is_malicious_data: false,
                is_summary: false,
                is_worker_or_turn_exit: false,
                is_mcp_return: false,
            });
        }
    }
    live
}

/// Marks one admitted task subject as the current input for the recipient
/// Conversation. The SourceRef identity is the subject; body text is still
/// grant-checked at compose time and is not copied here.
pub fn insert_task_subject(
    live: &FrozenContextStore,
    recipient_conversation_id: &str,
    source: &ContinuitySourceRef,
) {
    live.insert_record(ContextRecord {
        conversation_id: recipient_conversation_id.to_owned(),
        matter_id: None,
        class: InformationClass::ConversationFact,
        source: source.clone(),
        agreement: None,
        membership_id: None,
        recency: source.source_revision,
        entities: Vec::new(),
        text_bytes: 0,
        explicit_refs: Vec::new(),
        conversation_level: true,
        is_current_input: true,
        is_malicious_data: false,
        is_summary: false,
        is_worker_or_turn_exit: false,
        is_mcp_return: false,
    });
}
