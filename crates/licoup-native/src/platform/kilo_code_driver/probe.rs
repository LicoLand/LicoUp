use super::super::acp_driver_runtime::{CapabilityProbe, ProtocolFailure};
use super::super::kilo_code_serve;
use super::KILO_CODE_DRIVER;
use super::projection::serve_capabilities;
use crate::platform::native_agent_parser::adapters::kilo_code as serve_parser;
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
        .namespaced(KILO_CODE_DRIVER));
    }
    if executable.trim().is_empty() {
        return Err(unavailable_failure());
    }
    let attachment = kilo_code_serve::ensure_attachment(executable)
        .map_err(|error| endpoint_failure(&error.to_string()))?;
    let endpoint = &attachment.endpoint;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
    loop {
        match kilo_code_serve::get_json(&format!("{}/global/health", endpoint.attach_url)) {
            Ok(payload) if serve_parser::health_ready(&payload) => {
                let sessions =
                    kilo_code_serve::get_json(&format!("{}/session", endpoint.attach_url))
                        .map_err(|_| {
                            ProtocolFailure::new(
                                "acp_initialize_invalid",
                                "The ACP agent returned an invalid initialization response.",
                                "serve/session",
                            )
                            .namespaced(KILO_CODE_DRIVER)
                        })?;
                if !serve_parser::session_collection(&sessions) {
                    return Err(ProtocolFailure::new(
                        "kilo_code_serve_session_invalid",
                        "The Kilo session endpoint returned an invalid response.",
                        "serve/session",
                    ));
                }
                return Ok(serve_capabilities());
            }
            _ if Instant::now() >= deadline => {
                return Err(ProtocolFailure::new(
                    "acp_protocol_timeout",
                    "The ACP agent timed out during capability negotiation.",
                    "serve/health",
                )
                .namespaced(KILO_CODE_DRIVER));
            }
            _ => thread::sleep(HEALTH_POLL_INTERVAL),
        }
    }
}

pub(super) fn unavailable_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "acp_process_start_failed",
        "The requested ACP agent executable is not available.",
        "serve/ensure",
    )
    .namespaced(KILO_CODE_DRIVER)
}

pub(super) fn endpoint_failure(error_code: &str) -> ProtocolFailure {
    match error_code.trim() {
        "kilo_executable_missing" => ProtocolFailure::new(
            "kilo_executable_missing",
            "The requested Kilo executable is not available.",
            "serve/ensure",
        ),
        "kilo_code_serve_port_exhausted" => ProtocolFailure::new(
            "kilo_code_serve_port_exhausted",
            "No local port is available for the Kilo serve endpoint.",
            "serve/ensure",
        ),
        "kilo_code_serve_start_failed" => ProtocolFailure::new(
            "kilo_code_serve_start_failed",
            "The Kilo serve process could not be started.",
            "serve/ensure",
        ),
        "kilo_code_serve_health_failed" => ProtocolFailure::new(
            "kilo_code_serve_health_failed",
            "The Kilo serve endpoint did not become healthy.",
            "serve/health",
        ),
        "kilo_code_serve_attach_probe_failed" => ProtocolFailure::new(
            "kilo_code_serve_attach_probe_failed",
            "The Kilo serve endpoint rejected the attach probe.",
            "serve/session",
        ),
        "kilo_code_serve_state_invalid" => ProtocolFailure::new(
            "kilo_code_serve_state_invalid",
            "The Kilo serve state is invalid.",
            "serve/ensure",
        ),
        _ => ProtocolFailure::new(
            "acp_process_start_failed",
            "The Kilo serve endpoint is not available for attach.",
            "serve/ensure",
        )
        .namespaced(KILO_CODE_DRIVER),
    }
}
