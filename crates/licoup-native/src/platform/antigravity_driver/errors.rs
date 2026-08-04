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
        let Some(session_id) = session_id.map(str::trim).filter(|value| !value.is_empty()) else {
            return self;
        };
        self.session_id = Some(session_id.to_string());
        self.thread_id = Some(session_id.to_string());
        self
    }

    pub(super) fn with_user_interaction(mut self) -> Self {
        self.user_interaction_required = true;
        self
    }
}
