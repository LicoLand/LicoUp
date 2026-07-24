use crate::core::acp;

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

    pub(super) fn user_interaction(
        method: &str,
        session_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> Self {
        Self {
            code: "openclaw_user_interaction_required",
            message: "OpenClaw requires explicit user interaction before this turn can continue.",
            stage: "server/request",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        }
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
