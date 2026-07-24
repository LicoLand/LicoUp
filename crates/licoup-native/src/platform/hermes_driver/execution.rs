use super::super::acp_session_transport::{self, ControlDisposition, RunResult};
use super::HERMES_SESSION_DRIVER;
use serde_json::Value;
use std::path::Path;

pub(in crate::platform) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    acp_session_transport::execute(
        HERMES_SESSION_DRIVER,
        executable,
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
