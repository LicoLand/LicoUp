//! Admitted ordinary-continuity Assistant turn envelope.
//!
//! Decode is terminal-assembled only. Callers must not scan ordinary chat or
//! treat model JSON as the admission that enables this contract.

use serde_json::{Value, json};

use super::generated::ContinuityAssistantTurnResponse;

pub const TRUSTED_RESPONSE_MODE_ASSISTANT_TURN: &str = "assistant-turn-response";
pub const ASSISTANT_TURN_INVALID_ERROR: &str = "continuity_assistant_turn_invalid";

pub fn trusted_response_mode_metadata(mode: &str) -> String {
    json!({ "trustedResponseMode": mode }).to_string()
}

pub fn trusted_response_mode_from_metadata(content: &str) -> Option<String> {
    let value: Value = serde_json::from_str(content).ok()?;
    value
        .get("trustedResponseMode")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

pub fn is_assistant_turn_response_mode(mode: Option<&str>) -> bool {
    mode == Some(TRUSTED_RESPONSE_MODE_ASSISTANT_TURN)
}

pub fn decode_assistant_turn_response(output: &str) -> Option<ContinuityAssistantTurnResponse> {
    serde_json::from_str(output.trim()).ok()
}

pub fn usable_reply_text(response: &ContinuityAssistantTurnResponse) -> Option<&str> {
    let text = response.reply_text.trim();
    if text.is_empty() {
        None
    } else {
        Some(response.reply_text.as_str())
    }
}

pub fn proposal_json(response: &ContinuityAssistantTurnResponse) -> Option<String> {
    serde_json::to_string(&response.interpretation_proposal).ok()
}

pub fn published_envelope(output: &str) -> Option<(String, String)> {
    let response = decode_assistant_turn_response(output)?;
    let reply = usable_reply_text(&response)?.to_owned();
    let proposal = proposal_json(&response)?;
    Some((reply, proposal))
}

/// User-facing admitted output is replyText only. The private proposal stays
/// on the host settlement / canonical metadata owner.
pub fn public_admitted_output(output: &str) -> Option<String> {
    published_envelope(output).map(|(reply, _)| reply)
}

pub fn public_admitted_failure_payload() -> Value {
    json!({
        "ok": false,
        "turnStatus": "failed",
        "code": ASSISTANT_TURN_INVALID_ERROR,
        "error": {
            "code": ASSISTANT_TURN_INVALID_ERROR,
            "stage": "conversation/dispatch",
            "turnStatus": "failed",
        },
    })
}

/// Overlay envelope-validation failure facts without dropping existing
/// tool, evidence, artifact, or author keys.
pub fn apply_admitted_validation_failure_facts(payload: &mut Value) {
    payload["ok"] = json!(false);
    payload["turnStatus"] = json!("failed");
    payload["code"] = json!(ASSISTANT_TURN_INVALID_ERROR);
    payload["error"] = json!({
        "code": ASSISTANT_TURN_INVALID_ERROR,
        "stage": "conversation/dispatch",
        "turnStatus": "failed",
    });
}

/// Replace known adapter text fields by role. Admitted `output`,
/// `events[].text` when `kind=text`, and `terminalTransition.text` when
/// `kind=text` carry the envelope. Other keys stay untouched.
pub fn project_admitted_known_text_fields(payload: &mut Value, public_text: &str) {
    if payload.get("output").and_then(Value::as_str).is_some() {
        payload["output"] = json!(public_text);
    }
    if let Some(events) = payload.get_mut("events").and_then(Value::as_array_mut) {
        for event in events {
            project_admitted_text_role(event, public_text);
        }
    }
    if let Some(transition) = payload.get_mut("terminalTransition") {
        project_admitted_text_role(transition, public_text);
    }
}

fn project_admitted_text_role(value: &mut Value, public_text: &str) {
    if value.get("kind").and_then(Value::as_str) != Some("text") {
        return;
    }
    if value.get("text").and_then(Value::as_str).is_some() {
        value["text"] = json!(public_text);
    }
}

/// Live observers may only see replyText after a successful terminal decode.
pub fn redact_live_runtime_event(event: &Value) -> Value {
    let kind = event.get("event").and_then(Value::as_str).unwrap_or("");
    if kind != "agent.message.chunk" && kind != "agent.message.completed" {
        return event.clone();
    }
    let mut redacted = event.clone();
    let Some(payload) = redacted.get_mut("payload").and_then(Value::as_object_mut) else {
        return redacted;
    };
    let text = payload.get("text").and_then(Value::as_str).unwrap_or("");
    match published_envelope(text) {
        Some((reply, _)) => {
            payload.insert("text".into(), json!(reply));
        }
        None => {
            payload.insert("text".into(), json!(""));
        }
    }
    redacted
}
