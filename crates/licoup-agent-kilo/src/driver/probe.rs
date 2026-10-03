//! The capability probe this Agent answers before it is offered.
//!
//! A host asks one thing before it offers Kilo Code: is this endpoint up, and
//! which models is it on? The probe answers by reading this Agent's own four
//! documents — health, sessions, configuration and providers — and reporting
//! readiness only when all four were understood. Anything less reports a failure
//! with the code that names what was missing.
//!
//! The loop is here because the *waiting* is this Agent's contract: the endpoint
//! may take up to a minute to become healthy, and a probe that gave up early
//! would report a healthy endpoint as missing. The sockets, however, are the
//! engine's — every read arrives through [`crate::port::serve`], so the package
//! never opens one.

use super::{ProtocolFailure, RUNTIME_PROTOCOL};
use crate::parser;
use crate::policy;
use crate::port::serve;
use licoup_agent_adapter_sdk::serve::ServeReadiness;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

/// How long the probe waits between two health reads.
const HEALTH_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// The engine operations one probe performs.
///
/// It carries the two facts the engine owns — where a diagnostic record's bytes
/// are filed and whether a path is absolute — so a probe can be exercised
/// without a host at all.
#[derive(Clone, Copy)]
pub struct EndpointProbe {
    pub get_json: fn(&str) -> Result<serde_json::Value, String>,
    pub observe_bytes: fn(source: &str, direction: serve::ServeByteDirection, bytes: &str),
    pub is_absolute: fn(&Path) -> bool,
}

impl EndpointProbe {
    /// The probe an installed host answers with.
    pub fn installed() -> Self {
        Self {
            get_json: |url| serve::get_json(url),
            observe_bytes: |source, direction, bytes| {
                serve::observe_bytes(source, direction, bytes)
            },
            is_absolute: Path::is_absolute,
        }
    }
}

/// This Agent's endpoint paths, read from its own policy.
fn health_url(attach_url: &str) -> String {
    policy::endpoint_url(attach_url, policy::SPEC.health_path)
}

fn sessions_url(attach_url: &str) -> String {
    policy::endpoint_url(attach_url, policy::SPEC.session_probe_path)
}

/// Probe one endpoint, reporting what this Agent's documents said.
///
/// `executable` names the program the engine attaches to; `cwd` is the directory
/// this Agent requires to be absolute; `timeout_ms` bounds the wait for health.
pub fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    probe: EndpointProbe,
) -> Result<ServeReadiness, ProtocolFailure> {
    if !(probe.is_absolute)(cwd) {
        return Err(ProtocolFailure::new(
            "acp_working_directory_invalid",
            "ACP conversation sessions require an absolute working directory.",
            "initialize",
        ));
    }
    if executable.trim().is_empty() {
        return Err(unavailable_failure());
    }
    let attachment = serve::ensure_attachment(executable)
        .map_err(|error_code| endpoint_failure(&error_code))?;
    let attach_url = &attachment.endpoint.attach_url;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
    loop {
        match (probe.get_json)(&health_url(attach_url)) {
            Ok(health) if parser::health_ready(&health) => {
                let sessions = (probe.get_json)(&sessions_url(attach_url)).map_err(|_| {
                    ProtocolFailure::new(
                        "acp_initialize_invalid",
                        "The ACP agent returned an invalid initialization response.",
                        "serve/session",
                    )
                })?;
                if !parser::session_collection(&sessions) {
                    return Err(ProtocolFailure::new(
                        "kilo_code_serve_session_invalid",
                        "The Kilo session endpoint returned an invalid response.",
                        "serve/session",
                    ));
                }
                // The configuration and provider documents decide the model
                // catalogue. A service that answers health but not these is not
                // ready: a turn started against it could not resolve its model.
                let config = (probe.get_json)(&policy::endpoint_url(
                    attach_url,
                    policy::SPEC.config_path,
                ))
                .map_err(|_| readiness_unavailable("serve/config"))?;
                let providers = (probe.get_json)(&policy::endpoint_url(
                    attach_url,
                    policy::SPEC.provider_path,
                ))
                .map_err(|_| readiness_unavailable("serve/provider"))?;
                return parser::readiness(&health, &sessions, &config, &providers)
                    .ok_or_else(|| readiness_unavailable("serve/readiness"));
            }
            _ if Instant::now() >= deadline => {
                return Err(ProtocolFailure::new(
                    "acp_protocol_timeout",
                    "The ACP agent timed out during capability negotiation.",
                    "serve/health",
                ));
            }
            _ => thread::sleep(HEALTH_POLL_INTERVAL),
        }
    }
}

fn readiness_unavailable(stage: &'static str) -> ProtocolFailure {
    ProtocolFailure::new(
        "kilo_code_serve_readiness_unavailable",
        "The Kilo serve endpoint did not report the documents a turn needs.",
        stage,
    )
}

/// The failure one missing executable reports.
pub fn unavailable_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "acp_process_start_failed",
        "The requested ACP agent executable is not available.",
        "serve/ensure",
    )
}

/// The failure one engine code means, in this Agent's own vocabulary.
///
/// Every code the Agent's own policy can report has a fixed message and stage
/// here; a code this package does not recognise is reported as a start failure
/// rather than passed through as an unexplained string.
pub fn endpoint_failure(error_code: &str) -> ProtocolFailure {
    let errors = policy::SPEC.errors;
    match error_code.trim() {
        code if code == errors.executable_missing => ProtocolFailure::new(
            errors.executable_missing,
            "The requested Kilo executable is not available.",
            "serve/ensure",
        ),
        code if code == errors.port_exhausted => ProtocolFailure::new(
            errors.port_exhausted,
            "No local port is available for the Kilo serve endpoint.",
            "serve/ensure",
        ),
        code if code == errors.start_failed => ProtocolFailure::new(
            errors.start_failed,
            "The Kilo serve process could not be started.",
            "serve/ensure",
        ),
        code if code == errors.health_failed => ProtocolFailure::new(
            errors.health_failed,
            "The Kilo serve endpoint did not become healthy.",
            "serve/health",
        ),
        code if code == errors.attach_probe_failed => ProtocolFailure::new(
            errors.attach_probe_failed,
            "The Kilo serve endpoint rejected the attach probe.",
            "serve/session",
        ),
        code if code == errors.invalid_state => ProtocolFailure::new(
            errors.invalid_state,
            "The Kilo serve state is invalid.",
            "serve/ensure",
        ),
        _ => ProtocolFailure::new(
            "acp_process_start_failed",
            "The Kilo serve endpoint is not available for attach.",
            "serve/ensure",
        ),
    }
}

/// The absolute path this Agent requires, or the failure that says so.
pub fn require_absolute(cwd: &Path) -> Result<PathBuf, ProtocolFailure> {
    if cwd.is_absolute() {
        Ok(cwd.to_path_buf())
    } else {
        Err(ProtocolFailure::new(
            "acp_working_directory_invalid",
            "ACP conversation sessions require an absolute working directory.",
            "initialize",
        ))
    }
}

/// The runtime protocol stamp this Agent's results carry.
pub fn runtime_protocol() -> &'static str {
    RUNTIME_PROTOCOL
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// A probe that reads nothing: the refusals below happen before any read,
    /// which is exactly what they assert.
    fn silent_probe() -> EndpointProbe {
        EndpointProbe {
            get_json: |_| Err("the probe must not read before it is ready".to_owned()),
            observe_bytes: |_, _, _| {},
            is_absolute: Path::is_absolute,
        }
    }

    #[test]
    fn a_relative_directory_is_refused_before_the_endpoint_is_touched() {
        let probe = silent_probe();
        let failure = capability_probe("kilo", Path::new("relative"), 10, probe).unwrap_err();
        assert_eq!(failure.code, "acp_working_directory_invalid");
    }

    #[test]
    fn an_empty_executable_reports_the_unavailable_failure() {
        let probe = silent_probe();
        let failure = capability_probe("  ", Path::new("/workspace"), 10, probe).unwrap_err();
        assert_eq!(failure.code, "acp_process_start_failed");
        assert_eq!(failure.stage, "serve/ensure");
    }

    #[test]
    fn every_policy_code_has_its_own_message_and_an_unknown_code_falls_back() {
        let errors = policy::SPEC.errors;
        for code in [
            errors.executable_missing,
            errors.port_exhausted,
            errors.start_failed,
            errors.health_failed,
            errors.attach_probe_failed,
            errors.invalid_state,
        ] {
            let failure = endpoint_failure(code);
            assert_eq!(failure.code, code);
            assert!(!failure.message.is_empty());
        }
        let unknown = endpoint_failure("something_else");
        assert_eq!(unknown.code, "acp_process_start_failed");
        assert_eq!(unknown.stage, "serve/ensure");
    }

    #[test]
    fn readiness_requires_all_four_documents() {
        // Health and sessions are healthy, but the provider catalogue is empty,
        // so no current model exists and the endpoint is not ready.
        assert!(
            parser::readiness(
                &json!({"healthy": true, "version": "1.2.3"}),
                &json!([]),
                &json!({}),
                &json!({"all": []}),
            )
            .is_none()
        );
    }

    #[test]
    fn require_absolute_answers_the_path_or_the_refusal() {
        assert_eq!(
            require_absolute(Path::new("/workspace")).unwrap(),
            PathBuf::from("/workspace")
        );
        assert!(require_absolute(Path::new("workspace")).is_err());
        assert_eq!(runtime_protocol(), "kilo-code-serve-http-v1");
    }
}
