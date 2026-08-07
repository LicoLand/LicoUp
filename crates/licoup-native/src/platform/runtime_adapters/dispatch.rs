use super::adapter::adapter_for_agent;
use super::artifact::runtime_executable;
use super::normalization::{
    execution_response, normalize_acp, normalize_antigravity, normalize_claude, normalize_codex,
    normalize_cursor, normalize_hermes_with_protocol, normalize_lico_agent, normalize_openclaw,
    normalize_pi,
};
use super::params::{
    binary_param, bounded_output_param, codex_binary_param, message_param, text_param, u64_param,
};
use super::{
    DEFAULT_MAX_STDERR_BYTES, DEFAULT_MAX_STDOUT_BYTES, DEFAULT_TIMEOUT_MS, MAX_MESSAGE_BYTES,
    MAX_TIMEOUT_MS, MIN_TIMEOUT_MS, RuntimeAdapter, RuntimeAdapterError,
};
use crate::platform::agent_workspace::resolve_local_agent_workspace;
use crate::platform::virtual_machine::{SshRuntimeConnection, is_valid_guest_working_directory};
use crate::platform::{
    antigravity_driver, claude_code_driver, codex_app_server, copilot_driver, cursor_driver,
    hermes_driver, kilo_code_driver, kimi_code_driver, lico_agent_driver, openclaw_driver,
    opencode_driver, pi_driver,
};
use serde_json::Value;
use std::{
    borrow::Cow,
    path::{Path, PathBuf},
};

pub fn send_message(params: &Value) -> Result<Value, RuntimeAdapterError> {
    let agent_id = text_param(params, &["agent", "agentId", "target"])
        .filter(|value| !value.is_empty())
        .ok_or(RuntimeAdapterError::AgentIdentifierMissing)?;
    let text = message_param(params, &["text", "message", "prompt"])
        .filter(|value| !value.trim().is_empty())
        .ok_or(RuntimeAdapterError::MessageMissing)?;
    if text.len() > MAX_MESSAGE_BYTES {
        return Err(RuntimeAdapterError::MessageInputLimit);
    }
    let adapter =
        adapter_for_agent(&agent_id).ok_or_else(|| RuntimeAdapterError::UnsupportedAdapter {
            agent_label: agent_id.clone(),
        })?;
    let runtime_connection = SshRuntimeConnection::from_params(params, adapter.id())
        .map_err(|_| RuntimeAdapterError::ConversationDispatchFailed)?;
    let session_id = text_param(params, &["sessionId", "nativeSessionId"]).unwrap_or_default();
    let requested_cwd = text_param(params, &["cwd", "workingDirectory"])
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    if runtime_connection.is_some()
        && requested_cwd
            .as_deref()
            .is_some_and(|path| !is_valid_guest_working_directory(path))
    {
        return Err(RuntimeAdapterError::ConversationDispatchFailed);
    }
    // A local agent indexes the directory it runs in, so the client resolves
    // one bounded workspace here and every driver reads it from the same place.
    // A guest working directory belongs to the remote host and stays untouched.
    let cwd = match runtime_connection.as_ref() {
        Some(connection) => {
            requested_cwd.or_else(|| Some(PathBuf::from(connection.working_directory())))
        }
        None => resolve_local_agent_workspace(adapter.id(), requested_cwd.as_deref()),
    };
    let params = match (runtime_connection.is_none(), cwd.as_deref()) {
        (true, Some(workspace)) => Cow::Owned(params_with_workspace(params, workspace)),
        _ => Cow::Borrowed(params),
    };
    let params = params.as_ref();
    let timeout_ms =
        u64_param(params, "timeoutMs", DEFAULT_TIMEOUT_MS).clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    let max_stdout = bounded_output_param(params, "maxStdoutBytes", DEFAULT_MAX_STDOUT_BYTES);
    let max_stderr = bounded_output_param(params, "maxStderrBytes", DEFAULT_MAX_STDERR_BYTES);
    let requested_executable = if adapter == RuntimeAdapter::Codex {
        codex_binary_param(params)
    } else {
        binary_param(params, adapter.default_binary())
    };
    let executable = if runtime_connection.is_some() {
        "ssh".to_string()
    } else {
        runtime_executable(adapter, &requested_executable)?
    };

    let execution = match adapter {
        RuntimeAdapter::Antigravity => normalize_antigravity(antigravity_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            Some(max_stdout),
            max_stderr,
        )),
        RuntimeAdapter::ClaudeCode => normalize_claude(claude_code_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::Codex => normalize_codex(codex_app_server::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::Copilot => normalize_acp(
            adapter,
            copilot_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::Cursor => normalize_cursor(cursor_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            Some(max_stdout),
            max_stderr,
        )),
        RuntimeAdapter::KiloCode => normalize_acp(
            adapter,
            kilo_code_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::KimiCode => normalize_acp(
            adapter,
            kimi_code_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::Hermes => {
            let runtime_protocol = if runtime_connection
                .as_ref()
                .is_some_and(SshRuntimeConnection::is_hermes_tui_gateway)
            {
                crate::platform::hermes_tui_gateway::RUNTIME_PROTOCOL
            } else {
                hermes_driver::RUNTIME_PROTOCOL
            };
            normalize_hermes_with_protocol(
                hermes_driver::execute_with_connection(
                    &executable,
                    runtime_connection.as_ref(),
                    params,
                    &text,
                    &session_id,
                    cwd.as_deref(),
                    timeout_ms,
                    max_stdout,
                    max_stderr,
                ),
                runtime_protocol,
            )
        }
        RuntimeAdapter::OpenClaw => normalize_openclaw(openclaw_driver::execute_with_connection(
            &executable,
            runtime_connection.as_ref(),
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::OpenCode => normalize_acp(
            adapter,
            opencode_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::Pi => normalize_pi(pi_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::LicoAgent => normalize_lico_agent(lico_agent_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
    };

    Ok(execution_response(adapter, execution))
}

/// Republish the resolved workspace under both request keys so a driver that
/// reads its working directory from the request cannot reach past the bound.
pub(super) fn params_with_workspace(params: &Value, workspace: &Path) -> Value {
    let mut resolved = params.clone();
    if let Some(object) = resolved.as_object_mut() {
        let workspace = Value::String(workspace.to_string_lossy().into_owned());
        object.insert("cwd".to_string(), workspace.clone());
        object.insert("workingDirectory".to_string(), workspace);
    }
    resolved
}
