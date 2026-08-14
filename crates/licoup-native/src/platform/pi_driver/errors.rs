#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolFailure(Box<ProtocolFailurePayload>);

#[derive(Clone, Debug)]
pub(in crate::platform) struct ProtocolFailurePayload {
    pub(in crate::platform) code: &'static str,
    pub(in crate::platform) message: &'static str,
    pub(in crate::platform) stage: &'static str,
    pub(in crate::platform) user_interaction_required: bool,
    pub(in crate::platform) request_method: Option<String>,
    pub(in crate::platform) session_id: Option<String>,
    pub(in crate::platform) turn_id: Option<String>,
    pub(in crate::platform) turn_status: Option<String>,
}

impl std::ops::Deref for ProtocolFailure {
    type Target = ProtocolFailurePayload;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for ProtocolFailure {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

impl ProtocolFailure {
    pub(in crate::platform) fn into_payload(self) -> ProtocolFailurePayload {
        *self.0
    }

    pub(super) fn new(code: &'static str, message: &'static str, stage: &'static str) -> Self {
        Self(Box::new(ProtocolFailurePayload {
            code,
            message,
            stage,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            turn_id: None,
            turn_status: None,
        }))
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
        Self(Box::new(ProtocolFailurePayload {
            code: "pi_user_interaction_required",
            message: "Pi Agent requires explicit user interaction before this turn can continue.",
            stage: "extension/ui",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        }))
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
