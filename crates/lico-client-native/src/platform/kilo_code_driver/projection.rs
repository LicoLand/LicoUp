use super::super::acp_driver_runtime::{CapabilityProbe, EffectiveSettings, ProtocolFailure};
use super::config::ServeTurnConfig;
use serde_json::{Value, json};

pub(super) struct ProtocolOutcome {
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) session_id: String,
    pub(super) thread_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: EffectiveSettings,
    pub(super) capabilities: CapabilityProbe,
}

pub(super) fn project_turn(
    response: &Value,
    mut streamed: Vec<String>,
    session_id: String,
    turn_id: String,
    config: &ServeTurnConfig,
) -> Result<ProtocolOutcome, ProtocolFailure> {
    let output = extract_assistant_text(response);
    if output.is_empty() {
        return Err(ProtocolFailure::new(
            "acp_final_message_missing",
            "The ACP agent completed the turn without a final agent message.",
            "session/prompt",
        )
        .with_session(Some(&session_id)));
    }
    if streamed.is_empty() {
        streamed.push(output.clone());
    }
    let mut events = streamed
        .into_iter()
        .map(|text| {
            json!({
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}
            })
        })
        .collect::<Vec<_>>();
    events.extend(super::super::skill_invocation_projection::project_skill_invocations(response));
    Ok(ProtocolOutcome {
        output,
        events,
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

pub(super) fn extract_assistant_text(response: &Value) -> String {
    let mut chunks = Vec::new();
    if let Some(parts) = response.get("parts").and_then(Value::as_array) {
        append_text_parts(parts, &mut chunks);
    }
    if chunks.is_empty()
        && let Some(items) = response.as_array()
    {
        for item in items {
            if let Some(parts) = item.get("parts").and_then(Value::as_array) {
                append_text_parts(parts, &mut chunks);
            }
        }
    }
    chunks.join("")
}

fn append_text_parts(parts: &[Value], chunks: &mut Vec<String>) {
    for part in parts {
        if part.get("type").and_then(Value::as_str) == Some("text")
            && let Some(text) = part.get("text").and_then(Value::as_str)
        {
            chunks.push(text.to_string());
        }
    }
}
