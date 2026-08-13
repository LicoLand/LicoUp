use super::super::acp_session_transport::{self, ControlDisposition, RunResult};
use super::super::virtual_machine::SshRuntimeConnection;
use super::HERMES_SESSION_DRIVER;
use serde_json::Value;
use std::path::Path;

#[cfg(test)]
pub(in crate::platform) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    execute_with_connection(
        executable, None, params, prompt, session_id, cwd, timeout_ms, max_stdout, max_stderr,
    )
}

pub(in crate::platform) fn execute_with_connection(
    executable: &str,
    runtime_connection: Option<&SshRuntimeConnection>,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    if let Some(runtime_connection) =
        runtime_connection.filter(|connection| connection.is_hermes_tui_gateway())
    {
        return super::super::hermes_tui_gateway_driver::execute(
            runtime_connection,
            params,
            prompt,
            session_id,
            cwd,
            timeout_ms,
            max_stdout,
            max_stderr,
        );
    }
    acp_session_transport::execute(
        HERMES_SESSION_DRIVER,
        executable,
        runtime_connection,
        params,
        prompt,
        session_id,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
    )
}

pub(in crate::platform) fn cancel(session_id: &str) -> ControlDisposition {
    acp_session_transport::cancel(HERMES_SESSION_DRIVER, session_id)
}

pub(in crate::platform) fn cleanup_session(session_id: &str) -> ControlDisposition {
    acp_session_transport::cleanup_session(HERMES_SESSION_DRIVER, session_id)
}

pub fn resolve_parked_permission(token: &str, allow: bool) -> Result<Value, &'static str> {
    acp_session_transport::resolve_parked_permission(token, allow)
}
