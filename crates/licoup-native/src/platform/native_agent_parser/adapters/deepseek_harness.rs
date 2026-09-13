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
    reasoning_effort: Option<&str>,
    max_tokens: Option<u64>,
) -> Value {
    let mut params = json!({"cwd":cwd,"provider":provider,"model":model});
    if let Some(reasoning_effort) = reasoning_effort {
        params["reasoningEffort"] = json!(reasoning_effort);
    }
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
    progress_cursor: usize,
    message_ordinal: usize,
}

pub(in crate::platform) struct CompletedMessage {
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) unit_id: String,
    pub(in crate::platform) text: String,
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
            progress_cursor: 0,
            message_ordinal: 0,
        }
    }

    pub(in crate::platform) fn ingest(
        &mut self,
        frame: ProtocolFrame,
    ) -> Result<Option<TurnResult>, TurnParseError> {
        if frame.value.get("id").and_then(Value::as_str) == Some(self.request_id.as_str()) {
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

    /// Publish only messages attributed to the acknowledged inbox receipt.
    /// Each completed native message is available before the agent becomes idle;
    /// its embedded timed stream is historical data, never replayed as live deltas.
    pub(in crate::platform) fn take_completed_messages(&mut self) -> Vec<CompletedMessage> {
        let Some(turn_id) = self.message_id.as_ref().filter(|_| self.receipt_seen) else {
            return Vec::new();
        };
        let messages = self.attributed[self.progress_cursor..]
            .iter()
            .filter_map(assistant_response)
            .map(|text| {
                self.message_ordinal += 1;
                CompletedMessage {
                    turn_id: turn_id.clone(),
                    unit_id: message_unit(self.message_ordinal),
                    text,
                }
            })
            .collect();
        self.progress_cursor = self.attributed.len();
        messages
    }

    fn finish(&mut self) -> Result<TurnResult, TurnParseError> {
        let turn_id = self
            .message_id
            .clone()
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
        transitions.extend(
            frames
                .iter()
                .filter_map(assistant_response)
                .enumerate()
                .map(|(index, text)| Transition::Text {
                    unit_id: message_unit(index + 1),
                    text,
                }),
        );
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

fn message_unit(ordinal: usize) -> String {
    format!("deepseek-harness:reply:{ordinal}")
}

fn assistant_response(frame: &ProtocolFrame) -> Option<String> {
    let event = frame.value.pointer("/params/event")?;
    if event.get("type").and_then(Value::as_str) != Some("assistant/message") {
        return None;
    }
    let text: String = event
        .pointer("/data/message/content")
        .or_else(|| event.pointer("/data/content"))
        .and_then(Value::as_array)?
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect();
    (!text.is_empty()).then_some(text)
}

fn final_assistant_response(frames: &[ProtocolFrame]) -> String {
    frames.iter().filter_map(assistant_response).collect()
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
    fn initialize_preserves_native_model_and_optional_reasoning_selection() {
        let automatic = initialize_request(
            "/synthetic",
            "deepseek-official",
            "native-model",
            None,
            None,
        );
        assert!(automatic["params"].get("reasoningEffort").is_none());
        let selected = initialize_request(
            "/synthetic",
            "deepseek-official",
            "native-model",
            Some("max"),
            Some(4096),
        );
        assert_eq!(selected["params"]["model"], "native-model");
        assert_eq!(selected["params"]["reasoningEffort"], "max");
        assert_eq!(selected["params"]["maxTokens"], 4096);
    }

    #[test]
    fn parser_attributes_only_the_receipted_turn_until_idle() {
        let mut parser = TurnParser::new("prompt-1", "session-1");
        assert!(
            parser
                .ingest(frame(
                    json!({"id":"prompt-1","result":{"messageId":"message-1"}})
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
    fn completed_messages_wait_for_receipt_but_not_idle_and_keep_distinct_units() {
        let mut parser = TurnParser::new("prompt-1", "session-1");
        for event in [
            json!({"type":"agent/inbox/spliced","data":{"inserted":[{"id":"message-1"}]}}),
            json!({"type":"assistant/message","data":{"message":{"content":[{"type":"text","text":"first"}]},"stream":[{"private":"not-live"}]}}),
        ] {
            assert!(parser.ingest(frame(json!({"method":"session.event","params":{"sessionId":"session-1","event":event}}))).unwrap().is_none());
        }
        assert!(parser.take_completed_messages().is_empty());
        assert!(
            parser
                .ingest(frame(
                    json!({"id":"prompt-1","result":{"messageId":"message-1"}})
                ))
                .unwrap()
                .is_none()
        );
        let first = parser.take_completed_messages();
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].turn_id, "message-1");
        assert_eq!(first[0].unit_id, "deepseek-harness:reply:1");
        assert_eq!(first[0].text, "first");
        assert!(parser.take_completed_messages().is_empty());
        assert!(parser.ingest(frame(json!({"method":"session.event","params":{"sessionId":"session-1","event":{"type":"assistant/message","data":{"message":{"content":[{"type":"text","text":"second"}]}}}}}))).unwrap().is_none());
        let second = parser.take_completed_messages();
        assert_eq!(second.len(), 1);
        assert_eq!(second[0].unit_id, "deepseek-harness:reply:2");
        let final_result = parser.ingest(frame(json!({"method":"session.status","params":{"sessionId":"session-1","status":"idle"}}))).unwrap().unwrap();
        assert!(parser.take_completed_messages().is_empty());
        assert_eq!(final_result.output, "firstsecond");
        let units: Vec<_> = final_result
            .transitions
            .iter()
            .filter_map(|transition| {
                if let Transition::Text { unit_id, .. } = transition {
                    Some(unit_id.as_str())
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(
            units,
            ["deepseek-harness:reply:1", "deepseek-harness:reply:2"]
        );
    }

    #[test]
    fn parser_rejects_missing_receipt_or_event_bound_to_another_session() {
        let mut response_parser = TurnParser::new("prompt-1", "session-1");
        assert_eq!(
            response_parser
                .ingest(frame(json!({
                    "id":"prompt-1",
                    "result":{}
                })))
                .unwrap_err(),
            TurnParseError::Incomplete
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
