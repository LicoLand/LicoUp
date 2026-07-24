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
    pub(in crate::platform) fn new(
        code: &'static str,
        message: &'static str,
        stage: &'static str,
    ) -> Self {
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

    pub(in crate::platform) fn user_interaction(
        method: &str,
        session_id: Option<&str>,
        turn_id: Option<&str>,
    ) -> Self {
        Self {
            code: "hermes_user_interaction_required",
            message: "Hermes Agent requires explicit user interaction before this turn can continue.",
            stage: "server/request",
            user_interaction_required: true,
            request_method: Some(method.to_string()),
            session_id: session_id.map(str::to_string),
            turn_id: turn_id.map(str::to_string),
            turn_status: None,
        }
    }

    pub(in crate::platform) fn from_acp(error: acp::AcpError, stage: &'static str) -> Self {
        Self::new(
            error.code(),
            "The Hermes ACP protocol message could not be processed safely.",
            stage,
        )
    }
}

pub(in crate::platform) fn supervisor_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "hermes_acp_supervisor_unavailable",
        "Hermes ACP supervisor state is unavailable.",
        "process/supervisor",
    )
}

pub(in crate::platform) fn failure_requires_transport_reset(failure: &ProtocolFailure) -> bool {
    matches!(
        failure.code,
        "hermes_acp_write_failed"
            | "hermes_acp_timeout"
            | "hermes_acp_invalid_json"
            | "hermes_acp_output_limit"
            | "hermes_acp_read_failed"
            | "hermes_acp_exited"
            | "hermes_acp_cleanup_requested"
    )
}
