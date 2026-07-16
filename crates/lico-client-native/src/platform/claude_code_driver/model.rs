use super::errors::ProtocolFailure;
use serde_json::Value;
use std::time::Duration;

/// Official Claude Code streaming-input lane. Prompt and process-local
/// conversation identity never use the command line.
pub(in crate::platform) const RUNTIME_PROTOCOL: &str = "claude-code-cli-stream-json";
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
    pub(in crate::platform) events: Vec<Value>,
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
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            thread_id: failure
                .thread_id
                .clone()
                .unwrap_or_else(|| session_id.clone()),
            session_id,
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code: None,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}

/// Continuation is available only while the exact supervised streaming-input
/// process remains live. Persisted CLI resume is intentionally not used because
/// the vendor contract puts the native session identifier on argv.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(in crate::platform) struct CapabilityProbe {
    pub(in crate::platform) available: bool,
    pub(in crate::platform) version_command_ok: bool,
    pub(in crate::platform) help_command_ok: bool,
    pub(in crate::platform) stdin_prompt: bool,
    pub(in crate::platform) structured_stream: bool,
    pub(in crate::platform) new_session: bool,
    pub(in crate::platform) resume_session: bool,
    pub(in crate::platform) model: bool,
    pub(in crate::platform) reasoning_effort: bool,
    pub(in crate::platform) permission_mode: bool,
    pub(in crate::platform) interactive_approval_events: bool,
}

impl CapabilityProbe {
    pub(super) fn official(version_command_ok: bool, help_command_ok: bool) -> Self {
        Self {
            available: version_command_ok || help_command_ok,
            version_command_ok,
            help_command_ok,
            stdin_prompt: true,
            structured_stream: true,
            new_session: true,
            resume_session: true,
            model: true,
            reasoning_effort: true,
            permission_mode: true,
            interactive_approval_events: false,
        }
    }
}
