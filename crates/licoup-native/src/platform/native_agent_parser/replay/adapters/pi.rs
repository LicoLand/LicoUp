//! Replay arm for the `pi` adapter.
//!
//! Pi frames are JSONL lines on the stdio RPC channel. The arm feeds each
//! recorded line through the transport's own framing helper
//! (`decode_jsonl_line`) into the same `PiProtocol` the driver builds, and
//! reports the protocol effects that frame produced. Nothing here re-reads a
//! vendor payload.

use super::super::{FrameReplay, RecordedFrame};
use crate::platform::native_agent_parser::adapters::pi::{
    PiProtocol, ProtocolEffect, decode_jsonl_line,
};
use crate::platform::pi_driver::params::ProtocolConfig;
use serde_json::{Value, json};
use std::path::PathBuf;

/// Synthetic invocation identity. The driver decides resume-versus-new before
/// the first inbound frame, so the arm reconstructs that decision from the
/// protocol (see `configuration`). None of these values is a machine fact.
const SYNTHETIC_PROMPT: &str = "synthetic-pi-prompt";
const SYNTHETIC_CWD: &str = "synthetic-workspace";
const SYNTHETIC_TURN_ID: &str = "synthetic-turn";
const RESUMED_SESSION_ID: &str = "pi-native-resume-1";
const RESUMED_SESSION_PATH: &str = "synthetic-pi-native-resume.jsonl";

pub(super) struct Replay {
    protocol: Option<PiProtocol>,
}

impl Replay {
    pub(super) fn new() -> Result<Self, String> {
        Ok(Self { protocol: None })
    }
}

impl FrameReplay for Replay {
    fn feed(&mut self, frame: &RecordedFrame) -> Result<Vec<Value>, String> {
        let message = match decode_jsonl_line(&frame.payload) {
            Ok(Some(message)) => message,
            Ok(None) => return Ok(Vec::new()),
            // The transport's own framing rejection. `decode_jsonl_line`
            // answers a unit error, so `invalid_json` is the whole fact: this
            // line did not decode. The driver's protocol-failure code for the
            // same event is deliberately not projected, so the fixture fails
            // when the framing helper changes rather than when a code is
            // renamed.
            Err(()) => return Ok(vec![json!({"error": "invalid_json"})]),
        };
        let protocol = self
            .protocol
            .get_or_insert_with(|| PiProtocol::new(configuration(&message)));
        Ok(protocol
            .handle_message(message)
            .iter()
            .map(effect_fact)
            .collect())
    }
}

/// Rebuild the invocation the driver would have started this transcript with.
/// Only Pi's own `switch_session` response belongs to a resumed conversation
/// (`PiProtocol::initial_request` issues the switch only when a resume path was
/// supplied), so that frame is the one document that identifies the resume
/// invocation; every other transcript starts a new session.
fn configuration(message: &Value) -> ProtocolConfig {
    let resuming = message.get("type").and_then(Value::as_str) == Some("response")
        && message.get("command").and_then(Value::as_str) == Some("switch_session");
    ProtocolConfig {
        prompt: SYNTHETIC_PROMPT.to_string(),
        requested_session_id: if resuming {
            RESUMED_SESSION_ID.to_string()
        } else {
            String::new()
        },
        resume_session_path: resuming.then(|| PathBuf::from(RESUMED_SESSION_PATH)),
        cwd: SYNTHETIC_CWD.to_string(),
        model: None,
        model_provider: None,
        model_id: None,
        thinking_level: None,
        turn_id: SYNTHETIC_TURN_ID.to_string(),
    }
}

fn effect_fact(effect: &ProtocolEffect) -> Value {
    match effect {
        // The request the parser emitted, carried verbatim under its own names.
        ProtocolEffect::Send(request) => {
            let mut fact = request.clone();
            fact["effect"] = json!("send");
            fact
        }
        // A parked dialog's callback token is process-unique and is therefore
        // never projected; the parser's own request identity stays on the
        // `extension_ui_request` frame the corpus records.
        ProtocolEffect::Interact(_) => json!({"effect": "interact"}),
        ProtocolEffect::Complete(outcome) => json!({
            "effect": "complete",
            "output": outcome.output,
            "sessionId": outcome.session_id,
            "turnId": outcome.turn_id,
            "turnStatus": outcome.turn_status,
            "effective": effective_settings(&outcome.effective),
        }),
        ProtocolEffect::Fail(failure) => json!({
            "effect": "fail",
            "code": failure.code,
            "message": failure.message,
            "stage": failure.stage,
            "userInteractionRequired": failure.user_interaction_required,
            "requestMethod": failure.request_method,
            "sessionId": failure.session_id,
            "turnId": failure.turn_id,
            "turnStatus": failure.turn_status,
        }),
    }
}

fn effective_settings(effective: &crate::platform::pi_driver::model::EffectiveSettings) -> Value {
    json!({
        "cwd": effective.cwd,
        "model": effective.model,
        "reasoningEffort": effective.reasoning_effort,
        "permissionMode": effective.permission_mode,
        "sandbox": effective.sandbox,
        "approvalPolicy": effective.approval_policy,
    })
}
