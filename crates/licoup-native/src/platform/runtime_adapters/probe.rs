use super::RuntimeAdapter;
use super::adapter::adapter_for_agent;
use crate::platform::{
    acp_driver_runtime, antigravity_driver, claude_code_driver, copilot_driver, cursor_driver,
    hermes_driver, kilo_code_driver, kimi_code_driver, lico_agent_driver, openclaw_driver,
    opencode_driver, pi_driver,
};
use serde_json::{Value, json};
use std::path::Path;

/// Probes only the official fixed-argument entrypoint and emits redacted
/// booleans. No command output, paths, account data, or runtime content escapes.
pub(crate) fn probe_runtime_driver(target: &str, executable: &Path, cwd: &Path) -> Value {
    let executable = executable.to_string_lossy();
    let Some(adapter) = adapter_for_agent(target) else {
        return json!({"available": false, "supported": false, "errorCode": "unknown_adapter"});
    };
    match adapter {
        RuntimeAdapter::Antigravity => {
            let probe = antigravity_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "stdinPrompt": probe.stdin_prompt,
                "structuredStream": probe.structured_stream,
                "newSession": probe.new_session,
                "resumeSession": probe.resume_session,
                "model": probe.model,
                "reasoningEffort": probe.reasoning_effort,
                "permissionMode": probe.permission_mode,
                "interactiveApprovalEvents": probe.interactive_approval_events,
                "versionCommandOk": probe.version_command_ok,
                "helpCommandOk": probe.help_command_ok,
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::ClaudeCode => {
            let probe = claude_code_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.available,
                "stdinPrompt": probe.stdin_prompt,
                "structuredStream": probe.structured_stream,
                "newSession": probe.new_session,
                "resumeSession": probe.resume_session,
                "model": probe.model,
                "reasoningEffort": probe.reasoning_effort,
                "permissionMode": probe.permission_mode,
                "interactiveApprovalEvents": probe.interactive_approval_events
            })
        }
        RuntimeAdapter::Codex => json!({
            "available": executable.as_ref() != "",
            "supported": true,
            "stdinPrompt": true,
            "structuredStream": true,
            "newSession": true,
            "resumeSession": true,
            "interactiveApprovalEvents": false
        }),
        RuntimeAdapter::Copilot => probe_acp_runtime(copilot_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            Some(64 * 1024),
            16 * 1024,
        )),
        RuntimeAdapter::Cursor => {
            let probe = cursor_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "createChat": probe.create_chat,
                "printTurn": probe.print_turn,
                "resumeSession": probe.resume_session,
                "structuredStream": probe.structured_stream,
                "versionCommandOk": probe.version_command_ok,
                "helpCommandOk": probe.help_command_ok,
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::Hermes => {
            let probe = hermes_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supports_streaming,
                "tools": probe.supports_tools,
                "approvals": probe.supports_approvals,
                "modelOverride": probe.supports_model_override,
                "reasoningOverride": probe.supports_reasoning_override,
                "versionDetected": probe.version.is_some(),
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::KiloCode => probe_acp_runtime(kilo_code_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            Some(64 * 1024),
            16 * 1024,
        )),
        RuntimeAdapter::KimiCode => probe_acp_runtime(kimi_code_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            Some(64 * 1024),
            16 * 1024,
        )),
        RuntimeAdapter::OpenClaw => {
            let probe = openclaw_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supports_streaming,
                "tools": probe.supports_tools,
                "approvals": probe.supports_approvals,
                "reasoning": probe.supports_reasoning,
                "modelOverride": probe.supports_model_override,
                "versionDetected": probe.version.is_some(),
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::OpenCode => probe_acp_runtime(opencode_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            Some(64 * 1024),
            16 * 1024,
        )),
        RuntimeAdapter::Pi => {
            let probe = pi_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supported,
                "versionCommandOk": probe.version_command_ok,
                "helpCommandOk": probe.help_command_ok,
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::LicoAgent => {
            let probe = lico_agent_driver::probe(Path::new(executable.as_ref()));
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supported,
                "versionCommandOk": probe.version_command_ok,
                "helpCommandOk": probe.help_command_ok,
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::DeepSeekHarness => {
            let available = !executable.as_ref().is_empty();
            let ready = super::registry::runtime_driver_profile(adapter.id())
                .is_some_and(|profile| profile.readiness == "ready");
            json!({
                "available": available,
                "supported": available && ready,
                "newSession": available && ready,
                "resumeSession": available && ready,
                "structuredStream": available && ready,
                "cancel": false,
                "interruptSteer": false,
                "history": false,
                "errorCode": if available && ready {
                    Value::Null
                } else {
                    json!("deepseek_harness_jsonrpc_carrier_unverified")
                }
            })
        }
    }
}

fn probe_acp_runtime(
    result: std::result::Result<
        acp_driver_runtime::CapabilityProbe,
        acp_driver_runtime::ProtocolFailure,
    >,
) -> Value {
    match result {
        Ok(probe) => json!({
            "available": true,
            "supported": probe.protocol_version == Some(1),
            "protocolVersion": probe.protocol_version,
            "loadSession": probe.load_session,
            "resumeSession": probe.resume_session,
            "closeSession": probe.close_session,
            "listSessions": probe.list_sessions,
            "deleteSession": probe.delete_session,
            "imagePrompts": probe.image_prompts,
            "audioPrompts": probe.audio_prompts,
            "embeddedContext": probe.embedded_context
        }),
        Err(failure) => json!({
            "available": false,
            "supported": false,
            "errorCode": failure.code
        }),
    }
}
