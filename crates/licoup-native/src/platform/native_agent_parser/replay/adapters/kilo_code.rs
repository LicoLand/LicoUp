//! Replay arm for the `kilo_code` adapter.
//!
//! The serve driver consumes three real document kinds: the session identity
//! document returned by `open_session` (through `session_id`), the SSE `data:`
//! payload of the event stream (through `observe`), and the whole-message
//! document returned by the message endpoint (through `message`). A recorded
//! frame is routed to the same entry point the driver uses for it, and the
//! projection is that entry point's own answer. Nothing here re-parses a vendor
//! frame.

use super::super::{FrameReplay, RecordedFrame};
use crate::platform::native_agent_parser::adapters::kilo_code::{
    ServeEventParser, message, session_id,
};
use serde_json::{Value, json};

pub(super) struct Replay {
    parser: ServeEventParser,
}

impl Replay {
    pub(super) fn new() -> Result<Self, String> {
        // The driver builds this parser once the session identity is known. The
        // arm rebinds it from the recorded identity document before any stream
        // frame is fed, so the initial unbound binding is never observed.
        Ok(Self {
            parser: ServeEventParser::new(""),
        })
    }
}

impl FrameReplay for Replay {
    fn feed(&mut self, frame: &RecordedFrame) -> Result<Vec<Value>, String> {
        let document = serde_json::from_str::<Value>(&frame.payload);
        if let Ok(value) = &document
            && let Some(identity) = session_id(value)
        {
            // `kilo_code_driver::open_session` binds the stream parser to the
            // identity carried by the session endpoint's own document.
            self.parser = ServeEventParser::new(identity);
            return Ok(vec![json!({"effect": "session", "sessionId": identity})]);
        }
        match self.parser.observe(&frame.payload) {
            Ok(Some(text)) => Ok(vec![json!({"effect": "text", "text": text})]),
            // The parser's own rejection: `ServeEventFailure::InvalidJson` is a
            // unit, so the fact it carries is only that the payload did not
            // decode. The driver's protocol-failure code for the same event is
            // deliberately not projected: the fixture must fail when the parser
            // changes, not when the driver renames a code.
            Err(_) => Ok(vec![json!({"error": "invalid_json"})]),
            Ok(None) => Ok(document
                .ok()
                .and_then(|value| message(&value))
                .map(|report| {
                    vec![json!({
                        "effect": "message",
                        "output": report.output,
                        "transitions": report
                            .transitions
                            .iter()
                            .map(|transition| transition.to_json())
                            .collect::<Vec<Value>>(),
                    })]
                })
                // `message` answering `None` is the parser's literal answer, and
                // this adapter has no in-band error terminal: a serve turn fails
                // out of band (HTTP status, the abort control lane), so a
                // whole-message document without assistant text leaves the
                // parser with nothing to report. The frame is recorded, its
                // projection is empty.
                .unwrap_or_default()),
        }
    }
}
