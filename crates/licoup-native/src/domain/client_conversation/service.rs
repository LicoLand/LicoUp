use super::{
    ConversationStore, DirectTurn, ImageAttachment, ImageAttachmentReference, MembershipAccess,
    MembershipStatus, NewEventPart, Principal, PrincipalKind, migrate_legacy_state,
};
use crate::platform::runtime_adapters::{
    MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE, MAX_IMAGE_ATTACHMENT_BYTES_TOTAL, MAX_IMAGE_ATTACHMENTS,
    attachment_media_type_supported,
};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::{
    fmt,
    path::Path,
    sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
};

type NativeTurnSender = dyn Fn(&Value) -> std::result::Result<Value, crate::platform::runtime_adapters::RuntimeAdapterError>
    + Send
    + Sync;
type ActiveTurnsLookup = dyn Fn(&str) -> Value + Send + Sync;
type TurnSteer = dyn Fn(&Value) -> std::result::Result<Value, crate::platform::runtime_adapters::RuntimeAdapterError>
    + Send
    + Sync;
type StrategyExecute = dyn Fn(Value) -> Result<Value> + Send + Sync;

/// Upper bound on direct turns dispatched to native runtimes in parallel.
/// Each worker is an independent runtime call; state leases are held only
/// around short local transactions, never across the runtime call itself.
pub const DEFAULT_DIRECT_TURN_WORKERS: usize = 4;

/// The persistent host runtime seams one dispatch can use. Every field is
/// absent on a default-constructed service, so dispatch-type work fails
/// closed with a typed transport rejection instead of running through a
/// one-shot lane no observer can attach.
#[derive(Clone, Default)]
struct HostRuntimePorts {
    native_turn_sender: Option<Arc<NativeTurnSender>>,
    active_turns: Option<Arc<ActiveTurnsLookup>>,
    steer_turn: Option<Arc<TurnSteer>>,
    strategy_execute: Option<Arc<StrategyExecute>>,
}

/// One application service for CLI, FFI, Conversation MCP, and Subagent MCP.
/// Transport adapters pass JSON envelopes here; domain validation remains in
/// `ConversationStore`. Strategy execution is a separate native authority.
#[derive(Clone)]
pub struct ConversationService {
    store: ConversationStore,
    host: HostRuntimePorts,
}

impl fmt::Debug for ConversationService {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConversationService")
            .field("store", &self.store)
            .finish_non_exhaustive()
    }
}

impl ConversationService {
    pub fn open(portable_root: &Path) -> Result<Self> {
        let store = ConversationStore::open(portable_root)?;
        // Startup admission is migration-first. A failed migration is returned
        // to the transport and never falls back to the retired JSON readers.
        migrate_legacy_state(&store, portable_root)?;
        store.ensure_default_local_group()?;
        Ok(Self {
            store,
            host: HostRuntimePorts::default(),
        })
    }

    pub fn from_store(store: ConversationStore) -> Self {
        Self {
            store,
            host: HostRuntimePorts::default(),
        }
    }

    /// Route native Agent work through a process-owned coordinator while
    /// keeping Conversation orchestration and persistence in this service.
    pub fn with_native_turn_sender(
        mut self,
        native_turn_sender: impl Fn(
            &Value,
        ) -> std::result::Result<
            Value,
            crate::platform::runtime_adapters::RuntimeAdapterError,
        > + Send
        + Sync
        + 'static,
    ) -> Self {
        self.host.native_turn_sender = Some(Arc::new(native_turn_sender));
        self
    }

    pub fn with_active_turns(
        mut self,
        active_turns: impl Fn(&str) -> Value + Send + Sync + 'static,
    ) -> Self {
        self.host.active_turns = Some(Arc::new(active_turns));
        self
    }

    pub fn with_steer_turn(
        mut self,
        steer_turn: impl Fn(
            &Value,
        ) -> std::result::Result<
            Value,
            crate::platform::runtime_adapters::RuntimeAdapterError,
        > + Send
        + Sync
        + 'static,
    ) -> Self {
        self.host.steer_turn = Some(Arc::new(steer_turn));
        self
    }

    pub fn with_strategy_execute(
        mut self,
        strategy_execute: impl Fn(Value) -> Result<Value> + Send + Sync + 'static,
    ) -> Self {
        self.host.strategy_execute = Some(Arc::new(strategy_execute));
        self
    }

    #[cfg(test)]
    fn from_store_with_runtime(
        store: ConversationStore,
        native_turn_sender: impl Fn(
            &Value,
        ) -> std::result::Result<
            Value,
            crate::platform::runtime_adapters::RuntimeAdapterError,
        > + Send
        + Sync
        + 'static,
    ) -> Self {
        Self::from_store(store).with_native_turn_sender(native_turn_sender)
    }

    pub fn store(&self) -> &ConversationStore {
        &self.store
    }

    pub fn execute(&self, request: Value) -> Result<Value> {
        let object = request
            .as_object()
            .ok_or_else(|| anyhow!("invalid_request"))?;
        let action = object
            .get("action")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("invalid_request"))?;
        ensure_allowed_fields(action, object)?;
        match action {
            "conversation.create" => {
                let title = required_string(object, "title")?;
                let owner = principal_from_value(
                    object
                        .get("owner")
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                let members = object
                    .get("members")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .map(|value| {
                                let member = value
                                    .as_object()
                                    .ok_or_else(|| anyhow!("invalid_request"))?;
                                ensure_member_fields(member)?;
                                let principal = principal_from_value(
                                    member
                                        .get("principal")
                                        .ok_or_else(|| anyhow!("invalid_request"))?,
                                )?;
                                let access = serde_json::from_value(
                                    member
                                        .get("access")
                                        .cloned()
                                        .unwrap_or_else(|| json!("member")),
                                )?;
                                Ok((principal, access))
                            })
                            .collect::<Result<Vec<_>>>()
                    })
                    .transpose()?
                    .unwrap_or_default();
                Ok(serde_json::to_value(
                    self.store
                        .create_conversation_with_members(title, owner, &members)?,
                )?)
            }
            "conversation.rename" => {
                self.store.rename_conversation(
                    required_string(object, "conversationId")?,
                    required_string(object, "title")?,
                )?;
                Ok(json!({"ok": true, "status": "accepted"}))
            }
            "conversation.archive" => {
                self.store.archive_conversation(
                    required_string(object, "conversationId")?,
                    object
                        .get("archived")
                        .and_then(Value::as_bool)
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                Ok(json!({"ok": true, "status": "accepted"}))
            }
            "conversation.pin.set" => {
                self.store.set_conversation_pinned(
                    required_string(object, "conversationId")?,
                    object
                        .get("pinned")
                        .and_then(Value::as_bool)
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                Ok(json!({"ok": true, "status": "accepted"}))
            }
            "conversation.strategy.set" => {
                let strategy_revision = match object.get("strategyRevision") {
                    Some(Value::Null) => None,
                    Some(Value::String(value)) if value.trim().is_empty() => None,
                    Some(Value::String(value)) => Some(value.as_str()),
                    _ => return Err(anyhow!("invalid_request")),
                };
                self.store.set_conversation_strategy_revision(
                    required_string(object, "conversationId")?,
                    strategy_revision,
                )?;
                Ok(json!({"ok": true}))
            }
            "conversation.assistant.set" => {
                let membership_id = match object.get("membershipId") {
                    Some(Value::Null) => None,
                    Some(Value::String(value)) if value.trim().is_empty() => None,
                    Some(Value::String(value)) => Some(value.as_str()),
                    _ => return Err(anyhow!("invalid_request")),
                };
                self.store.set_conversation_assistant(
                    required_string(object, "conversationId")?,
                    required_string(object, "ownerMembershipId")?,
                    required_revision(object, "expectedRevision")?,
                    membership_id,
                )?;
                Ok(json!({"ok": true}))
            }
            "conversation.profile.update" => {
                let intent: super::ProfileIntentUpdate = serde_json::from_value(
                    object
                        .get("intent")
                        .cloned()
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                let profile = self.store.set_membership_profile(
                    required_string(object, "conversationId")?,
                    required_string(object, "membershipId")?,
                    required_string(object, "ownerMembershipId")?,
                    required_revision(object, "expectedRevision")?,
                    &intent,
                )?;
                Ok(json!({"ok": true, "profile": serde_json::to_value(profile)?}))
            }
            "conversation.profile.get" => {
                let profile = self
                    .store
                    .membership_profile(required_string(object, "membershipId")?)?;
                Ok(serde_json::to_value(profile)?)
            }
            "conversation.profile.candidates" => {
                let conversation_id = required_string(object, "conversationId")?;
                let filters: super::CandidateFilters = serde_json::from_value(
                    object.get("filters").cloned().unwrap_or_else(|| json!({})),
                )?;
                let pairs = self.profile_projection_pairs(conversation_id)?;
                let authority = super::production_snapshot_authority();
                let snapshots =
                    super::project_profile_snapshots(conversation_id, &pairs, &authority);
                let candidates =
                    super::rank_candidates(snapshots, &filters).map_err(anyhow::Error::msg)?;
                Ok(json!({
                    "candidates": serde_json::to_value(&candidates)?,
                    "routeReceipt": route_receipt(conversation_id, &candidates),
                }))
            }
            "conversation.list" => Ok(serde_json::to_value(
                self.store.list(
                    object
                        .get("includeArchived")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                )?,
            )?),
            "conversation.get" => Ok(serde_json::to_value(
                self.store.get(required_string(object, "conversationId")?)?,
            )?),
            "conversation.events.page" => Ok(serde_json::to_value(self.store.page_events(
                required_string(object, "conversationId")?,
                object.get("afterSequence").and_then(Value::as_i64),
                object.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize,
            )?)?),
            "conversation.events.search" => Ok(serde_json::to_value(self.store.search(
                required_string(object, "query")?,
                object.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize,
            )?)?),
            "conversation.event.append" => {
                let parts = object
                    .get("parts")
                    .and_then(Value::as_array)
                    .ok_or_else(|| anyhow!("invalid_request"))?
                    .iter()
                    .map(|part| serde_json::from_value::<NewEventPart>(part.clone()))
                    .collect::<std::result::Result<Vec<_>, _>>()?;
                let event = self.store.append_event(
                    required_string(object, "conversationId")?,
                    object.get("authorMembershipId").and_then(Value::as_str),
                    serde_json::from_value(
                        object
                            .get("kind")
                            .cloned()
                            .ok_or_else(|| anyhow!("invalid_request"))?,
                    )?,
                    &parts,
                    object.get("causationId").and_then(Value::as_str),
                    object.get("correlationId").and_then(Value::as_str),
                    object
                        .get("finalized")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                )?;
                Ok(serde_json::to_value(event)?)
            }
            "conversation.message.post" => {
                let conversation_id = required_string(object, "conversationId")?;
                let author = object.get("authorMembershipId").and_then(Value::as_str);
                let attachments = admit_post_attachments(object.get("attachments"))?;
                // The text stays required unless admitted attachments carry the
                // post: an image-only group message posts empty content.
                let content = object
                    .get("content")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("invalid_request"))?;
                if content.trim().is_empty() && attachments.is_empty() {
                    return Err(anyhow!("invalid_request"));
                }
                self.persist_posted_message(
                    conversation_id,
                    author,
                    content,
                    object.get("correlationId").and_then(Value::as_str),
                    &attachments,
                )
            }
            "conversation.dispatch.after-post" => {
                let conversation_id = required_string(object, "conversationId")?;
                let event_id = required_string(object, "eventId")?;
                self.dispatch_posted_message(conversation_id, event_id)
            }
            "conversation.event.part.append" => {
                let part: NewEventPart = serde_json::from_value(
                    object
                        .get("part")
                        .cloned()
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                Ok(serde_json::to_value(self.store.append_event_part(
                    required_string(object, "eventId")?,
                    part,
                )?)?)
            }
            "conversation.event.finalize" => {
                self.store
                    .finalize_event(required_string(object, "eventId")?)?;
                Ok(json!({"ok": true}))
            }
            "conversation.membership.add" => {
                let principal = principal_from_value(
                    object
                        .get("principal")
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                let access: MembershipAccess = serde_json::from_value(
                    object
                        .get("access")
                        .cloned()
                        .unwrap_or_else(|| json!("member")),
                )?;
                Ok(serde_json::to_value(self.store.add_member(
                    required_string(object, "conversationId")?,
                    principal,
                    access,
                )?)?)
            }
            "conversation.membership.leave" => {
                self.store.leave_member(
                    required_string(object, "conversationId")?,
                    required_string(object, "membershipId")?,
                )?;
                Ok(json!({"ok": true}))
            }
            "conversation.membership.access.set" => {
                let access: MembershipAccess = serde_json::from_value(
                    object
                        .get("access")
                        .cloned()
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                Ok(serde_json::to_value(self.store.set_member_access(
                    required_string(object, "conversationId")?,
                    required_string(object, "membershipId")?,
                    access,
                )?)?)
            }
            "conversation.export" => {
                let ids = object
                    .get("conversationIds")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                self.store
                    .export_bundle(Path::new(required_string(object, "path")?), &ids)
            }
            "conversation.import" => self
                .store
                .import_bundle(Path::new(required_string(object, "path")?)),
            "conversation.subagent.edge" => {
                let edge = self.store.subagent_mesh_edge(
                    required_string(object, "conversationId")?,
                    required_string(object, "callerMembershipId")?,
                    required_string(object, "targetMembershipId")?,
                )?;
                Ok(json!({
                    "inbound": {
                        "delegate": edge.inbound_delegate,
                        "continue": edge.inbound_continue,
                        "cancel": edge.inbound_cancel,
                    },
                    "outcomes": {
                        "delegate": edge.delegate_outcome,
                        "continue": edge.continue_outcome,
                        "cancel": edge.cancel_outcome,
                    },
                    "claimState": edge.claim_state,
                    "dispatchState": edge.dispatch_state,
                }))
            }
            "conversation.subagent.target" => {
                let conversation_id = required_string(object, "conversationId")?;
                let membership_id = required_string(object, "membershipId")?;
                let conversation = self.store.get(conversation_id)?;
                let membership = conversation
                    .memberships
                    .iter()
                    .find(|membership| membership.id == membership_id)
                    .filter(|membership| membership.status == MembershipStatus::Active)
                    .filter(|membership| membership.principal.kind == PrincipalKind::Agent)
                    .ok_or_else(|| anyhow!("subagent_target_membership_inactive"))?;
                let provider_id = membership
                    .principal
                    .agent_id
                    .as_deref()
                    .ok_or_else(|| anyhow!("subagent_target_invalid"))?;
                let profile = self.store.membership_profile(membership_id)?;
                Ok(json!({
                    "providerId": provider_id,
                    "preferredModel": profile.as_ref().and_then(|profile| profile.preferred_model.as_deref()),
                    "preferredReasoningEffort": profile.as_ref().and_then(|profile| profile.preferred_reasoning_effort.as_deref()),
                }))
            }
            "conversation.subagent.claim" => {
                let claim = self.store.claim_subagent_dispatch(
                    required_string(object, "conversationId")?,
                    required_string(object, "callerMembershipId")?,
                    required_string(object, "targetMembershipId")?,
                    object.get("parentDispatchId").and_then(Value::as_str),
                )?;
                Ok(subagent_claim_json(&claim))
            }
            "conversation.subagent.claim.update" => {
                self.store.update_subagent_claim_state(
                    required_string(object, "dispatchId")?,
                    subagent_claim_state(required_string(object, "state")?)?,
                )?;
                Ok(json!({"ok": true}))
            }
            "conversation.subagent.claim.active" => Ok(self
                .store
                .active_subagent_claim(
                    required_string(object, "conversationId")?,
                    required_string(object, "callerMembershipId")?,
                    required_string(object, "targetMembershipId")?,
                )?
                .as_ref()
                .map(subagent_claim_json)
                .unwrap_or(Value::Null)),
            "conversation.subagent.inbound.record" => {
                self.store.record_subagent_mcp_inbound(
                    required_string(object, "conversationId")?,
                    object.get("callerMembershipId").and_then(Value::as_str),
                    object.get("targetMembershipId").and_then(Value::as_str),
                    required_string(object, "tool")?,
                    required_string(object, "outcome")?,
                )?;
                Ok(json!({"ok": true}))
            }
            "conversation.subagent.binding.get" => {
                let binding = self.store.private_runtime_binding(
                    required_string(object, "conversationId")?,
                    required_string(object, "membershipId")?,
                )?;
                Ok(binding.map_or(Value::Null, |binding| {
                    json!({
                        "runtimeSessionId": binding.runtime_session_id,
                        "runtimeConversationPath": binding.runtime_conversation_path,
                        "workingDirectory": binding.working_directory,
                    })
                }))
            }
            _ => Err(anyhow!("unsupported_action")),
        }
    }

    fn persist_posted_message(
        &self,
        conversation_id: &str,
        author: Option<&str>,
        content: &str,
        correlation_id: Option<&str>,
        attachments: &[ImageAttachment],
    ) -> Result<Value> {
        let (event, _) = self.store.post_message_with_attachments(
            conversation_id,
            author,
            content,
            correlation_id,
            &[],
            attachments,
        )?;
        Ok(json!({
            "event": {"id": event.id, "state": "finalized"},
            "directTurns": [],
            "turns": [],
            "dispatchPending": false,
        }))
    }

    /// Active Agent Memberships of one Conversation paired with their
    /// persistent Profile intents and the Assistant flag for projection.
    fn profile_projection_pairs(
        &self,
        conversation_id: &str,
    ) -> Result<Vec<(super::Membership, super::ProfileIntent, bool)>> {
        let conversation = self.store.get(conversation_id)?;
        let profiles = self.store.membership_profiles(conversation_id)?;
        Ok(profiles
            .into_iter()
            .map(|(membership, intent)| {
                let is_assistant =
                    conversation.assistant_membership_id.as_deref() == Some(membership.id.as_str());
                (membership, intent, is_assistant)
            })
            .collect())
    }

    /// The single dispatch door. Addressing runs natively from the stored
    /// Event text, registration happens before this response, a non-empty
    /// turn list means an attachable turn, and the error field is reserved
    /// for a start, resume, or dispatch call that actually failed.
    fn dispatch_posted_message(&self, conversation_id: &str, event_id: &str) -> Result<Value> {
        let Some(sender) = self.host.native_turn_sender.as_ref() else {
            return Err(anyhow!(super::PERSISTENT_TRANSPORT_REQUIRED));
        };
        let content = self.store.posted_event_text(conversation_id, event_id)?;
        let mention_ids = self.resolve_mentions(conversation_id, &content)?;
        let active = self.active_turns_for(conversation_id);
        let assistant_ids = if mention_ids.is_empty() {
            let conversation = self.store.get(conversation_id)?;
            conversation
                .assistant_membership_id
                .as_deref()
                .filter(|membership_id| {
                    conversation.memberships.iter().any(|membership| {
                        membership.id == **membership_id
                            && membership.status == MembershipStatus::Active
                            && membership.principal.kind == PrincipalKind::Agent
                    })
                })
                .map(|membership_id| vec![membership_id.to_owned()])
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let mut addressed = mention_ids.clone();
        for assistant_id in &assistant_ids {
            if !addressed.contains(assistant_id) {
                addressed.push(assistant_id.clone());
            }
        }
        let start_ids = addressed
            .iter()
            .filter(|membership_id| {
                !active
                    .iter()
                    .any(|turn| turn.membership_id == **membership_id)
            })
            .cloned()
            .collect::<Vec<_>>();
        let pending_turns = if start_ids.is_empty() {
            Vec::new()
        } else {
            self.store
                .enqueue_mention_turns(conversation_id, event_id, &start_ids)?
        };
        let mut live_turns = Vec::new();
        let mut direct_receipts = Vec::new();
        let mut boundary_queue_ids = Vec::new();
        let mut dispatch_error = None;
        if !addressed.is_empty() {
            for membership_id in &addressed {
                if let Some(turn) = active
                    .iter()
                    .find(|candidate| candidate.membership_id == *membership_id)
                {
                    match self.steer_active_turn(turn, &content) {
                        SteerDisposition::Accepted => {}
                        SteerDisposition::QueueAtBoundary => {
                            boundary_queue_ids.push(turn.membership_id.clone());
                        }
                        SteerDisposition::Unknown => {
                            dispatch_error.get_or_insert_with(dispatch_steer_error);
                        }
                    }
                    merge_live_turn(&mut live_turns, turn.to_json());
                }
            }
            let dispatched = self.execute_direct_turns(sender, pending_turns)?;
            for outcome in dispatched {
                direct_receipts.push(json!({
                    "id": outcome.turn.id,
                    "state": outcome.turn.state,
                }));
                if let Some(live) = outcome.live {
                    merge_live_turn(&mut live_turns, live);
                }
            }
            for turn in self.active_turns_for(conversation_id) {
                merge_live_turn(&mut live_turns, turn.to_json());
            }
        } else if active.len() == 1 {
            for turn in &active {
                match self.steer_active_turn(turn, &content) {
                    SteerDisposition::Accepted => {}
                    SteerDisposition::QueueAtBoundary => {
                        boundary_queue_ids.push(turn.membership_id.clone());
                    }
                    SteerDisposition::Unknown => {
                        dispatch_error.get_or_insert_with(dispatch_steer_error);
                    }
                }
                merge_live_turn(&mut live_turns, turn.to_json());
            }
        } else if !active.is_empty() {
            for turn in &active {
                merge_live_turn(&mut live_turns, turn.to_json());
            }
            dispatch_error = Some(json!({
                "code": "conversation_address_ambiguous",
                "stage": "conversation/address",
            }));
        }
        let strategy_address = if addressed.is_empty() && active.is_empty() {
            self.address_strategy(conversation_id, &content, event_id)?
        } else {
            StrategyAddress::default()
        };
        if let Some(entry_turn) = strategy_address.entry_turn {
            merge_live_turn(&mut live_turns, entry_turn);
        }
        if !boundary_queue_ids.is_empty() {
            for turn in
                self.store
                    .enqueue_mention_turns(conversation_id, event_id, &boundary_queue_ids)?
            {
                direct_receipts.push(json!({"id": turn.id, "state": turn.state}));
            }
        }
        if dispatch_error.is_none() {
            dispatch_error = strategy_address.error;
        }
        if dispatch_error.is_none()
            && direct_receipts
                .iter()
                .any(|receipt| receipt.get("state").and_then(Value::as_str) == Some("failed"))
        {
            dispatch_error = Some(json!({
                "code": "conversation_dispatch_failed",
                "stage": "conversation/dispatch",
            }));
        }
        let dispatch_pending = !live_turns.is_empty();
        let mut payload = json!({
            "event": {"id": event_id, "state": "finalized"},
            "directTurns": direct_receipts,
            "turns": live_turns,
            "dispatchPending": dispatch_pending,
        });
        if let Some(error) = dispatch_error {
            payload["strategyError"] = error;
        }
        Ok(payload)
    }

    /// Resolve mentioned Agent Memberships from the stored Event text. Each
    /// active Agent Membership is addressed by its display name and its Agent
    /// identifier; an alias matches when it follows a start or whitespace
    /// after the mention marker and is followed by whitespace, a sentence
    /// terminator, or the end of the text. Matching is case-insensitive.
    fn resolve_mentions(&self, conversation_id: &str, text: &str) -> Result<Vec<String>> {
        let conversation = self.store.get(conversation_id)?;
        let mut mentioned = Vec::new();
        for membership in &conversation.memberships {
            if membership.status != MembershipStatus::Active
                || membership.principal.kind != PrincipalKind::Agent
            {
                continue;
            }
            let display_name = membership.principal.display_name.trim();
            let agent_id = membership
                .principal
                .agent_id
                .as_deref()
                .map(str::trim)
                .unwrap_or_default();
            let matched = [display_name, agent_id]
                .into_iter()
                .filter(|alias| !alias.is_empty())
                .any(|alias| mention_alias_matches(text, alias));
            if matched {
                mentioned.push(membership.id.clone());
            }
        }
        Ok(mentioned)
    }

    fn active_turns_for(&self, conversation_id: &str) -> Vec<ActiveTurnRef> {
        let Some(active_turns) = self.host.active_turns.as_ref() else {
            return Vec::new();
        };
        active_turns(conversation_id)
            .get("turns")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|turn| {
                let handle = turn.get("turnHandle").and_then(Value::as_str)?;
                if handle.trim().is_empty() {
                    return None;
                }
                Some(ActiveTurnRef {
                    turn_handle: handle.to_owned(),
                    conversation_id: turn
                        .get("conversationId")
                        .and_then(Value::as_str)
                        .unwrap_or(conversation_id)
                        .to_owned(),
                    membership_id: turn
                        .get("membershipId")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                    agent: turn
                        .get("agent")
                        .or_else(|| turn.get("agentId"))
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_owned(),
                })
            })
            .collect()
    }

    fn steer_active_turn(&self, turn: &ActiveTurnRef, text: &str) -> SteerDisposition {
        let Some(steer_turn) = self.host.steer_turn.as_ref() else {
            return SteerDisposition::Unknown;
        };
        let Ok(receipt) = steer_turn(&json!({
            "turnHandle": turn.turn_handle,
            "conversationId": turn.conversation_id,
            "text": text,
            "agent": turn.agent,
        })) else {
            return SteerDisposition::Unknown;
        };
        match (
            receipt.get("ok").and_then(Value::as_bool),
            receipt.get("status").and_then(Value::as_str),
        ) {
            (Some(true), Some("accepted")) => SteerDisposition::Accepted,
            (Some(false), Some("unsupported" | "no_active_turn" | "session_unavailable")) => {
                SteerDisposition::QueueAtBoundary
            }
            _ => SteerDisposition::Unknown,
        }
    }

    fn address_strategy(
        &self,
        conversation_id: &str,
        content: &str,
        event_id: &str,
    ) -> Result<StrategyAddress> {
        let conversation = self.store.get(conversation_id)?;
        let Some(revision) = conversation
            .strategy_revision
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            return Ok(StrategyAddress::default());
        };
        let Some(execute) = self.host.strategy_execute.as_ref() else {
            return Err(anyhow!(super::PERSISTENT_TRANSPORT_REQUIRED));
        };
        let active = match execute(json!({
            "action": "strategy.run.active",
            "revisionDigest": revision,
            "conversationId": conversation_id,
        })) {
            Ok(value) => match unwrap_strategy_execute(value) {
                Ok(value) => value,
                Err(error) => {
                    return Ok(StrategyAddress {
                        entry_turn: None,
                        error: Some(error),
                    });
                }
            },
            Err(_) => {
                return Ok(StrategyAddress {
                    entry_turn: None,
                    error: Some(
                        json!({"code": "strategy_run_start_failed", "stage": "strategy/start"}),
                    ),
                });
            }
        };
        let run_id = active
            .get("runId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let status = active
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let terminal = matches!(
            status,
            "completed"
                | "failed"
                | "cancelled"
                | "blocked"
                | "cancel-requested"
                | "cancel-in-doubt"
        );
        let request = if run_id.is_empty() || terminal {
            json!({
                "action": "strategy.run.start",
                "revisionDigest": revision,
                "input": {"message": content},
                "idempotencyKey": format!("conversation-post-{event_id}"),
                "conversationId": conversation_id,
            })
        } else {
            json!({
                "action": "strategy.run.resume",
                "runId": run_id,
                "conversationId": conversation_id,
            })
        };
        match execute(request) {
            Ok(value) => match unwrap_strategy_execute(value) {
                Ok(result) => Ok(StrategyAddress {
                    entry_turn: entry_turn_projection(&result, conversation_id),
                    error: None,
                }),
                Err(error) => Ok(StrategyAddress {
                    entry_turn: None,
                    error: Some(error),
                }),
            },
            Err(_) => Ok(StrategyAddress {
                entry_turn: None,
                error: Some(
                    json!({"code": "strategy_run_start_failed", "stage": "strategy/start"}),
                ),
            }),
        }
    }

    fn execute_direct_turns(
        &self,
        sender: &Arc<NativeTurnSender>,
        pending_turns: Vec<DirectTurn>,
    ) -> Result<Vec<DirectTurnOutcome>> {
        if pending_turns.is_empty() {
            return Ok(Vec::new());
        }
        // Phase one claims every turn and marks it running. Each step is one
        // short local lease; no lease is held across the runtime dispatch.
        let mut claimed = Vec::with_capacity(pending_turns.len());
        let mut phase_one_error = None;
        for pending in pending_turns {
            match self.prepare_direct_turn(&pending.id) {
                Ok(claimed_turn) => claimed.push(claimed_turn),
                Err(error) => {
                    phase_one_error = Some(error);
                    break;
                }
            }
        }
        // Phase two dispatches the claimed turns with a bounded worker set.
        // Results are collected by input ordinal, so receipts keep the
        // original order regardless of completion timing.
        let results = self.dispatch_direct_turns(sender, &claimed);
        if let Some(error) = phase_one_error {
            return Err(error);
        }
        results.into_iter().collect()
    }

    /// Claim one pending turn and move it to running, or report its current
    /// state without a context when a concurrent claimant already owns it.
    fn prepare_direct_turn(&self, turn_id: &str) -> Result<ClaimedTurn> {
        let Some(context) = self.store.claim_direct_turn(turn_id)? else {
            return Ok(ClaimedTurn {
                turn_id: turn_id.to_owned(),
                context: None,
            });
        };
        if !self.store.mark_direct_turn_running(&context.turn.id)? {
            return Ok(ClaimedTurn {
                turn_id: turn_id.to_owned(),
                context: None,
            });
        }
        Ok(ClaimedTurn {
            turn_id: turn_id.to_owned(),
            context: Some(context),
        })
    }

    fn dispatch_direct_turns(
        &self,
        sender: &Arc<NativeTurnSender>,
        claimed: &[ClaimedTurn],
    ) -> Vec<Result<DirectTurnOutcome>> {
        let results: Mutex<Vec<Option<Result<DirectTurnOutcome>>>> =
            Mutex::new((0..claimed.len()).map(|_| None).collect());
        let next = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..DEFAULT_DIRECT_TURN_WORKERS.min(claimed.len()) {
                let service = self.clone();
                let sender = Arc::clone(sender);
                let results = &results;
                let next = &next;
                scope.spawn(move || {
                    loop {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        if index >= claimed.len() {
                            break;
                        }
                        let result = service.run_direct_turn(&sender, &claimed[index]);
                        results.lock().unwrap_or_else(|poison| poison.into_inner())[index] =
                            Some(result);
                    }
                });
            }
        });
        results
            .into_inner()
            .unwrap_or_else(|poison| poison.into_inner())
            .into_iter()
            .map(|result| result.expect("worker filled every slot"))
            .collect()
    }

    fn run_direct_turn(
        &self,
        sender: &Arc<NativeTurnSender>,
        claimed: &ClaimedTurn,
    ) -> Result<DirectTurnOutcome> {
        let Some(context) = claimed.context.as_ref() else {
            return Ok(DirectTurnOutcome {
                turn: self.store.direct_turn(&claimed.turn_id)?,
                live: None,
            });
        };
        // User-authored Event text stays exact. Generated guidance follows the
        // adapter's declared ephemeral policy and never enters Event/Part.
        let delivery = crate::platform::runtime_adapters::compose_generated_instruction_delivery(
            &context.agent_id,
            &context.source_content,
            context.private_instructions(),
        )
        .map_err(anyhow::Error::msg)?;
        let mut params = json!({
            "agentId": context.agent_id,
            "agent": context.agent_id,
            "text": delivery.text,
            "streamEvents": true,
            "conversationId": context.turn.conversation_id,
            "membershipId": context.turn.membership_id,
            "causationId": context.turn.source_event_id,
            "dispatchId": context.turn.id,
        });
        if let (Some(field), Some(guidance)) = (delivery.field, delivery.guidance) {
            params[field] = json!(guidance);
        }
        if !context.source_attachments.is_empty() {
            params["attachments"] = dispatch_attachments_param(&context.source_attachments);
        }
        if let Some(session_id) = context.runtime_session_id.as_deref() {
            params["sessionId"] = json!(session_id);
        }
        if let Some(source_path) = context.runtime_conversation_path.as_deref() {
            params["sourcePath"] = json!(source_path);
        }
        if let Some(working_directory) = context.working_directory.as_deref() {
            params["workingDirectory"] = json!(working_directory);
        }
        if let Some(model) = context.preferred_model.as_deref() {
            params["model"] = json!(model);
        }
        if let Some(reasoning_effort) = context.preferred_reasoning_effort.as_deref() {
            params["reasoningEffort"] = json!(reasoning_effort);
        }
        #[cfg(test)]
        self.store.counters().begin_turn();
        let dispatched = sender(&params);
        #[cfg(test)]
        self.store.counters().end_turn();
        let mut live = None;
        match dispatched {
            Ok(value) => {
                // An accepted receipt carries the attachable handle. Once the
                // dispatch is open, the dispatch completion authority alone
                // writes its terminal Event, dispatch state, and turn state.
                live = live_turn_from_accepted(&value, context);
            }
            Err(error) => {
                // Pre-dispatch rejection: settle the turn only when its
                // dispatch was never opened. An opened dispatch already
                // belongs to the completion authority.
                let projected = serde_json::to_value(error.client_error())?;
                let diagnostic = serde_json::to_string(&json!({
                    "code": safe_failure_field(
                        &projected,
                        "code",
                        "agent_conversation_dispatch_failed",
                    ),
                    "stage": safe_failure_field(&projected, "stage", "conversation/dispatch"),
                }))?;
                self.store
                    .fail_direct_turn_unless_dispatched(&claimed.turn_id, &diagnostic)?;
            }
        }
        Ok(DirectTurnOutcome {
            turn: self.store.direct_turn(&claimed.turn_id)?,
            live,
        })
    }
}

struct DirectTurnOutcome {
    turn: DirectTurn,
    live: Option<Value>,
}

/// A turn claimed for this fan-out: either with private execution context, or
/// without context when a concurrent claimant already owns it (its terminal
/// state is read back from the store).
struct ClaimedTurn {
    turn_id: String,
    context: Option<crate::domain::client_conversation::store::DirectTurnExecutionContext>,
}

#[derive(Default)]
struct StrategyAddress {
    entry_turn: Option<Value>,
    error: Option<Value>,
}

struct ActiveTurnRef {
    turn_handle: String,
    conversation_id: String,
    membership_id: String,
    agent: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SteerDisposition {
    Accepted,
    QueueAtBoundary,
    Unknown,
}

fn dispatch_steer_error() -> Value {
    json!({
        "code": "conversation_dispatch_failed",
        "stage": "conversation/steer",
    })
}

impl ActiveTurnRef {
    fn to_json(&self) -> Value {
        json!({
            "turnHandle": self.turn_handle,
            "conversationId": self.conversation_id,
            "membershipId": self.membership_id,
            "agent": self.agent,
        })
    }
}

fn unwrap_strategy_execute(value: Value) -> std::result::Result<Value, Value> {
    if value.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(value.get("result").cloned().unwrap_or_else(|| json!({})));
    }
    let error = value
        .get("error")
        .cloned()
        .unwrap_or_else(|| json!({"code": "strategy_run_start_failed"}));
    let code = error
        .get("code")
        .and_then(Value::as_str)
        .filter(|code| !code.is_empty())
        .unwrap_or("strategy_run_start_failed");
    Err(json!({"code": code, "stage": "strategy/start"}))
}

/// Privacy-safe immutable decision evidence. It freezes the exact allowlisted
/// facts and source revisions used for ranking; it is not a mutable catalog.
pub(crate) fn route_receipt(
    conversation_id: &str,
    snapshots: &[super::MembershipProfileSnapshot],
) -> Value {
    json!({
        "conversationId": conversation_id,
        "sourceRevisions": [
            {"source": "targets", "revision": "read-only-v1"},
            {"source": "nativeCapabilities", "revision": "v0.0.1"},
            {"source": "providerModelPricing", "revision": "catalog-v1"},
            {"source": "agentIntelligenceCatalog", "revision": "catalog-v1"},
            {"source": "skillHub", "revision": "request-snapshot-v1"},
            {"source": "assistantWorkflowAuthoringBundle", "revision": "v1"},
        ],
        "rankedMembershipIds": snapshots
            .iter()
            .map(|snapshot| snapshot.membership_id.clone())
            .collect::<Vec<_>>(),
        "candidates": snapshots.iter().map(|snapshot| json!({
            "membershipId": snapshot.membership_id,
            "profileRevision": snapshot.intent_revision,
            "responsibility": snapshot.responsibility,
            "model": snapshot.model,
            "capabilities": snapshot.capabilities,
            "skills": snapshot.skills,
            "environment": snapshot.environment,
            "readiness": snapshot.readiness,
            "inputPriceUsdPerMillionTokens": snapshot.price_input_usd_per_million_tokens,
            "outputPriceUsdPerMillionTokens": snapshot.price_output_usd_per_million_tokens,
            "codingScore": snapshot.intelligence_score,
            "reliabilityClass": snapshot.reliability_class,
            "latencyClass": snapshot.latency_class,
            "authority": snapshot.authority,
        })).collect::<Vec<_>>(),
    })
}

fn merge_live_turn(live_turns: &mut Vec<Value>, turn: Value) {
    let Some(handle) = turn
        .get("turnHandle")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|handle| !handle.is_empty())
    else {
        return;
    };
    if live_turns
        .iter()
        .any(|existing| existing.get("turnHandle").and_then(Value::as_str) == Some(handle))
    {
        return;
    }
    live_turns.push(turn);
}

/// The attachable entry handle from a strategy run start/resume response, in
/// the same shape as a live turn entry.
fn entry_turn_projection(result: &Value, conversation_id: &str) -> Option<Value> {
    let entry = result.get("entryTurn")?;
    let handle = entry
        .get("turnHandle")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|handle| !handle.is_empty())?;
    Some(json!({
        "turnHandle": handle,
        "conversationId": conversation_id,
        "membershipId": entry.get("membershipId").and_then(Value::as_str).unwrap_or_default(),
        "agent": entry.get("agent").and_then(Value::as_str).unwrap_or_default(),
    }))
}

/// One mention alias match: the alias follows a start or whitespace after the
/// `@` marker and is followed by whitespace, a sentence terminator, or the
/// end of the text. Matching is case-insensitive.
fn mention_alias_matches(text: &str, alias: &str) -> bool {
    let pattern = format!(
        r"(?i)(?:^|\s)@{}(?:\s|[,.!?;:，。！？；：]|$)",
        regex::escape(alias)
    );
    regex::Regex::new(&pattern)
        .map(|pattern| pattern.is_match(text))
        .unwrap_or(false)
}

fn live_turn_from_accepted(
    value: &Value,
    context: &crate::domain::client_conversation::store::DirectTurnExecutionContext,
) -> Option<Value> {
    if value.get("accepted").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let handle = value
        .get("turnHandle")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|handle| !handle.is_empty())?;
    Some(json!({
        "turnHandle": handle,
        "conversationId": context.turn.conversation_id,
        "membershipId": context.turn.membership_id,
        "agent": context.agent_id,
    }))
}

fn safe_failure_field<'a>(value: &'a Value, key: &str, fallback: &'a str) -> &'a str {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|text| {
            !text.is_empty()
                && text.len() <= 96
                && text.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || matches!(byte, b'_' | b'-' | b'/' | b'.')
                })
        })
        .unwrap_or(fallback)
}

/// Admit the optional `attachments` array of one `conversation.message.post`
/// request. The shape is the shared local-image shape of the 1:1 lane
/// (`id`, `name`, `mediaType`, `path`; the caller id is accepted and ignored —
/// the stored Event Part identity becomes the dispatch reference). Admission
/// validates image-only media types, the existing count and size limits, and
/// reads each file's real byte size from the filesystem; every failure
/// rejects the whole post before any Event is persisted.
fn admit_post_attachments(raw: Option<&Value>) -> Result<Vec<ImageAttachment>> {
    let Some(raw) = raw else {
        return Ok(Vec::new());
    };
    if raw.is_null() {
        return Ok(Vec::new());
    }
    let items = raw
        .as_array()
        .ok_or_else(|| anyhow!("attachment_invalid"))?;
    if items.len() > MAX_IMAGE_ATTACHMENTS {
        return Err(anyhow!("attachment_limit_exceeded"));
    }
    let mut total_bytes: u64 = 0;
    let mut admitted = Vec::with_capacity(items.len());
    for item in items {
        let object = item
            .as_object()
            .ok_or_else(|| anyhow!("attachment_invalid"))?;
        if object
            .keys()
            .any(|key| !matches!(key.as_str(), "id" | "name" | "mediaType" | "path"))
        {
            return Err(anyhow!("attachment_invalid"));
        }
        let name = required_attachment_string(object, "name")?;
        let media_type = required_attachment_string(object, "mediaType")?;
        let path = required_attachment_string(object, "path")?;
        if !attachment_media_type_supported(&media_type) {
            return Err(anyhow!("attachment_media_unsupported"));
        }
        if path.contains("://") {
            return Err(anyhow!("attachment_remote_unsupported"));
        }
        let metadata =
            std::fs::symlink_metadata(&path).map_err(|_| anyhow!("attachment_unavailable"))?;
        if !metadata.file_type().is_file() {
            return Err(anyhow!("attachment_invalid"));
        }
        let byte_size = metadata.len();
        total_bytes = total_bytes.saturating_add(byte_size);
        if byte_size > MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE
            || total_bytes > MAX_IMAGE_ATTACHMENT_BYTES_TOTAL
        {
            return Err(anyhow!("attachment_size_exceeded"));
        }
        admitted.push(ImageAttachment {
            path,
            name,
            media_type,
            byte_size,
        });
    }
    Ok(admitted)
}

fn required_attachment_string(
    object: &serde_json::Map<String, Value>,
    key: &str,
) -> Result<String> {
    object
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("attachment_invalid"))
}

/// The shared local-image wire shape admitted by the runtime-adapter
/// attachment lane. The durable Event Part identity is the reference id;
/// byte size stays in the canonical record and is never sent to adapters.
pub fn dispatch_attachments_param(references: &[ImageAttachmentReference]) -> Value {
    Value::Array(
        references
            .iter()
            .map(|reference| {
                json!({
                    "id": reference.part_id,
                    "name": reference.attachment.name,
                    "mediaType": reference.attachment.media_type,
                    "path": reference.attachment.path,
                })
            })
            .collect(),
    )
}

fn ensure_allowed_fields(action: &str, object: &serde_json::Map<String, Value>) -> Result<()> {
    let allowed: &[&str] = match action {
        "conversation.create" => &["action", "title", "owner", "members"],
        "conversation.rename" => &["action", "conversationId", "title"],
        "conversation.archive" => &["action", "conversationId", "archived"],
        "conversation.pin.set" => &["action", "conversationId", "pinned"],
        "conversation.strategy.set" => &["action", "conversationId", "strategyRevision"],
        "conversation.assistant.set" => &[
            "action",
            "conversationId",
            "ownerMembershipId",
            "expectedRevision",
            "membershipId",
        ],
        "conversation.profile.update" => &[
            "action",
            "conversationId",
            "membershipId",
            "ownerMembershipId",
            "expectedRevision",
            "intent",
        ],
        "conversation.profile.get" => &["action", "membershipId"],
        "conversation.profile.candidates" => &["action", "conversationId", "filters"],
        "conversation.list" => &["action", "includeArchived"],
        "conversation.get" => &["action", "conversationId"],
        "conversation.events.page" => &["action", "conversationId", "afterSequence", "limit"],
        "conversation.events.search" => &["action", "query", "limit"],
        "conversation.event.append" => &[
            "action",
            "conversationId",
            "authorMembershipId",
            "kind",
            "parts",
            "causationId",
            "correlationId",
            "finalized",
        ],
        "conversation.message.post" => &[
            "action",
            "conversationId",
            "authorMembershipId",
            "content",
            "correlationId",
            "mentionedMembershipIds",
            "attachments",
        ],
        "conversation.dispatch.after-post" => &["action", "conversationId", "eventId"],
        "conversation.event.part.append" => &["action", "eventId", "part"],
        "conversation.event.finalize" => &["action", "eventId"],
        "conversation.membership.add" => &["action", "conversationId", "principal", "access"],
        "conversation.membership.access.set" => {
            &["action", "conversationId", "membershipId", "access"]
        }
        "conversation.membership.leave" => &["action", "conversationId", "membershipId"],
        "conversation.export" => &["action", "path", "conversationIds"],
        "conversation.import" => &["action", "path"],
        "conversation.subagent.edge" => &[
            "action",
            "conversationId",
            "callerMembershipId",
            "targetMembershipId",
        ],
        "conversation.subagent.target" => &["action", "conversationId", "membershipId"],
        "conversation.subagent.claim" => &[
            "action",
            "conversationId",
            "callerMembershipId",
            "targetMembershipId",
            "parentDispatchId",
        ],
        "conversation.subagent.claim.update" => &["action", "dispatchId", "state"],
        "conversation.subagent.claim.active" => &[
            "action",
            "conversationId",
            "callerMembershipId",
            "targetMembershipId",
        ],
        "conversation.subagent.inbound.record" => &[
            "action",
            "conversationId",
            "callerMembershipId",
            "targetMembershipId",
            "tool",
            "outcome",
        ],
        "conversation.subagent.binding.get" => &["action", "conversationId", "membershipId"],
        _ => return Err(anyhow!("unsupported_action")),
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(anyhow!("invalid_request"));
    }
    Ok(())
}

fn subagent_claim_json(claim: &licoup_conversation::SubagentDispatchClaim) -> Value {
    json!({
        "id": claim.id,
        "conversationId": claim.conversation_id,
        "callerMembershipId": claim.caller_membership_id,
        "targetMembershipId": claim.target_membership_id,
        "parentDispatchId": claim.parent_dispatch_id,
        "depth": claim.depth,
        "state": claim.state.as_str(),
        "createdAtUnixMs": claim.created_at_unix_ms,
        "updatedAtUnixMs": claim.updated_at_unix_ms,
    })
}

fn subagent_claim_state(value: &str) -> Result<licoup_conversation::SubagentDispatchClaimState> {
    use licoup_conversation::SubagentDispatchClaimState;
    match value {
        "claimed" => Ok(SubagentDispatchClaimState::Claimed),
        "running" => Ok(SubagentDispatchClaimState::Running),
        "cancel-requested" => Ok(SubagentDispatchClaimState::CancelRequested),
        "reconciliation-required" => Ok(SubagentDispatchClaimState::ReconciliationRequired),
        "completed" => Ok(SubagentDispatchClaimState::Completed),
        "failed" => Ok(SubagentDispatchClaimState::Failed),
        "cancelled" => Ok(SubagentDispatchClaimState::Cancelled),
        _ => Err(anyhow!("subagent_dispatch_transition_invalid")),
    }
}

fn ensure_member_fields(object: &serde_json::Map<String, Value>) -> Result<()> {
    if object
        .keys()
        .any(|key| !matches!(key.as_str(), "principal" | "access"))
    {
        return Err(anyhow!("invalid_request"));
    }
    Ok(())
}

fn required_string<'a>(object: &'a serde_json::Map<String, Value>, key: &str) -> Result<&'a str> {
    object
        .get(key)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("invalid_request"))
}

fn required_revision(object: &serde_json::Map<String, Value>, key: &str) -> Result<i64> {
    object
        .get(key)
        .and_then(Value::as_i64)
        .filter(|revision| *revision >= 0)
        .ok_or_else(|| anyhow!("invalid_request"))
}

fn principal_from_value(value: &Value) -> Result<Principal> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("invalid_request"))?;
    let id = object
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("invalid_request"))?;
    let kind: PrincipalKind = serde_json::from_value(
        object
            .get("kind")
            .cloned()
            .unwrap_or_else(|| json!("human")),
    )?;
    Ok(Principal {
        id: id.to_owned(),
        kind,
        display_name: object
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or(id)
            .to_owned(),
        agent_id: object
            .get("agentId")
            .and_then(Value::as_str)
            .map(str::to_owned),
        created_at_unix_ms: object
            .get("createdAtUnixMs")
            .and_then(Value::as_i64)
            .unwrap_or(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Condvar, Mutex};

    /// Releases the runtime barrier even when an assertion fails first, so a
    /// panicking test can never leave the fan-out threads blocked forever.
    struct ReleaseGuard<'a>(&'a (Mutex<bool>, Condvar));

    impl Drop for ReleaseGuard<'_> {
        fn drop(&mut self) {
            let (lock, cvar) = self.0;
            *lock.lock().unwrap_or_else(|poison| poison.into_inner()) = true;
            cvar.notify_all();
        }
    }

    fn group_fixture(service: &ConversationService) -> (String, String, String) {
        let group = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Direct Turn",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [
                    {"principal": {"id": "agent:one", "kind": "agent", "displayName": "One", "agentId": "one"}, "access": "member"}
                ]
            }))
            .unwrap();
        let memberships = group["memberships"].as_array().unwrap();
        let owner = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "human")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let agent = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "agent")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        (group["id"].as_str().unwrap().to_owned(), owner, agent)
    }

    fn accepted_receipt(params: &Value) -> Value {
        json!({
            "ok": true,
            "accepted": true,
            "turnHandle": params["dispatchId"],
            "conversationId": params["conversationId"],
            "membershipId": params["membershipId"],
        })
    }

    /// One real local image file so post admission can stat it and adapter
    /// admission can verify its signature.
    struct ImageFixture {
        directory: std::path::PathBuf,
        png: std::path::PathBuf,
    }

    impl ImageFixture {
        const PNG_BYTES: [u8; 12] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];

        fn new() -> Self {
            let directory =
                std::env::temp_dir().join(format!("lico-post-attachment-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&directory).unwrap();
            let png = directory.join("synthetic.png");
            std::fs::write(&png, Self::PNG_BYTES).unwrap();
            Self { directory, png }
        }

        fn attachment(&self) -> Value {
            json!({
                "id": "sel-1",
                "name": "synthetic.png",
                "mediaType": "image/png",
                "path": self.png.to_string_lossy(),
            })
        }
    }

    impl Drop for ImageFixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    /// Persist one human message, then dispatch it by identity alone. The
    /// dispatch request carries no content and no client-computed mentions.
    fn persist_then_dispatch(service: &ConversationService, request: Value) -> Value {
        let persisted = service
            .execute(request.clone())
            .expect("persist posted message");
        let event_id = persisted
            .get("event")
            .and_then(|event| event.get("id"))
            .cloned()
            .expect("persisted event id");
        let conversation_id = request["conversationId"].clone();
        service
            .execute(json!({
                "action": "conversation.dispatch.after-post",
                "conversationId": conversation_id,
                "eventId": event_id,
            }))
            .expect("dispatch after post")
    }

    #[test]
    fn posted_message_persists_without_a_runtime() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let posted = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "hello without a host"
            }))
            .unwrap();
        assert_eq!(posted["event"]["state"], "finalized");
        assert!(posted["directTurns"].as_array().unwrap().is_empty());
        assert!(posted["turns"].as_array().unwrap().is_empty());
        assert_eq!(posted["dispatchPending"], false);
        let events = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events;
        assert!(events.iter().any(|event| event.id == posted["event"]["id"]));
        assert_eq!(
            events.last().unwrap().parts[0].content,
            "hello without a host"
        );
    }

    /// AC-013: one admitted image attachment persists as an image Event Part
    /// carrying the attachment metadata, with the byte size read from the
    /// real file, and the projected Event exposes it to Dart.
    #[test]
    fn message_post_with_image_attachments_persists_image_parts() {
        let fixture = ImageFixture::new();
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let posted = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "see the mockup",
                "attachments": [fixture.attachment()],
            }))
            .unwrap();
        assert_eq!(posted["event"]["state"], "finalized");

        let events = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events;
        let event = events
            .iter()
            .find(|event| event.id == posted["event"]["id"])
            .unwrap();
        assert_eq!(event.parts.len(), 2);
        let text = &event.parts[0];
        assert_eq!(text.kind, super::super::EventPartKind::Text);
        assert_eq!(text.content, "see the mockup");
        let image = &event.parts[1];
        assert_eq!(image.kind, super::super::EventPartKind::Image);
        let attachment = image.image_attachment().unwrap();
        assert_eq!(attachment.path, fixture.png.to_string_lossy());
        assert_eq!(attachment.name, "synthetic.png");
        assert_eq!(attachment.media_type, "image/png");
        assert_eq!(attachment.byte_size, ImageFixture::PNG_BYTES.len() as u64);

        // The projected message exposes the attachment to Dart.
        let projected = serde_json::to_value(event).unwrap();
        let parts = projected["parts"].as_array().unwrap();
        let image_json = parts
            .iter()
            .find(|part| part["kind"] == json!("image"))
            .unwrap();
        let content: Value = serde_json::from_str(image_json["content"].as_str().unwrap()).unwrap();
        assert_eq!(content["mediaType"], "image/png");
        assert_eq!(content["name"], "synthetic.png");
        assert_eq!(content["path"], json!(fixture.png.to_string_lossy()));
        assert_eq!(
            content["byteSize"],
            json!(ImageFixture::PNG_BYTES.len() as u64)
        );
    }

    /// Dishonest attachment posts reject with a stable code before any Event
    /// is persisted: no partial writes, no fabricated metadata.
    #[test]
    fn message_post_rejects_invalid_attachments_without_persisting() {
        let fixture = ImageFixture::new();
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let before = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events
            .len();
        let path = fixture.png.to_string_lossy().into_owned();
        let missing = fixture.directory.join("missing.png");
        let cases: Vec<(Value, &str)> = vec![
            (json!({"path": path}), "attachment_invalid"),
            (
                json!([{"name": "a.png", "mediaType": "image/png"}]),
                "attachment_invalid",
            ),
            (
                json!([{"name": "a.png", "mediaType": "image/png", "path": path, "byteSize": 1}]),
                "attachment_invalid",
            ),
            (
                json!([{"name": "a.pdf", "mediaType": "application/pdf", "path": path}]),
                "attachment_media_unsupported",
            ),
            (
                json!([{"name": "a.png", "mediaType": "image/png", "path": "https://example.test/a.png"}]),
                "attachment_remote_unsupported",
            ),
            (
                json!([{"name": "a.png", "mediaType": "image/png", "path": missing.to_string_lossy()}]),
                "attachment_unavailable",
            ),
            (
                json!([
                    {"name": "1.png", "mediaType": "image/png", "path": path},
                    {"name": "2.png", "mediaType": "image/png", "path": path},
                    {"name": "3.png", "mediaType": "image/png", "path": path},
                    {"name": "4.png", "mediaType": "image/png", "path": path},
                    {"name": "5.png", "mediaType": "image/png", "path": path},
                ]),
                "attachment_limit_exceeded",
            ),
        ];
        for (attachments, expected) in cases {
            let error = service
                .execute(json!({
                    "action": "conversation.message.post",
                    "conversationId": conversation_id,
                    "authorMembershipId": owner_id,
                    "content": "must not persist",
                    "attachments": attachments,
                }))
                .expect_err("dishonest attachment post must reject");
            assert_eq!(error.to_string(), expected);
        }
        let after = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events
            .len();
        assert_eq!(before, after, "rejected posts must not persist events");
    }

    /// Fake-adapter end-to-end: a group post carrying one image attachment
    /// persists the image part and dispatches the member turn with the
    /// attachment reference in the shared adapter wire shape.
    #[test]
    fn group_dispatch_carries_attachment_references_to_member_turn_params() {
        let fixture = ImageFixture::new();
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let recorded = Arc::clone(&calls);
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        )
        .with_native_turn_sender(move |params| {
            recorded.lock().unwrap().push(params.clone());
            Ok(accepted_receipt(params))
        });
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One look at this mockup",
                "attachments": [fixture.attachment()],
            }),
        );

        assert_eq!(posted["directTurns"][0]["state"], "running");
        let events = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events;
        let event = events
            .iter()
            .find(|event| event.id == posted["event"]["id"])
            .unwrap();
        let image_part = event
            .parts
            .iter()
            .find(|part| part.kind == super::super::EventPartKind::Image)
            .unwrap();
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["membershipId"], agent_id);
        assert_eq!(calls[0]["text"], "@One look at this mockup");
        let attachments = calls[0]["attachments"].as_array().unwrap();
        assert_eq!(attachments.len(), 1);
        // The durable Event Part identity is the dispatch reference id.
        assert_eq!(attachments[0]["id"], json!(image_part.id));
        assert_eq!(attachments[0]["name"], "synthetic.png");
        assert_eq!(attachments[0]["mediaType"], "image/png");
        assert_eq!(attachments[0]["path"], json!(fixture.png.to_string_lossy()));
        assert!(
            attachments[0].get("byteSize").is_none(),
            "byte size stays in the canonical record"
        );
    }

    /// An image-only group post admits empty content, persists only the image
    /// Event Part, and still dispatches to the designated Assistant — the
    /// default dispatch target when no mention exists. The wire text is the
    /// composed Assistant guidance with an empty user-authored portion, and
    /// the turn params carry the attachment reference.
    #[test]
    fn image_only_group_post_persists_and_dispatches_to_the_assistant() {
        let fixture = ImageFixture::new();
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let recorded = Arc::clone(&calls);
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        )
        .with_native_turn_sender(move |params| {
            recorded.lock().unwrap().push(params.clone());
            Ok(accepted_receipt(params))
        });
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let conversation_revision = service.store().get(&conversation_id).unwrap().revision;
        service
            .execute(json!({
                "action": "conversation.assistant.set",
                "conversationId": conversation_id,
                "ownerMembershipId": owner_id,
                "expectedRevision": conversation_revision,
                "membershipId": agent_id,
            }))
            .unwrap();

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "",
                "attachments": [fixture.attachment()],
            }),
        );

        assert_eq!(posted["directTurns"][0]["state"], "running");
        let events = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events;
        let event = events
            .iter()
            .find(|event| event.id == posted["event"]["id"])
            .unwrap();
        // No empty text part pollutes the record: the image part stands alone.
        assert_eq!(event.parts.len(), 1);
        assert_eq!(event.parts[0].kind, super::super::EventPartKind::Image);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["membershipId"], agent_id);
        let text = calls[0]["text"].as_str().unwrap();
        assert!(text.contains("Respond directly to the user's request."));
        let attachments = calls[0]["attachments"].as_array().unwrap();
        assert_eq!(attachments.len(), 1);
        assert_eq!(attachments[0]["id"], json!(event.parts[0].id));
        assert_eq!(attachments[0]["path"], json!(fixture.png.to_string_lossy()));
    }

    /// The text-only admission rule is unchanged: empty content without
    /// attachments still rejects before anything persists.
    #[test]
    fn message_post_still_rejects_empty_content_without_attachments() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let before = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events
            .len();
        for request in [
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "",
            }),
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "   ",
            }),
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "",
                "attachments": [],
            }),
        ] {
            let error = service
                .execute(request)
                .expect_err("empty content without attachments must reject");
            assert_eq!(error.to_string(), "invalid_request");
        }
        let after = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events
            .len();
        assert_eq!(before, after, "rejected posts must not persist events");
    }

    /// AC-014: with one image-capable member and one text-only member, the
    /// capable member's turn carries the attachment reference through the
    /// existing adapter admission while the text-only member rejects honestly
    /// before launch — no partial dispatch, no silent drop.
    #[cfg(unix)]
    #[test]
    fn text_only_member_rejects_attachments_before_launch() {
        use crate::platform::runtime_adapters::{RuntimeAdapterError, send_message};

        let fixture = ImageFixture::new();
        type Recorded = (
            String,
            Value,
            std::result::Result<Value, RuntimeAdapterError>,
        );
        let calls = Arc::new(Mutex::new(Vec::<Recorded>::new()));
        let recorded = Arc::clone(&calls);
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        )
        .with_native_turn_sender(move |params| {
            let agent = params["agentId"].as_str().unwrap_or_default().to_owned();
            // Route through the real 1:1 adapter admission; /bin/sh stands in
            // for the image-capable adapter binary exactly like the adapter
            // dispatch tests do.
            let mut admitted = params.clone();
            admitted["binaryPath"] = json!("/bin/sh");
            let result = send_message(&admitted);
            recorded
                .lock()
                .unwrap()
                .push((agent, params.clone(), result.clone()));
            result
        });
        let group = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Mixed capability",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [
                    {"principal": {"id": "agent:codex", "kind": "agent", "displayName": "Codex", "agentId": "codex"}, "access": "member"},
                    {"principal": {"id": "agent:claude", "kind": "agent", "displayName": "Claude", "agentId": "claude-code"}, "access": "member"}
                ]
            }))
            .unwrap();
        let memberships = group["memberships"].as_array().unwrap();
        let membership_of = |agent: &str| {
            memberships
                .iter()
                .find(|membership| membership["principal"]["agentId"] == json!(agent))
                .unwrap()["id"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        let codex_membership = membership_of("codex");
        let claude_membership = membership_of("claude-code");
        let owner_id = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "human")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let conversation_id = group["id"].as_str().unwrap().to_owned();

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@Codex @Claude review this screenshot",
                "attachments": [fixture.attachment()],
            }),
        );

        // Both member turns were attempted with the attachment reference.
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        for (_, params, _) in calls.iter() {
            let attachments = params["attachments"].as_array().unwrap();
            assert_eq!(attachments.len(), 1);
            assert_eq!(attachments[0]["path"], json!(fixture.png.to_string_lossy()));
            assert_eq!(attachments[0]["mediaType"], "image/png");
        }
        // The image-capable member passed admission and reached its driver
        // (the shell fixture fails at the Codex protocol stage, proving a
        // process was actually launched).
        let codex_call = calls.iter().find(|(agent, _, _)| agent == "codex").unwrap();
        let codex_result = codex_call.2.as_ref().expect("codex send dispatched");
        assert_eq!(codex_result["ok"], false);
        let code = codex_result["error"]["code"].as_str().unwrap_or_default();
        assert!(
            code.starts_with("codex_"),
            "expected a Codex protocol failure, got {code}"
        );
        // The text-only member rejected honestly before launch.
        let claude_call = calls
            .iter()
            .find(|(agent, _, _)| agent == "claude-code")
            .unwrap();
        assert_eq!(
            claude_call.2,
            Err(RuntimeAdapterError::AttachmentUnsupportedForAdapter {
                agent_label: "claude-code".to_owned()
            })
        );
        drop(calls);

        // Turn receipts report the honest per-member outcome.
        let receipts = posted["directTurns"].as_array().unwrap();
        assert_eq!(receipts.len(), 2);
        let state_of = |membership_id: &str| {
            receipts
                .iter()
                .find(|receipt| {
                    service
                        .store()
                        .direct_turn(receipt["id"].as_str().unwrap())
                        .unwrap()
                        .membership_id
                        == membership_id
                })
                .unwrap()["state"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        assert_eq!(state_of(&codex_membership), "running");
        assert_eq!(state_of(&claude_membership), "failed");
        assert_eq!(
            posted["strategyError"]["code"],
            "conversation_dispatch_failed"
        );
    }

    #[test]
    fn dispatch_after_post_without_the_host_runtime_is_fail_closed() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let posted = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One hello"
            }))
            .unwrap();
        let before = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events
            .len();
        let error = service
            .execute(json!({
                "action": "conversation.dispatch.after-post",
                "conversationId": conversation_id,
                "eventId": posted["event"]["id"],
            }))
            .expect_err("dispatch without the host runtime must reject");
        assert_eq!(
            error.to_string(),
            super::super::PERSISTENT_TRANSPORT_REQUIRED
        );
        let after = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events
            .len();
        assert_eq!(
            before, after,
            "no Agent work and no settlement happened without the host"
        );
    }

    #[test]
    fn dispatch_after_post_admits_only_conversation_and_event_identity() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        )
        .with_native_turn_sender(|_| {
            panic!("event validation must run before any runtime dispatch")
        });
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let posted = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One hello"
            }))
            .unwrap();
        for extra in [
            json!({"content": "@One hello"}),
            json!({"mentionedMembershipIds": [agent_id]}),
        ] {
            let mut request = json!({
                "action": "conversation.dispatch.after-post",
                "conversationId": conversation_id,
                "eventId": posted["event"]["id"],
            });
            request
                .as_object_mut()
                .unwrap()
                .extend(extra.as_object().unwrap().clone());
            let error = service
                .execute(request)
                .expect_err("extra field must reject");
            assert_eq!(error.to_string(), "invalid_request");
        }
        let missing = service.execute(json!({
            "action": "conversation.dispatch.after-post",
            "conversationId": conversation_id,
            "eventId": "event:missing",
        }));
        assert_eq!(
            missing.unwrap_err().to_string(),
            "conversation_event_not_found"
        );
    }

    #[test]
    fn mention_aliases_follow_the_client_boundary_rule() {
        assert!(mention_alias_matches("@One hello", "One"));
        assert!(mention_alias_matches("hello @one", "One"));
        assert!(mention_alias_matches("hello @one.", "One"));
        assert!(mention_alias_matches("hello @one,", "one"));
        assert!(mention_alias_matches("hello @one，", "one"));
        assert!(mention_alias_matches("hello @one。", "one"));
        assert!(mention_alias_matches("hello @ONE?", "one"));
        assert!(mention_alias_matches("ask @one two", "one"));
        assert!(!mention_alias_matches("hello@one", "one"));
        assert!(!mention_alias_matches("@onex", "one"));
        assert!(!mention_alias_matches("@one-two", "one"));
        assert!(!mention_alias_matches(
            "email one@example.com",
            "example.com"
        ));
        assert!(mention_alias_matches("ping @a.b now", "a.b"));
        assert!(!mention_alias_matches("ping @a.bx now", "a.b"));
    }

    #[test]
    fn product_startup_restores_one_canonical_default_local_group() {
        let root = std::env::temp_dir().join(format!(
            "lico-conversation-service-default-{}",
            uuid::Uuid::new_v4()
        ));

        let service = ConversationService::open(&root).unwrap();
        let groups = service.store().list(false).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].id, super::super::DEFAULT_LOCAL_AGENT_GROUP_ID);
        assert_eq!(
            groups[0].title,
            super::super::DEFAULT_LOCAL_AGENT_GROUP_TITLE
        );
        assert!(groups[0].pinned);
        assert!(groups[0].is_group);
        let local = service
            .store()
            .get(super::super::DEFAULT_LOCAL_AGENT_GROUP_ID)
            .unwrap();
        assert_eq!(local.memberships.len(), 1);
        assert_eq!(local.memberships[0].principal.id, "human:local");
        assert_eq!(local.memberships[0].access, MembershipAccess::Owner);
        drop(service);

        let reopened = ConversationService::open(&root).unwrap();
        assert_eq!(reopened.store().list(false).unwrap().len(), 1);
        assert_eq!(
            reopened
                .store()
                .get(super::super::DEFAULT_LOCAL_AGENT_GROUP_ID)
                .unwrap()
                .memberships
                .len(),
            1
        );
        drop(reopened);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn group_strategy_selection_persists_until_explicitly_cleared() {
        let root = std::env::temp_dir().join(format!(
            "lico-conversation-service-strategy-{}",
            uuid::Uuid::new_v4()
        ));
        let conversation_id = super::super::DEFAULT_LOCAL_AGENT_GROUP_ID;

        let service = ConversationService::open(&root).unwrap();
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        let selected = service
            .execute(json!({
                "action": "conversation.get",
                "conversationId": conversation_id
            }))
            .unwrap();
        assert_eq!(selected["strategyRevision"], "revision-one");
        let selected_revision = selected["revision"].as_i64().unwrap();
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        assert_eq!(
            service
                .execute(json!({
                    "action": "conversation.get",
                    "conversationId": conversation_id
                }))
                .unwrap()["revision"],
            selected_revision
        );
        drop(service);

        let reopened = ConversationService::open(&root).unwrap();
        assert_eq!(
            reopened
                .execute(json!({
                    "action": "conversation.get",
                    "conversationId": conversation_id
                }))
                .unwrap()["strategyRevision"],
            "revision-one"
        );
        reopened
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": null
            }))
            .unwrap();
        assert!(
            reopened
                .execute(json!({
                    "action": "conversation.get",
                    "conversationId": conversation_id
                }))
                .unwrap()
                .get("strategyRevision")
                .is_none()
        );

        drop(reopened);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn direct_turn_fanout_is_bounded_parallel_and_preserves_receipt_order() {
        let in_flight = Arc::new((Mutex::new(0usize), Condvar::new()));
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let runtime_in_flight = Arc::clone(&in_flight);
        let runtime_release = Arc::clone(&release);
        let runtime_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |params| {
                runtime_calls.lock().unwrap().push(params.clone());
                {
                    let (lock, cvar) = &*runtime_in_flight;
                    let mut count = lock.lock().unwrap_or_else(|poison| poison.into_inner());
                    *count += 1;
                    cvar.notify_all();
                }
                let (lock, cvar) = &*runtime_release;
                let mut flag = lock.lock().unwrap_or_else(|poison| poison.into_inner());
                while !*flag {
                    flag = cvar.wait(flag).unwrap_or_else(|poison| poison.into_inner());
                }
                drop(flag);
                Ok(accepted_receipt(params))
            },
        );
        let conversation = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Fanout",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [
                    {"principal": {"id": "agent:one", "kind": "agent", "displayName": "One", "agentId": "one"}, "access": "member"},
                    {"principal": {"id": "agent:two", "kind": "agent", "displayName": "Two", "agentId": "two"}, "access": "member"},
                    {"principal": {"id": "agent:three", "kind": "agent", "displayName": "Three", "agentId": "three"}, "access": "member"},
                    {"principal": {"id": "agent:four", "kind": "agent", "displayName": "Four", "agentId": "four"}, "access": "member"},
                    {"principal": {"id": "agent:five", "kind": "agent", "displayName": "Five", "agentId": "five"}, "access": "member"}
                ]
            }))
            .unwrap();
        let memberships = conversation["memberships"].as_array().unwrap();
        let owner_id = memberships
            .iter()
            .find(|membership| membership["principal"]["kind"] == "human")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();

        let conversation_id = conversation["id"].as_str().unwrap().to_owned();
        let persist_request = json!({
            "action": "conversation.message.post",
            "conversationId": conversation_id,
            "authorMembershipId": owner_id,
            "content": "@One @Two @Three @Four @Five run all"
        });
        let persisted = service.execute(persist_request).unwrap();
        let event_id = persisted["event"]["id"].clone();
        let service_for_post = service.clone();
        let dispatch_conversation_id = conversation_id.clone();
        let post = std::thread::spawn(move || {
            service_for_post
                .execute(json!({
                    "action": "conversation.dispatch.after-post",
                    "conversationId": dispatch_conversation_id,
                    "eventId": event_id,
                }))
                .unwrap()
        });

        {
            let (lock, cvar) = &*in_flight;
            let mut count = lock.lock().unwrap_or_else(|poison| poison.into_inner());
            while *count < DEFAULT_DIRECT_TURN_WORKERS {
                count = cvar
                    .wait(count)
                    .unwrap_or_else(|poison| poison.into_inner());
            }
        }
        let _guard = ReleaseGuard(&release);
        assert_eq!(
            service.store().counters().peak_in_flight_turns(),
            DEFAULT_DIRECT_TURN_WORKERS
        );
        assert_eq!(
            calls.lock().unwrap().len(),
            DEFAULT_DIRECT_TURN_WORKERS,
            "the fifth mention must wait for a worker slot"
        );
        let leases_while_blocked = service.store().counters().leases();
        std::thread::sleep(std::time::Duration::from_millis(60));
        assert_eq!(
            service.store().counters().leases(),
            leases_while_blocked,
            "no SQLite lease may span runtime work"
        );

        drop(_guard);
        let posted = post.join().unwrap();
        let receipts = posted["directTurns"].as_array().unwrap();
        assert_eq!(receipts.len(), 5);
        for (index, receipt) in receipts.iter().enumerate() {
            assert_eq!(receipt["state"], "running");
            let turn_id = receipt["id"].as_str().unwrap();
            let turn = service.store().direct_turn(turn_id).unwrap();
            assert_eq!(turn.ordinal, index as i64, "receipt {index} out of order");
        }
        assert_eq!(posted["turns"].as_array().unwrap().len(), 5);
        assert_eq!(posted["dispatchPending"], true);
        assert!(posted.get("strategyError").is_none());
        assert_eq!(calls.lock().unwrap().len(), 5);
        assert_eq!(
            service.store().counters().peak_in_flight_turns(),
            DEFAULT_DIRECT_TURN_WORKERS
        );
        assert_eq!(
            service.store().counters().in_flight_turns(),
            0,
            "no direct turn may stay in flight after the fanout completes"
        );
        assert!(
            service.store().counters().peak_in_flight()
                <= crate::domain::client_conversation::store::DEFAULT_CONVERSATION_POOL_SIZE,
            "pool leases stay bounded by the configured connection pool"
        );
    }

    #[test]
    fn creates_initial_group_memberships_through_one_service_action() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let result = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Group",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [
                    {"principal": {"id": "agent:one", "kind": "agent", "displayName": "One", "agentId": "one"}, "access": "member"}
                ]
            }))
            .unwrap();

        assert_eq!(result["memberships"].as_array().unwrap().len(), 2);
        assert_eq!(result["isGroup"], true);
    }

    #[test]
    fn structured_mention_dispatches_once_and_returns_the_attachable_handle() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |params| {
                captured_calls.lock().unwrap().push(params.clone());
                Ok(accepted_receipt(params))
            },
        );
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One Please answer"
            }),
        );

        assert_eq!(posted["directTurns"][0]["state"], "running");
        assert_eq!(posted["event"]["state"], "finalized");
        assert!(posted["event"].get("parts").is_none());
        assert!(posted.to_string().len() < 1024);
        assert_eq!(posted["dispatchPending"], true);
        assert_eq!(
            posted["turns"][0]["turnHandle"],
            posted["directTurns"][0]["id"]
        );
        assert_eq!(posted["turns"][0]["membershipId"], agent_id);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["agentId"], "one");
        assert_eq!(calls[0]["text"], "@One Please answer");
        assert!(calls[0].get("timeoutMs").is_none());
        assert_eq!(calls[0]["streamEvents"], true);
        assert_eq!(calls[0]["conversationId"], conversation_id);
        assert_eq!(calls[0]["membershipId"], agent_id);
        assert_eq!(calls[0]["causationId"], posted["event"]["id"]);
        assert_eq!(calls[0]["dispatchId"], posted["directTurns"][0]["id"]);
        assert!(calls[0].get("maxStdoutBytes").is_none());
        drop(calls);
        let events = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events;
        assert!(
            !events
                .iter()
                .any(|event| event.author_membership_id.as_deref() == Some(agent_id.as_str())),
            "the service never writes the agent reply; the completion authority owns it"
        );
    }

    #[test]
    fn persistent_group_dispatch_finalizes_one_canonical_agent_event() {
        let store = ConversationStore::open_in_memory().unwrap();
        let runtime_store = store.clone();
        let service =
            ConversationService::from_store(store).with_native_turn_sender(move |params| {
                let scope = runtime_store
                    .prepare_runtime_dispatch(
                        params["agentId"].as_str().unwrap(),
                        "",
                        params["text"].as_str().unwrap(),
                        params["conversationId"].as_str(),
                        params["membershipId"].as_str(),
                        params["causationId"].as_str(),
                        params["dispatchId"].as_str(),
                    )
                    .unwrap();
                runtime_store
                    .append_runtime_frame(
                        &scope,
                        1,
                        &json!({
                            "event": "agent.message.completed",
                            "sessionId": "session-fixture",
                            "turnId": "turn-fixture",
                            "payload": {"text": "agent answer"}
                        }),
                    )
                    .unwrap();
                runtime_store
                    .finish_runtime_dispatch(
                        &scope,
                        &json!({"ok": true, "output": "agent answer"}),
                        crate::domain::client_conversation::DispatchState::Completed,
                        None,
                    )
                    .unwrap();
                Ok(json!({
                    "ok": true,
                    "accepted": true,
                    "turnHandle": params["dispatchId"],
                    "nativeSessionId": "session-fixture"
                }))
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One one answer"
            }),
        );

        assert_eq!(posted["directTurns"][0]["state"], "succeeded");
        let turn_id = posted["directTurns"][0]["id"].as_str().unwrap();
        let events = service
            .store()
            .page_events(&conversation_id, None, 20)
            .unwrap()
            .events;
        let replies = events
            .iter()
            .filter(|event| event.correlation_id.as_deref() == Some(turn_id))
            .collect::<Vec<_>>();
        assert_eq!(replies.len(), 1);
        assert!(replies[0].finalized);
        assert_eq!(
            replies[0]
                .parts
                .iter()
                .filter(|part| part.kind == super::super::EventPartKind::Text)
                .count(),
            1
        );
        assert_eq!(
            replies[0]
                .parts
                .iter()
                .find(|part| part.kind == super::super::EventPartKind::Text)
                .unwrap()
                .content,
            "agent answer"
        );
        for expected_lifecycle in [
            r#"{"lifecycle":"submitted"}"#,
            r#"{"lifecycle":"accepted"}"#,
            r#"{"lifecycle":"processing"}"#,
            r#"{"lifecycle":"responding"}"#,
            r#"{"lifecycle":"completed"}"#,
        ] {
            assert!(replies[0].parts.iter().any(|part| {
                part.kind == super::super::EventPartKind::Metadata
                    && part.content == expected_lifecycle
            }));
        }
    }

    #[test]
    fn private_continuation_is_membership_scoped_and_non_pending_turns_never_replay() {
        let store = ConversationStore::open_in_memory().unwrap();
        let runtime_store = store.clone();
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_calls = Arc::clone(&calls);
        let service =
            ConversationService::from_store(store).with_native_turn_sender(move |params| {
                captured_calls.lock().unwrap().push(params.clone());
                let scope = runtime_store
                    .prepare_runtime_dispatch(
                        params["agentId"].as_str().unwrap(),
                        params
                            .get("sessionId")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                        params["text"].as_str().unwrap(),
                        params["conversationId"].as_str(),
                        params["membershipId"].as_str(),
                        params["causationId"].as_str(),
                        params["dispatchId"].as_str(),
                    )
                    .unwrap();
                runtime_store
                    .bind_runtime_session(
                        &scope,
                        params["agentId"].as_str().unwrap(),
                        "session-fixture",
                        Some("/fixture/session.jsonl"),
                        Some("/fixture/project"),
                    )
                    .unwrap();
                runtime_store
                    .finish_runtime_dispatch(
                        &scope,
                        &json!({
                            "ok": true,
                            "output": "done",
                            "nativeSessionId": "session-fixture",
                            "sourcePath": "/fixture/session.jsonl",
                            "workingDirectory": "/fixture/project"
                        }),
                        crate::domain::client_conversation::DispatchState::Completed,
                        None,
                    )
                    .unwrap();
                Ok(json!({
                    "ok": true,
                    "accepted": true,
                    "turnHandle": params["dispatchId"],
                    "nativeSessionId": "session-fixture"
                }))
            });
        let service = service;
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let post = |content: &str| {
            persist_then_dispatch(
                &service,
                json!({
                    "action": "conversation.message.post",
                    "conversationId": conversation_id,
                    "authorMembershipId": owner_id,
                    "content": content
                }),
            )
        };
        let first = post("@One first");
        let _ = post("@One second");

        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert!(calls[0].get("sessionId").is_none());
        assert_eq!(calls[1]["sessionId"], "session-fixture");
        assert_eq!(calls[1]["sourcePath"], "/fixture/session.jsonl");
        assert_eq!(calls[1]["workingDirectory"], "/fixture/project");
        drop(calls);
        let completed_turn = first["directTurns"][0]["id"].as_str().unwrap();
        assert!(
            service
                .store()
                .claim_direct_turn(completed_turn)
                .unwrap()
                .is_none()
        );
        let export_root =
            std::env::temp_dir().join(format!("lico-direct-turn-export-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&export_root).unwrap();
        let bundle = export_root.join("bundle.json");
        service
            .store()
            .export_bundle(&bundle, std::slice::from_ref(&conversation_id))
            .unwrap();
        let exported = std::fs::read_to_string(&bundle).unwrap();
        assert!(!exported.contains("session-fixture"));
        assert!(!exported.contains("/fixture/session.jsonl"));
        assert!(!exported.contains("/fixture/project"));
        std::fs::remove_dir_all(export_root).unwrap();
    }

    #[test]
    fn ordinary_message_does_not_dispatch() {
        let calls = Arc::new(Mutex::new(0usize));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |_| {
                *captured_calls.lock().unwrap() += 1;
                Ok(json!({"ok": true, "accepted": true, "turnHandle": "dispatch:unexpected"}))
            },
        );
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let ordinary = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "ordinary"
            }),
        );
        assert!(ordinary["directTurns"].as_array().unwrap().is_empty());
        assert_eq!(ordinary["dispatchPending"], false);
        assert!(ordinary["turns"].as_array().unwrap().is_empty());
        assert_eq!(*calls.lock().unwrap(), 0);
    }

    #[test]
    fn pre_dispatch_rejection_settles_the_unopened_turn_with_a_typed_code() {
        let calls = Arc::new(Mutex::new(0usize));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |_| {
                *captured_calls.lock().unwrap() += 1;
                Err(crate::platform::runtime_adapters::RuntimeAdapterError::ExecutableUnavailable)
            },
        );
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let failed = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One run"
            }),
        );
        assert_eq!(failed["directTurns"][0]["state"], "failed");
        assert_eq!(failed["dispatchPending"], false);
        assert_eq!(
            failed["strategyError"]["code"],
            "conversation_dispatch_failed"
        );
        assert_eq!(*calls.lock().unwrap(), 1);
        let events = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events;
        let replies = events
            .iter()
            .filter(|event| event.author_membership_id.as_deref() == Some(agent_id.as_str()))
            .collect::<Vec<_>>();
        assert_eq!(replies.len(), 1, "one settlement event for the rejection");
        let diagnostic = replies[0]
            .parts
            .iter()
            .find(|part| part.kind == super::super::EventPartKind::Diagnostic)
            .unwrap();
        assert!(
            diagnostic
                .content
                .contains("native_agent_executable_unavailable")
        );
        assert!(diagnostic.content.contains("process/launch"));
    }

    #[test]
    fn opened_dispatch_rejection_defers_to_the_completion_authority() {
        let store = ConversationStore::open_in_memory().unwrap();
        let runtime_store = store.clone();
        let service =
            ConversationService::from_store(store).with_native_turn_sender(move |params| {
                let scope = runtime_store
                    .prepare_runtime_dispatch(
                        params["agentId"].as_str().unwrap(),
                        "",
                        params["text"].as_str().unwrap(),
                        params["conversationId"].as_str(),
                        params["membershipId"].as_str(),
                        params["causationId"].as_str(),
                        params["dispatchId"].as_str(),
                    )
                    .unwrap();
                runtime_store
                    .finish_runtime_dispatch(
                        &scope,
                        &json!({
                            "ok": false,
                            "error": {
                                "code": "native_agent_executable_unavailable",
                                "stage": "process/launch"
                            }
                        }),
                        crate::domain::client_conversation::DispatchState::Failed,
                        Some("native_agent_executable_unavailable"),
                    )
                    .unwrap();
                Err(crate::platform::runtime_adapters::RuntimeAdapterError::ExecutableUnavailable)
            });
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let failed = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One run"
            }),
        );
        assert_eq!(failed["directTurns"][0]["state"], "failed");
        let events = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events;
        let replies = events
            .iter()
            .filter(|event| event.author_membership_id.as_deref() == Some(agent_id.as_str()))
            .collect::<Vec<_>>();
        assert_eq!(
            replies.len(),
            1,
            "the completion authority wrote the only terminal event"
        );
        assert!(replies[0].finalized);
        assert!(
            replies[0]
                .parts
                .iter()
                .any(|part| part.kind == super::super::EventPartKind::Diagnostic
                    && part.content.contains("native_agent_executable_unavailable"))
        );
    }

    #[test]
    fn accepted_receipt_keeps_mention_turn_running_for_attach() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |params| {
                captured_calls.lock().unwrap().push(params.clone());
                Ok(json!({
                    "ok": true,
                    "accepted": true,
                    "turnHandle": "dispatch:live",
                    "conversationId": params["conversationId"],
                    "membershipId": params["membershipId"],
                }))
            },
        );
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "@One Please answer"
            }),
        );
        assert_eq!(posted["directTurns"][0]["state"], "running");
        assert_eq!(posted["dispatchPending"], true);
        assert_eq!(posted["turns"][0]["turnHandle"], "dispatch:live");
        assert_eq!(posted["turns"][0]["membershipId"], agent_id);
        assert_eq!(calls.lock().unwrap()[0]["streamEvents"], true);
        let events = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events;
        assert!(
            !events
                .iter()
                .any(|event| event.author_membership_id.as_deref() == Some(agent_id.as_str()))
        );
    }

    #[test]
    fn strategy_bound_plain_post_starts_the_graph_without_mention_turns() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured = Arc::clone(&calls);
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| {
                panic!("plain strategy post must not start a mention turn")
            })
            .with_active_turns(|_| json!({"turns": []}))
            .with_strategy_execute(move |request| {
                captured.lock().unwrap().push(request.clone());
                let action = request.get("action").and_then(Value::as_str).unwrap_or("");
                if action == "strategy.run.active" {
                    Ok(json!({"ok": true, "result": {"runId": null}}))
                } else {
                    Ok(json!({
                        "ok": true,
                        "result": {
                            "runId": "run-1",
                            "status": "running",
                            "entryTurn": {
                                "turnHandle": "dispatch:entry",
                                "membershipId": "membership:entry",
                                "agent": "one"
                            }
                        }
                    }))
                }
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "start the graph"
            }),
        );
        assert!(posted["directTurns"].as_array().unwrap().is_empty());
        assert!(posted.get("strategyError").is_none());
        assert_eq!(posted["turns"][0]["turnHandle"], "dispatch:entry");
        assert_eq!(posted["turns"][0]["membershipId"], "membership:entry");
        assert_eq!(posted["turns"][0]["agent"], "one");
        assert_eq!(posted["dispatchPending"], true);
        let actions = calls
            .lock()
            .unwrap()
            .iter()
            .map(|request| request["action"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            actions,
            vec![
                "strategy.run.active".to_owned(),
                "strategy.run.start".to_owned()
            ]
        );
        assert_eq!(
            calls.lock().unwrap()[1]["input"]["message"],
            "start the graph"
        );
        assert_eq!(calls.lock().unwrap()[1]["conversationId"], conversation_id);
    }

    #[test]
    fn in_flight_follow_up_steers_instead_of_starting_a_mention_turn() {
        let steers = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured = Arc::clone(&steers);
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| panic!("in-flight follow-up must steer"))
            .with_active_turns(|conversation_id| {
                json!({
                    "turns": [{
                        "turnHandle": "dispatch:live",
                        "conversationId": conversation_id,
                        "membershipId": "membership:ignored",
                        "agent": "one"
                    }]
                })
            })
            .with_steer_turn(move |params| {
                captured.lock().unwrap().push(params.clone());
                Ok(json!({"ok": true, "status": "accepted"}))
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "steer please"
            }),
        );
        assert_eq!(posted["turns"][0]["turnHandle"], "dispatch:live");
        assert_eq!(posted["dispatchPending"], true);
        assert!(posted.get("strategyError").is_none());
        assert_eq!(steers.lock().unwrap()[0]["text"], "steer please");
        assert_eq!(steers.lock().unwrap()[0]["turnHandle"], "dispatch:live");
    }

    #[test]
    fn in_flight_steer_failure_is_reported_without_restarting_the_turn() {
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| panic!("a failed steer must not restart"))
            .with_active_turns(|conversation_id| {
                json!({
                    "turns": [{
                        "turnHandle": "dispatch:live",
                        "conversationId": conversation_id,
                        "membershipId": "membership:agent",
                        "agent": "one"
                    }]
                })
            })
            .with_steer_turn(|_| {
                Err(crate::platform::runtime_adapters::RuntimeAdapterError::ConversationDispatchFailed)
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "follow up"
            }),
        );
        assert_eq!(posted["turns"][0]["turnHandle"], "dispatch:live");
        assert_eq!(posted["dispatchPending"], true);
        assert_eq!(
            posted["strategyError"],
            json!({
                "code": "conversation_dispatch_failed",
                "stage": "conversation/steer"
            })
        );
    }

    #[test]
    fn known_unsupported_steer_queues_one_membership_turn_at_the_boundary() {
        let base = ConversationService::from_store(ConversationStore::open_in_memory().unwrap());
        let (conversation_id, owner_id, agent_id) = group_fixture(&base);
        let active_conversation = conversation_id.clone();
        let active_membership = agent_id.clone();
        let service = base
            .with_native_turn_sender(|_| panic!("boundary follow-up must not start early"))
            .with_active_turns(move |_| {
                json!({"turns": [{
                    "turnHandle": "dispatch:live",
                    "conversationId": active_conversation,
                    "membershipId": active_membership,
                    "agent": "one"
                }]})
            })
            .with_steer_turn(|_| Ok(json!({"ok": false, "status": "unsupported"})));
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "follow after the active turn"
            }),
        );
        assert!(posted.get("strategyError").is_none());
        assert_eq!(posted["directTurns"].as_array().unwrap().len(), 1);
        assert_eq!(posted["directTurns"][0]["state"], "pending");
        assert_eq!(posted["turns"][0]["turnHandle"], "dispatch:live");
    }

    #[test]
    fn waiting_follow_up_resumes_the_run_without_a_new_handle() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured = Arc::clone(&calls);
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| panic!("waiting follow-up must resume"))
            .with_active_turns(|_| json!({"turns": []}))
            .with_strategy_execute(move |request| {
                captured.lock().unwrap().push(request.clone());
                let action = request.get("action").and_then(Value::as_str).unwrap_or("");
                if action == "strategy.run.active" {
                    Ok(json!({"ok": true, "result": {"runId": "run-1", "status": "waiting"}}))
                } else {
                    assert_eq!(action, "strategy.run.resume");
                    Ok(json!({"ok": true, "result": {"runId": "run-1", "status": "running"}}))
                }
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "continue"
            }),
        );
        assert!(posted["turns"].as_array().unwrap().is_empty());
        assert_eq!(posted["dispatchPending"], false);
        assert!(posted.get("strategyError").is_none());
        let actions = calls
            .lock()
            .unwrap()
            .iter()
            .map(|request| request["action"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            actions,
            vec![
                "strategy.run.active".to_owned(),
                "strategy.run.resume".to_owned()
            ]
        );
        assert_eq!(calls.lock().unwrap()[1]["runId"], "run-1");
        assert_eq!(calls.lock().unwrap()[1]["conversationId"], conversation_id);
    }

    #[test]
    fn running_graph_follow_up_resumes_without_synthesizing_a_start_failure() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured = Arc::clone(&calls);
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| panic!("running graph must not start a mention turn"))
            .with_active_turns(|_| json!({"turns": []}))
            .with_strategy_execute(move |request| {
                captured.lock().unwrap().push(request.clone());
                let action = request.get("action").and_then(Value::as_str).unwrap_or("");
                if action == "strategy.run.active" {
                    Ok(json!({"ok": true, "result": {"runId": "run-1", "status": "running"}}))
                } else {
                    assert_eq!(action, "strategy.run.resume");
                    Ok(json!({"ok": true, "result": {"runId": "run-1", "status": "running"}}))
                }
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "still running"
            }),
        );
        assert!(posted["turns"].as_array().unwrap().is_empty());
        assert_eq!(posted["dispatchPending"], false);
        assert!(
            posted.get("strategyError").is_none(),
            "a resume without a fresh entry handle is not a failure"
        );
        let actions = calls
            .lock()
            .unwrap()
            .iter()
            .map(|request| request["action"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            actions,
            vec![
                "strategy.run.active".to_owned(),
                "strategy.run.resume".to_owned()
            ]
        );
        assert_eq!(calls.lock().unwrap()[1]["conversationId"], conversation_id);
    }

    #[test]
    fn strategy_start_failure_returns_an_inline_banner_error() {
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| panic!("failed start must not dispatch a mention turn"))
            .with_active_turns(|_| json!({"turns": []}))
            .with_strategy_execute(|request| {
                let action = request.get("action").and_then(Value::as_str).unwrap_or("");
                if action == "strategy.run.active" {
                    Ok(json!({"ok": true, "result": {"runId": null}}))
                } else {
                    Ok(json!({
                        "ok": false,
                        "error": {"code": "strategy_actor_quota_exhausted"}
                    }))
                }
            });
        let (conversation_id, owner_id, _) = group_fixture(&service);
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "start"
            }),
        );
        assert_eq!(
            posted["strategyError"]["code"],
            "strategy_actor_quota_exhausted"
        );
        assert_eq!(posted["strategyError"]["stage"], "strategy/start");
        assert_eq!(posted["dispatchPending"], false);
    }

    #[test]
    fn strategy_bound_dispatch_without_the_strategy_port_is_fail_closed() {
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_native_turn_sender(|_| panic!("fail-closed dispatch must not reach the runtime"))
            .with_active_turns(|_| json!({"turns": []}));
        let (conversation_id, owner_id, _) = group_fixture(&service);
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        let error = persist_then_dispatch_error(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "start"
            }),
        );
        assert_eq!(
            error,
            super::super::PERSISTENT_TRANSPORT_REQUIRED.to_owned()
        );
    }

    fn persist_then_dispatch_error(service: &ConversationService, request: Value) -> String {
        let persisted = service
            .execute(request.clone())
            .expect("persist posted message");
        let event_id = persisted["event"]["id"].clone();
        service
            .execute(json!({
                "action": "conversation.dispatch.after-post",
                "conversationId": request["conversationId"].clone(),
                "eventId": event_id,
            }))
            .expect_err("dispatch must reject")
            .to_string()
    }

    #[test]
    fn clearing_strategy_does_not_cancel_or_execute_a_run() {
        let service = ConversationService::from_store(ConversationStore::open_in_memory().unwrap())
            .with_strategy_execute(|_| panic!("clearing the capsule must not touch the run"));
        let (conversation_id, _, _) = group_fixture(&service);
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": "revision-one"
            }))
            .unwrap();
        service
            .execute(json!({
                "action": "conversation.strategy.set",
                "conversationId": conversation_id,
                "strategyRevision": null
            }))
            .unwrap();
        let conversation = service.store().get(&conversation_id).unwrap();
        assert!(conversation.strategy_revision.is_none());
    }
    #[test]
    fn assistant_designation_profile_actions_and_candidate_projection_are_bounded() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let (conversation_id, owner_id, agent_one) = group_fixture(&service);
        let agent_two = service
            .execute(json!({
                "action": "conversation.membership.add",
                "conversationId": conversation_id,
                "principal": {
                    "id": "agent:two",
                    "kind": "agent",
                    "displayName": "Two",
                    "agentId": "two",
                },
                "access": "member",
            }))
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();

        let conversation_revision = service.store().get(&conversation_id).unwrap().revision;
        service
            .execute(json!({
                "action": "conversation.assistant.set",
                "conversationId": conversation_id,
                "ownerMembershipId": owner_id,
                "expectedRevision": conversation_revision,
                "membershipId": agent_one,
            }))
            .unwrap();
        let conversation = service.store().get(&conversation_id).unwrap();
        assert_eq!(
            conversation.assistant_membership_id.as_deref(),
            Some(agent_one.as_str())
        );

        let intent = json!({
            "requiredCapabilities": [],
            "preferredCapabilities": ["workspace"],
            "skillReferences": [],
            "preferredModel": "model-a",
            "preferredReasoningEffort": "high",
            "preferredEnvironment": "local",
        });
        for membership_id in [&agent_one, &agent_two] {
            let expected_revision = service
                .store()
                .membership_profile(membership_id)
                .unwrap()
                .unwrap()
                .revision;
            let updated = service
                .execute(json!({
                    "action": "conversation.profile.update",
                    "conversationId": conversation_id,
                    "membershipId": membership_id,
                    "ownerMembershipId": owner_id,
                    "expectedRevision": expected_revision,
                    "intent": intent,
                }))
                .unwrap();
            assert_eq!(updated["profile"]["revision"], expected_revision + 1);
        }
        let stored = service
            .execute(json!({
                "action": "conversation.profile.get",
                "membershipId": agent_one,
            }))
            .unwrap();
        assert_eq!(stored["revision"], 2);
        assert_eq!(stored["preferredModel"], "model-a");
        assert_eq!(stored["preferredReasoningEffort"], "high");
        assert_eq!(stored["responsibility"], "assistant");
        assert!(
            stored["skillReferences"]
                .as_array()
                .unwrap()
                .iter()
                .any(|skill| skill == "assistant-workflow-authoring")
        );

        let candidates = service
            .execute(json!({
                "action": "conversation.profile.candidates",
                "conversationId": conversation_id,
            }))
            .unwrap();
        assert_eq!(candidates["candidates"].as_array().unwrap().len(), 2);
        assert_eq!(
            candidates["routeReceipt"]["rankedMembershipIds"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(
            candidates["routeReceipt"]["sourceRevisions"]
                .as_array()
                .unwrap()
                .iter()
                .all(|source| source["revision"] != "local-current")
        );

        let hard_failure = service
            .execute(json!({
                "action": "conversation.profile.candidates",
                "conversationId": conversation_id,
                "filters": {"membershipIds": ["membership:missing"]},
            }))
            .expect_err("a missing exact binding must reject before any effect");
        assert_eq!(hard_failure.to_string(), "profile_candidate_rejected");
    }

    #[test]
    fn designated_group_plain_message_dispatches_to_the_assistant_membership_turn() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |params| {
                captured_calls.lock().unwrap().push(params.clone());
                Ok(accepted_receipt(params))
            },
        );
        let (conversation_id, owner_id, agent_one) = group_fixture(&service);
        let conversation_revision = service.store().get(&conversation_id).unwrap().revision;
        service
            .execute(json!({
                "action": "conversation.assistant.set",
                "conversationId": conversation_id,
                "ownerMembershipId": owner_id,
                "expectedRevision": conversation_revision,
                "membershipId": agent_one,
            }))
            .unwrap();
        let profile_revision = service
            .store()
            .membership_profile(&agent_one)
            .unwrap()
            .unwrap()
            .revision;
        service
            .execute(json!({
                "action": "conversation.profile.update",
                "conversationId": conversation_id,
                "membershipId": agent_one,
                "ownerMembershipId": owner_id,
                "expectedRevision": profile_revision,
                "intent": {
                    "preferredModel": "model-a",
                    "preferredReasoningEffort": "high"
                }
            }))
            .unwrap();

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "plain message without a mention",
            }),
        );
        assert_eq!(posted["dispatchPending"], true);
        assert_eq!(posted["directTurns"].as_array().unwrap().len(), 1);
        assert_eq!(posted["directTurns"][0]["state"], "running");
        assert_eq!(posted["turns"][0]["membershipId"], agent_one);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["membershipId"], agent_one);
        let text = calls[0]["text"].as_str().unwrap();
        assert!(text.starts_with("Respond directly to the user's request."));
        assert!(text.contains("Respond directly to the user's request."));
        assert!(text.contains("Use tools only when the current request requires them."));
        assert!(text.contains("Do not start, resume, or invent unrelated work."));
        assert!(!text.contains("use tools freely"));
        assert!(text.ends_with("plain message without a mention"));
        assert!(calls[0].get("privateInstructions").is_none());
        assert!(calls[0].get("timeoutMs").is_none());
        assert_eq!(calls[0]["streamEvents"], true);
        assert_eq!(calls[0]["model"], "model-a");
        assert_eq!(calls[0]["reasoningEffort"], "high");
    }

    #[test]
    fn plain_group_follow_up_steers_only_the_designated_assistant_turn() {
        let steers = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_steers = Arc::clone(&steers);
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        )
        .with_native_turn_sender(|_| panic!("active turns must be steered, not restarted"))
        .with_steer_turn(move |params| {
            captured_steers.lock().unwrap().push(params.clone());
            Ok(json!({"ok": true, "status": "accepted"}))
        });
        let (conversation_id, owner_id, agent_one) = group_fixture(&service);
        let agent_two = service
            .execute(json!({
                "action": "conversation.membership.add",
                "conversationId": conversation_id,
                "principal": {"id": "agent:two", "kind": "agent", "displayName": "Two", "agentId": "two"},
                "access": "member",
            }))
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let active_turns = vec![
            json!({"turnHandle": "turn:assistant", "conversationId": conversation_id, "membershipId": agent_one, "agent": "one"}),
            json!({"turnHandle": "turn:member", "conversationId": conversation_id, "membershipId": agent_two, "agent": "two"}),
        ];
        let service = service.with_active_turns(move |_| json!({"turns": active_turns}));
        let conversation_revision = service.store().get(&conversation_id).unwrap().revision;
        service
            .execute(json!({
                "action": "conversation.assistant.set",
                "conversationId": conversation_id,
                "ownerMembershipId": owner_id,
                "expectedRevision": conversation_revision,
                "membershipId": agent_one,
            }))
            .unwrap();

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "continue the goal",
            }),
        );
        assert!(posted.get("strategyError").is_none());
        let recorded = steers.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        assert_eq!(recorded[0]["turnHandle"], "turn:assistant");
        assert_eq!(recorded[0]["text"], "continue the goal");
    }

    #[test]
    fn plain_group_follow_up_without_an_assistant_never_fans_out_to_active_turns() {
        let steers = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_steers = Arc::clone(&steers);
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        )
        .with_native_turn_sender(|_| panic!("ambiguous active turns must not be restarted"))
        .with_steer_turn(move |params| {
            captured_steers.lock().unwrap().push(params.clone());
            Ok(json!({"ok": true, "status": "accepted"}))
        });
        let (conversation_id, owner_id, agent_one) = group_fixture(&service);
        let agent_two = service
            .execute(json!({
                "action": "conversation.membership.add",
                "conversationId": conversation_id,
                "principal": {"id": "agent:two", "kind": "agent", "displayName": "Two", "agentId": "two"},
                "access": "member",
            }))
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let active_turns = vec![
            json!({"turnHandle": "turn:one", "conversationId": conversation_id, "membershipId": agent_one, "agent": "one"}),
            json!({"turnHandle": "turn:two", "conversationId": conversation_id, "membershipId": agent_two, "agent": "two"}),
        ];
        let service = service.with_active_turns(move |_| json!({"turns": active_turns}));

        let posted = persist_then_dispatch(
            &service,
            json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "ambiguous follow up",
            }),
        );
        assert_eq!(
            posted["strategyError"]["code"],
            "conversation_address_ambiguous"
        );
        assert!(steers.lock().unwrap().is_empty());
    }

    #[test]
    fn subagent_edge_projects_inbound_without_identifiers() {
        let service = ConversationService::from_store(
            crate::domain::client_conversation::ConversationStore::open_in_memory().unwrap(),
        );
        let group = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Mesh edge",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [
                    {"principal": {"id": "agent:one", "kind": "agent", "displayName": "One", "agentId": "one"}, "access": "member"},
                    {"principal": {"id": "agent:two", "kind": "agent", "displayName": "Two", "agentId": "two"}, "access": "member"}
                ]
            }))
            .unwrap();
        let conversation_id = group["id"].as_str().unwrap().to_owned();
        let memberships = group["memberships"].as_array().unwrap();
        let caller = memberships
            .iter()
            .find(|membership| membership["principal"]["agentId"] == "one")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let target = memberships
            .iter()
            .find(|membership| membership["principal"]["agentId"] == "two")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        service
            .store()
            .record_subagent_mcp_inbound(
                &conversation_id,
                Some(&caller),
                Some(&target),
                "lico_subagent_delegate",
                "accepted",
            )
            .unwrap();
        let edge = service
            .execute(json!({
                "action": "conversation.subagent.edge",
                "conversationId": conversation_id,
                "callerMembershipId": caller,
                "targetMembershipId": target,
            }))
            .unwrap();
        assert_eq!(edge["inbound"]["delegate"], true);
        assert_eq!(edge["inbound"]["continue"], false);
        assert_eq!(edge["inbound"]["cancel"], false);
        assert_eq!(edge["outcomes"]["delegate"], "accepted");
        assert_eq!(edge["outcomes"]["continue"], Value::Null);
        assert_eq!(edge["outcomes"]["cancel"], Value::Null);
        assert_eq!(edge["claimState"], Value::Null);
        assert_eq!(edge["dispatchState"], Value::Null);
        let wire = edge.to_string();
        assert!(!wire.contains(&conversation_id));
        assert!(!wire.contains(&caller));
        assert!(!wire.contains(&target));
    }
}
