use super::*;
use crate::core::mcp::{McpApplication, McpToolCallContext};
use licoup_agent_runtime::{
    AdapterFailure, CallerRegistrationPlan, CallerRegistrationReceipt, DurableNativeBinding,
    ExecutionAdmissionEvidence, McpCallerIntegration, NativeResumeIdentity, ReadinessEvidence,
    RegistrationApproval, RuntimeDispatchReceipt, RuntimeObservation, RuntimeTransition,
    SubagentCapabilities, SubagentContinueRequest, SubagentDispatchRequest, SubagentRuntimeAdapter,
};
use licoup_conversation::{
    ConversationStore, MembershipAccess, Principal, PrincipalKind, SubagentDispatchClaimState,
};
use std::collections::BTreeMap;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};

#[test]
fn frozen_server_and_ordered_closed_catalog_are_exact() {
    let definition = server_definition();
    assert_eq!(definition.protocol_revision, "2025-06-18");
    assert_eq!(definition.compatible_protocol_revisions, &["2025-11-25"]);
    assert_eq!(definition.server_name, "lico-up-subagents");
    assert_eq!(definition.server_version, "0.11.0");
    let catalog = tool_catalog();
    assert_eq!(
        catalog
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str))
            .collect::<Vec<_>>(),
        TOOL_NAMES
    );
    assert!(catalog.iter().all(|tool| {
        tool.pointer("/inputSchema/additionalProperties") == Some(&Value::Bool(false))
    }));
}

#[test]
fn validation_is_closed_and_bounds_effect_arguments() {
    let valid = json!({
        "conversationId": "conversation:fixture",
        "membershipId": "membership:fixture",
        "prompt": "bounded task",
        "timeoutMs": 0,
    });
    assert!(validate_tool_arguments(
        "lico_subagent_delegate",
        valid.as_object().unwrap()
    ));
    let mut unknown = valid.as_object().unwrap().clone();
    unknown.insert("provider".into(), json!("codex"));
    assert!(!validate_tool_arguments("lico_subagent_delegate", &unknown));
    let oversized = json!({
        "conversationId": "conversation:fixture",
        "membershipId": "membership:fixture",
        "prompt": "x".repeat(MAX_PROMPT_BYTES + 1),
    });
    assert!(!validate_tool_arguments(
        "lico_subagent_delegate",
        oversized.as_object().unwrap()
    ));
    let whitespace_prompt = json!({
        "conversationId": "conversation:fixture",
        "membershipId": "membership:fixture",
        "prompt": "   ",
    });
    assert!(!validate_tool_arguments(
        "lico_subagent_delegate",
        whitespace_prompt.as_object().unwrap()
    ));
}

#[test]
fn caller_effect_scope_is_exact_membership_and_conversation_bound() {
    let caller = CallerContext {
        provider_id: ProviderId::parse("codex").unwrap(),
        conversation_id: Some("conversation:one".into()),
        membership_id: Some("membership:caller".into()),
        parent_dispatch_id: None,
        authenticated: true,
    };
    assert_eq!(
        caller.effect_scope("conversation:one").unwrap(),
        "membership:caller"
    );
    assert_eq!(
        caller.effect_scope("conversation:two").unwrap_err().code,
        "subagent_cross_conversation_rejected"
    );
}

struct FixtureCaller {
    provider: ProviderId,
}

impl McpCallerIntegration for FixtureCaller {
    fn provider_id(&self) -> &ProviderId {
        &self.provider
    }
    fn plan_registration(&self) -> Result<CallerRegistrationPlan, AdapterFailure> {
        unreachable!()
    }
    fn readiness(&self) -> ReadinessEvidence {
        ready(&self.provider)
    }
    fn apply_registration(
        &self,
        _: &CallerRegistrationPlan,
        _: &mut RegistrationApproval,
    ) -> Result<CallerRegistrationReceipt, AdapterFailure> {
        unreachable!()
    }
    fn remove_registration(
        &self,
        _: &CallerRegistrationPlan,
        _: &mut RegistrationApproval,
    ) -> Result<(), AdapterFailure> {
        unreachable!()
    }
}

struct FixtureRuntime {
    provider: ProviderId,
    calls: Arc<Mutex<Vec<String>>>,
    persistent_store: Option<ConversationStore>,
    execution_admitted: bool,
    capability_available: bool,
    readiness: ReadinessEvidence,
    send_failure: Option<AdapterFailure>,
}

impl FixtureRuntime {
    fn with_send_failure(mut self, failure: Option<AdapterFailure>) -> Self {
        self.send_failure = failure;
        self
    }
}

impl SubagentRuntimeAdapter for FixtureRuntime {
    fn provider_id(&self) -> &ProviderId {
        &self.provider
    }
    fn capabilities(&self) -> SubagentCapabilities {
        SubagentCapabilities {
            create: self.capability_available,
            exact_resume: true,
            observe: true,
            continue_turn: true,
            active_cancel: true,
            native_steer: self.provider.as_str() == "codex",
            instruction_policy: if self.provider.as_str() == "codex" {
                licoup_agent_runtime::InstructionPolicy::NativeDeveloperInstructions
            } else {
                licoup_agent_runtime::InstructionPolicy::OrdinaryWirePrefix
            },
        }
    }
    fn execution_admission(&self) -> ExecutionAdmissionEvidence {
        ExecutionAdmissionEvidence {
            provider_id: self.provider.as_str().into(),
            installed: self.execution_admitted,
            executable_message_send_route: self.execution_admitted,
        }
    }
    fn readiness(&self) -> ReadinessEvidence {
        self.readiness.clone()
    }
    fn resolve_resume_identity(
        &self,
        durable: &DurableNativeBinding,
    ) -> Result<NativeResumeIdentity, AdapterFailure> {
        NativeResumeIdentity::from_durable(durable, durable.native_session_id())
    }
    fn send(
        &self,
        request: &SubagentDispatchRequest,
    ) -> Result<RuntimeDispatchReceipt, AdapterFailure> {
        if let Some(error) = &self.send_failure {
            self.calls.lock().unwrap().push(request.dispatch_id.clone());
            return Err(error.clone());
        }
        if let Some(store) = &self.persistent_store {
            store
                .prepare_runtime_dispatch(
                    self.provider.as_str(),
                    "",
                    &request.prompt,
                    Some(&request.conversation_id),
                    Some(&request.target_membership_id),
                    None,
                    Some(&request.dispatch_id),
                )
                .map_err(|_| AdapterFailure::permanent("fixture_dispatch_failed", "fixture"))?;
        }
        self.calls.lock().unwrap().push(request.dispatch_id.clone());
        Ok(RuntimeDispatchReceipt {
            dispatch_id: request.dispatch_id.clone(),
            transition: RuntimeTransition::Accepted,
            identity: None,
        })
    }
    fn continue_turn(
        &self,
        request: &SubagentContinueRequest,
    ) -> Result<RuntimeDispatchReceipt, AdapterFailure> {
        self.calls
            .lock()
            .unwrap()
            .push(request.dispatch.dispatch_id.clone());
        Ok(RuntimeDispatchReceipt {
            dispatch_id: request.dispatch.dispatch_id.clone(),
            transition: RuntimeTransition::Accepted,
            identity: None,
        })
    }
    fn observe(&self, dispatch_id: &str) -> Result<RuntimeObservation, AdapterFailure> {
        Ok(RuntimeObservation {
            dispatch_id: dispatch_id.into(),
            transition: RuntimeTransition::Processing,
            parts: vec![],
        })
    }
    fn cancel_active(
        &self,
        dispatch_id: &str,
        _: &NativeResumeIdentity,
    ) -> Result<RuntimeDispatchReceipt, AdapterFailure> {
        Ok(RuntimeDispatchReceipt {
            dispatch_id: dispatch_id.into(),
            transition: RuntimeTransition::CancelRequested,
            identity: None,
        })
    }
    fn cleanup(&self, _: &NativeResumeIdentity) -> Result<(), AdapterFailure> {
        Ok(())
    }
}

fn ready(provider: &ProviderId) -> ReadinessEvidence {
    ReadinessEvidence {
        provider_id: provider.as_str().into(),
        installed: true,
        identity_verified: true,
        transport_ready: true,
        permission_ready: true,
        capability_revision: format!("fixture:{}:1", provider),
        blocker_code: None,
    }
}

fn unverified(provider: &ProviderId) -> ReadinessEvidence {
    ReadinessEvidence {
        provider_id: provider.as_str().into(),
        installed: true,
        identity_verified: false,
        transport_ready: false,
        permission_ready: false,
        capability_revision: format!("fixture:{}:unverified", provider),
        blocker_code: Some("provider_readiness_evidence_incomplete".into()),
    }
}

fn fixture_runtime(
    provider: ProviderId,
    calls: Arc<Mutex<Vec<String>>>,
    persistent_store: Option<ConversationStore>,
) -> FixtureRuntime {
    FixtureRuntime {
        readiness: ready(&provider),
        provider,
        calls,
        persistent_store,
        execution_admitted: true,
        capability_available: true,
        send_failure: None,
    }
}

struct FixtureHost {
    store: ConversationStore,
    providers: BTreeMap<String, ProviderId>,
}

impl ConversationHostPort for FixtureHost {
    fn verify_caller(
        &self,
        caller: &CallerContext,
        conversation_id: &str,
    ) -> Result<(), McpApplicationError> {
        let membership = caller.effect_scope(conversation_id)?;
        if self.providers.get(membership) == Some(&caller.provider_id) {
            Ok(())
        } else {
            Err(permanent("caller_identity_mismatch", "fixture"))
        }
    }
    fn assistant_profiles(
        &self,
        _: &CallerContext,
        _: &Map<String, Value>,
    ) -> Result<Value, McpApplicationError> {
        Ok(json!({}))
    }
    fn assistant_workflow(
        &self,
        _: &CallerContext,
        _: &str,
        _: &Map<String, Value>,
    ) -> Result<Value, McpApplicationError> {
        Ok(json!({}))
    }
    fn target_membership(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> Result<TargetMembership, McpApplicationError> {
        let provider_id = self
            .providers
            .get(membership_id)
            .cloned()
            .ok_or_else(|| permanent("membership_not_found", "fixture"))?;
        Ok(TargetMembership {
            conversation_id: conversation_id.into(),
            membership_id: membership_id.into(),
            provider_id,
            preferred_model: None,
            preferred_reasoning_effort: None,
        })
    }
    fn claim_dispatch(
        &self,
        conversation_id: &str,
        caller: &str,
        target: &str,
        parent: Option<&str>,
    ) -> Result<SubagentDispatchClaim, McpApplicationError> {
        self.store
            .claim_subagent_dispatch(conversation_id, caller, target, parent)
            .map_err(project_fixture_store)
    }
    fn update_claim(
        &self,
        dispatch_id: &str,
        state: SubagentDispatchClaimState,
    ) -> Result<(), McpApplicationError> {
        self.store
            .update_subagent_claim_state(dispatch_id, state)
            .map_err(|_| permanent("transition_failed", "fixture"))
    }
    fn active_claim(
        &self,
        conversation_id: &str,
        caller: &str,
        target: &str,
    ) -> Result<Option<SubagentDispatchClaim>, McpApplicationError> {
        self.store
            .active_subagent_claim(conversation_id, caller, target)
            .map_err(|_| permanent("claim_failed", "fixture"))
    }
    fn record_inbound(
        &self,
        conversation_id: &str,
        caller: Option<&str>,
        target: Option<&str>,
        tool: &str,
        outcome: &str,
    ) -> Result<(), McpApplicationError> {
        self.store
            .record_subagent_mcp_inbound(conversation_id, caller, target, tool, outcome)
            .map_err(|_| permanent("inbound_failed", "fixture"))
    }
    fn latest_resume_binding(
        &self,
        _: &str,
        membership_id: &str,
    ) -> Result<DurableNativeBinding, McpApplicationError> {
        DurableNativeBinding::new(
            self.providers[membership_id].clone(),
            format!("native-{membership_id}"),
            None,
            None,
        )
        .map_err(project_adapter_failure)
    }
}

struct FixtureTargets;
impl ReadOnlyTargetPort for FixtureTargets {
    fn list(&self) -> Result<Value, McpApplicationError> {
        Ok(json!({"count":3}))
    }
    fn probe(&self, provider: &ProviderId) -> Result<Value, McpApplicationError> {
        Ok(json!({"agentId":provider.as_str()}))
    }
}

fn project_fixture_store(error: anyhow::Error) -> McpApplicationError {
    match error.to_string().split(':').next().unwrap_or("") {
        "subagent_self_call_rejected" => permanent("subagent_self_call_rejected", "lineage/admit"),
        "subagent_duplicate_active_edge" => {
            permanent("subagent_duplicate_active_edge", "lineage/admit")
        }
        "subagent_caller_membership_inactive" => permanent(
            "subagent_caller_membership_inactive",
            "conversation/authorize",
        ),
        "subagent_target_membership_inactive" => permanent(
            "subagent_target_membership_inactive",
            "conversation/authorize",
        ),
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
        _ => permanent("claim_failed", "fixture"),
    }
}

fn invoke(
    app: &SubagentMcpApplication,
    caller: &CallerContext,
    name: &str,
    arguments: Value,
) -> Result<Value, McpApplicationError> {
    app.call_tool(
        McpToolCallContext {
            caller,
            cancelled: Arc::new(AtomicBool::new(false)),
        },
        name,
        arguments.as_object().unwrap(),
    )
}

#[test]
fn dispatch_request_inherits_target_profile_and_preserves_explicit_overrides() {
    let target = TargetMembership {
        conversation_id: "conversation:fixture".into(),
        membership_id: "membership:target".into(),
        provider_id: ProviderId::parse("cursor").unwrap(),
        preferred_model: Some("profile-model".into()),
        preferred_reasoning_effort: Some("profile-effort".into()),
    };
    let claim = SubagentDispatchClaim {
        id: "subagent:fixture".into(),
        conversation_id: target.conversation_id.clone(),
        caller_membership_id: "membership:caller".into(),
        target_membership_id: target.membership_id.clone(),
        parent_dispatch_id: None,
        depth: 1,
        state: SubagentDispatchClaimState::Claimed,
        created_at_unix_ms: 1,
        updated_at_unix_ms: 1,
    };

    let inherited = dispatch_request(
        json!({"prompt":"bounded task"}).as_object().unwrap(),
        "membership:caller",
        &target,
        &claim,
    )
    .unwrap();
    assert_eq!(inherited.model.as_deref(), Some("profile-model"));
    assert_eq!(
        inherited.reasoning_effort.as_deref(),
        Some("profile-effort")
    );

    let overridden = dispatch_request(
        json!({
            "prompt":"bounded task",
            "model":"request-model",
            "reasoningEffort":"request-effort"
        })
        .as_object()
        .unwrap(),
        "membership:caller",
        &target,
        &claim,
    )
    .unwrap();
    assert_eq!(overridden.model.as_deref(), Some("request-model"));
    assert_eq!(
        overridden.reasoning_effort.as_deref(),
        Some("request-effort")
    );
}

#[test]
fn impossible_runtime_admission_stops_before_target_effect() {
    let calls = Arc::new(Mutex::new(Vec::new()));
    let provider = ProviderId::parse("cursor").unwrap();
    let target = TargetMembership {
        conversation_id: "conversation:fixture".into(),
        membership_id: "membership:target".into(),
        provider_id: provider.clone(),
        preferred_model: None,
        preferred_reasoning_effort: None,
    };
    let app_with = |runtime: FixtureRuntime| {
        let mut registry = AdapterRegistry::empty();
        registry
            .register_pair(
                Arc::new(FixtureCaller {
                    provider: provider.clone(),
                }),
                Arc::new(runtime),
            )
            .unwrap();
        SubagentMcpApplication::new(
            Arc::new(FixtureHost {
                store: ConversationStore::open_in_memory().unwrap(),
                providers: BTreeMap::new(),
            }),
            registry,
            Arc::new(FixtureTargets),
        )
    };

    let mut missing_route = fixture_runtime(provider.clone(), Arc::clone(&calls), None);
    missing_route.execution_admitted = false;
    assert_eq!(
        app_with(missing_route)
            .runtime(&target, Operation::Delegate)
            .err()
            .unwrap()
            .code,
        "provider_not_installed"
    );

    let mut missing_capability = fixture_runtime(provider.clone(), Arc::clone(&calls), None);
    missing_capability.capability_available = false;
    assert_eq!(
        app_with(missing_capability)
            .runtime(&target, Operation::Delegate)
            .err()
            .unwrap()
            .code,
        "subagent_capability_unavailable"
    );

    let empty = SubagentMcpApplication::new(
        Arc::new(FixtureHost {
            store: ConversationStore::open_in_memory().unwrap(),
            providers: BTreeMap::new(),
        }),
        AdapterRegistry::empty(),
        Arc::new(FixtureTargets),
    );
    assert_eq!(
        empty
            .runtime(&target, Operation::Delegate)
            .err()
            .unwrap()
            .code,
        "subagent_adapter_unavailable"
    );

    let admitted = app_with(fixture_runtime(provider.clone(), Arc::clone(&calls), None));
    let unauthenticated = CallerContext {
        provider_id: provider,
        conversation_id: Some(target.conversation_id.clone()),
        membership_id: Some("membership:caller".into()),
        parent_dispatch_id: None,
        authenticated: false,
    };
    assert_eq!(
        invoke(
            &admitted,
            &unauthenticated,
            "lico_subagent_delegate",
            json!({
                "conversationId": target.conversation_id,
                "membershipId": target.membership_id,
                "prompt": "must not execute"
            }),
        )
        .unwrap_err()
        .code,
        "caller_authentication_required"
    );
    assert!(calls.lock().unwrap().is_empty());
}

#[test]
fn unverified_direct_dispatch_records_inbound_claim_and_preserves_native_failure() {
    let store = ConversationStore::open_in_memory().unwrap();
    let owner = Principal {
        id: "human:owner".into(),
        kind: PrincipalKind::Human,
        display_name: "Owner".into(),
        agent_id: None,
        created_at_unix_ms: 1,
    };
    let members = ["codex", "cursor", "antigravity"].map(|provider| {
        (
            Principal {
                id: format!("agent:{provider}"),
                kind: PrincipalKind::Agent,
                display_name: provider.into(),
                agent_id: Some(provider.into()),
                created_at_unix_ms: 1,
            },
            MembershipAccess::Member,
        )
    });
    let conversation = store
        .create_conversation_with_members("Direct", owner, &members)
        .unwrap();
    let by_provider = conversation
        .memberships
        .iter()
        .filter_map(|membership| {
            membership
                .principal
                .agent_id
                .as_deref()
                .map(|provider| (provider.to_owned(), membership.id.clone()))
        })
        .collect::<BTreeMap<_, _>>();
    let calls = Arc::new(Mutex::new(Vec::new()));
    let host = Arc::new(FixtureHost {
        store: store.clone(),
        providers: by_provider
            .iter()
            .map(|(provider, membership)| {
                (
                    membership.clone(),
                    ProviderId::parse(provider.clone()).unwrap(),
                )
            })
            .collect(),
    });
    let mut registry = AdapterRegistry::empty();
    for provider in ["codex", "cursor", "antigravity"] {
        let provider_id = ProviderId::parse(provider).unwrap();
        registry
            .register_pair(
                Arc::new(FixtureCaller {
                    provider: provider_id.clone(),
                }),
                Arc::new(FixtureRuntime {
                    readiness: if provider == "cursor" {
                        unverified(&provider_id)
                    } else {
                        ready(&provider_id)
                    },
                    ..fixture_runtime(
                        provider_id,
                        Arc::clone(&calls),
                        (provider == "cursor").then(|| store.clone()),
                    )
                    .with_send_failure((provider == "antigravity").then_some(
                        AdapterFailure::retryable(
                            "provider_protocol_unavailable",
                            "protocol/initialize",
                        ),
                    ))
                }),
            )
            .unwrap();
    }
    let app = SubagentMcpApplication::new(host, registry, Arc::new(FixtureTargets));
    let caller = CallerContext {
        provider_id: ProviderId::parse("codex").unwrap(),
        conversation_id: Some(conversation.id.clone()),
        membership_id: Some(by_provider["codex"].clone()),
        parent_dispatch_id: None,
        authenticated: true,
    };
    let receipt = invoke(
        &app,
        &caller,
        "lico_subagent_delegate",
        json!({
            "conversationId": conversation.id,
            "membershipId": by_provider["cursor"],
            "prompt": "synthetic bounded work",
            "model": "composer-2.5"
        }),
    )
    .unwrap();
    assert_eq!(receipt["accepted"], true);
    assert_eq!(receipt["agentId"], "cursor");
    assert_eq!(
        calls.lock().unwrap().len(),
        1,
        "only the selected target runs"
    );
    assert_eq!(
        calls.lock().unwrap()[0],
        receipt["dispatchId"].as_str().unwrap()
    );

    let edge = store
        .subagent_mesh_edge(
            &conversation.id,
            &by_provider["codex"],
            &by_provider["cursor"],
        )
        .unwrap();
    assert!(edge.inbound_delegate);
    assert_eq!(edge.delegate_outcome.as_deref(), Some("accepted"));
    assert_eq!(edge.claim_state.as_deref(), Some("running"));
    assert_eq!(edge.dispatch_state.as_deref(), Some("accepted"));

    let calls_before_invalid_request = calls.lock().unwrap().len();
    assert_eq!(
        invoke(
            &app,
            &caller,
            "lico_subagent_delegate",
            json!({
                "conversationId": conversation.id,
                "membershipId": by_provider["cursor"],
                "prompt": "   "
            }),
        )
        .unwrap_err()
        .code,
        "invalid_request"
    );
    assert_eq!(calls.lock().unwrap().len(), calls_before_invalid_request);

    let failure = invoke(
        &app,
        &caller,
        "lico_subagent_delegate",
        json!({
            "conversationId": conversation.id,
            "membershipId": by_provider["antigravity"],
            "prompt": "synthetic typed failure"
        }),
    )
    .unwrap_err();
    assert_eq!(failure.code, "provider_protocol_unavailable");
    assert_eq!(failure.stage, "protocol/initialize");
    assert!(failure.retryable);
    assert_eq!(failure.recovery, "retry_after_recovery");
    assert_eq!(calls.lock().unwrap().len(), 2);
}

#[test]
fn self_call_records_rejected_inbound_without_a_claim() {
    let store = ConversationStore::open_in_memory().unwrap();
    let owner = Principal {
        id: "human:owner".into(),
        kind: PrincipalKind::Human,
        display_name: "Owner".into(),
        agent_id: None,
        created_at_unix_ms: 1,
    };
    let conversation = store
        .create_conversation_with_members(
            "Self",
            owner,
            &[(
                Principal {
                    id: "agent:codex".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Codex".into(),
                    agent_id: Some("codex".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )],
        )
        .unwrap();
    let membership = conversation
        .memberships
        .iter()
        .find(|membership| membership.principal.agent_id.as_deref() == Some("codex"))
        .unwrap()
        .id
        .clone();
    let host = Arc::new(FixtureHost {
        store: store.clone(),
        providers: BTreeMap::from([(membership.clone(), ProviderId::parse("codex").unwrap())]),
    });
    let mut registry = AdapterRegistry::empty();
    let provider_id = ProviderId::parse("codex").unwrap();
    registry
        .register_pair(
            Arc::new(FixtureCaller {
                provider: provider_id.clone(),
            }),
            Arc::new(fixture_runtime(
                provider_id.clone(),
                Arc::new(Mutex::new(Vec::new())),
                None,
            )),
        )
        .unwrap();
    let app = SubagentMcpApplication::new(host, registry, Arc::new(FixtureTargets));
    let caller = CallerContext {
        provider_id,
        conversation_id: Some(conversation.id.clone()),
        membership_id: Some(membership.clone()),
        parent_dispatch_id: None,
        authenticated: true,
    };
    assert_eq!(
        invoke(
            &app,
            &caller,
            "lico_subagent_delegate",
            json!({
                "conversationId": conversation.id,
                "membershipId": membership,
                "prompt": "synthetic self call"
            }),
        )
        .unwrap_err()
        .code,
        "subagent_self_call_rejected"
    );
    let edge = store
        .subagent_mesh_edge(&conversation.id, &membership, &membership)
        .unwrap();
    assert_eq!(edge.inbound_delegate, true);
    assert_eq!(
        edge.delegate_outcome.as_deref(),
        Some("subagent_self_call_rejected")
    );
    assert_eq!(edge.claim_state, None);
}
