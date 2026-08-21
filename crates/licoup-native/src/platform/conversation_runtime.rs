//! Native execution adapter for the current delivery scheduler.

use crate::domain::client_conversation::{ConversationDispatch, ConversationStore, DispatchState};
use crate::domain::conversations;
use crate::domain::delivery_scheduler::{
    AdmittedConversation, DeliveryError, DeliveryExecutor, DeliveryResult, DispatchRequest,
    DispatchResult, TerminalState,
};
use crate::platform::{agent_workspace, dispatch_lane_operation, paths};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;

const MAX_MATCHES: u64 = 2;

/// One bounded request against the process-owned persistent Conversation
/// host: `agent.conversation.dispatch` opens, runs, and abandons one
/// Membership-scoped PersistentTurn internally and answers with an
/// attachable turn handle, and `agent.conversation.cancel` reaches the same
/// control plane. The port is injected so the adapter stays deterministic in
/// process; production composes the stdio-RPC transport where that helper
/// already exists. Host absence surfaces through the port as the typed
/// `persistent_conversation_transport_required` rejection, never as a
/// one-shot lane fallback.
pub type DeliveryHostRequest = Arc<dyn Fn(&str, &Value) -> DeliveryResult<Value> + Send + Sync>;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConversationAdmissionFailure {
    Relative,
    Missing,
    OutsideCatalog,
    Ambiguous,
    Unbounded,
}

impl ConversationAdmissionFailure {
    const fn code(self) -> &'static str {
        match self {
            Self::Relative => "conversation_location_relative",
            Self::Missing => "conversation_location_missing",
            Self::OutsideCatalog => "conversation_location_outside_catalog",
            Self::Ambiguous => "conversation_location_ambiguous",
            Self::Unbounded => "conversation_location_unbounded",
        }
    }
}

/// Delivery execution adapter bound to the persistent host. The adapter
/// holds the canonical Conversation store so terminal evidence is one read
/// of the canonical dispatch record under the durable Delivery dispatch
/// identity; the persistent host remains the sole turn owner and frame
/// publisher, and no Delivery-side mirror of turn state exists.
#[derive(Clone)]
pub struct NativeDeliveryRuntime {
    host: DeliveryHostRequest,
    store: ConversationStore,
}

impl NativeDeliveryRuntime {
    /// The host door is required at construction: no Delivery path can exist
    /// that would fall back to a one-shot lane.
    pub fn new(host: DeliveryHostRequest, store: ConversationStore) -> Self {
        Self { host, store }
    }

    fn admission_error(failure: ConversationAdmissionFailure) -> DeliveryError {
        DeliveryError::new(
            failure.code(),
            "conversation-admission",
            "native-catalog",
            false,
            "choose_one_exact_admitted_native_location",
        )
    }

    fn canonical_location(location: &str) -> Result<PathBuf, DeliveryError> {
        let path = Path::new(location);
        if !path.is_absolute() {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Relative,
            ));
        }
        let canonical = std::fs::canonicalize(path)
            .map_err(|_| Self::admission_error(ConversationAdmissionFailure::Missing))?;
        if !canonical.is_file() {
            return Err(Self::admission_error(ConversationAdmissionFailure::Missing));
        }
        let parent = canonical.parent().unwrap_or(&canonical);
        let home = paths::user_home_from_env();
        if agent_workspace::is_unbounded_agent_workspace(parent, home.as_deref()) {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Unbounded,
            ));
        }
        if let Ok(root) = paths::portable_data_dir()
            && canonical.starts_with(&root)
        {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Unbounded,
            ));
        }
        Ok(canonical)
    }

    fn exact_catalog_entry(agent_id: &str, location: &str) -> DeliveryResult<Value> {
        let canonical = Self::canonical_location(location)?;
        let canonical_text = canonical.to_string_lossy().into_owned();
        let response = conversations::conversation_list(&json!({
            "agent": agent_id,
            "matchProjectPath": canonical_text,
            "limit": MAX_MATCHES
        }))
        .map_err(|_| {
            DeliveryError::new(
                "conversation_catalog_unavailable",
                "conversation-admission",
                "native-catalog",
                true,
                "retry_after_catalog_recovers",
            )
        })?;
        let sessions = response
            .get("sessions")
            .and_then(Value::as_array)
            .ok_or_else(|| Self::admission_error(ConversationAdmissionFailure::OutsideCatalog))?;
        let exact = sessions
            .iter()
            .filter(|session| {
                session.get("sourcePath").and_then(Value::as_str) == Some(canonical_text.as_str())
            })
            .collect::<Vec<_>>();
        if exact.is_empty() {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::OutsideCatalog,
            ));
        }
        if exact.len() != 1 {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Ambiguous,
            ));
        }
        Ok(exact[0].clone())
    }

    fn exact_catalog_session(agent_id: &str, session_id: &str) -> DeliveryResult<Value> {
        let response = conversations::conversation_list(&json!({
            "agent": agent_id,
            "sessionId": session_id,
            "limit": MAX_MATCHES
        }))
        .map_err(|_| {
            DeliveryError::new(
                "conversation_catalog_unavailable",
                "conversation-admission",
                "native-catalog",
                true,
                "retry_after_catalog_recovers",
            )
        })?;
        let sessions = response
            .get("sessions")
            .and_then(Value::as_array)
            .ok_or_else(|| Self::admission_error(ConversationAdmissionFailure::OutsideCatalog))?;
        let exact = sessions
            .iter()
            .filter(|session| {
                session
                    .get("nativeSessionId")
                    .or_else(|| session.get("sessionId"))
                    .or_else(|| session.get("id"))
                    .and_then(Value::as_str)
                    == Some(session_id)
            })
            .collect::<Vec<_>>();
        if exact.is_empty() {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::OutsideCatalog,
            ));
        }
        if exact.len() != 1 {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Ambiguous,
            ));
        }
        let source_path = exact[0]
            .get("sourcePath")
            .and_then(Value::as_str)
            .filter(|path| !path.is_empty())
            .ok_or_else(|| Self::admission_error(ConversationAdmissionFailure::OutsideCatalog))?;
        Self::exact_catalog_entry(agent_id, source_path)
    }

    fn binding(agent_id: &str, session_id: &str) -> String {
        format!("native:{}:{}", agent_id, session_id)
    }

    /// Read the canonical dispatch record for one durable Delivery dispatch
    /// identity. This is the single dispatch bookkeeping read: the record is
    /// the terminal evidence source for dispatch replay, reconciliation, and
    /// cancellation.
    fn canonical_record(&self, dispatch_id: &str) -> DeliveryResult<Option<ConversationDispatch>> {
        let record = self
            .store
            .dispatch_record(dispatch_id)
            .map_err(|_| Self::public_runtime_error("conversation_state_unavailable", true))?;
        if record
            .as_ref()
            .is_some_and(|record| record.operation != "send")
        {
            // A caller-selected identity that belongs to another canonical
            // operation is not replay evidence for this Delivery attempt.
            return Err(Self::native_effect_in_doubt());
        }
        Ok(record)
    }

    /// Project the canonical dispatch record as Delivery terminal evidence. A
    /// live turn (running, or cancel requested but not yet arbitrated) stays
    /// pending; a terminal record projects its terminal state; a
    /// persisted-but-uncommitted record — absent, or still merely accepted
    /// after a host or process restart — settles as a retryable failure with
    /// the existing typed terminal code instead of opening a second turn.
    fn canonical_terminal(record: Option<ConversationDispatch>) -> TerminalState {
        match record {
            None => TerminalState::Failed,
            Some(record) => match record.state {
                DispatchState::Running | DispatchState::CancelRequested => TerminalState::Pending,
                DispatchState::Completed => TerminalState::Completed,
                DispatchState::Cancelled => TerminalState::Cancelled,
                DispatchState::Accepted | DispatchState::Failed => TerminalState::Failed,
            },
        }
    }

    fn public_runtime_error(code: &'static str, retryable: bool) -> DeliveryError {
        DeliveryError::new(
            code,
            "native-dispatch",
            "persistent-host",
            retryable,
            if retryable {
                "retry_after_native_lane_recovers"
            } else {
                "inspect_typed_terminal_failure"
            },
        )
    }

    fn native_effect_in_doubt() -> DeliveryError {
        DeliveryError::new(
            "native_effect_in_doubt",
            "native-dispatch",
            "persistent-host",
            true,
            "reconcile_exact_conversation_before_retry",
        )
    }
}

impl DeliveryExecutor for NativeDeliveryRuntime {
    fn prepare_conversation(
        &self,
        agent_id: &str,
        working_directory: &str,
        existing: Option<&str>,
    ) -> DeliveryResult<AdmittedConversation> {
        if let Some(location) = existing {
            let entry = Self::exact_catalog_entry(agent_id, location)?;
            let source_path = entry
                .get("sourcePath")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    Self::admission_error(ConversationAdmissionFailure::OutsideCatalog)
                })?;
            let source = Self::canonical_location(source_path)?;
            let session_id = entry
                .get("nativeSessionId")
                .or_else(|| entry.get("sessionId"))
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| {
                    Self::admission_error(ConversationAdmissionFailure::OutsideCatalog)
                })?;
            let cwd = entry
                .get("workingDirectory")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .or_else(|| (!working_directory.is_empty()).then_some(working_directory))
                .ok_or_else(|| Self::admission_error(ConversationAdmissionFailure::Missing))?;
            if !Path::new(cwd).is_absolute() {
                return Err(Self::admission_error(
                    ConversationAdmissionFailure::Relative,
                ));
            }
            let cwd = std::fs::canonicalize(cwd)
                .map_err(|_| Self::admission_error(ConversationAdmissionFailure::Missing))?;
            if !cwd.is_dir()
                || agent_workspace::is_unbounded_agent_workspace(
                    &cwd,
                    paths::user_home_from_env().as_deref(),
                )
            {
                return Err(Self::admission_error(
                    ConversationAdmissionFailure::Unbounded,
                ));
            }
            if let Ok(root) = paths::portable_data_dir()
                && cwd.starts_with(&root)
            {
                return Err(Self::admission_error(
                    ConversationAdmissionFailure::Unbounded,
                ));
            }
            return Ok(AdmittedConversation {
                agent_id: agent_id.to_owned(),
                session_id: session_id.to_owned(),
                source_path: source.to_string_lossy().into_owned(),
                working_directory: cwd.to_string_lossy().into_owned(),
                binding: Self::binding(agent_id, session_id),
            });
        }
        if working_directory.is_empty() || !Path::new(working_directory).is_absolute() {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Relative,
            ));
        }
        let cwd = std::fs::canonicalize(working_directory)
            .map_err(|_| Self::admission_error(ConversationAdmissionFailure::Missing))?;
        if !cwd.is_dir()
            || agent_workspace::is_unbounded_agent_workspace(
                &cwd,
                paths::user_home_from_env().as_deref(),
            )
        {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Unbounded,
            ));
        }
        if let Ok(root) = paths::portable_data_dir()
            && cwd.starts_with(&root)
        {
            return Err(Self::admission_error(
                ConversationAdmissionFailure::Unbounded,
            ));
        }
        let opened = dispatch_lane_operation(
            "open",
            &json!({"agent": agent_id, "workingDirectory": cwd.to_string_lossy()}),
        )
        .map_err(|_| Self::public_runtime_error("native_session_open_failed", true))?;
        let session_id = opened
            .get("nativeSessionId")
            .or_else(|| opened.get("sessionId"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                DeliveryError::new(
                    "native_effect_in_doubt",
                    "conversation-admission",
                    "persistent-host",
                    true,
                    "reconcile_exact_conversation_before_retry",
                )
            })?;
        let entry = Self::exact_catalog_session(agent_id, session_id)?;
        let source_path = entry
            .get("sourcePath")
            .and_then(Value::as_str)
            .ok_or_else(|| Self::admission_error(ConversationAdmissionFailure::OutsideCatalog))?;
        let source = Self::canonical_location(source_path)?;
        Ok(AdmittedConversation {
            agent_id: agent_id.to_owned(),
            session_id: session_id.to_owned(),
            source_path: source.to_string_lossy().into_owned(),
            working_directory: cwd.to_string_lossy().into_owned(),
            binding: Self::binding(agent_id, session_id),
        })
    }

    fn dispatch(&self, request: &DispatchRequest) -> DeliveryResult<DispatchResult> {
        // Structural idempotency: the durable Delivery dispatch identity is
        // the requested canonical dispatch identity, so the identity exists
        // before any turn opens and a duplicate open is impossible. An
        // existing canonical record projects its state instead of opening a
        // second turn.
        let existing = self.canonical_record(&request.dispatch_id)?;
        if existing.is_some() {
            return Ok(DispatchResult {
                conversation: request.conversation.clone(),
                terminal: Self::canonical_terminal(existing),
                usage: json!({}),
            });
        }
        let text = serde_json::to_string(&json!({
            "brief": request.brief,
            "nativeConversationLocation": request.conversation.source_path.clone()
        }))
        .map_err(|_| Self::public_runtime_error("brief_encode_failed", false))?;
        let mut params = json!({
            "agent": request.route.agent_id,
            "agentId": request.route.agent_id,
            "text": text,
            "sessionId": request.conversation.session_id,
            "workingDirectory": request.conversation.working_directory,
            "streamEvents": true,
            "dispatchId": request.dispatch_id,
            "causationId": "delivery.dispatch",
        });
        if let Some(model) = &request.route.model {
            params["model"] = json!(model);
        }
        if let Some(effort) = &request.route.reasoning_effort {
            params["reasoningEffort"] = json!(effort);
        }
        // The persistent host opens one Membership-scoped PersistentTurn
        // under the requested identity with streaming enabled, records
        // acceptance, and keeps executing in the background; the ACK carries
        // the attachable turn handle. Host absence is the typed
        // persistent-transport rejection propagated by the port.
        let accepted = (self.host)("agent.conversation.dispatch", &params)?;
        let receipt_conversation_id = accepted.get("conversationId").and_then(Value::as_str);
        let receipt_membership_id = accepted.get("membershipId").and_then(Value::as_str);
        if accepted.get("accepted").and_then(Value::as_bool) != Some(true)
            || accepted.get("turnHandle").and_then(Value::as_str)
                != Some(request.dispatch_id.as_str())
            || receipt_conversation_id.is_none_or(str::is_empty)
            || receipt_membership_id.is_none_or(str::is_empty)
        {
            return Err(Self::native_effect_in_doubt());
        }
        // An ACK is not acceptance evidence by itself. Verify that the host
        // committed the requested identity and the exact Conversation scope
        // carried by the receipt before Delivery reports the turn as pending.
        let record = self
            .canonical_record(&request.dispatch_id)?
            .ok_or_else(Self::native_effect_in_doubt)?;
        if record.conversation_id != receipt_conversation_id.unwrap_or_default()
            || record.membership_id != receipt_membership_id.unwrap_or_default()
            || record.state == DispatchState::Accepted
        {
            return Err(Self::native_effect_in_doubt());
        }
        Ok(DispatchResult {
            conversation: request.conversation.clone(),
            terminal: Self::canonical_terminal(Some(record)),
            usage: json!({}),
        })
    }

    fn reconcile(
        &self,
        dispatch_id: &str,
        _conversation: &AdmittedConversation,
    ) -> DeliveryResult<TerminalState> {
        Ok(Self::canonical_terminal(
            self.canonical_record(dispatch_id)?,
        ))
    }

    fn cancel(&self, dispatch_id: &str) -> DeliveryResult<()> {
        let Some(record) = self.canonical_record(dispatch_id)? else {
            // A never-opened dispatch needs no host call and is no failure.
            return Ok(());
        };
        if matches!(
            record.state,
            DispatchState::Completed | DispatchState::Failed | DispatchState::Cancelled
        ) {
            // An already-settled dispatch is an idempotent no-op.
            return Ok(());
        }
        // Each live dispatch receives exactly one control-plane cancel for
        // its recorded identity and Conversation scope; the host owns the
        // durable cancellation and terminal arbitration order.
        let result = (self.host)(
            "agent.conversation.cancel",
            &json!({
                "turnHandle": record.id,
                "conversationId": record.conversation_id,
            }),
        )?;
        if result.get("ok").and_then(Value::as_bool) == Some(true) {
            Ok(())
        } else {
            Err(Self::public_runtime_error("native_cancel_rejected", false))
        }
    }

    fn usage_snapshot(&self, conversation: &AdmittedConversation) -> DeliveryResult<Value> {
        let entry = Self::exact_catalog_entry(&conversation.agent_id, &conversation.source_path)?;
        let mut prompt_tokens = 0_u64;
        let mut cached_input_tokens = 0_u64;
        let mut completion_tokens = 0_u64;
        let mut model = "Others".to_owned();
        let mut found = false;
        if let Some(usage) = entry
            .get("usage")
            .and_then(crate::domain::agent_usage::workflow_ledger::NormalizedUsage::from_value)
        {
            prompt_tokens = usage.prompt_tokens;
            cached_input_tokens = usage.cached_input_tokens;
            completion_tokens = usage.completion_tokens;
            model = usage.model;
            found = true;
        } else if let Some(messages) = entry.get("messages").and_then(Value::as_array) {
            for message in messages.iter().take(10_000) {
                let Some(usage) = message.get("usage").and_then(
                    crate::domain::agent_usage::workflow_ledger::NormalizedUsage::from_value,
                ) else {
                    continue;
                };
                prompt_tokens = prompt_tokens.saturating_add(usage.prompt_tokens);
                cached_input_tokens = cached_input_tokens.saturating_add(usage.cached_input_tokens);
                completion_tokens = completion_tokens.saturating_add(usage.completion_tokens);
                if usage.model != "Others" {
                    model = usage.model;
                }
                found = true;
            }
        }
        if !found {
            model = "Others".to_owned();
        }
        cached_input_tokens = cached_input_tokens.min(prompt_tokens);
        Ok(json!({
            "promptTokens": prompt_tokens,
            "cachedInputTokens": cached_input_tokens,
            "completionTokens": completion_tokens,
            "totalTokens": prompt_tokens.saturating_add(completion_tokens),
            "model": model,
            "accuracy": "exact",
            "eventId": format!("snapshot:{}", conversation.session_id),
            "lineageScope": conversation.binding,
            "cumulative": true
        }))
    }
}

pub fn run_once(
    workflow_id: &str,
    engine: crate::domain::delivery_plan::DeliveryPlanEngine,
    config: crate::domain::delivery_scheduler::SchedulerConfig,
    runtime: &NativeDeliveryRuntime,
) -> DeliveryResult<crate::domain::delivery_scheduler::ScheduleReport> {
    let selector =
        crate::domain::delivery_scheduler::AdaptiveFlywheelRouteSelector::from_client_state()?;
    let mut scheduler = crate::domain::delivery_scheduler::DeliveryScheduler::new(
        workflow_id,
        engine,
        &selector,
        runtime,
        config,
    );
    scheduler.drive()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED;
    use crate::domain::delivery_plan::{ExecutionPolicy, Role, RoleBrief};
    use crate::domain::delivery_scheduler::{Difficulty, ROUTE_SELECTION_AUTHORITY, RouteReceipt};
    use std::sync::Mutex;

    fn test_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "licoup-delivery-runtime-{label}-{}",
            uuid::Uuid::new_v4()
        ))
    }

    fn open_store(root: &Path) -> ConversationStore {
        crate::platform::file_security::ensure_private_dir(root).unwrap();
        ConversationStore::open(root).unwrap()
    }

    fn insert_canonical_dispatch(database: &Path, dispatch_id: &str, state: &str, operation: &str) {
        let connection = rusqlite::Connection::open(database).unwrap();
        connection
            .pragma_update(None, "foreign_keys", "OFF")
            .unwrap();
        connection
            .execute(
                "INSERT INTO conversation_dispatches(
                   id, conversation_id, membership_id, operation, state, session_mode,
                   runtime_conversation_path, error_code, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, 'new', NULL, NULL, 1, 1)",
                rusqlite::params![
                    dispatch_id,
                    "conversation:delivery-seed",
                    "membership:delivery-seed",
                    operation,
                    state,
                ],
            )
            .unwrap();
    }

    /// Seed one canonical dispatch row exactly where the persistent host
    /// would commit it, without going through the host itself.
    fn seed_canonical_dispatch(root: &Path, dispatch_id: &str, state: &str) {
        let database = root
            .join("client-state")
            .join("conversations")
            .join("conversations.sqlite3");
        insert_canonical_dispatch(&database, dispatch_id, state, "send");
    }

    struct FakeHost {
        calls: Mutex<Vec<(String, Value)>>,
    }

    impl FakeHost {
        fn calls(&self) -> Vec<(String, Value)> {
            self.calls
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .clone()
        }
    }

    fn fake_host_with(
        respond: impl Fn(&str, &Value) -> DeliveryResult<Value> + Send + Sync + 'static,
    ) -> (DeliveryHostRequest, Arc<FakeHost>) {
        let fake = Arc::new(FakeHost {
            calls: Mutex::new(Vec::new()),
        });
        let probe = Arc::clone(&fake);
        let port: DeliveryHostRequest = Arc::new(move |method, params| {
            probe
                .calls
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .push((method.to_owned(), params.clone()));
            respond(method, params)
        });
        (port, fake)
    }

    fn fake_host(respond: DeliveryResult<Value>) -> (DeliveryHostRequest, Arc<FakeHost>) {
        fake_host_with(move |_, _| respond.clone())
    }

    fn committing_fake_host(store: ConversationStore) -> (DeliveryHostRequest, Arc<FakeHost>) {
        fake_host_with(move |method, params| {
            assert_eq!(method, "agent.conversation.dispatch");
            let dispatch_id = params["dispatchId"].as_str().unwrap();
            insert_canonical_dispatch(store.db_path(), dispatch_id, "running", "send");
            Ok(json!({
                "ok": true,
                "accepted": true,
                "turnHandle": dispatch_id,
                "conversationId": "conversation:delivery-seed",
                "membershipId": "membership:delivery-seed",
            }))
        })
    }

    fn delivery_request(dispatch_id: &str) -> DispatchRequest {
        DispatchRequest {
            workflow_id: "workflow-delivery".to_owned(),
            dispatch_id: dispatch_id.to_owned(),
            role: Role::Worker,
            task_code: Some("TASK-001".to_owned()),
            attempt: 1,
            route: RouteReceipt {
                role: Role::Worker,
                difficulty: Difficulty::Standard,
                agent_id: "worker-agent".to_owned(),
                model: None,
                reasoning_effort: None,
                authority: ROUTE_SELECTION_AUTHORITY.to_owned(),
            },
            brief: RoleBrief {
                role: Role::Worker,
                authority: "delivery-plan.worker".to_owned(),
                selected_decisions: Vec::new(),
                direct_inputs: Vec::new(),
                task: None,
                review: None,
                execution_policy: ExecutionPolicy::default(),
                repository_references: Vec::new(),
                native_conversation_location: None,
            },
            parent_conversation: None,
            conversation: AdmittedConversation {
                agent_id: "worker-agent".to_owned(),
                session_id: "native-session-1".to_owned(),
                source_path: "/fixture-root/conversations/worker.jsonl".to_owned(),
                working_directory: "/fixture-root/project".to_owned(),
                binding: "native:worker-agent:native-session-1".to_owned(),
            },
            working_directory: "/fixture-root/project".to_owned(),
        }
    }

    #[test]
    fn delivery_dispatch_opens_one_persistent_turn_with_the_shared_identity() {
        let root = test_root("open");
        let store = open_store(&root);
        let dispatch_id = "workflow-delivery:task:TASK-001:1";
        let (port, fake) = committing_fake_host(store.clone());
        let runtime = NativeDeliveryRuntime::new(port, store.clone());
        let result = runtime.dispatch(&delivery_request(dispatch_id)).unwrap();
        assert_eq!(result.terminal, TerminalState::Pending);
        let record = store.dispatch_record(dispatch_id).unwrap().unwrap();
        assert_eq!(record.id, dispatch_id);
        assert_eq!(record.operation, "send");
        assert_eq!(record.state, DispatchState::Running);
        let calls = fake.calls();
        assert_eq!(calls.len(), 1);
        let (method, params) = &calls[0];
        assert_eq!(method, "agent.conversation.dispatch");
        assert_eq!(params["dispatchId"], json!(dispatch_id));
        assert_eq!(params["streamEvents"], json!(true));
        assert_eq!(params["agent"], json!("worker-agent"));
        assert_eq!(params["sessionId"], json!("native-session-1"));
        assert_eq!(params["causationId"], json!("delivery.dispatch"));
        // The canonical Conversation scope is committed by the host, never
        // by a Delivery-side admission scope or duplicate bookkeeping row.
        assert!(params.get("conversationId").is_none());
        assert!(params.get("membershipId").is_none());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_dispatch_rejects_a_receipt_that_mismatches_the_requested_identity() {
        let root = test_root("receipt-mismatch");
        let store = open_store(&root);
        let accepted = json!({
            "ok": true,
            "accepted": true,
            "turnHandle": "dispatch:someone-else",
            "conversationId": "conversation:canonical",
            "membershipId": "membership:canonical",
        });
        let (port, _fake) = fake_host(Ok(accepted));
        let runtime = NativeDeliveryRuntime::new(port, store);
        let error = runtime
            .dispatch(&delivery_request("workflow-delivery:task:TASK-001:1"))
            .unwrap_err();
        assert_eq!(error.code, "native_effect_in_doubt");
        assert!(error.retryable);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_dispatch_rejects_a_receipt_scope_not_committed_by_the_host() {
        let root = test_root("receipt-scope-mismatch");
        let store = open_store(&root);
        let committed_store = store.clone();
        let (port, _fake) = fake_host_with(move |_, params| {
            let dispatch_id = params["dispatchId"].as_str().unwrap();
            insert_canonical_dispatch(committed_store.db_path(), dispatch_id, "running", "send");
            Ok(json!({
                "ok": true,
                "accepted": true,
                "turnHandle": dispatch_id,
                "conversationId": "conversation:wrong",
                "membershipId": "membership:delivery-seed",
            }))
        });
        let runtime = NativeDeliveryRuntime::new(port, store);
        let error = runtime
            .dispatch(&delivery_request("workflow-delivery:task:TASK-009:1"))
            .unwrap_err();
        assert_eq!(error.code, "native_effect_in_doubt");
        assert!(error.retryable);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_dispatch_replays_an_existing_canonical_record_without_a_second_turn() {
        for (state, expected) in [
            ("running", TerminalState::Pending),
            ("cancel-requested", TerminalState::Pending),
            ("completed", TerminalState::Completed),
            ("failed", TerminalState::Failed),
            ("cancelled", TerminalState::Cancelled),
            ("accepted", TerminalState::Failed),
        ] {
            let root = test_root("replay");
            let store = open_store(&root);
            let dispatch_id = "workflow-delivery:task:TASK-002:1";
            seed_canonical_dispatch(&root, dispatch_id, state);
            let (port, fake) = fake_host(Ok(json!({"ok": true})));
            let runtime = NativeDeliveryRuntime::new(port, store);
            let result = runtime.dispatch(&delivery_request(dispatch_id)).unwrap();
            assert_eq!(result.terminal, expected, "{state}");
            assert!(fake.calls().is_empty(), "{state}");
            let _ = std::fs::remove_dir_all(root);
        }
    }

    #[test]
    fn delivery_dispatch_rejects_an_identity_owned_by_another_canonical_operation() {
        let root = test_root("identity-conflict");
        let store = open_store(&root);
        let dispatch_id = "workflow-delivery:task:TASK-010:1";
        insert_canonical_dispatch(store.db_path(), dispatch_id, "running", "subagent.delegate");
        let (port, fake) = fake_host(Ok(json!({"ok": true})));
        let runtime = NativeDeliveryRuntime::new(port, store);
        let error = runtime
            .dispatch(&delivery_request(dispatch_id))
            .unwrap_err();
        assert_eq!(error.code, "native_effect_in_doubt");
        assert!(error.retryable);
        assert!(fake.calls().is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_reconcile_projects_each_canonical_state_with_zero_port_calls() {
        for (state, expected) in [
            ("running", TerminalState::Pending),
            ("cancel-requested", TerminalState::Pending),
            ("completed", TerminalState::Completed),
            ("failed", TerminalState::Failed),
            ("cancelled", TerminalState::Cancelled),
            ("accepted", TerminalState::Failed),
        ] {
            let root = test_root("reconcile");
            let store = open_store(&root);
            let dispatch_id = "workflow-delivery:task:TASK-003:1";
            seed_canonical_dispatch(&root, dispatch_id, state);
            let (port, fake) = fake_host(Ok(json!({"ok": true})));
            let runtime = NativeDeliveryRuntime::new(port, store);
            let request = delivery_request(dispatch_id);
            let terminal = runtime
                .reconcile(dispatch_id, &request.conversation)
                .unwrap();
            assert_eq!(terminal, expected, "{state}");
            assert!(fake.calls().is_empty(), "{state}");
            let _ = std::fs::remove_dir_all(root);
        }
    }

    #[test]
    fn delivery_reconcile_settles_a_persisted_but_uncommitted_dispatch_as_failed() {
        let root = test_root("uncommitted");
        let store = open_store(&root);
        let dispatch_id = "workflow-delivery:task:TASK-004:1";
        let (port, fake) = fake_host(Ok(json!({"ok": true})));
        let runtime = NativeDeliveryRuntime::new(port, store);
        let request = delivery_request(dispatch_id);
        let terminal = runtime
            .reconcile(dispatch_id, &request.conversation)
            .unwrap();
        assert_eq!(terminal, TerminalState::Failed);
        assert!(fake.calls().is_empty());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_dispatch_maps_host_absence_to_the_typed_persistent_transport_rejection() {
        let root = test_root("host-absent");
        let store = open_store(&root);
        let failure = DeliveryError::new(
            PERSISTENT_TRANSPORT_REQUIRED,
            "native-dispatch",
            "persistent-host",
            true,
            "retry_after_recovery",
        );
        let (port, fake) = fake_host(Err(failure));
        let runtime = NativeDeliveryRuntime::new(port, store);
        let error = runtime
            .dispatch(&delivery_request("workflow-delivery:task:TASK-005:1"))
            .unwrap_err();
        assert_eq!(error.code, PERSISTENT_TRANSPORT_REQUIRED);
        assert!(error.retryable);
        // The dispatch attempted only the persistent door: no other lane ran.
        assert_eq!(fake.calls().len(), 1);
        assert_eq!(fake.calls()[0].0, "agent.conversation.dispatch");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_cancel_reaches_the_control_plane_once_for_a_live_turn() {
        let root = test_root("cancel-live");
        let store = open_store(&root);
        let dispatch_id = "workflow-delivery:task:TASK-006:1";
        seed_canonical_dispatch(&root, dispatch_id, "running");
        let (port, fake) = fake_host(Ok(json!({"ok": true})));
        let runtime = NativeDeliveryRuntime::new(port, store);
        runtime.cancel(dispatch_id).unwrap();
        let calls = fake.calls();
        assert_eq!(calls.len(), 1);
        let (method, params) = &calls[0];
        assert_eq!(method, "agent.conversation.cancel");
        assert_eq!(params["turnHandle"], json!(dispatch_id));
        assert_eq!(
            params["conversationId"],
            json!("conversation:delivery-seed")
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn delivery_cancel_is_an_idempotent_noop_for_settled_or_unopened_dispatches() {
        for state in ["completed", "failed", "cancelled"] {
            let root = test_root("cancel-settled");
            let store = open_store(&root);
            let dispatch_id = "workflow-delivery:task:TASK-007:1";
            seed_canonical_dispatch(&root, dispatch_id, state);
            let (port, fake) = fake_host(Ok(json!({"ok": true})));
            let runtime = NativeDeliveryRuntime::new(port, store);
            runtime.cancel(dispatch_id).unwrap();
            assert!(fake.calls().is_empty(), "{state}");
            let _ = std::fs::remove_dir_all(root);
        }
        let root = test_root("cancel-unopened");
        let store = open_store(&root);
        let (port, fake) = fake_host(Ok(json!({"ok": true})));
        let runtime = NativeDeliveryRuntime::new(port, store);
        runtime.cancel("workflow-delivery:task:TASK-008:1").unwrap();
        assert!(fake.calls().is_empty());
        let _ = std::fs::remove_dir_all(root);
    }
}
