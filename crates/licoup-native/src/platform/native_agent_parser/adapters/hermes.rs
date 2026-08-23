use super::AdapterContract;
use crate::core::acp::{self, AcpSessionUpdate, AcpStopReason};
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use serde_json::Value;

pub(super) const CONTRACT: AdapterContract = AdapterContract::new("hermes", "stdio-jsonrpc-acp");

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
pub(in crate::platform) struct PermissionRequest {
    pub(in crate::platform) id: Value,
    pub(in crate::platform) method: String,
    pub(in crate::platform) session_id: Option<String>,
    pub(in crate::platform) display_summary: String,
    pub(in crate::platform) option_id: Option<String>,
    pub(in crate::platform) requested_tools: Vec<String>,
}

pub(in crate::platform) fn permission_request(message: &Value) -> Option<PermissionRequest> {
    let id = message.get("id")?.clone();
    let method = message.get("method")?.as_str()?.to_owned();
    if message.get("result").is_some() || message.get("error").is_some() {
        return None;
    }
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let mut requested_tools = params
        .get("toolCalls")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|call| {
            call.get("title")
                .or_else(|| call.get("kind"))
                .or_else(|| call.pointer("/toolCall/title"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|name| !name.is_empty())
                .map(|name| name.chars().take(64).collect::<String>())
        })
        .take(8)
        .collect::<Vec<_>>();
    requested_tools.shrink_to_fit();
    let option_id = params
        .get("options")
        .and_then(Value::as_array)
        .and_then(|options| {
            options
                .iter()
                .find(|option| {
                    matches!(
                        option.get("kind").and_then(Value::as_str),
                        Some("allow_once" | "allow_always" | "allow")
                    ) || option
                        .get("optionId")
                        .and_then(Value::as_str)
                        .is_some_and(|id| id.contains("allow"))
                })
                .or_else(|| options.first())
        })
        .and_then(|option| option.get("optionId"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let display_summary = if requested_tools.is_empty() {
        "Hermes Agent requests permission to continue.".to_owned()
    } else {
        format!(
            "Hermes Agent requests permission for: {}",
            requested_tools.join(", ")
        )
    };
    Some(PermissionRequest {
        id,
        method,
        session_id: params
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::to_owned),
        display_summary,
        option_id,
        requested_tools,
    })
}

pub(in crate::platform) fn is_notification(message: &Value) -> bool {
    message.get("method").is_some() && message.get("id").is_none()
}

pub(in crate::platform) fn response_id_matches(message: &Value, expected: i64) -> bool {
    message.get("id").is_some_and(|id| {
        id.as_i64() == Some(expected)
            || id
                .as_str()
                .is_some_and(|value| value == expected.to_string())
    })
}

pub(in crate::platform) fn response_is_error(message: &Value) -> bool {
    message.get("error").is_some()
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
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    transitions.extend(reducer.advance(LifecycleStage::Processing));
    transitions.extend(reducer.advance(LifecycleStage::Responding));
    transitions.push(Transition::Text {
        unit_id: "hermes:reply".to_owned(),
        text: output.to_owned(),
    });
    transitions.extend(reducer.advance(LifecycleStage::Completed));
    transitions
}

pub(in crate::platform) fn failed_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    if let Some(failure) = reducer.fail(code, stage, message) {
        transitions.push(failure);
    }
    transitions
}
