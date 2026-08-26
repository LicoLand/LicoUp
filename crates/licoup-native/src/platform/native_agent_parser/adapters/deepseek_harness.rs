use super::{AdapterContract, NativeLineParser};
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use serde_json::{Value, json};

pub(super) const CONTRACT: AdapterContract =
    AdapterContract::new("deepseek-harness", "lf-jsonl-jsonrpc");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum FrameError {
    InvalidJson,
    OutputLimit,
}

#[derive(Debug)]
pub(in crate::platform) struct ProtocolFrame {
    value: Value,
    wire_bytes: usize,
}

impl ProtocolFrame {
    pub(in crate::platform) fn wire_bytes(&self) -> usize {
        self.wire_bytes
    }
}

#[derive(Default)]
pub(in crate::platform) struct FrameParser;

impl NativeLineParser for FrameParser {
    type Report = ProtocolFrame;
    type Error = FrameError;

    fn parse_line(&mut self, bytes: &[u8]) -> Result<Self::Report, Self::Error> {
        let value = serde_json::from_slice(bytes).map_err(|_| FrameError::InvalidJson)?;
        Ok(ProtocolFrame {
            value,
            wire_bytes: bytes.len().saturating_add(1),
        })
    }
}

pub(in crate::platform) fn encode_request(value: &Value) -> Result<Vec<u8>, serde_json::Error> {
    let mut encoded = serde_json::to_vec(value)?;
    encoded.push(b'\n');
    Ok(encoded)
}

pub(in crate::platform) fn initialize_request(
    cwd: &str,
    provider: &str,
    model: &str,
    max_tokens: Option<u64>,
) -> Value {
    let mut params = json!({"cwd":cwd,"provider":provider,"model":model});
    if let Some(max_tokens) = max_tokens {
        params["maxTokens"] = json!(max_tokens);
    }
    json!({"jsonrpc":"2.0","id":"initialize","method":"initialize","params":params})
}

pub(in crate::platform) fn initialize_accepted(frame: &ProtocolFrame) -> Option<bool> {
    (frame.value.get("id").and_then(Value::as_str) == Some("initialize")).then(|| {
        frame
            .value
            .pointer("/result/serverInfo/name")
            .and_then(Value::as_str)
            == Some("deepseek-harness-sdk-runtime")
    })
}

pub(in crate::platform) fn prompt_request(
    request_id: &str,
    session_id: &str,
    prompt: &str,
) -> Value {
    json!({"jsonrpc":"2.0","id":request_id,"method":"session/prompt","params":{"sessionId":session_id,"contentBlocks":[{"type":"text","text":prompt}]}})
}

pub(in crate::platform) fn shutdown_request() -> Value {
    json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"})
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum TurnParseError {
    Incomplete,
    SessionMismatch,
}

#[derive(Debug)]
pub(in crate::platform) struct TurnResult {
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) output: String,
    pub(in crate::platform) transitions: Vec<Transition>,
}

pub(in crate::platform) struct TurnParser {
    request_id: String,
    session_id: String,
    message_id: Option<String>,
    buffered: Vec<ProtocolFrame>,
    attributed: Vec<ProtocolFrame>,
    receipt_seen: bool,
}

impl TurnParser {
    pub(in crate::platform) fn new(request_id: &str, session_id: &str) -> Self {
        Self {
            request_id: request_id.to_owned(),
            session_id: session_id.to_owned(),
            message_id: None,
            buffered: Vec::new(),
            attributed: Vec::new(),
            receipt_seen: false,
        }
    }

    pub(in crate::platform) fn ingest(
        &mut self,
        frame: ProtocolFrame,
    ) -> Result<Option<TurnResult>, TurnParseError> {
        if frame.value.get("id").and_then(Value::as_str) == Some(self.request_id.as_str()) {
            if frame
                .value
                .pointer("/result/sessionId")
                .and_then(Value::as_str)
                != Some(self.session_id.as_str())
            {
                return Err(TurnParseError::SessionMismatch);
            }
            let Some(message_id) = frame
                .value
                .pointer("/result/messageId")
                .and_then(Value::as_str)
                .map(str::to_owned)
            else {
                return Err(TurnParseError::Incomplete);
            };
            self.message_id = Some(message_id.clone());
            if let Some(index) = self
                .buffered
                .iter()
                .position(|frame| is_inbox_receipt(frame, &message_id))
            {
                self.receipt_seen = true;
                self.attributed.extend(self.buffered.drain(index..));
                if self.attributed.iter().skip(1).any(is_idle_status) {
                    return self.finish().map(Some);
                }
            }
            return Ok(None);
        }
        if !matches!(
            frame.value.get("method").and_then(Value::as_str),
            Some("session.event" | "session.status")
        ) {
            return Ok(None);
        }
        if frame
            .value
            .pointer("/params/sessionId")
            .and_then(Value::as_str)
            != Some(self.session_id.as_str())
        {
            return Err(TurnParseError::SessionMismatch);
        }
        if self.receipt_seen {
            let terminal = is_idle_status(&frame);
            self.attributed.push(frame);
            return if terminal {
                self.finish().map(Some)
            } else {
                Ok(None)
            };
        }
        if let Some(message_id) = self.message_id.as_deref() {
            if is_inbox_receipt(&frame, message_id) {
                self.receipt_seen = true;
                self.attributed.push(frame);
            }
        } else {
            self.buffered.push(frame);
        }
        Ok(None)
    }

    fn finish(&mut self) -> Result<TurnResult, TurnParseError> {
        let turn_id = self
            .message_id
            .take()
            .filter(|_| self.receipt_seen)
            .ok_or(TurnParseError::Incomplete)?;
        let output = final_assistant_response(&self.attributed);
        Ok(TurnResult {
            turn_id,
            transitions: success_transitions(&output, &self.attributed),
            output,
        })
    }
}

fn success_transitions(output: &str, frames: &[ProtocolFrame]) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Processing);
    transitions.extend(frames.iter().filter_map(|frame| {
        let method = frame
            .value
            .pointer("/params/event/type")
            .and_then(Value::as_str)?;
        (method == "response.tool_call").then(|| Transition::Control {
            method: method.to_owned(),
            summary: "Native agent interaction requires an explicit client response.".to_owned(),
        })
    }));
    if !output.is_empty() {
        transitions.extend(reducer.advance(LifecycleStage::Responding));
        transitions.push(Transition::Text {
            unit_id: "deepseek-harness:reply".to_owned(),
            text: output.to_owned(),
        });
    }
    transitions.extend(reducer.advance(LifecycleStage::Completed));
    transitions
}

pub(in crate::platform) fn failure_transitions(
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

fn is_inbox_receipt(frame: &ProtocolFrame, message_id: &str) -> bool {
    frame.value.get("method").and_then(Value::as_str) == Some("session.event")
        && frame
            .value
            .pointer("/params/event/type")
            .and_then(Value::as_str)
            == Some("agent/inbox/spliced")
        && frame
            .value
            .pointer("/params/event/data/inserted")
            .and_then(Value::as_array)
            .is_some_and(|messages| {
                messages
                    .iter()
                    .any(|message| message.get("id").and_then(Value::as_str) == Some(message_id))
            })
}

fn is_idle_status(frame: &ProtocolFrame) -> bool {
    frame.value.get("method").and_then(Value::as_str) == Some("session.status")
        && frame
            .value
            .pointer("/params/status")
            .and_then(Value::as_str)
            == Some("idle")
}

fn final_assistant_response(frames: &[ProtocolFrame]) -> String {
    frames
        .iter()
        .filter_map(|frame| frame.value.pointer("/params/event"))
        .filter(|event| event.get("type").and_then(Value::as_str) == Some("assistant/message"))
        .flat_map(|event| {
            event
                .pointer("/data/message/content")
                .or_else(|| event.pointer("/data/content"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
        })
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(value: Value) -> ProtocolFrame {
        FrameParser
            .parse_line(value.to_string().as_bytes())
            .unwrap()
    }

    #[test]
    fn parser_attributes_only_the_receipted_turn_until_idle() {
        let mut parser = TurnParser::new("prompt-1", "session-1");
        assert!(
            parser
                .ingest(frame(
                    json!({"id":"prompt-1","result":{"sessionId":"session-1","messageId":"message-1"}})
                ))
                .unwrap()
                .is_none()
        );
        assert!(parser.ingest(frame(json!({"method":"session.event","params":{"sessionId":"session-1","event":{"type":"agent/inbox/spliced","data":{"inserted":[{"id":"message-1"}]}}}}))).unwrap().is_none());
        assert!(parser.ingest(frame(json!({"method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant/message","data":{"message":{"content":[{"type":"text","text":"first "}]}}}}}))).unwrap().is_none());
        assert!(parser.ingest(frame(json!({"method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant/message","data":{"message":{"content":[{"type":"text","text":"second"}]}}}}}))).unwrap().is_none());
        let result = parser.ingest(frame(json!({"method":"session.status","params":{"sessionId":"session-1","status":"idle"}}))).unwrap().unwrap();
        assert_eq!(result.turn_id, "message-1");
        assert_eq!(result.output, "first second");
        assert_eq!(
            result.transitions.last(),
            Some(&Transition::Lifecycle(LifecycleStage::Completed))
        );
    }

    #[test]
    fn parser_rejects_matching_response_or_event_bound_to_another_session() {
        let mut response_parser = TurnParser::new("prompt-1", "session-1");
        assert_eq!(
            response_parser
                .ingest(frame(json!({
                    "id":"prompt-1",
                    "result":{"sessionId":"other-session","messageId":"message-1"}
                })))
                .unwrap_err(),
            TurnParseError::SessionMismatch
        );

        let mut event_parser = TurnParser::new("prompt-1", "session-1");
        assert_eq!(
            event_parser
                .ingest(frame(json!({
                    "method":"session.event",
                    "params":{"sessionId":"other-session","event":{"type":"assistant/message"}}
                })))
                .unwrap_err(),
            TurnParseError::SessionMismatch
        );
    }
}
