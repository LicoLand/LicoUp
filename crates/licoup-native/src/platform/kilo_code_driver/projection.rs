use super::super::acp_driver_runtime::{CapabilityProbe, EffectiveSettings, ProtocolFailure};
use super::config::ServeTurnConfig;
use crate::platform::native_agent_parser::adapters::kilo_code::ServeMessage;

pub(super) struct ProtocolOutcome {
    pub(super) output: String,
    pub(super) transitions: Vec<crate::platform::native_agent_parser::Transition>,
    pub(super) session_id: String,
    pub(super) thread_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: EffectiveSettings,
    pub(super) capabilities: CapabilityProbe,
}

pub(super) fn project_turn(
    response: ServeMessage,
    session_id: String,
    turn_id: String,
    config: &ServeTurnConfig,
) -> Result<ProtocolOutcome, ProtocolFailure> {
    let output = response.output;
    Ok(ProtocolOutcome {
        output,
        transitions: response.transitions,
        thread_id: session_id.clone(),
        session_id,
        turn_id,
        turn_status: "end_turn".to_string(),
        effective: EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            model: config.model.clone(),
            reasoning_effort: config.reasoning_effort.clone(),
            mode: config.mode.clone(),
            runtime_agent: config.runtime_agent.clone(),
            allow_all: config.allow_all,
            sandbox: None,
            approval_policy: None,
        },
        capabilities: serve_capabilities(),
    })
}

pub(super) fn serve_capabilities() -> CapabilityProbe {
    CapabilityProbe {
        protocol_version: Some(1),
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
