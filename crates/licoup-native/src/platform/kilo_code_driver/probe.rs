//! The capability probe, composed from the package that owns it.
//!
//! *Which* documents decide Kilo Code's readiness — health, sessions,
//! configuration and providers — and *when* the endpoint counts as ready are the
//! Agent's own answers and live in `licoup-agent-kilo::driver::probe`. What this
//! module owns is where the reads go: the client's serve engine, reached through
//! the package's `ServePort`.
//!
//! The translation is one way. A package failure keeps the package's message and
//! stage exactly, and its code is re-stated from this Agent's own closed set,
//! because the client's failure type carries a static code. A code outside that
//! set is reported as a protocol failure rather than spliced in as an arbitrary
//! string.

use super::super::acp_driver_runtime::{CapabilityProbe, ProtocolFailure};
use super::KILO_CODE_DRIVER;
use licoup_agent_kilo::driver::{self, EndpointProbe};
use std::path::Path;

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    let _ = (max_stdout, max_stderr);
    driver::capability_probe(executable, cwd, timeout_ms, EndpointProbe::installed())
        .map(probe_to_client)
        .map_err(failure_to_client)
        .map_err(|failure| failure.namespaced(KILO_CODE_DRIVER))
}

/// The package's failure, in the client's shared driver vocabulary.
fn failure_to_client(failure: driver::ProtocolFailure) -> ProtocolFailure {
    ProtocolFailure::new(
        static_code(&failure.code),
        failure.message,
        failure.stage,
    )
    .with_session(failure.session_id.as_deref())
}

/// The client's static spelling of one of this Agent's closed failure codes.
fn static_code(code: &str) -> &'static str {
    let errors = &licoup_agent_kilo::policy::SPEC.errors;
    for known in [
        errors.executable_missing,
        errors.port_exhausted,
        errors.start_failed,
        errors.health_failed,
        errors.attach_probe_failed,
        errors.not_found,
        errors.request_failed,
        errors.invalid_json,
        errors.invalid_state,
        errors.stop_failed,
        "acp_working_directory_invalid",
        "acp_initialize_invalid",
        "acp_protocol_timeout",
        "acp_process_start_failed",
        "kilo_code_serve_session_invalid",
        "kilo_code_serve_readiness_unavailable",
    ] {
        if code == known {
            return known;
        }
    }
    "kilo_code_serve_protocol_failed"
}

/// The package's capability answer, in the client's shared probe vocabulary.
///
/// It is a field copy: the package already decided every capability, and this
/// function decides none of them.
fn probe_to_client(probe: driver::CapabilityProbe) -> CapabilityProbe {
    CapabilityProbe {
        protocol_version: probe.protocol_version,
        load_session: probe.load_session,
        resume_session: probe.resume_session,
        close_session: probe.close_session,
        list_sessions: probe.list_sessions,
        delete_session: probe.delete_session,
        additional_directories: probe.additional_directories,
        image_prompts: probe.image_prompts,
        audio_prompts: probe.audio_prompts,
        embedded_context: probe.embedded_context,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_relative_workspace_is_refused_before_any_process_or_http_work() {
        let failure = capability_probe("unused", Path::new("relative"), 10, None, 16).unwrap_err();
        assert_eq!(failure.code, "acp_working_directory_invalid");
        assert_eq!(failure.stage, "initialize");
    }

    #[test]
    fn an_empty_executable_reports_the_process_start_failure() {
        let failure = capability_probe("  ", Path::new("/workspace"), 10, None, 16).unwrap_err();
        assert_eq!(failure.code, "kilo_code_serve_process_start_failed");
        assert_eq!(failure.stage, "serve/ensure");
    }

    #[test]
    fn every_package_code_keeps_its_own_spelling_across_the_seam() {
        let errors = &licoup_agent_kilo::policy::SPEC.errors;
        for code in [
            errors.executable_missing,
            errors.port_exhausted,
            errors.start_failed,
            errors.health_failed,
            errors.attach_probe_failed,
            errors.invalid_state,
        ] {
            assert_eq!(static_code(code), code);
        }
        // A code outside the closed set is reported as a protocol failure rather
        // than spliced in as an arbitrary string.
        assert_eq!(
            static_code("something_unexpected"),
            "kilo_code_serve_protocol_failed"
        );
    }

    #[test]
    fn the_package_failure_crosses_with_its_message_stage_and_session_intact() {
        let failure = failure_to_client(
            driver::ProtocolFailure::new(
                "kilo_code_serve_session_invalid",
                "The Kilo session endpoint returned an invalid response.",
                "serve/session",
            )
            .with_session(Some("kilo-1")),
        );
        assert_eq!(failure.code, "kilo_code_serve_session_invalid");
        assert_eq!(failure.stage, "serve/session");
        assert_eq!(failure.message, "The Kilo session endpoint returned an invalid response.");
        assert_eq!(failure.session_id.as_deref(), Some("kilo-1"));
        assert_eq!(failure.thread_id.as_deref(), Some("kilo-1"));
    }

    #[test]
    fn the_capability_answer_crosses_as_a_field_copy() {
        let probe = driver::serve_capabilities();
        assert_eq!(probe_to_client(probe), probe);
        assert_eq!(probe.protocol_version, Some(1));
        assert!(probe.load_session && probe.resume_session && probe.list_sessions);
        assert!(!probe.delete_session && !probe.image_prompts && !probe.audio_prompts);
    }
}
