use super::AdapterContract;
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use serde_json::Value;

pub(super) const CONTRACT: AdapterContract = AdapterContract::new("lico-agent", "lf-jsonl-jsonrpc");

#[derive(Debug)]
pub(in crate::platform) enum RpcEffect {
    Handshake { accepted: bool },
    Text { delta: String },
    Processing,
    Control { method: String },
    Completed,
    Failed,
    Ignored,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum FrameError {
    Empty,
    InvalidJson,
}

pub(in crate::platform) fn encode_request(value: &Value) -> Result<Vec<u8>, serde_json::Error> {
    let mut encoded = serde_json::to_vec(value)?;
    encoded.push(b'\n');
    Ok(encoded)
}

pub(in crate::platform) fn parse_line(line: &str) -> Result<RpcEffect, FrameError> {
    let line = line.trim();
    if line.is_empty() {
        return Err(FrameError::Empty);
    }
    let event: Value = serde_json::from_str(line).map_err(|_| FrameError::InvalidJson)?;
    if event.get("type").and_then(Value::as_str) == Some("response") {
        return Ok(RpcEffect::Handshake {
            accepted: event.get("success").and_then(Value::as_bool) == Some(true),
        });
    }
    if let Some(delta) = event
        .pointer("/assistantMessageEvent/delta")
        .and_then(Value::as_str)
    {
        return Ok(RpcEffect::Text {
            delta: delta.to_owned(),
        });
    }
    match event.get("type").and_then(Value::as_str) {
        Some("agent.event" | "agent.progress" | "agent.tool") => Ok(RpcEffect::Processing),
        Some("agent.interaction") => Ok(RpcEffect::Control {
            method: "agent.interaction".to_owned(),
        }),
        Some("agent_end") => Ok(RpcEffect::Completed),
        Some("error") => Ok(RpcEffect::Failed),
        _ => Ok(RpcEffect::Ignored),
    }
}

pub(in crate::platform) fn success_transitions(
    output: &str,
    saw_processing: bool,
    controls: &[String],
) -> Vec<Transition> {
    terminal_transitions(output, saw_processing, controls, None)
}

pub(in crate::platform) fn failure_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    terminal_transitions("", false, &[], Some((code, stage, message)))
}

fn terminal_transitions(
    output: &str,
    saw_processing: bool,
    controls: &[String],
    failure: Option<(&str, &str, &str)>,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    if saw_processing {
        transitions.extend(reducer.advance(LifecycleStage::Processing));
    }
    transitions.extend(controls.iter().map(|method| Transition::Control {
        method: method.clone(),
        summary: "Native agent interaction requires an explicit client response.".to_owned(),
    }));
    if !output.is_empty() {
        transitions.extend(reducer.advance(LifecycleStage::Responding));
        transitions.push(Transition::Text {
            unit_id: "lico-agent:reply".to_owned(),
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn jsonl_parser_owns_handshake_text_and_terminal_classification() {
        assert!(matches!(
            parse_line(r#"{"type":"response","success":true}"#),
            Ok(RpcEffect::Handshake { accepted: true })
        ));
        assert!(matches!(
            parse_line(r#"{"assistantMessageEvent":{"delta":"hello"}}"#),
            Ok(RpcEffect::Text { delta }) if delta == "hello"
        ));
        assert!(matches!(
            parse_line(r#"{"type":"agent_end"}"#),
            Ok(RpcEffect::Completed)
        ));
        assert_eq!(
            encode_request(&json!({"type":"get_state"})).unwrap().last(),
            Some(&b'\n')
        );
        assert_eq!(
            success_transitions("hello", true, &[]).last(),
            Some(&Transition::Lifecycle(LifecycleStage::Completed))
        );
    }
}
