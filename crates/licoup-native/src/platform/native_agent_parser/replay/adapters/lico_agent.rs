//! Replay arm for the `lico_agent` adapter.
//!
//! One real [`RpcParser`] — the same line parser the driver's read loop runs —
//! consumes the recorded `lf-jsonl-jsonrpc` frames, so every projection is the
//! parser's own report and never a re-derivation of the payload. A rejected
//! frame is reported as the parser's own closed error kind.

use super::super::{FrameReplay, RecordedFrame};
use crate::platform::native_agent_parser::adapters::NativeLineParser;
use crate::platform::native_agent_parser::adapters::lico_agent::{
    FrameError, RpcEffect, RpcParser,
};
use crate::platform::runtime_adapters::RuntimeAdapter;
use serde_json::{Value, json};

pub(super) struct Replay;

impl Replay {
    pub(super) fn new() -> Result<Self, String> {
        Ok(Self)
    }

    /// The framing this boundary consumes, taken from the adapter's own
    /// contract so a frame recorded under another channel cannot pass.
    fn framing() -> &'static str {
        crate::platform::native_agent_parser::adapters::contract(RuntimeAdapter::LicoAgent).framing
    }
}

impl FrameReplay for Replay {
    fn feed(&mut self, frame: &RecordedFrame) -> Result<Vec<Value>, String> {
        if frame.channel != Self::framing() {
            return Err(format!(
                "lico-agent frames cross the {:?} channel; {:?} is not this boundary's framing",
                Self::framing(),
                frame.channel
            ));
        }
        // `read_effect` parses one line with the unit parser, so the arm does
        // the same; the payload is the recorded line, newline excluded.
        match RpcParser.parse_line(frame.payload.as_bytes()) {
            Ok(effect) => Ok(vec![effect_json(effect)]),
            Err(FrameError::Empty) => Ok(vec![json!({"error": "empty"})]),
            Err(FrameError::InvalidJson) => Ok(vec![json!({"error": "invalid_json"})]),
        }
    }
}

/// The parser's report, named by its own variant. `sessionId` and `code` are
/// the report's own `Option` fields and are omitted when the frame carried
/// none, so the projection never invents a value.
fn effect_json(effect: RpcEffect) -> Value {
    match effect {
        RpcEffect::Handshake {
            accepted,
            session_id,
        } => {
            let mut entry = json!({"effect": "handshake", "accepted": accepted});
            if let Some(session_id) = session_id {
                entry["sessionId"] = json!(session_id);
            }
            entry
        }
        RpcEffect::Text { delta } => json!({"effect": "text", "delta": delta}),
        RpcEffect::Processing => json!({"effect": "processing"}),
        RpcEffect::Control { method } => json!({"effect": "control", "method": method}),
        RpcEffect::Completed => json!({"effect": "completed"}),
        RpcEffect::Failed { code } => {
            let mut entry = json!({"effect": "failed"});
            if let Some(code) = code {
                entry["code"] = json!(code);
            }
            entry
        }
        RpcEffect::Ignored => json!({"effect": "ignored"}),
    }
}
