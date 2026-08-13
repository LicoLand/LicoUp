use super::{CapabilityProbe, OPENCODE_DRIVER};

pub(in crate::platform) fn cancel(
    session_id: &str,
) -> super::super::local_service::turn_control::ControlDisposition {
    super::super::local_service::turn_control::cancel(OPENCODE_DRIVER.agent_id, session_id)
}

pub(in crate::platform) fn serve_capabilities() -> CapabilityProbe {
    CapabilityProbe {
        protocol_version: Some(u64::from(crate::core::acp::PROTOCOL_VERSION)),
        load_session: true,
        resume_session: true,
        close_session: true,
        list_sessions: true,
        delete_session: false,
        additional_directories: false,
        image_prompts: false,
        audio_prompts: false,
        embedded_context: false,
    }
}
