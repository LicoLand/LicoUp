use super::{AdapterContract, NativeLineParser};
use crate::platform::cursor_driver::model::EffectiveSettings;
use crate::platform::cursor_driver::model::{MAX_SESSION_ID_LEN, MIN_SESSION_ID_LEN};
use crate::platform::native_agent_parser::{LifecycleStage, Transition, TransitionReducer};
use crate::platform::native_agent_parser::{TextForm, TextReconciler};
use serde_json::Value;
pub(super) const CONTRACT: AdapterContract = AdapterContract::new("cursor", "strict-lf-ndjson");

pub(in crate::platform) fn completed_transitions(output: &str) -> Vec<Transition> {
    terminal_transitions("cursor:reply", output)
}

pub(in crate::platform) fn failure_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Submitted);
    if let Some(failure) = reducer.fail(code, stage, message) {
        transitions.push(failure);
    }
    transitions
}

pub(in crate::platform) enum CreatedSessionFailure {
    Missing,
    Invalid,
}

pub(in crate::platform) fn parse_created_session(
    output: &str,
) -> Result<String, CreatedSessionFailure> {
    let session_id = output
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .ok_or(CreatedSessionFailure::Missing)?;
    if !safe_session_id(session_id) {
        return Err(CreatedSessionFailure::Invalid);
    }
    Ok(session_id.to_owned())
}

pub(in crate::platform) fn safe_session_id(session_id: &str) -> bool {
    let len = session_id.len();
    len >= MIN_SESSION_ID_LEN
        && len <= MAX_SESSION_ID_LEN
        && session_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
}

fn terminal_transitions(unit_id: &str, output: &str) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Responding);
    if !output.is_empty() {
        transitions.push(Transition::Text {
            unit_id: unit_id.to_owned(),
            text: output.to_owned(),
        });
    }
    transitions.extend(reducer.advance(LifecycleStage::Completed));
    transitions
}

pub(in crate::platform) struct CursorParser {
    requested_session: String,
    observed_session: String,
    turn_id: String,
    effective: EffectiveSettings,
    text: TextReconciler,
    accepted: bool,
}

pub(in crate::platform) enum CursorEffect {
    Accepted {
        session_id: String,
        turn_id: String,
    },
    Text {
        session_id: String,
        turn_id: String,
        text: String,
    },
    Complete(CursorOutcome),
}

pub(in crate::platform) struct CursorOutcome {
    pub(in crate::platform) output: String,
    pub(in crate::platform) session_id: String,
    pub(in crate::platform) turn_id: String,
    pub(in crate::platform) effective: EffectiveSettings,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum CursorParseFailure {
    InvalidJson,
    TextSnapshotDiverged,
    TurnFailed,
}

impl CursorParser {
    pub(in crate::platform) fn new(requested_session: &str, effective: EffectiveSettings) -> Self {
        Self {
            requested_session: requested_session.to_owned(),
            observed_session: requested_session.to_owned(),
            turn_id: String::new(),
            effective,
            text: TextReconciler::default(),
            accepted: false,
        }
    }

    pub(in crate::platform) fn session_id(&self) -> &str {
        if self.observed_session.is_empty() {
            &self.requested_session
        } else {
            &self.observed_session
        }
    }

    pub(in crate::platform) fn parse_line(
        &mut self,
        line: &[u8],
    ) -> Result<Vec<CursorEffect>, CursorParseFailure> {
        NativeLineParser::parse_line(self, line)
    }
}

impl NativeLineParser for CursorParser {
    type Report = Vec<CursorEffect>;
    type Error = CursorParseFailure;

    /// Sole ingress for a PTY-originated strict NDJSON wire line.
    fn parse_line(&mut self, line: &[u8]) -> Result<Self::Report, Self::Error> {
        let trimmed = line
            .iter()
            .copied()
            .skip_while(|byte| byte.is_ascii_whitespace())
            .collect::<Vec<_>>();
        if trimmed.iter().all(|byte| byte.is_ascii_whitespace()) {
            return Ok(Vec::new());
        }
        let message: Value =
            serde_json::from_slice(&trimmed).map_err(|_| CursorParseFailure::InvalidJson)?;
        let mut effects = Vec::new();
        if let Some(id) = session_id(&message) {
            self.observed_session = id.to_owned();
        }
        if self.turn_id.is_empty() {
            self.turn_id = native_turn_id(&message).to_owned();
        }
        if !self.accepted {
            effects.push(CursorEffect::Accepted {
                session_id: self.observed_session.clone(),
                turn_id: self.turn_id.clone(),
            });
            self.accepted = true;
        }
        update_effective(&message, &mut self.effective);
        if let Some(delta) = delta_text(&message) {
            let suffix = self
                .text
                .observe("assistant", TextForm::Delta(delta))
                .map_err(|_| CursorParseFailure::TextSnapshotDiverged)?;
            if !suffix.is_empty() {
                effects.push(CursorEffect::Text {
                    session_id: self.observed_session.clone(),
                    turn_id: self.turn_id.clone(),
                    text: suffix,
                });
            }
        }
        if let Some(snapshot) = assistant_text(&message).filter(|text| !text.is_empty()) {
            let suffix = self
                .text
                .observe("assistant", TextForm::Cumulative(&snapshot))
                .map_err(|_| CursorParseFailure::TextSnapshotDiverged)?;
            if !suffix.is_empty() {
                effects.push(CursorEffect::Text {
                    session_id: self.observed_session.clone(),
                    turn_id: self.turn_id.clone(),
                    text: suffix,
                });
            }
        }
        let terminal = terminal_result(&message).map(str::to_owned);
        let terminal_failed = terminal.is_some() && is_error_result(&message);
        if terminal_failed {
            return Err(CursorParseFailure::TurnFailed);
        }
        if let Some(result) = terminal {
            if !result.is_empty() && self.text.observed("assistant").is_none() {
                let _ = self
                    .text
                    .observe("assistant", TextForm::Cumulative(&result))
                    .map_err(|_| CursorParseFailure::TextSnapshotDiverged)?;
            }
            let output = self
                .text
                .observed("assistant")
                .unwrap_or_default()
                .to_owned();
            effects.push(CursorEffect::Complete(CursorOutcome {
                output,
                session_id: self.observed_session.clone(),
                turn_id: self.turn_id.clone(),
                effective: self.effective.clone(),
            }));
        }
        Ok(effects)
    }
}

fn update_effective(message: &Value, effective: &mut EffectiveSettings) {
    let is_init = message.get("subtype").and_then(Value::as_str) == Some("init")
        || message.get("type").and_then(Value::as_str) == Some("init");
    if !is_init {
        return;
    }
    if let Some(model) = message
        .get("model")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        effective.model = Some(model.to_owned());
    }
    if let Some(mode) = message
        .get("permissionMode")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    {
        effective.permission_mode = Some(mode.to_owned());
    }
}

fn native_turn_id(message: &Value) -> &str {
    message
        .get("uuid")
        .or_else(|| message.get("turn_id"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("cursor-turn")
}

fn session_id(message: &Value) -> Option<&str> {
    message
        .get("session_id")
        .or_else(|| message.get("sessionId"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

fn assistant_text(message: &Value) -> Option<String> {
    message
        .pointer("/message/content")
        .and_then(Value::as_array)
        .and_then(|blocks| {
            blocks.iter().find_map(|block| {
                (block.get("type").and_then(Value::as_str) == Some("text"))
                    .then(|| block.get("text").and_then(Value::as_str))
                    .flatten()
                    .map(str::to_owned)
            })
        })
        .or_else(|| {
            message
                .get("result")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| {
            message
                .pointer("/content/text")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
}

fn delta_text(message: &Value) -> Option<&str> {
    message
        .pointer("/event/delta/text")
        .and_then(Value::as_str)
        .or_else(|| message.pointer("/delta/text").and_then(Value::as_str))
        .or_else(|| {
            (message.get("type").and_then(Value::as_str) == Some("content_block_delta"))
                .then(|| message.pointer("/delta/text").and_then(Value::as_str))
                .flatten()
        })
}

fn terminal_result(message: &Value) -> Option<&str> {
    (message.get("type").and_then(Value::as_str) == Some("result")).then(|| {
        message
            .get("result")
            .and_then(Value::as_str)
            .unwrap_or_default()
    })
}

fn is_error_result(message: &Value) -> bool {
    message
        .get("is_error")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || message
            .get("subtype")
            .and_then(Value::as_str)
            .is_some_and(|value| value != "success")
}
