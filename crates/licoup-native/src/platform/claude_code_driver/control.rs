use serde_json::{Value, json};
use std::sync::mpsc::SyncSender;

#[derive(Debug)]
pub(super) enum ControlRequest {
    Cancel {
        session_id: String,
        acknowledged: SyncSender<bool>,
    },
    Steer {
        session_id: String,
        text: String,
        acknowledged: SyncSender<bool>,
    },
    Cleanup {
        acknowledged: SyncSender<bool>,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ControlDisposition {
    Accepted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

pub(super) fn interrupt_request() -> Value {
    json!({
        "type": "control_request",
        "request_id": uuid::Uuid::new_v4().to_string(),
        "request": {"subtype": "interrupt"}
    })
}

pub(super) fn steer_message(text: &str) -> Option<Value> {
    (!text.trim().is_empty()).then(|| {
        json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": [{"type": "text", "text": text}]
            }
        })
    })
}

pub(super) fn denied_control_response(message: &Value) -> Option<Value> {
    let request_id = message.get("request_id").and_then(Value::as_str)?;
    Some(json!({
        "type": "control_response",
        "response": {
            "subtype": "error",
            "request_id": request_id,
            "error": "Client interaction is unavailable."
        }
    }))
}
