use crate::core::acp;

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

    pub(super) fn user_interaction(
        method: &str,
        session_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> Self {
        Self(Box::new(ProtocolFailurePayload {
            code: "openclaw_user_interaction_required",
            message: "OpenClaw requires explicit user interaction before this turn can continue.",
            stage: "server/request",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        }))
    }

    pub(super) fn from_acp(error: acp::AcpError, stage: &'static str) -> Self {
        Self::new(
            error.code(),
            "The OpenClaw ACP protocol message could not be processed safely.",
            stage,
        )
    }

    pub(super) fn with_ids(mut self, session_id: Option<String>, turn_id: &str) -> Self {
        self.session_id = session_id.filter(|value| !value.is_empty());
        self.turn_id = (!turn_id.is_empty()).then(|| turn_id.to_string());
        self
    }
}
