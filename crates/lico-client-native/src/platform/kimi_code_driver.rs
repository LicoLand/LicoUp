//! Kimi Code's canonical local conversation transport.
//!
//! Kimi Code officially exposes ACP v1 over stdio through `kimi acp`. The
//! stable ACP surface owns session creation, exact load/resume, streamed
//! updates, in-flight cancellation, and session listing. Keeping every
//! operation on that one transport prevents a session created by one protocol
//! from being resumed through a different protocol with a misleading identity.

use serde_json::Value;
use std::path::Path;

use super::acp_driver_runtime::{AcpDriverSpec, execute_acp, probe_acp};
pub(super) use super::acp_driver_runtime::{CapabilityProbe, ProtocolFailure, RunResult};

pub(super) const RUNTIME_PROTOCOL: &str = "kimi-code-acp-v1-stdio-ndjson";
const KIMI_CODE_DRIVER: AcpDriverSpec =
    AcpDriverSpec::new(RUNTIME_PROTOCOL, &["acp"]).with_identity("kimi-code-acp", "kimi_code_acp");

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    probe_acp(
        KIMI_CODE_DRIVER,
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
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    execute_acp(
        KIMI_CODE_DRIVER,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn canonical_driver_is_only_official_acp_entrypoint() {
        assert_eq!(RUNTIME_PROTOCOL, "kimi-code-acp-v1-stdio-ndjson");
        assert_eq!(KIMI_CODE_DRIVER.agent_id, "kimi-code-acp");
        assert_eq!(KIMI_CODE_DRIVER.error_prefix, "kimi_code_acp");
        assert_eq!(KIMI_CODE_DRIVER.launch_args, &["acp"]);
    }

    #[test]
    fn launch_arguments_cannot_disclose_prompt_or_native_session() {
        assert_eq!(KIMI_CODE_DRIVER.launch_args.len(), 1);
        assert!(
            !KIMI_CODE_DRIVER
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
            1024,
            1024,
        );
        assert!(!result.ok);
        assert_eq!(result.driver_id, "kimi-code-acp");
        assert_eq!(result.runtime_protocol, RUNTIME_PROTOCOL);
        let failure = result.error.expect("structured ACP failure");
        assert_eq!(failure.code, "kimi_code_acp_working_directory_invalid");
        assert!(!failure.message.contains("private"));
    }
}
