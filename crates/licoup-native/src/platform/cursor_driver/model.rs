use super::errors::ProtocolFailure;
use serde_json::Value;
use std::time::Duration;

/// Official Cursor Agent CLI lane. Prompt and native session identity travel in
/// fixed launch arguments; continuity is backed by local Cursor chat storage.
pub(in crate::platform) const RUNTIME_PROTOCOL: &str = "cursor-agent-cli-v1";
pub(in crate::platform) const DRIVER_ID: &str = "cursor-cli";
pub(super) const CREATE_CHAT_ARGS: &[&str] = &["create-chat"];
pub(super) const TURN_ARGS: &[&str] = &[
    "--print",
    "--output-format",
    "stream-json",
    "--trust",
    "--force",
    "--stream-partial-output",
];
pub(super) const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
pub(in crate::platform) const MAX_SESSION_ID_LEN: usize = 128;
pub(in crate::platform) const MIN_SESSION_ID_LEN: usize = 8;

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
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let session_id = failure.session_id.clone().unwrap_or_default();
        let transitions =
            crate::platform::native_agent_parser::adapters::cursor::failure_transitions(
                failure.code,
                failure.stage,
                failure.message,
            );
        Self {
            ok: false,
            output: String::new(),
            transitions,
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
    pub(in crate::platform) create_chat: bool,
    pub(in crate::platform) print_turn: bool,
    pub(in crate::platform) resume_session: bool,
    pub(in crate::platform) structured_stream: bool,
    pub(in crate::platform) error_code: Option<&'static str>,
}

impl CapabilityProbe {
    pub(in crate::platform) fn official(version_ok: bool, help_ok: bool, help_text: &str) -> Self {
        let help_lower = help_text.to_ascii_lowercase();
        let create_chat = help_lower.contains("create-chat");
        let print_turn = help_lower.contains("--print");
        let resume_session = help_lower.contains("--resume");
        let structured_stream = help_lower.contains("stream-json");
        let supported = version_ok
            && help_ok
            && create_chat
            && print_turn
            && resume_session
            && structured_stream;
        Self {
            available: version_ok || help_ok,
            supported,
            version_command_ok: version_ok,
            help_command_ok: help_ok,
            create_chat,
            print_turn,
            resume_session,
            structured_stream,
            error_code: if supported {
                None
            } else {
                Some("cursor_cli_capability_incomplete")
            },
        }
    }
}
