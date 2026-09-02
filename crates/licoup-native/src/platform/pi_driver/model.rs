use super::errors::ProtocolFailure;
use serde_json::Value;
use std::time::Duration;

/// Official Pi Coding Agent lane: `pi --mode rpc` JSONL over stdin/stdout.
/// Prompts and session identity stay on the stdio channel; launch argv is fixed.
pub(in crate::platform) const RUNTIME_PROTOCOL: &str = "pi-rpc-stdio-jsonl";
pub(super) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct EffectiveSettings {
    pub(in crate::platform) cwd: Option<String>,
    pub(in crate::platform) model: Option<String>,
    pub(in crate::platform) reasoning_effort: Option<String>,
    pub(in crate::platform) permission_mode: Option<String>,
    pub(in crate::platform) sandbox: Option<Value>,
    pub(in crate::platform) approval_policy: Option<Value>,
}

#[derive(Debug)]
pub(in crate::platform) struct RunResult {
    pub(in crate::platform) ok: bool,
    pub(in crate::platform) output: String,
    pub(in crate::platform) transitions: Vec<crate::platform::native_agent_parser::Transition>,
    pub(in crate::platform) error: Option<ProtocolFailure>,
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) thread_id: String,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) turn_status: String,
    pub(in crate::platform) effective: EffectiveSettings,
    pub(in crate::platform) status_code: Option<i32>,
    pub(in crate::platform) stdout_truncated: bool,
    pub(in crate::platform) stderr_truncated: bool,
    pub(in crate::platform) started_at: String,
}

impl RunResult {
    pub(super) fn failed(
        failure: ProtocolFailure,
        started_at: String,
        status_code: Option<i32>,
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        let transitions =
            crate::platform::native_agent_parser::adapters::pi::failed_transitions(&failure);
        Self {
            ok: false,
            output: String::new(),
            transitions,
            error: Some(failure.clone()),
            thread_id: session_id.clone(),
            session_id,
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            status_code,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct CapabilityProbe {
    pub(in crate::platform) available: bool,
    pub(in crate::platform) supported: bool,
    pub(in crate::platform) version_command_ok: bool,
    pub(in crate::platform) help_command_ok: bool,
    pub(in crate::platform) error_code: Option<&'static str>,
}

impl CapabilityProbe {
    pub(super) fn unavailable() -> Self {
        Self {
            available: false,
            supported: false,
            version_command_ok: false,
            help_command_ok: false,
            error_code: Some("pi_executable_unavailable"),
        }
    }

    pub(super) fn installed(version_command_ok: bool, help_command_ok: bool) -> Self {
        Self {
            available: true,
            supported: true,
            version_command_ok,
            help_command_ok,
            error_code: None,
        }
    }
}
