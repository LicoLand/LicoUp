#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolFailure {
    pub(in crate::platform) code: &'static str,
    pub(in crate::platform) message: &'static str,
    pub(in crate::platform) stage: &'static str,
    pub(in crate::platform) user_interaction_required: bool,
    pub(in crate::platform) request_method: Option<String>,
    pub(in crate::platform) session_id: Option<String>,
    pub(in crate::platform) thread_id: Option<String>,
    pub(in crate::platform) turn_id: Option<String>,
    pub(in crate::platform) turn_status: Option<String>,
}

impl ProtocolFailure {
    pub(super) fn new(code: &'static str, message: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            message,
            stage,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            thread_id: None,
            turn_id: None,
            turn_status: None,
        }
    }

    pub(super) fn with_session(mut self, session_id: Option<&str>) -> Self {
        self.session_id = session_id
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string);
        self.thread_id = self.session_id.clone();
        self
    }

    pub(super) fn with_turn(mut self, turn_id: &str) -> Self {
        self.turn_id = (!turn_id.is_empty()).then(|| turn_id.to_string());
        self
    }
}

pub(super) fn supervisor_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "claude_code_supervisor_unavailable",
        "Claude Code supervisor state is unavailable.",
        "process/supervisor",
    )
}

pub(super) fn pipe_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "claude_code_pipe_failed",
        "Claude Code standard I/O is unavailable.",
        "process/start",
    )
}

pub(super) fn requires_transport_reset(failure: &ProtocolFailure) -> bool {
    matches!(
        failure.code,
        "claude_code_write_failed"
            | "claude_code_timeout"
            | "claude_code_invalid_json"
            | "claude_code_output_limit"
            | "claude_code_read_failed"
            | "claude_code_exited"
            | "claude_code_cleanup_requested"
            | "claude_code_session_mismatch"
    )
}
