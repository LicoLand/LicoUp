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
            component: None,
            retryable: None,
            recovery: None,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            thread_id: None,
            turn_id: None,
            turn_status: None,
        })
    }

    pub(in crate::platform) fn with_resolution(
        mut self,
        component: &'static str,
        retryable: bool,
        recovery: &'static str,
    ) -> Self {
        self.component = Some(component);
        self.retryable = Some(retryable);
        self.recovery = Some(recovery);
        self
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
