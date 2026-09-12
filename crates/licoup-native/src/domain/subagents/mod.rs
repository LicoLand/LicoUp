//! Transport-neutral native Subagents authority.
//!
//! CLI and optional protocol adapters invoke the same domain operations.
//! Dispatch, caller membership, target inventory and provider execution remain native.

use licoup_agent_adapters::AdapterRegistry;
use licoup_agent_runtime::{
    AdapterFailure, DurableNativeBinding, ProviderId, RuntimeDispatchReceipt, RuntimeTransition,
    SubagentContinueRequest, SubagentDispatchRequest, reduce_execution_admission, reduce_readiness,
};
use licoup_conversation::{SubagentDispatchClaim, SubagentDispatchClaimState};
use serde_json::{Map, Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SubagentError {
    pub code: &'static str,
    pub stage: &'static str,
    pub retryable: bool,
    pub recovery: &'static str,
}

impl SubagentError {
    pub const fn permanent(code: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            stage,
            retryable: false,
            recovery: "correct_request_and_retry",
        }
    }

    pub const fn retryable(code: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            stage,
            retryable: true,
            recovery: "retry_after_recovery",
        }
    }
}

pub struct SubagentCallContext<'a, C> {
    pub caller: &'a C,
    pub cancelled: Arc<AtomicBool>,
}

mod callback;
pub(crate) mod local;
mod production;

pub use callback::{CALLBACK_CAUSATION_ID, subagent_callback_plan};
pub use production::production_application;

pub const MAX_PROMPT_BYTES: usize = 48 * 1024;
pub const MAX_ID_BYTES: usize = 256;
pub const MAX_WORKING_DIRECTORY_BYTES: usize = 4096;
pub const MIN_SUBAGENT_TIMEOUT_MS: u64 = 1_000;
pub const MAX_SUBAGENT_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
pub const MIN_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024;
pub const MAX_SUBAGENT_STDOUT_BYTES: u64 = 64 * 1024 * 1024;
pub const MIN_SUBAGENT_STDERR_BYTES: u64 = 16 * 1024;
pub const MAX_SUBAGENT_STDERR_BYTES: u64 = 4 * 1024 * 1024;

pub const TOOL_NAMES: &[&str] = &[
    "lico_assistant_profiles",
    "lico_assistant_workflow_execute",
    "lico_assistant_workflow_inspect",
    "lico_assistant_workflow_cancel",
    "lico_subagents_list",
    "lico_subagent_probe",
    "lico_subagent_delegate",
    "lico_subagent_continue",
    "lico_subagent_cancel",
];

/// Authenticated server context. Membership and parent lineage are supplied by
/// the client-owned HTTP service, never accepted from tool arguments.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CallerContext {
    pub provider_id: ProviderId,
    pub conversation_id: Option<String>,
    pub membership_id: Option<String>,
    pub parent_dispatch_id: Option<String>,
    pub authenticated: bool,
}

impl CallerContext {
    pub fn effect_scope(&self, conversation_id: &str) -> Result<&str, SubagentError> {
        if !self.authenticated {
            return Err(permanent(
                "caller_authentication_required",
                "caller/authenticate",
            ));
        }
        if self.conversation_id.as_deref() != Some(conversation_id) {
            return Err(permanent(
                "subagent_cross_conversation_rejected",
                "conversation/authorize",
            ));
        }
        self.membership_id.as_deref().ok_or_else(|| {
            permanent(
                "caller_membership_binding_required",
                "conversation/authorize",
            )
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TargetMembership {
    pub conversation_id: String,
    pub membership_id: String,
    pub provider_id: ProviderId,
    pub preferred_model: Option<String>,
    pub preferred_reasoning_effort: Option<String>,
}

/// Canonical Conversation and PersistentTurn authority. Implementations must
/// commit a claim before returning it and retain native binding data privately.
pub trait ConversationHostPort: Send + Sync {
    fn verify_caller(
        &self,
        caller: &CallerContext,
        conversation_id: &str,
    ) -> Result<(), SubagentError>;
    fn assistant_profiles(
        &self,
        caller: &CallerContext,
        arguments: &Map<String, Value>,
    ) -> Result<Value, SubagentError>;
    fn assistant_workflow(
        &self,
        caller: &CallerContext,
        action: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Value, SubagentError>;
    fn target_membership(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> Result<TargetMembership, SubagentError>;
    fn target_membership_by_agent(
        &self,
        conversation_id: &str,
        agent: &str,
    ) -> Result<TargetMembership, SubagentError>;
    fn claim_dispatch(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
        parent_dispatch_id: Option<&str>,
    ) -> Result<SubagentDispatchClaim, SubagentError>;
    fn update_claim(
        &self,
        dispatch_id: &str,
        state: SubagentDispatchClaimState,
    ) -> Result<(), SubagentError>;
    fn active_claim(
        &self,
        conversation_id: &str,
        caller_membership_id: &str,
        target_membership_id: &str,
    ) -> Result<Option<SubagentDispatchClaim>, SubagentError>;
    fn latest_resume_binding(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> Result<DurableNativeBinding, SubagentError>;
    fn record_inbound(
        &self,
        conversation_id: &str,
        caller_membership_id: Option<&str>,
        target_membership_id: Option<&str>,
        tool: &str,
        outcome: &str,
    ) -> Result<(), SubagentError>;
}

/// Read-only target inventory. Implementations must not launch a provider,
/// inject a probe prompt, refresh mutable history, or project private facts.
pub trait ReadOnlyTargetPort: Send + Sync {
    fn list(&self) -> Result<Value, SubagentError>;
    fn probe(&self, provider: &ProviderId) -> Result<Value, SubagentError>;
}

#[derive(Clone)]
pub struct SubagentApplication {
    conversation: Arc<dyn ConversationHostPort>,
    adapters: AdapterRegistry,
    targets: Arc<dyn ReadOnlyTargetPort>,
}

impl SubagentApplication {
    pub fn new(
        conversation: Arc<dyn ConversationHostPort>,
        adapters: AdapterRegistry,
        targets: Arc<dyn ReadOnlyTargetPort>,
    ) -> Self {
        Self {
            conversation,
            adapters,
            targets,
        }
    }

    /// Mesh members: the providers the adapter registry admits as callers, in
    /// provider-id order. This is the single authority for the caller set. The
    /// supervisor publishes exactly these as discovery tokens, and the connector
    /// reads its own membership back from that set, so neither side keeps a
    /// private copy of the list.
    pub fn caller_providers(&self) -> Vec<String> {
        self.adapters
            .caller_providers()
            .map(|provider| provider.as_str().to_owned())
            .collect()
    }

    fn runtime(
        &self,
        target: &TargetMembership,
        operation: Operation,
    ) -> Result<Arc<dyn licoup_agent_runtime::SubagentRuntimeAdapter>, SubagentError> {
        let runtime = self
            .adapters
            .runtime(&target.provider_id)
            .ok_or_else(|| permanent("subagent_adapter_unavailable", "adapter/select"))?;
        let capabilities = runtime.capabilities();
        let supported = match operation {
            Operation::Delegate => capabilities.create,
            Operation::Continue => capabilities.exact_resume && capabilities.continue_turn,
            Operation::Cancel => capabilities.active_cancel,
        };
        if !supported {
            return Err(permanent(
                "subagent_capability_unavailable",
                "capability/admit",
            ));
        }
        let decision =
            reduce_execution_admission(runtime.provider_id(), &runtime.execution_admission());
        if !decision.admitted {
            return Err(permanent(
                decision
                    .blocker_code
                    .unwrap_or("provider_execution_route_unavailable"),
                "target/admit",
            ));
        }
        Ok(runtime)
    }

    fn resolve_target(
        &self,
        conversation_id: &str,
        arguments: &Map<String, Value>,
    ) -> Result<TargetMembership, SubagentError> {
        if let Some(membership_id) = optional_bounded_text(arguments, "membershipId", MAX_ID_BYTES)?
        {
            return self
                .conversation
                .target_membership(conversation_id, &membership_id);
        }
        if let Some(agent) = optional_bounded_text(arguments, "agent", MAX_ID_BYTES)? {
            return self
                .conversation
                .target_membership_by_agent(conversation_id, &agent);
        }
        Err(retryable(
            "subagent_target_seat_missing",
            "conversation/authorize",
        ))
    }

    fn dispatch(
        &self,
        caller: &CallerContext,
        arguments: &Map<String, Value>,
        continuing: bool,
    ) -> Result<Value, SubagentError> {
        let conversation_id = resolve_conversation_id(caller, arguments)?;
        // Parse every fallible request field before the durable claim. A
        // whitespace-only prompt passes JSON Schema minLength but is rejected
        // by the normalized application contract; discovering that after the
        // claim would strand an active edge without a provider effect.
        let _prompt = required_text(arguments, "prompt", MAX_PROMPT_BYTES)?;
        if arguments
            .get("workingDirectory")
            .and_then(Value::as_str)
            .is_some_and(|value| !std::path::Path::new(value).is_absolute())
        {
            return Err(permanent("invalid_working_directory", "schema/validate"));
        }
        let caller_membership_id = caller.effect_scope(&conversation_id)?;
        self.conversation.verify_caller(caller, &conversation_id)?;
        let target = self.resolve_target(&conversation_id, arguments)?;
        let operation = if continuing {
            Operation::Continue
        } else {
            Operation::Delegate
        };
        let runtime = self.runtime(&target, operation)?;

        // Exact resume identity is adapter-owned and resolved before the new
        // durable claim. A stale or ambiguous identity therefore has zero
        // effect and leaves no active edge.
        let resume_identity = if continuing {
            let binding = self
                .conversation
                .latest_resume_binding(&conversation_id, &target.membership_id)?;
            if let (Some(requested), Some(recorded)) = (
                arguments.get("workingDirectory").and_then(Value::as_str),
                binding.working_directory(),
            ) && requested != recorded
            {
                return Err(permanent(
                    "conversation_working_directory_mismatch",
                    "identity/resolve",
                ));
            }
            Some(
                runtime
                    .resolve_resume_identity(&binding)
                    .map_err(project_adapter_failure)?,
            )
        } else {
            None
        };

        let claim = self.conversation.claim_dispatch(
            &conversation_id,
            caller_membership_id,
            &target.membership_id,
            caller.parent_dispatch_id.as_deref(),
        )?;
        let request = dispatch_request(arguments, caller_membership_id, &target, &claim)?;
        let result = if let Some(identity) = resume_identity {
            runtime.continue_turn(&SubagentContinueRequest {
                dispatch: request,
                identity,
            })
        } else {
            runtime.send(&request)
        };
        let receipt = match result {
            Ok(receipt) => {
                if self
                    .conversation
                    .update_claim(&claim.id, SubagentDispatchClaimState::Running)
                    .is_err()
                {
                    return Err(reconciliation_required());
                }
                receipt
            }
            Err(error) => {
                let state = if error.uncertain_effect {
                    SubagentDispatchClaimState::ReconciliationRequired
                } else {
                    SubagentDispatchClaimState::Failed
                };
                if self.conversation.update_claim(&claim.id, state).is_err() {
                    return Err(reconciliation_required());
                }
                return Err(project_adapter_failure(error));
            }
        };
        Ok(public_dispatch_receipt(
            &target,
            &claim,
            if continuing {
                "subagent.continue"
            } else {
                "subagent.delegate"
            },
            &receipt,
        ))
    }

    fn cancel(
        &self,
        caller: &CallerContext,
        arguments: &Map<String, Value>,
    ) -> Result<Value, SubagentError> {
        let conversation_id = resolve_conversation_id(caller, arguments)?;
        let caller_membership_id = caller.effect_scope(&conversation_id)?;
        self.conversation.verify_caller(caller, &conversation_id)?;
        let target = self.resolve_target(&conversation_id, arguments)?;
        let runtime = self.runtime(&target, Operation::Cancel)?;
        let claim = self
            .conversation
            .active_claim(
                &conversation_id,
                caller_membership_id,
                &target.membership_id,
            )?
            .ok_or_else(|| permanent("subagent_cancel_unavailable", "dispatch/cancel"))?;
        self.conversation
            .update_claim(&claim.id, SubagentDispatchClaimState::CancelRequested)?;
        // The process-local adapter resolves the active dispatch handle through
        // its exact identity implementation; generic path/session heuristics do
        // not exist in the application.
        let identity = licoup_agent_runtime::NativeResumeIdentity::new(
            target.provider_id.clone(),
            claim.id.clone(),
        )
        .map_err(project_adapter_failure)?;
        match runtime.cancel_active(&claim.id, &identity) {
            Ok(receipt) => Ok(public_dispatch_receipt(
                &target,
                &claim,
                "subagent.cancel",
                &receipt,
            )),
            Err(error) => {
                let _ = self.conversation.update_claim(
                    &claim.id,
                    SubagentDispatchClaimState::ReconciliationRequired,
                );
                Err(project_adapter_failure(if error.uncertain_effect {
                    error
                } else {
                    AdapterFailure::uncertain("subagent_cancel_uncertain", "dispatch/reconcile")
                }))
            }
        }
    }

    fn probe(&self, arguments: &Map<String, Value>) -> Result<Value, SubagentError> {
        let provider = ProviderId::parse(required_text(arguments, "agentId", MAX_ID_BYTES)?)
            .map_err(project_adapter_failure)?;
        let runtime = self
            .adapters
            .runtime(&provider)
            .ok_or_else(|| permanent("subagent_adapter_unavailable", "adapter/select"))?;
        let decision = reduce_readiness(&provider, &runtime.readiness());
        let target = self.targets.probe(&provider)?;
        Ok(json!({
            "schemaVersion": "licoup.subagent.readiness.v2",
            "agentId": provider.as_str(),
            "state": if decision.ready { "ready" } else { "blocked" },
            "blockerCode": decision.blocker_code,
            "capabilityRevision": decision.capability_revision,
            "capabilities": runtime.capabilities(),
            "target": target,
        }))
    }

    fn workflow(
        &self,
        caller: &CallerContext,
        action: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Value, SubagentError> {
        if action == "strategy.assistant.workflow.execute" {
            let conversation_id = required_text(arguments, "conversationId", MAX_ID_BYTES)?;
            caller.effect_scope(&conversation_id)?;
            let bindings = arguments
                .get("bindings")
                .and_then(Value::as_array)
                .ok_or_else(|| permanent("invalid_request", "schema/validate"))?;
            for membership_id in bindings.iter().filter_map(|binding| {
                binding
                    .get("valueId")
                    .or_else(|| binding.get("membershipId"))
                    .and_then(Value::as_str)
            }) {
                let target = self
                    .conversation
                    .target_membership(&conversation_id, membership_id)?;
                let _ = self.runtime(&target, Operation::Delegate)?;
            }
        }
        self.conversation
            .assistant_workflow(caller, action, arguments)
    }

    fn record_mesh_inbound(
        &self,
        caller: &CallerContext,
        name: &str,
        arguments: &Map<String, Value>,
        result: &Result<Value, SubagentError>,
    ) -> Result<(), SubagentError> {
        let Some(conversation_id) = arguments
            .get("conversationId")
            .and_then(Value::as_str)
            .map(str::trim)
            .or(caller.conversation_id.as_deref())
            .filter(|value| !value.is_empty())
        else {
            return Ok(());
        };
        let outcome = match result {
            Ok(_) => "accepted",
            Err(error) => error.code,
        };
        self.conversation.record_inbound(
            conversation_id,
            caller.membership_id.as_deref(),
            arguments
                .get("membershipId")
                .and_then(Value::as_str)
                .map(str::trim),
            name,
            outcome,
        )
    }
}

#[derive(Clone, Copy)]
enum Operation {
    Delegate,
    Continue,
    Cancel,
}

impl SubagentApplication {
    pub fn tool_catalog(&self) -> Vec<Value> {
        tool_catalog()
    }

    pub fn call_tool(
        &self,
        context: SubagentCallContext<'_, CallerContext>,
        name: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Value, SubagentError> {
        if context.cancelled.load(Ordering::Acquire) {
            return Err(permanent("request_cancelled", "request/cancel"));
        }
        if !context.caller.authenticated {
            return Err(permanent(
                "caller_authentication_required",
                "caller/authenticate",
            ));
        }
        match name {
            "lico_assistant_profiles" => self
                .conversation
                .assistant_profiles(context.caller, arguments),
            "lico_assistant_workflow_execute" => self.workflow(
                context.caller,
                "strategy.assistant.workflow.execute",
                arguments,
            ),
            "lico_assistant_workflow_inspect" => self.workflow(
                context.caller,
                "strategy.assistant.workflow.inspect",
                arguments,
            ),
            "lico_assistant_workflow_cancel" => self.workflow(
                context.caller,
                "strategy.assistant.workflow.cancel",
                arguments,
            ),
            "lico_subagents_list" => self.targets.list(),
            "lico_subagent_probe" => self.probe(arguments),
            "lico_subagent_delegate" | "lico_subagent_continue" | "lico_subagent_cancel" => {
                let result = match name {
                    "lico_subagent_delegate" => self.dispatch(context.caller, arguments, false),
                    "lico_subagent_continue" => self.dispatch(context.caller, arguments, true),
                    _ => self.cancel(context.caller, arguments),
                };
                let inbound = self.record_mesh_inbound(context.caller, name, arguments, &result);
                match (result, inbound) {
                    (Ok(value), Ok(())) => Ok(value),
                    (Ok(_), Err(_)) => Err(reconciliation_required()),
                    (Err(error), _) => Err(error),
                }
            }
            _ => Err(permanent("tool_not_found", "tool/select")),
        }
    }
}

/// Default guidance for a delegated Membership: the target knows it is a
/// subagent in a group, must finish the bounded task, and must report back.
fn subagent_situation_guidance() -> String {
    [
        "You are a delegated LicoUp subagent in the current Canonical Conversation.",
        "Do only the bounded task in the prompt.",
        "When the work is finished, report the outcome back to the caller so the supervisor can continue.",
        "Do not stay silent after the work completes.",
        "Do not attempt a self-call or a cross-conversation call.",
    ]
    .join(" ")
}

fn dispatch_request(
    arguments: &Map<String, Value>,
    caller_membership_id: &str,
    target: &TargetMembership,
    claim: &SubagentDispatchClaim,
) -> Result<SubagentDispatchRequest, SubagentError> {
    Ok(SubagentDispatchRequest {
        conversation_id: target.conversation_id.clone(),
        caller_membership_id: caller_membership_id.to_owned(),
        target_membership_id: target.membership_id.clone(),
        dispatch_id: claim.id.clone(),
        prompt: required_text(arguments, "prompt", MAX_PROMPT_BYTES)?,
        model: optional_text(arguments, "model").or_else(|| target.preferred_model.clone()),
        reasoning_effort: optional_text(arguments, "reasoningEffort")
            .or_else(|| target.preferred_reasoning_effort.clone()),
        working_directory: optional_text(arguments, "workingDirectory"),
        task_type: optional_text(arguments, "taskType"),
        timeout_ms: arguments.get("timeoutMs").and_then(Value::as_u64),
        timeout_unbounded: arguments
            .get("timeoutUnbounded")
            .or_else(|| arguments.get("unboundedTimeout"))
            .and_then(Value::as_bool)
            == Some(true),
        max_stdout_bytes: arguments.get("maxStdoutBytes").and_then(Value::as_u64),
        max_stderr_bytes: arguments.get("maxStderrBytes").and_then(Value::as_u64),
        generated_guidance: Some(subagent_situation_guidance()),
    })
}

fn public_dispatch_receipt(
    target: &TargetMembership,
    claim: &SubagentDispatchClaim,
    operation: &str,
    receipt: &RuntimeDispatchReceipt,
) -> Value {
    let state = match receipt.transition {
        RuntimeTransition::Accepted
        | RuntimeTransition::Processing
        | RuntimeTransition::Responding => "accepted",
        RuntimeTransition::CancelRequested => "cancel-requested",
        RuntimeTransition::Cancelled => "cancelled",
        RuntimeTransition::Completed => "completed",
        RuntimeTransition::Failed => "failed",
        RuntimeTransition::ReconciliationRequired => "reconciliation-required",
    };
    json!({
        "schemaVersion": "licoup.subagent.receipt.v3",
        "operation": operation,
        "agentId": target.provider_id.as_str(),
        "conversationId": target.conversation_id,
        "membershipId": target.membership_id,
        "dispatchId": claim.id,
        "depth": claim.depth,
        "state": state,
        "accepted": matches!(receipt.transition, RuntimeTransition::Accepted | RuntimeTransition::Processing | RuntimeTransition::Responding),
    })
}

fn project_adapter_failure(error: AdapterFailure) -> SubagentError {
    SubagentError {
        code: error.code,
        stage: error.stage,
        retryable: error.retryable,
        recovery: if error.uncertain_effect {
            "reconcile_before_retry"
        } else if error.retryable {
            "retry_after_recovery"
        } else {
            "correct_request_and_retry"
        },
    }
}

fn permanent(code: &'static str, stage: &'static str) -> SubagentError {
    SubagentError::permanent(code, stage)
}

fn retryable(code: &'static str, stage: &'static str) -> SubagentError {
    SubagentError::retryable(code, stage)
}

fn resolve_conversation_id(
    caller: &CallerContext,
    arguments: &Map<String, Value>,
) -> Result<String, SubagentError> {
    if let Some(conversation_id) = optional_bounded_text(arguments, "conversationId", MAX_ID_BYTES)?
    {
        return Ok(conversation_id);
    }
    caller
        .conversation_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= MAX_ID_BYTES && !value.contains('\0'))
        .map(str::to_owned)
        .ok_or_else(|| permanent("invalid_request", "schema/validate"))
}

fn reconciliation_required() -> SubagentError {
    SubagentError {
        code: "dispatch_reconciliation_required",
        stage: "dispatch/reconcile",
        retryable: true,
        recovery: "reconcile_before_retry",
    }
}

fn required_text(
    arguments: &Map<String, Value>,
    key: &str,
    max: usize,
) -> Result<String, SubagentError> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= max && !value.contains('\0'))
        .map(str::to_owned)
        .ok_or_else(|| permanent("invalid_request", "schema/validate"))
}

fn optional_text(arguments: &Map<String, Value>, key: &str) -> Option<String> {
    arguments
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn optional_bounded_text(
    arguments: &Map<String, Value>,
    key: &str,
    max: usize,
) -> Result<Option<String>, SubagentError> {
    let Some(value) = optional_text(arguments, key) else {
        return Ok(None);
    };
    if value.len() > max || value.contains('\0') {
        return Err(permanent("invalid_request", "schema/validate"));
    }
    Ok(Some(value))
}

pub fn tool_catalog() -> Vec<Value> {
    vec![
        tool(
            "lico_assistant_profiles",
            &[("conversationId", bounded_string(MAX_ID_BYTES))],
            &["conversationId"],
        ),
        tool(
            "lico_assistant_workflow_execute",
            &[
                ("conversationId", bounded_string(MAX_ID_BYTES)),
                ("membershipId", bounded_string(MAX_ID_BYTES)),
                ("workflow", json!({"type": "object"})),
                ("bindings", json!({"type": "array", "maxItems": 32})),
                ("filters", json!({"type": "object"})),
                ("input", json!({"type": "object"})),
                ("idempotencyKey", bounded_string(MAX_ID_BYTES)),
                // Optional callback-decision fields: when the replayed execute
                // answers a parked callback wait, the master agent's decision
                // rides the same idempotent call.
                (
                    "decision",
                    json!({
                        "type": "string",
                        "minLength": 1,
                        "maxLength": MAX_ID_BYTES,
                        "enum": ["advance", "return", "terminate"]
                    }),
                ),
                ("callbackStateId", bounded_string(MAX_ID_BYTES)),
                (
                    "callbackStateVisit",
                    json!({"type": "integer", "minimum": 1}),
                ),
            ],
            &[
                "conversationId",
                "membershipId",
                "workflow",
                "bindings",
                "idempotencyKey",
            ],
        ),
        tool(
            "lico_assistant_workflow_inspect",
            &[("runId", bounded_string(MAX_ID_BYTES))],
            &["runId"],
        ),
        tool(
            "lico_assistant_workflow_cancel",
            &[("runId", bounded_string(MAX_ID_BYTES))],
            &["runId"],
        ),
        tool("lico_subagents_list", &[], &[]),
        tool(
            "lico_subagent_probe",
            &[("agentId", bounded_string(MAX_ID_BYTES))],
            &["agentId"],
        ),
        dispatch_tool("lico_subagent_delegate"),
        dispatch_tool("lico_subagent_continue"),
        tool(
            "lico_subagent_cancel",
            &[
                ("conversationId", bounded_string(MAX_ID_BYTES)),
                ("membershipId", bounded_string(MAX_ID_BYTES)),
                ("agent", bounded_string(MAX_ID_BYTES)),
            ],
            &[],
        ),
    ]
}

fn dispatch_tool(name: &'static str) -> Value {
    tool(
        name,
        &[
            ("conversationId", bounded_string(MAX_ID_BYTES)),
            ("membershipId", bounded_string(MAX_ID_BYTES)),
            ("agent", bounded_string(MAX_ID_BYTES)),
            ("prompt", bounded_string(MAX_PROMPT_BYTES)),
            ("model", bounded_string(MAX_ID_BYTES)),
            ("reasoningEffort", bounded_string(32)),
            (
                "taskType",
                json!({
                    "type": "string",
                    "enum": ["frontend", "backend", "retrieval", "text"]
                }),
            ),
            (
                "workingDirectory",
                bounded_string(MAX_WORKING_DIRECTORY_BYTES),
            ),
            (
                "timeoutMs",
                json!({
                    "type":"integer",
                    "minimum":0,
                    "maximum":MAX_SUBAGENT_TIMEOUT_MS,
                    "x-zeroMeansPolicyDefault":true,
                    "x-minFiniteTimeoutMs": MIN_SUBAGENT_TIMEOUT_MS
                }),
            ),
            ("timeoutUnbounded", json!({"type": "boolean"})),
            ("unboundedTimeout", json!({"type": "boolean"})),
            (
                "maxStdoutBytes",
                json!({"type":"integer", "minimum":MIN_SUBAGENT_STDOUT_BYTES, "maximum":MAX_SUBAGENT_STDOUT_BYTES}),
            ),
            (
                "maxStderrBytes",
                json!({"type":"integer", "minimum":MIN_SUBAGENT_STDERR_BYTES, "maximum":MAX_SUBAGENT_STDERR_BYTES}),
            ),
        ],
        &["prompt"],
    )
}

fn tool(name: &'static str, properties: &[(&str, Value)], required: &[&str]) -> Value {
    let properties = properties
        .iter()
        .map(|(name, schema)| ((*name).to_owned(), schema.clone()))
        .collect::<Map<_, _>>();
    json!({
        "name": name,
        "description": name,
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": required,
        }
    })
}

fn bounded_string(max: usize) -> Value {
    json!({"type":"string", "minLength":1, "maxLength":max})
}

pub fn validate_tool_arguments(name: &str, arguments: &Map<String, Value>) -> bool {
    let Some(schema) = tool_catalog()
        .into_iter()
        .find(|tool| tool.get("name").and_then(Value::as_str) == Some(name))
        .and_then(|tool| tool.get("inputSchema").cloned())
    else {
        return false;
    };
    let Some(properties) = schema.get("properties").and_then(Value::as_object) else {
        return false;
    };
    if arguments.keys().any(|key| !properties.contains_key(key)) {
        return false;
    }
    if schema
        .get("required")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .any(|key| !arguments.contains_key(key))
    {
        return false;
    }
    arguments.iter().all(|(key, value)| {
        let schema = &properties[key];
        if key == "timeoutMs" && value.as_u64() == Some(0) {
            return true;
        }
        match schema.get("type").and_then(Value::as_str) {
            Some("string") => value.as_str().is_some_and(|value| {
                let minimum = schema.get("minLength").and_then(Value::as_u64).unwrap_or(0) as usize;
                let maximum = schema
                    .get("maxLength")
                    .and_then(Value::as_u64)
                    .unwrap_or(u64::MAX) as usize;
                value.len() >= minimum
                    && value.len() <= maximum
                    && !value.trim().is_empty()
                    && !value.contains('\0')
            }),
            Some("integer") => value.as_u64().is_some_and(|value| {
                value >= schema.get("minimum").and_then(Value::as_u64).unwrap_or(0)
                    && value
                        <= schema
                            .get("maximum")
                            .and_then(Value::as_u64)
                            .unwrap_or(u64::MAX)
            }),
            Some("object") => value.is_object(),
            Some("boolean") => value.is_boolean(),
            Some("array") => value.as_array().is_some_and(|items| {
                items.len()
                    <= schema
                        .get("maxItems")
                        .and_then(Value::as_u64)
                        .unwrap_or(u64::MAX) as usize
            }),
            _ => false,
        }
    })
}

#[cfg(test)]
mod tests;
