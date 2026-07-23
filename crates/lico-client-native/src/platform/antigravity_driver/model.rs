use super::errors::ProtocolFailure;
use serde_json::Value;
use std::time::Duration;

/// Temporary official Antigravity CLI lane.
///
/// Prompt and native conversation identity travel in launch arguments
/// (`--print=<prompt>`, `--conversation=<id>`), matching Cursor's argv privacy
/// exception. Session identity is recovered from the official Agent Hooks
/// contract (`conversationId` on stdin / `ANTIGRAVITY_CONVERSATION_ID`).
pub(in crate::platform) const RUNTIME_PROTOCOL: &str = "antigravity-cli-argv-hook-v1";
pub(in crate::platform) const DRIVER_ID: &str = "antigravity-cli";
pub(super) const HOOK_NAMESPACE: &str = "lico-arc-antigravity-session";
pub(super) const RECEIPT_ENV: &str = "LICO_ANTIGRAVITY_SESSION_RECEIPT";
pub(super) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
pub(super) const MAX_SESSION_ID_LEN: usize = 128;
pub(super) const MIN_SESSION_ID_LEN: usize = 8;

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
            thread_id: failure.thread_id.clone().unwrap_or_default(),
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

#[derive(Clone, Debug, Default)]
pub(in crate::platform) struct CapabilityProbe {
    pub(in crate::platform) available: bool,
    pub(in crate::platform) supported: bool,
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
    pub(in crate::platform) error_code: Option<&'static str>,
}

impl CapabilityProbe {
    pub(super) fn unavailable() -> Self {
        Self {
            available: false,
            supported: false,
            error_code: Some("antigravity_executable_unavailable"),
            ..Self::default()
        }
    }

    pub(super) fn official(
        version_command_ok: bool,
        help_command_ok: bool,
        help_text: &str,
    ) -> Self {
        let print = help_text.contains("--print");
        let conversation = help_text.contains("--conversation");
        let model = help_text.contains("--model");
        let effort = help_text.contains("--effort");
        let supported = print && conversation;
        Self {
            available: true,
            supported,
            version_command_ok,
            help_command_ok,
            stdin_prompt: false,
            structured_stream: false,
            new_session: supported,
            resume_session: supported,
            model,
            reasoning_effort: effort,
            permission_mode: help_text.contains("--dangerously-skip-permissions"),
            interactive_approval_events: false,
            error_code: if supported {
                None
            } else {
                Some("antigravity_cli_argv_hook_surface_unavailable")
            },
        }
    }
}
