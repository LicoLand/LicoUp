use super::{OPENCODE_DRIVER, serve_capabilities};
use crate::platform::acp_driver_runtime::{CapabilityProbe, ProtocolFailure};
use serde_json::Value;
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(50);

pub(in crate::platform) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
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
    let endpoint =
        super::super::opencode_serve::ensure_attach_endpoint(executable).map_err(|_| {
            ProtocolFailure::new(
                "acp_process_start_failed",
                "The OpenCode serve endpoint is not available for attach.",
                "serve/ensure",
            )
            .namespaced(OPENCODE_DRIVER)
        })?;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
    loop {
        match super::super::opencode_serve::get_json(&format!(
            "{}/global/health",
            endpoint.attach_url
        )) {
            Ok(payload)
                if payload
                    .get("healthy")
                    .and_then(Value::as_bool)
                    .unwrap_or(false) =>
            {
                super::super::opencode_serve::get_json(&format!("{}/session", endpoint.attach_url))
                    .map_err(|_| {
                        ProtocolFailure::new(
                            "acp_initialize_invalid",
                            "The ACP agent returned an invalid initialization response.",
                            "serve/session",
                        )
                        .namespaced(OPENCODE_DRIVER)
                    })?;
                return Ok(serve_capabilities());
            }
            _ if Instant::now() >= deadline => {
                return Err(ProtocolFailure::new(
                    "acp_protocol_timeout",
                    "The ACP agent timed out during capability negotiation.",
                    "serve/health",
                )
                .namespaced(OPENCODE_DRIVER));
            }
            _ => thread::sleep(HEALTH_POLL_INTERVAL),
        }
    }
}
