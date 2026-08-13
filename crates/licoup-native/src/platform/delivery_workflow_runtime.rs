//! Native execution adapter for the current delivery scheduler.

use crate::domain::conversations;
use crate::domain::delivery_workflow::{
    AdmittedConversation, DeliveryError, DeliveryExecutor, DeliveryResult, DispatchRequest,
    DispatchResult, TerminalState,
};
use crate::platform::{agent_workspace, dispatch_lane_operation, paths};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

const MAX_MATCHES: u64 = 2;

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

#[derive(Clone, Copy, Debug, Default)]
pub struct NativeDeliveryRuntime;

impl NativeDeliveryRuntime {
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
        let home = directories::UserDirs::new().map(|dirs| dirs.home_dir().to_path_buf());
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

    fn terminal(value: &Value) -> TerminalState {
        let status = value
            .get("turnStatus")
            .or_else(|| value.get("status"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_ascii_lowercase();
        if matches!(
            status.as_str(),
            "running" | "in-progress" | "pending" | "awaiting"
        ) {
            TerminalState::Pending
        } else if matches!(status.as_str(), "cancelled" | "canceled") {
            TerminalState::Cancelled
        } else if value.get("ok").and_then(Value::as_bool) == Some(false)
            || matches!(status.as_str(), "failed" | "error")
        {
            TerminalState::Failed
        } else {
            TerminalState::Completed
        }
    }

    fn public_runtime_error(code: &'static str, retryable: bool) -> DeliveryError {
        DeliveryError::new(
            code,
            "native-dispatch",
            "native-lane",
            retryable,
            if retryable {
                "retry_after_native_lane_recovers"
            } else {
                "inspect_typed_terminal_failure"
            },
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
                    directories::UserDirs::new()
                        .map(|dirs| dirs.home_dir().to_path_buf())
                        .as_deref(),
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
                directories::UserDirs::new()
                    .map(|dirs| dirs.home_dir().to_path_buf())
                    .as_deref(),
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
                    "native-lane",
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
            "streamEvents": false
        });
        if let Some(model) = &request.route.model {
            params["model"] = json!(model);
        }
        if let Some(effort) = &request.route.reasoning_effort {
            params["reasoningEffort"] = json!(effort);
        }
        let response = dispatch_lane_operation("send", &params).map_err(|_| {
            DeliveryError::new(
                "native_effect_in_doubt",
                "native-dispatch",
                "native-lane",
                true,
                "reconcile_exact_conversation_before_retry",
            )
        })?;
        let session_id = response
            .get("nativeSessionId")
            .or_else(|| response.get("sessionId"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                DeliveryError::new(
                    "native_effect_in_doubt",
                    "native-dispatch",
                    "native-lane",
                    true,
                    "reconcile_exact_conversation_before_retry",
                )
            })?;
        if session_id != request.conversation.session_id {
            return Err(DeliveryError::new(
                "native_effect_in_doubt",
                "native-dispatch",
                "native-lane",
                true,
                "reconcile_exact_conversation_before_retry",
            ));
        }
        Ok(DispatchResult {
            conversation: request.conversation.clone(),
            terminal: Self::terminal(&response),
            usage: response.get("usage").cloned().unwrap_or_else(|| json!({})),
        })
    }

    fn reconcile(&self, conversation: &AdmittedConversation) -> DeliveryResult<TerminalState> {
        let entry = Self::exact_catalog_entry(&conversation.agent_id, &conversation.source_path)?;
        if entry.get("failed").and_then(Value::as_bool) == Some(true) {
            return Ok(TerminalState::Failed);
        }
        if entry.get("cancelled").and_then(Value::as_bool) == Some(true) {
            return Ok(TerminalState::Cancelled);
        }
        // Historical assistant messages may predate the scheduled turn, so
        // their mere presence cannot prove this turn completed. Only the
        // native terminal status is authoritative during reconciliation.
        let status = entry
            .get("turnStatus")
            .or_else(|| entry.get("status"))
            .and_then(Value::as_str)
            .filter(|status| !status.trim().is_empty());
        Ok(status.map_or(TerminalState::Pending, |_| Self::terminal(&entry)))
    }

    fn cancel(&self, conversation: &AdmittedConversation) -> DeliveryResult<()> {
        let result = dispatch_lane_operation(
            "cancel",
            &json!({"agent": conversation.agent_id, "sessionId": conversation.session_id}),
        )
        .map_err(|_| Self::public_runtime_error("native_cancel_failed", true))?;
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
    config: crate::domain::delivery_workflow::SchedulerConfig,
) -> DeliveryResult<crate::domain::delivery_workflow::ScheduleReport> {
    let selector =
        crate::domain::delivery_workflow::AdaptiveFlywheelRouteSelector::from_client_state()?;
    let runtime = NativeDeliveryRuntime;
    let mut scheduler = crate::domain::delivery_workflow::DeliveryScheduler::new(
        workflow_id,
        engine,
        &selector,
        &runtime,
        config,
    );
    scheduler.drive()
}
