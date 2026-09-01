use super::super::acp_driver_runtime::{CapabilityProbe, RunResult};
use super::super::kilo_code_serve;
use super::KILO_CODE_DRIVER;
use super::config::{ServeTurnConfig, timestamp};
use super::probe::{endpoint_failure, unavailable_failure};
use super::transport::execute_via_serve;
use serde_json::Value;
use std::path::Path;
use std::time::{Duration, Instant};

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
    let _ = (max_stdout, max_stderr);
    let started_at = timestamp();
    let mut config = match ServeTurnConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => return failed(failure, started_at),
    };
    if executable.trim().is_empty() {
        return failed(unavailable_failure(), started_at);
    }

    let attachment = match kilo_code_serve::ensure_attachment(executable) {
        Ok(attachment) => attachment,
        Err(error) => return failed(endpoint_failure(&error.to_string()), started_at),
    };
    let Some(model) = attachment.catalog.resolve(config.model.as_deref()) else {
        return failed(
            super::super::acp_driver_runtime::ProtocolFailure::new(
                "kilo_code_serve_model_unavailable",
                "The selected Kilo model is not available from the current provider catalog.",
                "serve/model",
            ),
            started_at,
        );
    };
    config.model = Some(model.selector());
    // timeoutMs 0 opts out of any turn deadline (see runtime_adapters/dispatch),
    // so only a non-zero window gets a concrete deadline.
    let deadline = (timeout_ms != 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    match execute_via_serve(&attachment.endpoint, &config, deadline) {
        Ok(outcome) => RunResult {
            transitions: outcome.transitions,
            ok: true,
            output: outcome.output,
            error: None,
            session_id: outcome.session_id,
            thread_id: outcome.thread_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: outcome.effective,
            capabilities: outcome.capabilities,
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at,
            runtime_protocol: KILO_CODE_DRIVER.runtime_protocol,
            driver_id: KILO_CODE_DRIVER.agent_id,
        },
        Err(failure) => failed(failure, started_at),
    }
}

fn failed(
    failure: super::super::acp_driver_runtime::ProtocolFailure,
    started_at: String,
) -> RunResult {
    let failure = failure.namespaced(KILO_CODE_DRIVER);
    let transitions =
        crate::platform::native_agent_parser::adapters::kilo_code::failure_transitions(
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
        runtime_protocol: KILO_CODE_DRIVER.runtime_protocol,
        driver_id: KILO_CODE_DRIVER.agent_id,
        error: Some(failure),
    }
}
