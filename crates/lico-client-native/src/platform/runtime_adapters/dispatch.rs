use super::adapter::adapter_for_agent;
use super::artifact::runtime_executable;
use super::normalization::{
    execution_response, normalize_acp, normalize_antigravity, normalize_claude, normalize_codex,
    normalize_cursor, normalize_hermes, normalize_openclaw, normalize_pi,
};
use super::params::{
    binary_param, bounded_output_param, codex_binary_param, message_param, text_param, u64_param,
};
use super::{
    DEFAULT_MAX_STDERR_BYTES, DEFAULT_MAX_STDOUT_BYTES, DEFAULT_TIMEOUT_MS, MAX_MESSAGE_BYTES,
    MAX_TIMEOUT_MS, MIN_TIMEOUT_MS, RuntimeAdapter, RuntimeAdapterError,
};
use crate::platform::{
    antigravity_driver, claude_code_driver, codex_app_server, copilot_driver, cursor_driver,
    hermes_driver, kilo_code_driver, kimi_code_driver, openclaw_driver, opencode_driver, pi_driver,
};
use serde_json::Value;
use std::{env, path::PathBuf};

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
    let session_id = text_param(params, &["sessionId", "nativeSessionId"]).unwrap_or_default();
    let cwd = text_param(params, &["cwd", "workingDirectory"])
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::current_dir().ok());
    let timeout_ms =
        u64_param(params, "timeoutMs", DEFAULT_TIMEOUT_MS).clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    let max_stdout = bounded_output_param(params, "maxStdoutBytes", DEFAULT_MAX_STDOUT_BYTES);
    let max_stderr = bounded_output_param(params, "maxStderrBytes", DEFAULT_MAX_STDERR_BYTES);
    let requested_executable = if adapter == RuntimeAdapter::Codex {
        codex_binary_param(params)
    } else {
        binary_param(params, adapter.default_binary())
    };
    let executable = runtime_executable(adapter, &requested_executable)?;

    let execution = match adapter {
        RuntimeAdapter::Antigravity => normalize_antigravity(antigravity_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
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
            max_stdout,
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
        RuntimeAdapter::Hermes => normalize_hermes(hermes_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::OpenClaw => normalize_openclaw(openclaw_driver::execute(
            &executable,
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
    };

    Ok(execution_response(adapter, execution))
}
