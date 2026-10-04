//! The Kimi Code driver, composed from the Kimi Code adapter package.
//!
//! What is Kimi's — the runtime protocol identity, the `kimi acp` launch
//! metadata, the model and reasoning settings, the autonomous-mode flag, and the
//! ACP frame dialect its frames are read through — belongs to Kimi and lives in
//! `licoup-agent-kimi` now. This module composes that half with the shared ACP
//! engine `licoup-agent-drivers` owns, at the visibility the host's own driver
//! table reads.
//!
//! What is still composed by the client is the *turn* half: the conversation
//! lane that decides whether a Kimi turn may run, the normalization that folds
//! the Agent's report into this host's execution vocabulary, and the control
//! plane that answers a cancellation. The package declares the agent-execution
//! port that half is meant to travel through; until that route is completed,
//! the kernel still reaches the engines directly here, and a turn does not run
//! from the package's binary. That remainder belongs to `VENDOR-CODE-REMOVAL`.

use serde_json::Value;
use std::path::Path;

use super::acp_driver_runtime::{CapabilityProbe, ControlDisposition, ProtocolFailure, RunResult};

pub(super) use licoup_agent_kimi::driver::RUNTIME_PROTOCOL;

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    licoup_agent_kimi::driver::capability_probe(
        executable,
        cwd,
        timeout_ms,
        max_stdout,
        max_stderr,
    )
}

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
    licoup_agent_kimi::driver::execute(
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
    licoup_agent_kimi::driver::cancel(session_id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The launch metadata this host composes is the package's own, so the
    /// host cannot describe a different Kimi than the package declares.
    #[test]
    fn canonical_driver_is_only_official_acp_entrypoint() {
        let driver = licoup_agent_kimi::driver::DRIVER;
        assert_eq!(RUNTIME_PROTOCOL, "kimi-code-acp-v1-stdio-ndjson");
        assert_eq!(driver.runtime_protocol, RUNTIME_PROTOCOL);
        assert_eq!(driver.agent_id, "kimi-code-acp");
        assert_eq!(driver.error_prefix, "kimi_code_acp");
        assert_eq!(driver.launch_args, &["acp"]);
        assert_eq!(driver.launch_model_arg, Some("--model"));
        assert_eq!(driver.launch_reasoning_env, Some("KIMI_MODEL_THINKING_EFFORT"));
        assert_eq!(driver.launch_reasoning_values, &["low", "high", "max"]);
        assert_eq!(driver.launch_allow_all_arg, Some("--auto"));
    }

    #[test]
    fn launch_arguments_cannot_disclose_prompt_or_native_session() {
        let driver = licoup_agent_kimi::driver::DRIVER;
        assert_eq!(driver.launch_args.len(), 1);
        assert!(
            !driver
                .launch_args
                .iter()
                .any(|argument| argument.contains("prompt") || argument.contains("session"))
        );
    }

    #[test]
    fn failures_keep_the_single_acp_identity_and_redact_request_values() {
        let result = execute(
            "unused",
            &json!({}),
            "private-prompt",
            "private-session",
            Some(Path::new("relative")),
            10,
            Some(1024),
            1024,
        );
        assert!(!result.ok);
        assert_eq!(result.driver_id, "kimi-code-acp");
        assert_eq!(result.runtime_protocol, RUNTIME_PROTOCOL);
        let failure = result.error.expect("structured ACP failure");
        assert!(!failure.message.contains("private"));
    }
}
