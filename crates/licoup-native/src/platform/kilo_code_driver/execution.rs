//! One Kilo Code turn, composed from the package that owns it.
//!
//! What one Kilo turn *is* — the request shape, the session-open protocol, the
//! stream classification, the terminal projection — belongs to the package
//! ([`licoup_agent_kilo::driver`]). What this module owns is the composition: it
//! attaches to the endpoint through the engine, admits the turn so force stop can
//! reach it, asks the package to perform the turn against the installed ports,
//! and maps the package's result onto the client's shared driver vocabulary.
//!
//! Nothing here re-reads a vendor document and nothing here decides what a frame
//! means. The client supplies the engine and the consumer; the Agent supplies the
//! protocol.

use super::super::acp_driver_runtime::{CapabilityProbe, RunResult};
use super::super::local_service;
use super::{KILO_CODE_DRIVER, RUNTIME_PROTOCOL, policy};
use licoup_agent_kilo::driver::{self, ServeTurnConfig};
use serde_json::Value;
use std::path::Path;
use std::time::{Duration, Instant};

pub(super) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    let _ = (max_stdout, max_stderr);
    let started_at = driver::timestamp();
    let mut config = match ServeTurnConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return failed(failure, started_at),
    };
    if executable.trim().is_empty() {
        return failed(driver::protocol::unavailable_failure(), started_at);
    }

    let attachment = match local_service::serve::ensure_attachment(policy::serve_spec(), executable)
    {
        Ok(attachment) => attachment,
        Err(error) => {
            return failed(
                driver::protocol::endpoint_failure(&error.to_string()),
                started_at,
            );
        }
    };
    let Some(model) = attachment.catalog.resolve(config.model.as_deref()) else {
        return failed(
            driver::ProtocolFailure::new(
                "kilo_code_serve_model_unavailable",
                "The selected Kilo model is not available from the current provider catalog.",
                "serve/model",
            ),
            started_at,
        );
    };
    config.model = Some(model.selector());

    let endpoint = licoup_agent_kilo::port::serve::ServeEndpoint {
        host: attachment.endpoint.host.clone(),
        port: attachment.endpoint.port,
        attach_url: attachment.endpoint.attach_url.clone(),
    };
    // Admission belongs to the engine and its guard is held for the whole turn:
    // force stop reaches an active turn through this registration, and a turn
    // that gave the guard up early would be unreachable while it still runs. The
    // session identity is bound once the turn has opened it, so the registration
    // names the endpoint rather than a session the turn has not chosen yet.
    let Ok(_active_turn) = local_service::turn_control::register(
        KILO_CODE_DRIVER.agent_id,
        &endpoint.attach_url,
        turn_registration_key(&config),
        None,
    ) else {
        return failed(
            driver::ProtocolFailure::new(
                "acp_control_capacity",
                "The Kilo active-turn control registry is at capacity.",
                "turn/control",
            )
            .with_session(Some(&config.requested_session_id)),
            started_at,
        );
    };

    // timeoutMs 0 opts out of any turn deadline (see runtime_adapters/dispatch),
    // so only a non-zero window gets a concrete deadline.
    let deadline = (timeout_ms != 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    match driver::execute_via_serve(&endpoint, &config, deadline) {
        Ok(outcome) => RunResult {
            transitions: outcome.transitions,
            ok: true,
            output: outcome.output,
            error: None,
            session_id: outcome.session_id,
            thread_id: outcome.thread_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: effective(outcome.effective),
            capabilities: capabilities(outcome.capabilities),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at,
            runtime_protocol: RUNTIME_PROTOCOL,
            driver_id: KILO_CODE_DRIVER.agent_id,
        },
        Err(failure) => failed(failure, started_at),
    }
}

/// The key one turn is registered under.
///
/// A fresh turn has no native session yet, so it registers under the driver
/// identity; a resume registers under the session it is resuming, which is what
/// force stop looks a resumed conversation up by.
fn turn_registration_key(config: &ServeTurnConfig) -> &str {
    if config.is_resume() {
        &config.requested_session_id
    } else {
        KILO_CODE_DRIVER.agent_id
    }
}

/// The package's failure, in the client's shared driver vocabulary.
///
/// The code, the message and the stage are the package's own; only the type
/// changes, because the client's driver table reads its own shape.
fn failed(failure: driver::ProtocolFailure, started_at: String) -> RunResult {
    let failure = failure.namespaced(KILO_CODE_DRIVER);
    let transitions = licoup_agent_kilo::parser::failure_transitions(
        &failure.code,
        failure.stage,
        failure.message,
    );
    RunResult {
        ok: false,
        output: String::new(),
        transitions,
        session_id: failure.session_id.clone().unwrap_or_default(),
        thread_id: failure.thread_id.clone().unwrap_or_default(),
        turn_id: failure.turn_id.clone().unwrap_or_default(),
        turn_status: failure.turn_status.clone().unwrap_or_default(),
        effective: Default::default(),
        capabilities: CapabilityProbe::default(),
        status_code: None,
        stdout_truncated: false,
        stderr_truncated: false,
        started_at,
        runtime_protocol: RUNTIME_PROTOCOL,
        driver_id: KILO_CODE_DRIVER.agent_id,
        error: Some(failure),
    }
}

fn effective(
    settings: driver::EffectiveSettings,
) -> super::super::acp_driver_runtime::EffectiveSettings {
    super::super::acp_driver_runtime::EffectiveSettings {
        cwd: settings.cwd,
        model: settings.model,
        reasoning_effort: settings.reasoning_effort,
        mode: settings.mode,
        runtime_agent: settings.runtime_agent,
        allow_all: settings.allow_all,
        sandbox: settings.sandbox,
        approval_policy: settings.approval_policy,
    }
}

fn capabilities(probe: driver::CapabilityProbe) -> CapabilityProbe {
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
    use serde_json::json;

    #[test]
    fn an_empty_executable_fails_closed_without_a_session_fallback() {
        let cwd = std::env::current_dir().unwrap();
        let result = execute(
            "",
            &json!({}),
            "private-kilo-prompt",
            "existing-kilo-native",
            Some(&cwd),
            1_000,
            Some(1024),
            1024,
        );
        assert!(!result.ok);
        assert_eq!(result.driver_id, "kilo-code-serve");
        assert_eq!(result.runtime_protocol, RUNTIME_PROTOCOL);
        assert_eq!(
            result.error.as_ref().map(|failure| failure.code.as_str()),
            Some("kilo_code_serve_process_start_failed")
        );
        assert!(matches!(
            result.transitions.last(),
            Some(licoup_agent_kilo::driver::Transition::Failed { code, .. })
                if code == "kilo_code_serve_process_start_failed"
        ));
    }

    #[test]
    fn a_relative_workspace_is_refused_before_the_endpoint_is_attached() {
        let result = execute(
            "kilo",
            &json!({}),
            "prompt",
            "native",
            Some(Path::new("relative")),
            1_000,
            None,
            1024,
        );
        assert!(!result.ok);
        assert_eq!(
            result.error.as_ref().map(|failure| failure.code.as_str()),
            Some("acp_working_directory_invalid")
        );
    }

    #[test]
    fn a_fresh_turn_registers_under_the_driver_and_a_resume_under_its_session() {
        let fresh = ServeTurnConfig::from_params(
            &json!({"cwd": "/workspace"}),
            "prompt",
            "",
            None,
        )
        .unwrap();
        assert_eq!(turn_registration_key(&fresh), "kilo-code-serve");
        let resumed = ServeTurnConfig::from_params(
            &json!({"cwd": "/workspace"}),
            "prompt",
            "kilo-1",
            None,
        )
        .unwrap();
        assert_eq!(turn_registration_key(&resumed), "kilo-1");
    }
}
