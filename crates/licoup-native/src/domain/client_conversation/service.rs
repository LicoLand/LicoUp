use super::{
    ConversationStore, DirectTurn, MembershipAccess, NewEventPart, Principal, PrincipalKind,
    migrate_legacy_state,
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

/// Upper bound on direct turns dispatched to native runtimes in parallel.
/// Each worker is an independent runtime call; state leases are held only
/// around short local transactions, never across the runtime call itself.
pub const DEFAULT_DIRECT_TURN_WORKERS: usize = 4;

/// One application service for CLI, FFI, Conversation MCP, and Subagent MCP.
/// Transport adapters pass JSON envelopes here; domain validation remains in
/// `ConversationStore`. Strategy execution is a separate native authority.
#[derive(Clone)]
pub struct ConversationService {
    store: ConversationStore,
    native_turn_sender: Arc<NativeTurnSender>,
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
        Ok(Self::from_store(store))
    }

    pub fn from_store(store: ConversationStore) -> Self {
        Self {
            store,
            native_turn_sender: Arc::new(|params| {
                crate::platform::dispatch_lane_operation("send", params)
            }),
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
        self.native_turn_sender = Arc::new(native_turn_sender);
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
                Ok(json!({"ok": true}))
            }
            "conversation.archive" => {
                self.store.archive_conversation(
                    required_string(object, "conversationId")?,
                    object
                        .get("archived")
                        .and_then(Value::as_bool)
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                Ok(json!({"ok": true}))
            }
            "conversation.pin.set" => {
                self.store.set_conversation_pinned(
                    required_string(object, "conversationId")?,
                    object
                        .get("pinned")
                        .and_then(Value::as_bool)
                        .ok_or_else(|| anyhow!("invalid_request"))?,
                )?;
                Ok(json!({"ok": true}))
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
                let content = required_string(object, "content")?;
                let mention_ids = object
                    .get("mentionedMembershipIds")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect::<Vec<_>>()
                    })
                    .unwrap_or_default();
                let (event, pending_turns) = self.store.post_message_with_mentions(
                    conversation_id,
                    author,
                    content,
                    object.get("correlationId").and_then(Value::as_str),
                    &mention_ids,
                )?;
                let direct_turns = self.execute_direct_turns(pending_turns)?;
                let turn_receipts = direct_turns
                    .into_iter()
                    .map(|turn| json!({"id": turn.id, "state": turn.state}))
                    .collect::<Vec<_>>();
                Ok(json!({
                    "event": {"id": event.id, "state": "finalized"},
                    "directTurns": turn_receipts,
                }))
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
            _ => Err(anyhow!("unsupported_action")),
        }
    }

    fn execute_direct_turns(&self, pending_turns: Vec<DirectTurn>) -> Result<Vec<DirectTurn>> {
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
        let results = self.dispatch_direct_turns(&claimed);
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

    fn dispatch_direct_turns(&self, claimed: &[ClaimedTurn]) -> Vec<Result<DirectTurn>> {
        let results: Mutex<Vec<Option<Result<DirectTurn>>>> =
            Mutex::new((0..claimed.len()).map(|_| None).collect());
        let next = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..DEFAULT_DIRECT_TURN_WORKERS.min(claimed.len()) {
                let service = self.clone();
                let results = &results;
                let next = &next;
                scope.spawn(move || {
                    loop {
                        let index = next.fetch_add(1, Ordering::Relaxed);
                        if index >= claimed.len() {
                            break;
                        }
                        let result = service.run_direct_turn(&claimed[index]);
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

    fn run_direct_turn(&self, claimed: &ClaimedTurn) -> Result<DirectTurn> {
        let Some(context) = claimed.context.as_ref() else {
            return self.store.direct_turn(&claimed.turn_id);
        };
        let mut params = json!({
            "agentId": context.agent_id,
            "text": context.source_content,
            "streamEvents": false,
            "timeoutMs": 0,
            "conversationId": context.turn.conversation_id,
            "membershipId": context.turn.membership_id,
            "causationId": context.turn.source_event_id,
            "dispatchId": context.turn.id,
        });
        if let Some(session_id) = context.runtime_session_id.as_deref() {
            params["sessionId"] = json!(session_id);
        }
        if let Some(source_path) = context.runtime_conversation_path.as_deref() {
            params["sourcePath"] = json!(source_path);
        }
        if let Some(working_directory) = context.working_directory.as_deref() {
            params["workingDirectory"] = json!(working_directory);
        }
        #[cfg(test)]
        self.store.counters().begin_turn();
        let dispatched = (self.native_turn_sender)(&params);
        #[cfg(test)]
        self.store.counters().end_turn();
        match dispatched {
            Ok(value) if value.get("ok").and_then(Value::as_bool) == Some(true) => {
                if let Some(output) = value.get("output").and_then(Value::as_str) {
                    self.store.complete_direct_turn(
                        &claimed.turn_id,
                        output,
                        first_non_empty_text(&value, &["nativeSessionId", "sessionId"]),
                        first_non_empty_text(&value, &["sourcePath", "conversationPath"]),
                        first_non_empty_text(&value, &["workingDirectory"]),
                    )?;
                } else {
                    self.persist_direct_turn_failure(
                        &claimed.turn_id,
                        "terminal_result_invalid",
                        "conversation/terminal_result",
                    )?;
                }
            }
            Ok(value) => {
                let error = value.get("error").unwrap_or(&value);
                self.persist_direct_turn_failure(
                    &claimed.turn_id,
                    safe_failure_field(error, "code", "agent_conversation_dispatch_failed"),
                    safe_failure_field(error, "stage", "conversation/dispatch"),
                )?;
            }
            Err(error) => {
                let projected = serde_json::to_value(error.client_error())?;
                self.persist_direct_turn_failure(
                    &claimed.turn_id,
                    safe_failure_field(&projected, "code", "agent_conversation_dispatch_failed"),
                    safe_failure_field(&projected, "stage", "conversation/dispatch"),
                )?;
            }
        }
        self.store.direct_turn(&claimed.turn_id)
    }

    fn persist_direct_turn_failure(&self, turn_id: &str, code: &str, stage: &str) -> Result<()> {
        let diagnostic = serde_json::to_string(&json!({"code": code, "stage": stage}))?;
        self.store.fail_direct_turn(turn_id, &diagnostic)?;
        Ok(())
    }
}

/// A turn claimed for this fan-out: either with private execution context, or
/// without context when a concurrent claimant already owns it (its terminal
/// state is read back from the store).
struct ClaimedTurn {
    turn_id: String,
    context: Option<crate::domain::client_conversation::store::DirectTurnExecutionContext>,
}

fn first_non_empty_text<'a>(value: &'a Value, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        value
            .get(*key)
            .and_then(Value::as_str)
            .filter(|text| !text.trim().is_empty())
    })
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

fn ensure_allowed_fields(action: &str, object: &serde_json::Map<String, Value>) -> Result<()> {
    let allowed: &[&str] = match action {
        "conversation.create" => &["action", "title", "owner", "members"],
        "conversation.rename" => &["action", "conversationId", "title"],
        "conversation.archive" => &["action", "conversationId", "archived"],
        "conversation.pin.set" => &["action", "conversationId", "pinned"],
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
        ],
        "conversation.event.part.append" => &["action", "eventId", "part"],
        "conversation.event.finalize" => &["action", "eventId"],
        "conversation.membership.add" => &["action", "conversationId", "principal", "access"],
        "conversation.membership.access.set" => {
            &["action", "conversationId", "membershipId", "access"]
        }
        "conversation.membership.leave" => &["action", "conversationId", "membershipId"],
        "conversation.export" => &["action", "path", "conversationIds"],
        "conversation.import" => &["action", "path"],
        _ => return Err(anyhow!("unsupported_action")),
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(anyhow!("invalid_request"));
    }
    Ok(())
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
                Ok(json!({
                    "ok": true,
                    "output": "agent answer",
                    "nativeSessionId": "session-fixture",
                    "sourcePath": "/fixture/session.jsonl",
                    "workingDirectory": "/fixture/project"
                }))
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
        let agent_ids = memberships
            .iter()
            .filter(|membership| membership["principal"]["kind"] == "agent")
            .map(|membership| membership["id"].as_str().unwrap().to_owned())
            .collect::<Vec<_>>();
        assert_eq!(agent_ids.len(), 5);

        let service_for_post = service.clone();
        let conversation_id = conversation["id"].as_str().unwrap().to_owned();
        let post = std::thread::spawn(move || {
            service_for_post
                .execute(json!({
                    "action": "conversation.message.post",
                    "conversationId": conversation_id,
                    "authorMembershipId": owner_id,
                    "content": "run all",
                    "mentionedMembershipIds": agent_ids
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
            assert_eq!(receipt["state"], "succeeded");
            let turn_id = receipt["id"].as_str().unwrap();
            let turn = service.store().direct_turn(turn_id).unwrap();
            assert_eq!(turn.ordinal, index as i64, "receipt {index} out of order");
        }
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
    fn structured_mention_executes_once_and_persists_complete_agent_output() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_calls = Arc::clone(&calls);
        let output = format!("{}\0tail", "response-block-".repeat(100_000));
        assert!(output.len() > 1_048_576);
        let runtime_output = output.clone();
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |params| {
                captured_calls.lock().unwrap().push(params.clone());
                Ok(json!({
                    "ok": true,
                    "output": runtime_output,
                    "nativeSessionId": "session-fixture",
                    "sourcePath": "/fixture/session.jsonl",
                    "workingDirectory": "/fixture/project"
                }))
            },
        );
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);

        let posted = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "Please answer",
                "mentionedMembershipIds": [agent_id]
            }))
            .unwrap();

        assert_eq!(posted["directTurns"][0]["state"], "succeeded");
        assert_eq!(posted["event"]["state"], "finalized");
        assert!(posted["event"].get("parts").is_none());
        assert!(posted.to_string().len() < 1024);
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0]["agentId"], "one");
        assert_eq!(calls[0]["text"], "Please answer");
        assert_eq!(calls[0]["timeoutMs"], 0);
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
        let reply = events
            .iter()
            .find(|event| event.author_membership_id.as_deref() == Some(agent_id.as_str()))
            .unwrap();
        assert_eq!(reply.parts[0].content, output);
        assert_eq!(
            reply.causation_id,
            posted["event"]["id"].as_str().map(str::to_owned)
        );
        assert!(events.iter().any(|event| event.id == posted["event"]["id"]));
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
                    "output": "agent answer",
                    "nativeSessionId": "session-fixture"
                }))
            });
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);

        let posted = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "one answer",
                "mentionedMembershipIds": [agent_id]
            }))
            .unwrap();

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
        assert_eq!(replies[0].parts[0].content, "agent answer");
    }

    #[test]
    fn private_continuation_is_membership_scoped_and_non_pending_turns_never_replay() {
        let calls = Arc::new(Mutex::new(Vec::<Value>::new()));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |params| {
                captured_calls.lock().unwrap().push(params.clone());
                Ok(json!({
                    "ok": true,
                    "output": "done",
                    "nativeSessionId": "session-fixture",
                    "sourcePath": "/fixture/session.jsonl",
                    "workingDirectory": "/fixture/project"
                }))
            },
        );
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let post = |content: &str| {
            service
                .execute(json!({
                    "action": "conversation.message.post",
                    "conversationId": conversation_id,
                    "authorMembershipId": owner_id,
                    "content": content,
                    "mentionedMembershipIds": [agent_id]
                }))
                .unwrap()
        };
        let first = post("first");
        let _ = post("second");

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
        let bundle = std::env::temp_dir().join(format!(
            "lico-direct-turn-export-{}.json",
            uuid::Uuid::new_v4()
        ));
        service
            .store()
            .export_bundle(&bundle, std::slice::from_ref(&conversation_id))
            .unwrap();
        let exported = std::fs::read_to_string(&bundle).unwrap();
        assert!(!exported.contains("session-fixture"));
        assert!(!exported.contains("/fixture/session.jsonl"));
        assert!(!exported.contains("/fixture/project"));
        let _ = std::fs::remove_file(bundle);
    }

    #[test]
    fn ordinary_message_does_not_dispatch_and_runtime_failure_is_inline_and_redacted() {
        let calls = Arc::new(Mutex::new(0usize));
        let captured_calls = Arc::clone(&calls);
        let service = ConversationService::from_store_with_runtime(
            ConversationStore::open_in_memory().unwrap(),
            move |_| {
                *captured_calls.lock().unwrap() += 1;
                Ok(json!({
                    "ok": false,
                    "error": {
                        "code": "native_agent_executable_unavailable",
                        "stage": "process/launch",
                        "message": "private runtime detail must not persist",
                        "stderr": "secret backend output"
                    }
                }))
            },
        );
        let (conversation_id, owner_id, agent_id) = group_fixture(&service);
        let ordinary = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "ordinary",
                "mentionedMembershipIds": []
            }))
            .unwrap();
        assert!(ordinary["directTurns"].as_array().unwrap().is_empty());
        assert_eq!(*calls.lock().unwrap(), 0);

        let failed = service
            .execute(json!({
                "action": "conversation.message.post",
                "conversationId": conversation_id,
                "authorMembershipId": owner_id,
                "content": "run",
                "mentionedMembershipIds": [agent_id]
            }))
            .unwrap();
        assert_eq!(failed["directTurns"][0]["state"], "failed");
        assert_eq!(*calls.lock().unwrap(), 1);
        let events = service
            .store()
            .page_events(&conversation_id, None, 50)
            .unwrap()
            .events;
        assert!(events.iter().any(|event| event.id == failed["event"]["id"]));
        let diagnostic = events
            .iter()
            .flat_map(|event| &event.parts)
            .find(|part| part.kind == super::super::EventPartKind::Diagnostic)
            .unwrap();
        assert!(
            diagnostic
                .content
                .contains("native_agent_executable_unavailable")
        );
        assert!(diagnostic.content.contains("process/launch"));
        assert!(!diagnostic.content.contains("private runtime detail"));
        assert!(!diagnostic.content.contains("secret backend output"));
    }
}
