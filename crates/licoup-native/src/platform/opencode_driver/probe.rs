use super::{OPENCODE_DRIVER, serve_capabilities};
use crate::platform::acp_driver_runtime::{CapabilityProbe, ProtocolFailure};
use crate::platform::native_agent_parser::adapters::opencode as serve_parser;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(50);

pub(in crate::platform) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    let _ = (max_stdout, max_stderr);
    if !cwd.is_absolute() {
        return Err(ProtocolFailure::new(
            "acp_working_directory_invalid",
            "ACP conversation sessions require an absolute working directory.",
            "initialize",
        )
        .namespaced(OPENCODE_DRIVER));
    }
    let attachment = super::super::opencode_serve::ensure_attachment(executable)
        .map_err(|error| super::serve_transport::endpoint_failure(&error.to_string()))?;
    let endpoint = &attachment.endpoint;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
    let session_url = super::serve_transport::workspace_request_url(
        &endpoint.attach_url,
        &["session"],
        &cwd.to_string_lossy(),
    )
    .map_err(|failure| failure.namespaced(OPENCODE_DRIVER))?;
    let mut first_health_failure = None;
    loop {
        match super::super::opencode_serve::get_json(&format!(
            "{}/global/health",
            endpoint.attach_url
        )) {
            Ok(payload) if serve_parser::health_ready(&payload) => {
                let sessions =
                    super::super::opencode_serve::get_json(&session_url).map_err(|failure| {
                        super::serve_transport::request_failure(failure, "serve/session", None)
                    })?;
                if !serve_parser::session_collection(&sessions) {
                    return Err(ProtocolFailure::new(
                        "opencode_serve_session_invalid",
                        "The OpenCode session endpoint returned an invalid response.",
                        "serve/session",
                    ));
                }
                return Ok(serve_capabilities());
            }
            Err(failure @ super::super::local_service::http::HttpFailure::Status(401 | 403)) => {
                return Err(super::serve_transport::request_failure(
                    failure,
                    "serve/health",
                    None,
                ));
            }
            Err(failure) => {
                if first_health_failure.is_none() {
                    first_health_failure = Some(super::serve_transport::request_failure(
                        failure,
                        "serve/health",
                        None,
                    ));
                }
            }
            Ok(_) => {}
        }
        if Instant::now() >= deadline {
            return Err(first_health_failure.unwrap_or_else(|| {
                ProtocolFailure::new(
                    "opencode_serve_health_timeout",
                    "The OpenCode health endpoint did not become ready before the probe deadline.",
                    "serve/health",
                )
            }));
        }
        thread::sleep(HEALTH_POLL_INTERVAL);
    }
}
