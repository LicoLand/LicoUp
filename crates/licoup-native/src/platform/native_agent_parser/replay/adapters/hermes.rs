//! Replay arm for the `hermes` adapter.

use super::super::{FrameReplay, RecordedFrame};
use crate::platform::acp_session_transport::{
    EffectiveSettings, ProtocolConfig, ProtocolEffect, ProtocolFailure, SessionProtocol,
};
use serde_json::{Value, json};

/// The exact-resume request configuration. `SessionProtocol` fixes its
/// configuration for the whole transcript, and the recorded transcripts open
/// the conversation the client already knew, so the arm replays the driver's
/// exact-resume configuration: `session/load` carrying `REQUESTED_SESSION_ID`.
const REQUESTED_SESSION_ID: &str = "native-session";
const PROMPT: &str = "<REDACTED_CONTENT>";
const CWD: &str = "/workspace/synthetic-project";
/// The turn id is request identity rather than parser output, so the recorder
/// keeps it fixed; it is never projected.
const TURN_ID: &str = "synthetic-turn";

pub(super) struct Replay {
    protocol: SessionProtocol,
}

impl Replay {
    pub(super) fn new() -> Result<Self, String> {
        Ok(Self {
            protocol: SessionProtocol::new(ProtocolConfig {
                prompt: PROMPT.to_owned(),
                requested_session_id: REQUESTED_SESSION_ID.to_owned(),
                cwd: CWD.to_owned(),
                model: None,
                turn_id: TURN_ID.to_owned(),
                mcp_servers: Vec::new(),
            }),
        })
    }
}

impl FrameReplay for Replay {
    fn feed(&mut self, frame: &RecordedFrame) -> Result<Vec<Value>, String> {
        // The Hermes session state machine consumes every recorded frame: a
        // frame it rejects is reported as a `fail` effect, never as a boundary
        // error.
        Ok(self
            .protocol
            .handle_frame(frame.payload.as_bytes())
            .effects
            .into_iter()
            .map(effect_projection)
            .collect())
    }
}

/// Project one real `ProtocolEffect`. The turn id is carried from the request
/// configuration and is never parser output, so it is omitted here as it is for
/// the ACP adapters whose state machine generates one.
fn effect_projection(effect: ProtocolEffect) -> Value {
    match effect {
        ProtocolEffect::Send(message) => json!({"effect": "send", "message": message}),
        ProtocolEffect::Complete(outcome) => json!({
            "effect": "complete",
            "output": outcome.output,
            "sessionId": outcome.session_id,
            "turnStatus": outcome.turn_status,
            "effective": effective_projection(&outcome.effective),
            "events": outcome.events,
        }),
        ProtocolEffect::Fail(failure) => failure_projection(&failure),
        ProtocolEffect::AwaitExternalApproval {
            request_id,
            display_summary,
            option_id,
            requested_tools,
        } => json!({
            "effect": "await_external_approval",
            "requestId": request_id,
            "displaySummary": display_summary,
            "optionId": option_id,
            "requestedTools": requested_tools,
        }),
    }
}

fn failure_projection(failure: &ProtocolFailure) -> Value {
    let mut entry = json!({
        "error": failure.code,
        "message": failure.message,
        "stage": failure.stage,
        "userInteractionRequired": failure.user_interaction_required,
    });
    let fields = entry.as_object_mut().expect("projection object");
    if let Some(session_id) = failure.session_id.as_deref() {
        fields.insert("sessionId".into(), json!(session_id));
    }
    if let Some(method) = failure.request_method.as_deref() {
        fields.insert("requestMethod".into(), json!(method));
    }
    if let Some(status) = failure.turn_status.as_deref() {
        fields.insert("turnStatus".into(), json!(status));
    }
    entry
}

fn effective_projection(effective: &EffectiveSettings) -> Value {
    json!({
        "cwd": effective.cwd,
        "model": effective.model,
        "reasoningEffort": effective.reasoning_effort,
        "sandbox": effective.sandbox,
        "approvalPolicy": effective.approval_policy,
    })
}
