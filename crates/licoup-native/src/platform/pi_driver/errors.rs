#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolFailure {
    pub(in crate::platform) code: &'static str,
    pub(in crate::platform) message: &'static str,
    pub(in crate::platform) stage: &'static str,
    pub(in crate::platform) user_interaction_required: bool,
    pub(in crate::platform) request_method: Option<String>,
    pub(in crate::platform) session_id: Option<String>,
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
            turn_id: None,
            turn_status: None,
        }
    }

    pub(super) fn with_session(mut self, session_id: Option<&str>) -> Self {
        let session_id = session_id.map(str::trim).filter(|value| !value.is_empty());
        self.session_id = session_id.map(str::to_string);
        self
    }

    pub(super) fn user_interaction(
        method: &str,
        session_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> Self {
        Self {
            code: "pi_user_interaction_required",
            message: "Pi Agent requires explicit user interaction before this turn can continue.",
            stage: "extension/ui",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        }
    }
}

impl ProtocolFailure {
    pub(super) fn with_turn(mut self, turn_id: &str) -> Self {
        if !turn_id.is_empty() {
            self.turn_id = Some(turn_id.to_string());
        }
        self
    }
}
