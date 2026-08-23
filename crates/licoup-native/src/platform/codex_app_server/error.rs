use super::model::{EffectiveSettings, ProtocolFailure, ProtocolFailurePayload, RunResult};

impl ProtocolFailure {
    pub(in crate::platform) fn new(
        code: &'static str,
        message: &'static str,
        stage: &'static str,
    ) -> Self {
        Self::from_payload(ProtocolFailurePayload {
            code,
            message,
            stage,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            thread_id: None,
            turn_id: None,
            turn_status: None,
        })
    }

    pub(in crate::platform) fn user_interaction(
        method: &str,
        session_id: Option<&str>,
        thread_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> Self {
        Self::from_payload(ProtocolFailurePayload {
            code: "codex_user_interaction_required",
            message: "Codex requires user interaction before this turn can continue.",
            stage: "server/request",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            thread_id: thread_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        })
    }
}

impl RunResult {
    pub(in crate::platform) fn failed(
        failure: ProtocolFailure,
        started_at: String,
        status_code: Option<i32>,
        stdout_truncated: bool,
        stderr_truncated: bool,
    ) -> Self {
        let transitions =
            crate::platform::native_agent_parser::adapters::codex::failure_transitions(
                failure.code,
                failure.stage,
                failure.message,
            );
        Self {
            ok: false,
            output: String::new(),
            transitions,
            session_id: failure.session_id.clone().unwrap_or_default(),
            thread_id: failure.thread_id.clone().unwrap_or_default(),
            turn_id: failure.turn_id.clone().unwrap_or_default(),
            turn_status: failure.turn_status.clone().unwrap_or_default(),
            effective: EffectiveSettings::default(),
            error: Some(failure),
            status_code,
            stdout_truncated,
            stderr_truncated,
            started_at,
        }
    }
}
