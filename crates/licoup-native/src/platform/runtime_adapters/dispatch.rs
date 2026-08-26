use super::adapter::adapter_for_agent;
use super::artifact::runtime_executable;
use super::normalization::{
    execution_response, normalize_acp, normalize_antigravity, normalize_claude, normalize_codex,
    normalize_cursor, normalize_deepseek_harness, normalize_hermes_with_protocol,
    normalize_lico_agent, normalize_openclaw, normalize_pi,
};
use super::params::{
    AttachmentShapeFailure, LocalImageInput, MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE,
    MAX_IMAGE_ATTACHMENT_BYTES_TOTAL, binary_param, bounded_output_param, codex_binary_param,
    message_param, optional_output_param, parse_attachments, text_param, timeout_param,
};
use super::{
    DEFAULT_MAX_STDERR_BYTES, MAX_TIMEOUT_MS, MIN_TIMEOUT_MS, RuntimeAdapter, RuntimeAdapterError,
    runtime_driver_profile,
};
use crate::platform::agent_workspace::resolve_local_agent_workspace;
use crate::platform::virtual_machine::{SshRuntimeConnection, is_valid_guest_working_directory};
use crate::platform::{
    antigravity_driver, claude_code_driver, codex_app_server, copilot_driver, cursor_driver,
    deepseek_harness_driver, hermes_driver, kilo_code_driver, kimi_code_driver, lico_agent_driver,
    openclaw_driver, opencode_driver, pi_driver,
};
use serde_json::Value;
use std::{
    borrow::Cow,
    fs,
    io::Read,
    path::{Path, PathBuf},
};

fn attachment_shape_error(failure: AttachmentShapeFailure) -> RuntimeAdapterError {
    match failure {
        AttachmentShapeFailure::ListExceeded => RuntimeAdapterError::AttachmentListExceeded,
        AttachmentShapeFailure::NotArray
        | AttachmentShapeFailure::NotObject
        | AttachmentShapeFailure::UnknownField
        | AttachmentShapeFailure::FieldMissing => RuntimeAdapterError::AttachmentInvalid,
        AttachmentShapeFailure::MediaUnsupported => RuntimeAdapterError::AttachmentMediaUnsupported,
        AttachmentShapeFailure::RemoteUrl => RuntimeAdapterError::AttachmentRemoteUnsupported,
    }
}

/// Only the exact Codex app-server adapter with direct local transport may
/// carry image attachments. Every admission failure happens before any
/// process launch and never exposes a path.
fn admit_attachments(
    attachments: &[LocalImageInput],
    adapter: &RuntimeAdapter,
    remote_transport: bool,
) -> Result<(), RuntimeAdapterError> {
    if *adapter != RuntimeAdapter::Codex || remote_transport {
        return Err(RuntimeAdapterError::AttachmentUnsupportedForAdapter {
            agent_label: adapter.id().to_string(),
        });
    }
    let mut total_bytes: u64 = 0;
    for attachment in attachments {
        let metadata = fs::symlink_metadata(&attachment.path)
            .map_err(|_| RuntimeAdapterError::AttachmentFileUnavailable)?;
        if metadata.file_type().is_symlink() {
            return Err(RuntimeAdapterError::AttachmentSymlinkRejected);
        }
        if !metadata.file_type().is_file() {
            return Err(RuntimeAdapterError::AttachmentFileUnavailable);
        }
        total_bytes = total_bytes.checked_add(metadata.len()).unwrap_or(u64::MAX);
        if metadata.len() > MAX_IMAGE_ATTACHMENT_BYTES_PER_FILE
            || total_bytes > MAX_IMAGE_ATTACHMENT_BYTES_TOTAL
        {
            return Err(RuntimeAdapterError::AttachmentSizeLimit);
        }
        verify_attachment_signature(Path::new(&attachment.path), &attachment.media_type)?;
    }
    Ok(())
}

fn verify_attachment_signature(path: &Path, media_type: &str) -> Result<(), RuntimeAdapterError> {
    let mut file =
        fs::File::open(path).map_err(|_| RuntimeAdapterError::AttachmentFileUnavailable)?;
    let mut prefix = [0u8; 12];
    let mut read = 0usize;
    loop {
        let chunk = file
            .read(&mut prefix[read..])
            .map_err(|_| RuntimeAdapterError::AttachmentFileUnavailable)?;
        if chunk == 0 {
            break;
        }
        read += chunk;
        if read == prefix.len() {
            break;
        }
    }
    let matches = match media_type {
        "image/png" => read >= 8 && prefix[..8] == [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A],
        "image/jpeg" => read >= 3 && prefix[..3] == [0xFF, 0xD8, 0xFF],
        "image/gif" => read >= 4 && &prefix[..4] == b"GIF8",
        "image/webp" => read >= 12 && &prefix[..4] == b"RIFF" && &prefix[8..12] == b"WEBP",
        _ => false,
    };
    if !matches {
        return Err(RuntimeAdapterError::AttachmentSignatureMismatch);
    }
    Ok(())
}

pub fn send_message(params: &Value) -> Result<Value, RuntimeAdapterError> {
    if params.get("command").is_some() || params.get("args").is_some() {
        return Err(RuntimeAdapterError::LegacyLaunchConfiguration);
    }
    let agent_id = text_param(params, &["agent", "agentId", "target"])
        .filter(|value| !value.is_empty())
        .ok_or(RuntimeAdapterError::AgentIdentifierMissing)?;
    let attachments = parse_attachments(params).map_err(attachment_shape_error)?;
    let text = message_param(params, &["text", "message", "prompt"]).unwrap_or_default();
    if text.trim().is_empty() && attachments.is_empty() {
        return Err(RuntimeAdapterError::MessageMissing);
    }
    let adapter =
        adapter_for_agent(&agent_id).ok_or_else(|| RuntimeAdapterError::UnsupportedAdapter {
            agent_label: agent_id.clone(),
        })?;
    crate::platform::native_agent_parser::require_registered(adapter);
    if adapter == RuntimeAdapter::DeepSeekHarness
        && runtime_driver_profile(adapter.id()).is_none_or(|profile| profile.readiness != "ready")
    {
        return Err(RuntimeAdapterError::RuntimeProfileUnavailable);
    }
    let runtime_connection = SshRuntimeConnection::from_params(params, adapter.id())
        .map_err(|_| RuntimeAdapterError::ConversationDispatchFailed)?;
    if !attachments.is_empty() {
        admit_attachments(&attachments, &adapter, runtime_connection.is_some())?;
    }
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
    // Omission and zero mean no deadline. Every explicit non-zero setting is
    // either preserved byte-for-byte as the driver window or rejected before
    // process launch; dispatch never silently clamps a caller request.
    let timeout_ms = timeout_param(params, "timeoutMs", MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
        .map_err(|_| RuntimeAdapterError::InvalidRuntimeSetting { field: "timeoutMs" })?;
    let max_stdout = optional_output_param(params, "maxStdoutBytes").map_err(|_| {
        RuntimeAdapterError::InvalidRuntimeSetting {
            field: "maxStdoutBytes",
        }
    })?;
    let max_stderr = bounded_output_param(params, "maxStderrBytes", DEFAULT_MAX_STDERR_BYTES)
        .map_err(|_| RuntimeAdapterError::InvalidRuntimeSetting {
            field: "maxStderrBytes",
        })?;
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
        RuntimeAdapter::DeepSeekHarness => {
            normalize_deepseek_harness(deepseek_harness_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ))
        }
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
