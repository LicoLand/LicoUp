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
    expected_prompt: String,
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
    IdentityMismatch,
    TextSnapshotDiverged,
    PromptAcknowledgementMissing,
    PromptAcknowledgementMismatch,
    TurnFailed,
}

impl CursorParser {
    pub(in crate::platform) fn new(
        requested_session: &str,
        expected_prompt: &str,
        effective: EffectiveSettings,
    ) -> Self {
        Self {
            requested_session: requested_session.to_owned(),
            expected_prompt: expected_prompt.to_owned(),
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
            // The turn was launched bound to the requested (or freshly
            // created) native id. Any explicit stream identity must equal that
            // bound id before this frame contributes an accepted, chunk, or
            // terminal effect: a different or drifted conversation is never
            // silently relabeled.
            if id != self.requested_session {
                return Err(CursorParseFailure::IdentityMismatch);
            }
            self.observed_session = id.to_owned();
        }
        // The real protocol carries `request_id` on frames, never `uuid`. The
        // first frame with an explicit transport id wins; the synthetic
        // default only stands in while nothing better has arrived.
        let frame_turn_id = native_turn_id(&message);
        if self.turn_id.is_empty()
            || (self.turn_id == "cursor-turn" && frame_turn_id != "cursor-turn")
        {
            self.turn_id = frame_turn_id.to_owned();
        }
        update_effective(&message, &mut self.effective);
        if !self.accepted && is_user_frame(&message) {
            let acknowledged = user_prompt_text(&message)
                .filter(|text| text == &self.expected_prompt)
                .is_some();
            if !acknowledged {
                return Err(CursorParseFailure::PromptAcknowledgementMismatch);
            }
            effects.push(CursorEffect::Accepted {
                session_id: self.observed_session.clone(),
                turn_id: self.turn_id.clone(),
            });
            self.accepted = true;
        }
        let terminal = terminal_result(&message).map(str::to_owned);
        let terminal_failed = terminal.is_some() && is_error_result(&message);
        if terminal_failed {
            return Err(CursorParseFailure::TurnFailed);
        }
        // A system/init frame proves only that the process started. Delivery
        // belongs exclusively to Cursor's exact user prompt echo. Never show
        // assistant output or success for an unacknowledged input.
        if !self.accepted && (is_assistant_frame(&message) || terminal.is_some()) {
            return Err(CursorParseFailure::PromptAcknowledgementMissing);
        }
        if is_assistant_frame(&message) {
            if let Some(text) = assistant_text(&message) {
                // Current Cursor stream-json marks partial deltas with a
                // timestamp and then emits one timestamp-free cumulative
                // assistant snapshot before the result frame.
                let form = if message.get("timestamp_ms").is_some() {
                    TextForm::Delta(&text)
                } else {
                    TextForm::Cumulative(&text)
                };
                let suffix = self
                    .text
                    .observe("assistant", form)
                    .map_err(|_| CursorParseFailure::TextSnapshotDiverged)?;
                if !suffix.is_empty() {
                    effects.push(CursorEffect::Text {
                        session_id: self.observed_session.clone(),
                        turn_id: self.turn_id.clone(),
                        text: suffix,
                    });
                }
            }
        }
        if let Some(result) = terminal {
            // The successful result text is cumulative terminal authority:
            // reconcile it against every streamed fragment in one unit. The
            // reconciler appends a missing suffix, accepts an exact repeat
            // (emitting nothing), and rejects true divergence.
            let suffix = self
                .text
                .observe("assistant", TextForm::Cumulative(&result))
                .map_err(|_| CursorParseFailure::TextSnapshotDiverged)?;
            if !suffix.is_empty() {
                effects.push(CursorEffect::Text {
                    session_id: self.observed_session.clone(),
                    turn_id: self.turn_id.clone(),
                    text: suffix,
                });
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
    if effective.model.as_deref().is_none_or(str::is_empty)
        && let Some(model) = message
            .get("model")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
    {
        // Cursor reports a display label (for example `Composer 2.5`) even
        // when the launch selector was the stable slug (`composer-2.5`). Keep
        // an explicit request authoritative so validation compares one
        // selector namespace; use the init value only for default-model turns.
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
        .or_else(|| message.get("request_id"))
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

fn is_assistant_frame(message: &Value) -> bool {
    message.get("type").and_then(Value::as_str) == Some("assistant")
        && message.pointer("/message/role").and_then(Value::as_str) == Some("assistant")
}

fn is_user_frame(message: &Value) -> bool {
    message.get("type").and_then(Value::as_str) == Some("user")
        && message.pointer("/message/role").and_then(Value::as_str) == Some("user")
}

fn user_prompt_text(message: &Value) -> Option<String> {
    text_blocks(message)
}

fn assistant_text(message: &Value) -> Option<String> {
    text_blocks(message)
}

fn text_blocks(message: &Value) -> Option<String> {
    let blocks = message
        .pointer("/message/content")
        .and_then(Value::as_array)?;
    let text = blocks
        .iter()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect::<String>();
    (!text.is_empty()).then_some(text)
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
