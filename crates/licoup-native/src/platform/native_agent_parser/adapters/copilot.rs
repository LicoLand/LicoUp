use super::AdapterContract;
use crate::core::acp::{self, AcpSessionUpdate, AcpStopReason};
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use serde_json::Value;

pub(super) const CONTRACT: AdapterContract = AdapterContract::new("copilot", "lf-ndjson-acp");

/// Copilot ACP's complete parser-owned ingress. The stdio transport passes
/// each raw LF-delimited frame here exactly once and never decodes JSON itself.
pub(in crate::platform) fn decode_frame(line: &[u8]) -> Result<Value, acp::AcpError> {
    acp::decode_json_line(line)
}

pub(in crate::platform) fn initialize_response(
    line: &[u8],
    request_id: i64,
) -> Result<Option<acp::AcpInitializeResponse>, acp::AcpError> {
    let frame = decode_frame(line)?;
    if !response_id_matches(&frame, request_id) {
        return Ok(None);
    }
    acp::validate_initialize_response(&frame, request_id).map(Some)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(in crate::platform) struct ClientRequest {
    pub(in crate::platform) id: Value,
    pub(in crate::platform) method: String,
    pub(in crate::platform) session_id: Option<String>,
    pub(in crate::platform) allow_once_option: Option<String>,
}

pub(in crate::platform) fn client_request(message: &Value) -> Option<ClientRequest> {
    let id = message.get("id")?.clone();
    let method = message.get("method")?.as_str()?.to_owned();
    if message.get("result").is_some() || message.get("error").is_some() {
        return None;
    }
    let params = message.get("params");
    Some(ClientRequest {
        id,
        method,
        session_id: params
            .and_then(|params| params.get("sessionId"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        allow_once_option: params
            .and_then(|params| params.get("options"))
            .and_then(Value::as_array)
            .and_then(|options| {
                ["allow_once", "allow"].into_iter().find_map(|expected| {
                    options.iter().find_map(|option| {
                        let kind = option.get("kind")?.as_str()?;
                        let id = option.get("optionId")?.as_str()?.trim();
                        (kind == expected
                            && !id.is_empty()
                            && id.len() <= 256
                            && !id.contains('\0'))
                        .then(|| id.to_owned())
                    })
                })
            }),
    })
}

pub(in crate::platform) fn is_notification(message: &Value) -> bool {
    message.get("method").is_some() && message.get("id").is_none()
}

pub(in crate::platform) fn response_id_matches(message: &Value, expected: i64) -> bool {
    message.get("id").and_then(Value::as_i64) == Some(expected)
}

pub(in crate::platform) fn session_update(
    message: &Value,
    expected_session_id: Option<&str>,
) -> Result<AcpSessionUpdate, acp::AcpError> {
    acp::validate_session_update(message, expected_session_id)
}

pub(in crate::platform) fn prompt_stop_reason(
    message: &Value,
    request_id: i64,
) -> Result<AcpStopReason, acp::AcpError> {
    acp::validate_prompt_response(message, request_id).map(|response| response.stop_reason)
}

pub(in crate::platform) fn completed_transitions(output: &str) -> Vec<Transition> {
    terminal_transitions("copilot:reply", output, None)
}

pub(in crate::platform) fn failed_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    terminal_transitions("copilot:reply", "", Some((code, stage, message)))
}

fn terminal_transitions(
    unit_id: &str,
    output: &str,
    failure: Option<(&str, &str, &str)>,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    if !output.is_empty() {
        transitions.extend(reducer.advance(LifecycleStage::Processing));
        transitions.extend(reducer.advance(LifecycleStage::Responding));
        transitions.push(Transition::Text {
            unit_id: unit_id.to_owned(),
            text: output.to_owned(),
        });
    }
    if let Some((code, stage, message)) = failure {
        if let Some(failure) = reducer.fail(code, stage, message) {
            transitions.push(failure);
        }
    } else {
        transitions.extend(reducer.advance(LifecycleStage::Completed));
    }
    transitions
}
