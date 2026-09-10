//! Admitted ordinary-continuity Assistant turn envelope.
//!
//! Decode is terminal-assembled only. Callers must not scan ordinary chat or
//! treat model JSON as the admission that enables this contract.

use serde_json::{Value, json};

use super::generated::{
    ContinuityAssistantTurnResponse, ContinuityCommitmentProposal,
    ContinuityInterpretationProposal, ContinuityMatterSubject, ContinuitySpeechAct,
    ContinuityWriteEnvelope,
};

pub const TRUSTED_RESPONSE_MODE_ASSISTANT_TURN: &str = "assistant-turn-response";
pub const ASSISTANT_TURN_INVALID_ERROR: &str = "continuity_assistant_turn_invalid";
const UNTYPED_ASSISTANT_REPLY_REASON: &str = "untyped-assistant-reply";

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

/// Terminal-assembled publication. A complete typed envelope still unwraps
/// `replyText`. Any other nonempty output is the raw conversation. Live chunks
/// stay on [`published_envelope`] so a partial object is never flashed early.
pub fn published_terminal_envelope(output: &str) -> Option<(String, String)> {
    if let Some(published) = published_envelope(output) {
        return Some(published);
    }
    if let Some(embedded) = extract_embedded_json_object(output)
        && let Some(published) = published_envelope(&embedded)
    {
        return Some(published);
    }
    recover_raw_reply(output)
}

/// User-facing admitted output is replyText when a typed envelope is present.
/// Otherwise the raw terminal text is the conversation.
pub fn public_admitted_output(output: &str) -> Option<String> {
    published_terminal_envelope(output).map(|(reply, _)| reply)
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
    let published = if kind == "agent.message.completed" {
        published_terminal_envelope(text)
    } else {
        published_envelope(text)
    };
    match published {
        Some((reply, _)) => {
            payload.insert("text".into(), json!(reply));
        }
        None => {
            payload.insert("text".into(), json!(""));
        }
    }
    redacted
}

fn extract_embedded_json_object(output: &str) -> Option<String> {
    let trimmed = output.trim();
    let start = trimmed.find('{')?;
    let end = trimmed.rfind('}')?;
    if end < start {
        return None;
    }
    let slice = &trimmed[start..=end];
    let value: Value = serde_json::from_str(slice).ok()?;
    value.is_object().then(|| slice.to_owned())
}

fn recover_raw_reply(output: &str) -> Option<(String, String)> {
    let reply = output.trim();
    if reply.is_empty() {
        return None;
    }
    let proposal = serde_json::to_string(&host_abstain_proposal()).ok()?;
    Some((reply.to_owned(), proposal))
}

fn host_abstain_proposal() -> ContinuityInterpretationProposal {
    ContinuityInterpretationProposal {
        envelope: ContinuityWriteEnvelope {
            conversation_id: "conversation:host-owned".to_owned(),
            source_event_refs: Vec::new(),
            observed_revision: 0,
            designation_epoch: 0,
            request_id: "request:host-abstain".to_owned(),
        },
        matter_associations: Vec::new(),
        speech_act: ContinuitySpeechAct::Exploration,
        commitment_proposals: vec![ContinuityCommitmentProposal {
            matter_id: None,
            subject: ContinuityMatterSubject::Unresolved,
            expected_result: "abstain".to_owned(),
            criteria: Vec::new(),
            create_goal: false,
        }],
        agreement_proposals: Vec::new(),
        capability_needs: Vec::new(),
        uncertainty_reasons: vec![UNTYPED_ASSISTANT_REPLY_REASON.to_owned()],
        requested_reads: Vec::new(),
        task_child_admission: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn typed_envelope(reply: &str) -> String {
        serde_json::to_string(&ContinuityAssistantTurnResponse {
            reply_text: reply.to_owned(),
            interpretation_proposal: host_abstain_proposal(),
        })
        .expect("typed envelope")
    }

    #[test]
    fn live_decode_stays_strict() {
        assert!(published_envelope("普通中文回复").is_none());
        assert_eq!(
            published_envelope(&typed_envelope("typed reply"))
                .map(|(reply, _)| reply)
                .as_deref(),
            Some("typed reply")
        );
    }

    #[test]
    fn terminal_publishes_raw_conversation_when_envelope_is_absent() {
        let (reply, proposal) =
            published_terminal_envelope("  普通中文回复  ").expect("recovered prose");
        assert_eq!(reply, "普通中文回复");
        assert!(proposal.contains(UNTYPED_ASSISTANT_REPLY_REASON));
        assert_eq!(
            public_admitted_output("普通中文回复").as_deref(),
            Some("普通中文回复")
        );
        let private_only = r#"{"speechAct":"question"}"#;
        assert_eq!(
            published_terminal_envelope(private_only)
                .map(|(text, _)| text)
                .as_deref(),
            Some(private_only)
        );
        assert_eq!(
            published_terminal_envelope("{\"replyText\":")
                .map(|(text, _)| text)
                .as_deref(),
            Some("{\"replyText\":")
        );
        assert!(published_terminal_envelope("").is_none());
        assert!(published_terminal_envelope("   ").is_none());
    }

    #[test]
    fn live_chunks_hide_prose_until_completed() {
        let chunk = redact_live_runtime_event(&json!({
            "event": "agent.message.chunk",
            "payload": {"text": "普通中文回复"},
        }));
        assert_eq!(chunk["payload"]["text"], "");
        let completed = redact_live_runtime_event(&json!({
            "event": "agent.message.completed",
            "payload": {"text": "普通中文回复"},
        }));
        assert_eq!(completed["payload"]["text"], "普通中文回复");
    }
}
