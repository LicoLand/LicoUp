use super::model::{NormalizedEffectiveSettings, NormalizedExecution, NormalizedFailure};
use super::params::timestamp;
use super::{RUNTIME_SCHEMA_VERSION, RuntimeAdapter};
use crate::platform::{
    acp_driver_runtime, antigravity_driver, claude_code_driver, codex_app_server,
    deepseek_harness_driver, hermes_driver, lico_agent_driver, openclaw_driver, pi_driver,
};
use serde_json::{Value, json};

pub(super) fn execution_response(adapter: RuntimeAdapter, execution: NormalizedExecution) -> Value {
    debug_assert_eq!(execution.driver_id, adapter.driver_id());
    // Vendor frames have already crossed their isolated parser. Downstream
    // receives only the parser-produced closed transition vocabulary.
    let transitions = execution
        .transitions
        .iter()
        .map(crate::platform::native_agent_parser::Transition::to_json)
        .collect::<Vec<_>>();
    let lifecycle_prefix = transitions
        .iter()
        .filter_map(|transition| {
            (transition.get("kind").and_then(Value::as_str) == Some("lifecycle"))
                .then(|| {
                    transition
                        .get("stage")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                })
                .flatten()
        })
        .collect::<Vec<_>>();
    let terminal_transition = transitions
        .iter()
        .rev()
        .find(|transition| {
            matches!(
                transition.get("kind").and_then(Value::as_str),
                Some("failed")
            ) || transition.get("stage").and_then(Value::as_str) == Some("completed")
        })
        .cloned();
    let verified_native_session_id = if adapter == RuntimeAdapter::Codex {
        execution.thread_id.clone()
    } else {
        execution.session_id.clone()
    };
    let native_session_id = execution
        .ok
        .then_some(verified_native_session_id)
        .filter(|value| !value.trim().is_empty());
    let error = execution.error.as_ref().map(|failure| {
        json!({
            "code": failure.code,
            "message": failure.message,
            "stage": failure.stage,
            "userInteractionRequired": failure.user_interaction_required,
            "requestMethod": failure.request_method,
            "sessionId": failure.session_id,
            "threadId": failure.thread_id,
            "turnId": failure.turn_id,
            "turnStatus": failure.turn_status
        })
    });
    let stderr = execution
        .error
        .as_ref()
        .map(|failure| failure.message.clone())
        .unwrap_or_default();
    let effective = if native_session_id.is_some() {
        json!({
            "cwd": execution.effective.cwd,
            "model": execution.effective.model,
            "reasoningEffort": execution.effective.reasoning_effort,
            "permissionMode": execution.effective.permission_mode,
            "mode": execution.effective.mode,
            "runtimeAgent": execution.effective.runtime_agent,
            "allowAll": execution.effective.allow_all,
            "sandbox": execution.effective.sandbox,
            "approvalPolicy": execution.effective.approval_policy
        })
    } else {
        json!({
            "cwd": null,
            "model": null,
            "reasoningEffort": null,
            "permissionMode": null,
            "mode": null,
            "runtimeAgent": null,
            "allowAll": null,
            "sandbox": null,
            "approvalPolicy": null
        })
    };
    json!({
        "ok": execution.ok,
        "schemaVersion": RUNTIME_SCHEMA_VERSION,
        "mode": "runtime-adapter",
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "driverId": adapter.driver_id(),
        "runtimeProtocol": execution.runtime_protocol,
        "agentId": adapter.id(),
        "nativeSessionId": native_session_id,
        "sessionId": native_session_id,
        "threadId": execution.thread_id,
        "turnId": execution.turn_id,
        "turnStatus": execution.turn_status,
        "statusCode": execution.status_code,
        "output": execution.output,
        // Child stderr is never returned. This field preserves the old client
        // contract while containing only the driver's fixed sanitized message.
        "stderr": stderr,
        "error": error,
        "events": transitions,
        "lifecyclePrefix": lifecycle_prefix,
        "terminalTransition": terminal_transition,
        "capabilities": execution.capabilities,
        "stdoutTruncated": execution.stdout_truncated,
        "stderrTruncated": execution.stderr_truncated,
        "startedAt": execution.started_at,
        "completedAt": timestamp(),
        "cwd": effective["cwd"],
        "workingDirectory": effective["cwd"],
        "model": effective["model"],
        "reasoningEffort": effective["reasoningEffort"],
        "permissionMode": effective["permissionMode"],
        "sandbox": effective["sandbox"],
        "approvalPolicy": effective["approvalPolicy"],
        "effective": effective,
        "planner": false,
        "clientOwnedToolLoop": false,
        "approvalOwner": "user"
    })
}

pub(super) fn normalize_codex(execution: codex_app_server::RunResult) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false
        }),
        error: execution.error.map(|failure| {
            let failure = failure.into_payload();
            NormalizedFailure {
                code: failure.code.to_string(),
                message: failure.message.to_string(),
                stage: failure.stage.to_string(),
                user_interaction_required: failure.user_interaction_required,
                request_method: failure.request_method,
                session_id: failure.session_id,
                thread_id: failure.thread_id,
                turn_id: failure.turn_id,
                turn_status: failure.turn_status,
            }
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: codex_app_server::RUNTIME_PROTOCOL,
        driver_id: "codex-app-server",
    }
}

pub(super) fn normalize_antigravity(
    execution: antigravity_driver::RunResult,
) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false,
            "promptInArguments": true,
            "continuityIdInArguments": true
        }),
        error: execution.error.map(|failure| {
            let failure = failure.into_payload();
            NormalizedFailure {
                code: failure.code.to_string(),
                message: failure.message.to_string(),
                stage: failure.stage.to_string(),
                user_interaction_required: failure.user_interaction_required,
                request_method: failure.request_method,
                session_id: failure.session_id,
                thread_id: failure.thread_id,
                turn_id: failure.turn_id,
                turn_status: failure.turn_status,
            }
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: antigravity_driver::RUNTIME_PROTOCOL,
        driver_id: antigravity_driver::DRIVER_ID,
    }
}

pub(super) fn normalize_claude(execution: claude_code_driver::RunResult) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false,
            "processLocalContinuation": true
        }),
        error: execution.error.map(|failure| {
            let failure = failure.into_payload();
            NormalizedFailure {
                code: failure.code.to_string(),
                message: failure.message.to_string(),
                stage: failure.stage.to_string(),
                user_interaction_required: failure.user_interaction_required,
                request_method: failure.request_method,
                session_id: failure.session_id,
                thread_id: failure.thread_id,
                turn_id: failure.turn_id,
                turn_status: failure.turn_status,
            }
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: claude_code_driver::RUNTIME_PROTOCOL,
        driver_id: "claude-code-stream-json",
    }
}

pub(super) fn normalize_cursor(
    execution: crate::platform::cursor_driver::RunResult,
) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false,
            "promptInArguments": true,
            "continuityIdInArguments": true
        }),
        error: execution.error.map(|failure| {
            let failure = failure.into_payload();
            NormalizedFailure {
                code: failure.code.to_string(),
                message: failure.message.to_string(),
                stage: failure.stage.to_string(),
                user_interaction_required: failure.user_interaction_required,
                request_method: failure.request_method,
                session_id: failure.session_id,
                thread_id: failure.thread_id,
                turn_id: failure.turn_id,
                turn_status: failure.turn_status,
            }
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: crate::platform::cursor_driver::RUNTIME_PROTOCOL,
        driver_id: crate::platform::cursor_driver::DRIVER_ID,
    }
}

pub(super) fn normalize_acp(
    adapter: RuntimeAdapter,
    execution: acp_driver_runtime::RunResult,
) -> NormalizedExecution {
    debug_assert_eq!(execution.driver_id, adapter.driver_id());
    let capabilities = json!({
        "protocolVersion": execution.capabilities.protocol_version,
        "loadSession": execution.capabilities.load_session,
        "resumeSession": execution.capabilities.resume_session,
        "closeSession": execution.capabilities.close_session,
        "listSessions": execution.capabilities.list_sessions,
        "deleteSession": execution.capabilities.delete_session,
        "imagePrompts": execution.capabilities.image_prompts,
        "audioPrompts": execution.capabilities.audio_prompts,
        "embeddedContext": execution.capabilities.embedded_context
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities,
        error: execution.error.map(|failure| {
            let failure = failure.into_payload();
            NormalizedFailure {
                code: failure.code,
                message: failure.message.to_string(),
                stage: failure.stage.to_string(),
                user_interaction_required: failure.user_interaction_required,
                request_method: failure.request_method,
                session_id: failure.session_id,
                thread_id: failure.thread_id,
                turn_id: failure.turn_id,
                turn_status: failure.turn_status,
            }
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            mode: execution.effective.mode,
            runtime_agent: execution.effective.runtime_agent,
            allow_all: execution.effective.allow_all,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: execution.runtime_protocol,
        // The shared ACP engine reports the canonical driver identity from the
        // inventory. Keep the public response bound to that same identity,
        // which is deliberately distinct from the packaged agent id.
        driver_id: adapter.driver_id(),
    }
}

pub(super) fn normalize_openclaw(execution: openclaw_driver::RunResult) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let failure = failure.into_payload();
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "reasoning": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": false
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: openclaw_driver::RUNTIME_PROTOCOL,
        driver_id: "openclaw-acp",
    }
}

pub(super) fn normalize_hermes_with_protocol(
    execution: hermes_driver::RunResult,
    runtime_protocol: &'static str,
) -> NormalizedExecution {
    let transitions = match execution.error.as_ref() {
        Some(failure) => {
            crate::platform::native_agent_parser::adapters::hermes::failed_transitions(
                &failure.code,
                &failure.stage,
                &failure.message,
            )
        }
        None => crate::platform::native_agent_parser::adapters::hermes::completed_transitions(
            &execution.output,
        ),
    };
    let error = execution.error.map(|failure| {
        let failure = failure.into_payload();
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": true,
            "reasoningOverride": false
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol,
        driver_id: "hermes-acp",
    }
}

pub(super) fn normalize_pi(execution: pi_driver::RunResult) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let failure = failure.into_payload();
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": true,
            "reasoningOverride": true
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: pi_driver::RUNTIME_PROTOCOL,
        driver_id: "pi-rpc",
    }
}

pub(super) fn normalize_lico_agent(execution: lico_agent_driver::RunResult) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let failure = failure.into_payload();
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": true,
            "reasoningOverride": true
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: lico_agent_driver::RUNTIME_PROTOCOL,
        driver_id: "lico-agent-rpc",
    }
}

pub(super) fn normalize_deepseek_harness(
    execution: deepseek_harness_driver::RunResult,
) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let failure = failure.into_payload();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id: failure.thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        transitions: execution.transitions,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false,
            "cancel": false,
            "interruptSteer": false,
            "history": false,
            "modelOverride": true,
            "reasoningOverride": false
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: deepseek_harness_driver::RUNTIME_PROTOCOL,
        driver_id: deepseek_harness_driver::DRIVER_ID,
    }
}
