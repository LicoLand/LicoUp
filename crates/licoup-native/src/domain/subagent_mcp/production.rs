use super::{
    CallerContext, ConversationHostPort, McpApplicationError, ReadOnlyTargetPort,
    SubagentMcpApplication, TargetMembership, permanent,
};
use crate::domain::client_conversation::{Conversation, MembershipStatus, PrincipalKind};
use licoup_agent_runtime::{DurableNativeBinding, ProviderId};
use licoup_conversation::{SubagentDispatchClaim, SubagentDispatchClaimState};
use serde_json::{Map, Value, json};
use std::sync::Arc;

pub fn production_application() -> Result<SubagentMcpApplication, McpApplicationError> {
    Ok(SubagentMcpApplication::new(
        Arc::new(NativeConversationHost),
        crate::platform::runtime_adapters::production_subagent_registry(),
        Arc::new(NativeReadOnlyTargets),
    ))
}

struct NativeConversationHost;

impl NativeConversationHost {
    fn execute(&self, request: Value) -> Result<Value, McpApplicationError> {
        let response = crate::platform::subagent_mcp_host_client::execute_existing(
            "client.conversation.execute",
            &request,
        )
        .map_err(project_host_failure)?;
        response
            .get("result")
            .cloned()
            .ok_or_else(|| retryable("conversation_state_unavailable", "conversation/host"))
    }

    fn conversation(&self, conversation_id: &str) -> Result<Conversation, McpApplicationError> {
        serde_json::from_value(self.execute(json!({
            "action": "conversation.get",
            "conversationId": conversation_id,
        }))?)
        .map_err(|_| retryable("conversation_state_unavailable", "conversation/read"))
    }

    fn verified_caller<'a>(
        &self,
        caller: &CallerContext,
        conversation_id: &'a str,
    ) -> Result<&'a str, McpApplicationError> {
        let membership_id = caller.effect_scope(conversation_id)?;
        let conversation = self.conversation(conversation_id)?;
        let valid = conversation.memberships.iter().any(|membership| {
            membership.id == membership_id
                && membership.status == MembershipStatus::Active
                && membership.principal.kind == PrincipalKind::Agent
                && membership.principal.agent_id.as_deref() == Some(caller.provider_id.as_str())
        });
        if !valid {
            return Err(permanent(
                "caller_membership_not_authorized",
                "conversation/authorize",
            ));
        }
        Ok(conversation_id)
    }

    fn verified_assistant(
        &self,
        caller: &CallerContext,
        conversation_id: &str,
        expected_membership: Option<&str>,
    ) -> Result<(), McpApplicationError> {
        self.verified_caller(caller, conversation_id)?;
        let conversation = self.conversation(conversation_id)?;
        let assistant = conversation
            .assistant_membership_id
            .as_deref()
            .filter(|membership| Some(*membership) == caller.membership_id.as_deref())
            .filter(|membership| expected_membership.is_none_or(|expected| expected == *membership))
            .ok_or_else(|| {
                permanent(
                    "assistant_membership_not_authorized",
                    "conversation/authorize",
                )
            })?;
        if assistant.is_empty() {
            return Err(permanent(
                "assistant_membership_not_authorized",
                "conversation/authorize",
            ));
        }
        Ok(())
    }
}

impl ConversationHostPort for NativeConversationHost {
    fn verify_caller(
        &self,
        caller: &CallerContext,
        conversation_id: &str,
    ) -> Result<(), McpApplicationError> {
        self.verified_caller(caller, conversation_id).map(|_| ())
    }

    fn assistant_profiles(
        &self,
        caller: &CallerContext,
        arguments: &Map<String, Value>,
    ) -> Result<Value, McpApplicationError> {
        let conversation_id = arguments
            .get("conversationId")
            .and_then(Value::as_str)
            .ok_or_else(|| permanent("invalid_request", "schema/validate"))?;
        self.verified_assistant(caller, conversation_id, None)?;
        self.execute(json!({
            "action": "conversation.profile.candidates",
            "conversationId": conversation_id,
            "filters": arguments.get("filters").cloned().unwrap_or_else(|| json!({})),
        }))
    }

    fn assistant_workflow(
        &self,
        caller: &CallerContext,
        action: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Value, McpApplicationError> {
        let mut request = Value::Object(arguments.clone());
        request["action"] = json!(action);
        match action {
            "strategy.assistant.workflow.execute" => {
                let conversation_id = arguments
                    .get("conversationId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| permanent("invalid_request", "schema/validate"))?;
                let membership_id = arguments
                    .get("membershipId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| permanent("invalid_request", "schema/validate"))?;
                self.verified_assistant(caller, conversation_id, Some(membership_id))?;
                crate::platform::subagent_mcp_host_client::execute_existing(
                    "strategy.execute",
                    &request,
                )
                .map_err(|_| retryable("assistant_workflow_unavailable", "workflow/execute"))
            }
            "strategy.assistant.workflow.inspect" => {
                let value = crate::platform::subagent_mcp_host_client::execute_read_only(
                    "strategy.execute",
                    &request,
                )
                .map_err(|_| retryable("assistant_workflow_unavailable", "workflow/inspect"))?;
                let conversation_id = value
                    .get("conversationId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        permanent("assistant_workflow_not_authorized", "workflow/inspect")
                    })?;
                let membership_id = value
                    .get("assistantMembershipId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        permanent("assistant_workflow_not_authorized", "workflow/inspect")
                    })?;
                self.verified_assistant(caller, conversation_id, Some(membership_id))?;
                Ok(value)
            }
            "strategy.assistant.workflow.cancel" => {
                let mut inspect = request.clone();
                inspect["action"] = json!("strategy.assistant.workflow.inspect");
                let current = crate::platform::subagent_mcp_host_client::execute_read_only(
                    "strategy.execute",
                    &inspect,
                )
                .map_err(|_| retryable("assistant_workflow_unavailable", "workflow/inspect"))?;
                let conversation_id = current
                    .get("conversationId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        permanent("assistant_workflow_not_authorized", "workflow/cancel")
                    })?;
                let membership_id = current
                    .get("assistantMembershipId")
                    .and_then(Value::as_str)
                    .ok_or_else(|| {
                        permanent("assistant_workflow_not_authorized", "workflow/cancel")
                    })?;
                self.verified_assistant(caller, conversation_id, Some(membership_id))?;
                crate::platform::subagent_mcp_host_client::execute_existing(
                    "strategy.execute",
                    &request,
                )
                .map_err(|_| retryable("assistant_workflow_unavailable", "workflow/cancel"))
            }
            _ => Err(permanent("invalid_request", "workflow/select")),
        }
    }

    fn target_membership(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> Result<TargetMembership, McpApplicationError> {
        let target = self.execute(json!({
            "action": "conversation.subagent.target",
            "conversationId": conversation_id,
            "membershipId": membership_id,
        }))?;
        let provider_id = target
            .get("providerId")
            .and_then(Value::as_str)
            .ok_or_else(|| permanent("subagent_target_invalid", "conversation/authorize"))?;
        Ok(TargetMembership {
            conversation_id: conversation_id.to_owned(),
            membership_id: membership_id.to_owned(),
            provider_id: ProviderId::parse(provider_id.to_owned())
                .map_err(|_| permanent("subagent_target_invalid", "conversation/authorize"))?,
            preferred_model: target
                .get("preferredModel")
                .and_then(Value::as_str)
                .map(str::to_owned),
            preferred_reasoning_effort: target
                .get("preferredReasoningEffort")
                .and_then(Value::as_str)
                .map(str::to_owned),
        })
    }

    fn claim_dispatch(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
        parent_dispatch_id: Option<&str>,
    ) -> Result<SubagentDispatchClaim, McpApplicationError> {
        let value = self.execute(json!({
            "action": "conversation.subagent.claim",
            "conversationId": conversation_id,
            "callerMembershipId": caller_membership_id,
            "targetMembershipId": target_membership_id,
            "parentDispatchId": parent_dispatch_id,
        }))?;
        claim_from_value(value)
    }

    fn update_claim(
        &self,
        dispatch_id: &str,
        state: SubagentDispatchClaimState,
    ) -> Result<(), McpApplicationError> {
        self.execute(json!({
            "action": "conversation.subagent.claim.update",
            "dispatchId": dispatch_id,
            "state": state.as_str(),
        }))?;
        Ok(())
    }

    fn active_claim(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
    ) -> Result<Option<SubagentDispatchClaim>, McpApplicationError> {
        let value = self.execute(json!({
            "action": "conversation.subagent.claim.active",
            "conversationId": conversation_id,
            "callerMembershipId": caller_membership_id,
            "targetMembershipId": target_membership_id,
        }))?;
        if value.is_null() {
            Ok(None)
        } else {
            claim_from_value(value).map(Some)
        }
    }

    fn record_inbound(
        &self,
        conversation_id: &str,
        caller_membership_id: Option<&str>,
        target_membership_id: Option<&str>,
        tool: &str,
        outcome: &str,
    ) -> Result<(), McpApplicationError> {
        self.execute(json!({
            "action": "conversation.subagent.inbound.record",
            "conversationId": conversation_id,
            "callerMembershipId": caller_membership_id,
            "targetMembershipId": target_membership_id,
            "tool": tool,
            "outcome": outcome,
        }))?;
        Ok(())
    }

    fn latest_resume_binding(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> Result<DurableNativeBinding, McpApplicationError> {
        let target = self.target_membership(conversation_id, membership_id)?;
        let binding = self.execute(json!({
            "action": "conversation.subagent.binding.get",
            "conversationId": conversation_id,
            "membershipId": membership_id,
        }))?;
        if binding.is_null() {
            return Err(permanent("subagent_resume_unavailable", "identity/resolve"));
        }
        let runtime_session_id = binding
            .get("runtimeSessionId")
            .and_then(Value::as_str)
            .ok_or_else(|| permanent("subagent_resume_unavailable", "identity/resolve"))?;
        DurableNativeBinding::new(
            target.provider_id,
            runtime_session_id.to_owned(),
            binding
                .get("runtimeConversationPath")
                .and_then(Value::as_str)
                .map(str::to_owned),
            binding
                .get("workingDirectory")
                .and_then(Value::as_str)
                .map(str::to_owned),
        )
        .map_err(|_| permanent("subagent_resume_unavailable", "identity/resolve"))
    }
}

struct NativeReadOnlyTargets;

impl ReadOnlyTargetPort for NativeReadOnlyTargets {
    fn list(&self) -> Result<Value, McpApplicationError> {
        let targets = ["codex", "cursor", "antigravity"]
            .into_iter()
            .map(|provider| {
                crate::domain::targets::inspect_target_read_only(provider)
                    .map_err(|_| retryable("target_inventory_unavailable", "target/list"))?
                    .get("target")
                    .and_then(project_target)
                    .ok_or_else(|| retryable("target_inventory_unavailable", "target/list"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(json!({
            "schemaVersion": "licoup.subagents.v3",
            "count": targets.len(),
            "subagents": targets,
        }))
    }

    fn probe(&self, provider: &ProviderId) -> Result<Value, McpApplicationError> {
        let inspected = crate::domain::targets::inspect_target_read_only(provider.as_str())
            .map_err(|_| permanent("subagent_unavailable", "target/probe"))?;
        inspected
            .get("target")
            .and_then(project_target)
            .ok_or_else(|| permanent("subagent_unavailable", "target/probe"))
    }
}

fn project_target(target: &Value) -> Option<Value> {
    let agent_id = target.get("target").and_then(Value::as_str)?;
    if !matches!(agent_id, "codex" | "cursor" | "antigravity") {
        return None;
    }
    Some(json!({
        "agentId": agent_id,
        "status": target.get("status").and_then(Value::as_str).unwrap_or("unknown"),
        "conversationDriver": target.pointer("/adapterCapabilities/conversationDriver").and_then(Value::as_str).unwrap_or("unavailable"),
        "conversationReadiness": target.pointer("/adapterCapabilities/conversationReadiness").and_then(Value::as_str).unwrap_or("unverified"),
    }))
}

fn project_host_failure(error: anyhow::Error) -> McpApplicationError {
    match error.to_string().split(':').next().unwrap_or("") {
        "conversation_not_found" => permanent("conversation_not_found", "conversation/read"),
        "subagent_self_call_rejected" => permanent("subagent_self_call_rejected", "lineage/admit"),
        "subagent_caller_membership_inactive" => permanent(
            "subagent_caller_membership_inactive",
            "conversation/authorize",
        ),
        "subagent_target_membership_inactive" => permanent(
            "subagent_target_membership_inactive",
            "conversation/authorize",
        ),
        "subagent_duplicate_active_edge" => {
            permanent("subagent_duplicate_active_edge", "lineage/admit")
        }
        "subagent_parent_dispatch_unavailable" => {
            permanent("subagent_parent_dispatch_unavailable", "lineage/admit")
        }
        "subagent_cross_conversation_rejected" => {
            permanent("subagent_cross_conversation_rejected", "lineage/admit")
        }
        "subagent_lineage_caller_mismatch" => {
            permanent("subagent_lineage_caller_mismatch", "lineage/admit")
        }
        "subagent_repeated_ancestor" | "subagent_lineage_cycle" => {
            permanent("subagent_lineage_cycle", "lineage/admit")
        }
        "subagent_depth_exceeded" => permanent("subagent_depth_exceeded", "lineage/admit"),
        "subagent_dispatch_transition_invalid" => permanent(
            "subagent_dispatch_transition_invalid",
            "dispatch/transition",
        ),
        "subagent_dispatch_not_found" => {
            permanent("subagent_dispatch_not_found", "dispatch/transition")
        }
        "subagent_target_invalid" => permanent("subagent_target_invalid", "conversation/authorize"),
        "invalid_request" => permanent("invalid_request", "schema/validate"),
        _ => retryable("conversation_state_unavailable", "conversation/store"),
    }
}

fn claim_from_value(value: Value) -> Result<SubagentDispatchClaim, McpApplicationError> {
    let text = |field| {
        value
            .get(field)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| retryable("conversation_state_unavailable", "conversation/host"))
    };
    let state = match value.get("state").and_then(Value::as_str) {
        Some("claimed") => SubagentDispatchClaimState::Claimed,
        Some("running") => SubagentDispatchClaimState::Running,
        Some("cancel-requested") => SubagentDispatchClaimState::CancelRequested,
        Some("reconciliation-required") => SubagentDispatchClaimState::ReconciliationRequired,
        Some("completed") => SubagentDispatchClaimState::Completed,
        Some("failed") => SubagentDispatchClaimState::Failed,
        Some("cancelled") => SubagentDispatchClaimState::Cancelled,
        _ => {
            return Err(retryable(
                "conversation_state_unavailable",
                "conversation/host",
            ));
        }
    };
    Ok(SubagentDispatchClaim {
        id: text("id")?,
        conversation_id: text("conversationId")?,
        caller_membership_id: text("callerMembershipId")?,
        target_membership_id: text("targetMembershipId")?,
        parent_dispatch_id: value
            .get("parentDispatchId")
            .and_then(Value::as_str)
            .map(str::to_owned),
        depth: value
            .get("depth")
            .and_then(Value::as_u64)
            .and_then(|value| u8::try_from(value).ok())
            .ok_or_else(|| retryable("conversation_state_unavailable", "conversation/host"))?,
        state,
        created_at_unix_ms: value
            .get("createdAtUnixMs")
            .and_then(Value::as_i64)
            .ok_or_else(|| retryable("conversation_state_unavailable", "conversation/host"))?,
        updated_at_unix_ms: value
            .get("updatedAtUnixMs")
            .and_then(Value::as_i64)
            .ok_or_else(|| retryable("conversation_state_unavailable", "conversation/host"))?,
    })
}

fn retryable(code: &'static str, stage: &'static str) -> McpApplicationError {
    McpApplicationError::retryable(code, stage)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn production_construction_does_not_open_conversation_state() {
        let root = std::env::temp_dir().join(format!(
            "licoup-subagent-production-construction-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let application = production_application();
        crate::platform::paths::set_portable_data_dir_override(previous);

        assert!(application.is_ok());
        assert!(!root.join("conversations.sqlite3").exists());
        if root.exists() {
            std::fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn persistent_host_failures_keep_typed_safe_projection() {
        let duplicate = project_host_failure(anyhow::anyhow!("subagent_duplicate_active_edge"));
        assert_eq!(duplicate.code, "subagent_duplicate_active_edge");
        assert_eq!(duplicate.stage, "lineage/admit");
        assert!(!duplicate.retryable);

        let private = project_host_failure(anyhow::anyhow!("private database detail"));
        assert_eq!(private.code, "conversation_state_unavailable");
        assert_eq!(private.stage, "conversation/store");
        assert!(private.retryable);
    }

    #[test]
    fn target_projection_drops_user_labels_and_private_inventory() {
        let projected = project_target(&json!({
            "target": "cursor",
            "label": "private-user-label",
            "status": "detected",
            "binaryPath": "private-binary-canary",
            "model": "private-model",
            "adapterCapabilities": {
                "conversationDriver": "cursor-cli",
                "conversationReadiness": "ready"
            }
        }))
        .unwrap();
        assert_eq!(
            projected
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<std::collections::BTreeSet<_>>(),
            std::collections::BTreeSet::from([
                "agentId",
                "conversationDriver",
                "conversationReadiness",
                "status"
            ])
        );
        let wire = projected.to_string();
        assert!(!wire.contains("private"));
    }
}
