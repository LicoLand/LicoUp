use super::AdapterContract;
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use crate::platform::pty_transport::AnsiStripper;
use serde_json::Value;

pub(super) const CONTRACT: AdapterContract = AdapterContract::new("antigravity", "pty-hook-json");

const MIN_SESSION_ID_LEN: usize = 8;
const MAX_SESSION_ID_LEN: usize = 128;

pub(in crate::platform) fn valid_session_id(session_id: &str) -> bool {
    let len = session_id.len();
    (MIN_SESSION_ID_LEN..=MAX_SESSION_ID_LEN).contains(&len)
        && session_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
}

pub(in crate::platform) fn parse_hook_receipt(text: &str) -> Option<String> {
    let envelope: Value = serde_json::from_str(text).ok()?;
    let payload = envelope
        .get("hookPayload")
        .and_then(Value::as_str)
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok());
    [
        payload.as_ref().and_then(|value| {
            [
                "conversationId",
                "conversation_id",
                "sessionId",
                "session_id",
            ]
            .into_iter()
            .find_map(|key| value.get(key).and_then(Value::as_str))
        }),
        envelope
            .get("environmentConversationId")
            .and_then(Value::as_str),
    ]
    .into_iter()
    .flatten()
    .map(str::trim)
    .filter(|value| valid_session_id(value))
    .map(str::to_owned)
    .next()
}

pub(in crate::platform) struct PtyOutputParser {
    stripper: AnsiStripper,
    output: String,
}

impl PtyOutputParser {
    pub(in crate::platform) fn new() -> Self {
        Self {
            stripper: AnsiStripper::new(),
            output: String::new(),
        }
    }

    pub(in crate::platform) fn push(&mut self, bytes: &[u8]) -> Option<String> {
        let text = self.stripper.push(bytes);
        if text.is_empty() {
            None
        } else {
            self.output.push_str(&text);
            Some(text)
        }
    }

    pub(in crate::platform) fn finish(mut self) -> (String, Option<String>) {
        let tail = self.stripper.finish();
        let effect = (!tail.is_empty()).then(|| tail.clone());
        self.output.push_str(&tail);
        (self.output.trim().to_owned(), effect)
    }
}

#[derive(Clone, Copy, Debug)]
pub(in crate::platform) struct TerminalFacts<'a> {
    pub(in crate::platform) requested_session: &'a str,
    pub(in crate::platform) receipt_session: Option<&'a str>,
    pub(in crate::platform) output: &'a str,
    pub(in crate::platform) timed_out: bool,
    pub(in crate::platform) exit_success: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub(in crate::platform) struct TerminalFailure {
    pub(in crate::platform) code: &'static str,
    pub(in crate::platform) message: &'static str,
    pub(in crate::platform) stage: &'static str,
    pub(in crate::platform) session_id: String,
}

#[derive(Debug)]
pub(in crate::platform) struct TerminalSuccess {
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) output: String,
    pub(in crate::platform) transitions: Vec<Transition>,
}

pub(in crate::platform) fn classify_terminal(
    facts: TerminalFacts<'_>,
) -> Result<TerminalSuccess, TerminalFailure> {
    if facts.timed_out {
        return Err(failure(
            "antigravity_cli_timeout",
            "Antigravity CLI timed out before completing the turn.",
            "turn/execute",
            facts.requested_session,
        ));
    }
    let receipt = facts.receipt_session.unwrap_or_default();
    let native_session = if facts.requested_session.is_empty() {
        receipt
    } else {
        facts.requested_session
    };
    if !valid_session_id(native_session) {
        return Err(failure(
            "antigravity_hook_receipt_missing",
            "Antigravity hook bridge did not return a native conversation identifier.",
            "session/new",
            facts.requested_session,
        ));
    }
    if !facts.requested_session.is_empty()
        && !receipt.is_empty()
        && receipt != facts.requested_session
    {
        return Err(failure(
            "antigravity_cli_session_drift",
            "Antigravity CLI resumed a different native conversation than requested.",
            "session/resume",
            facts.requested_session,
        ));
    }
    if !facts.exit_success {
        return Err(failure(
            "antigravity_cli_turn_failed",
            "Antigravity CLI exited without a successful turn.",
            "turn/execute",
            native_session,
        ));
    }
    if facts.output.is_empty() {
        return Err(failure(
            "antigravity_cli_empty_output",
            "Antigravity CLI returned an empty final response.",
            "turn/execute",
            native_session,
        ));
    }
    Ok(TerminalSuccess {
        session_id: native_session.to_owned(),
        output: facts.output.to_owned(),
        transitions: success_transitions(facts.output),
    })
}

fn success_transitions(output: &str) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Processing);
    transitions.extend(reducer.advance(LifecycleStage::Responding));
    transitions.push(Transition::Text {
        unit_id: "antigravity:reply".to_owned(),
        text: output.to_owned(),
    });
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

fn failure(
    code: &'static str,
    message: &'static str,
    stage: &'static str,
    session_id: &str,
) -> TerminalFailure {
    TerminalFailure {
        code,
        message,
        stage,
        session_id: session_id.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_and_terminal_parser_reject_session_drift() {
        let receipt = parse_hook_receipt(
            r#"{"hookPayload":"{\"conversationId\":\"11111111-2222-3333-4444-555555555555\"}","environmentConversationId":""}"#,
        )
        .unwrap();
        let result = classify_terminal(TerminalFacts {
            requested_session: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            receipt_session: Some(&receipt),
            output: "ok",
            timed_out: false,
            exit_success: true,
        });
        assert_eq!(result.unwrap_err().code, "antigravity_cli_session_drift");

        let success = classify_terminal(TerminalFacts {
            requested_session: "",
            receipt_session: Some(&receipt),
            output: "ok",
            timed_out: false,
            exit_success: true,
        })
        .unwrap();
        assert_eq!(
            success.transitions.last(),
            Some(&Transition::Lifecycle(LifecycleStage::Completed))
        );
    }

    #[test]
    fn pty_parser_strips_terminal_control_and_emits_text_effects() {
        let mut parser = PtyOutputParser::new();
        assert_eq!(parser.push(b"\x1b[31mhello"), Some("hello".to_owned()));
        assert_eq!(parser.push(b"\x1b[0m\n"), Some("\n".to_owned()));
        let (output, tail) = parser.finish();
        assert_eq!(output, "hello");
        assert_eq!(tail, None);
    }
}
