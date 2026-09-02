use super::CodexProtocol;
use crate::platform::codex_app_server::model::{ProtocolEffect, ProtocolFailure};
use serde_json::{Value, json};

impl CodexProtocol {
    pub(super) fn reject_server_request(&self, message: &Value) -> Option<Vec<ProtocolEffect>> {
        let request_id = message.get("id")?;
        let method = message.get("method")?.as_str()?;
        if message.get("result").is_some() || message.get("error").is_some() {
            return None;
        }

        Some(vec![
            ProtocolEffect::Send(json!({
                "id": request_id,
                "error": {
                    "code": -32001,
                    "message": "User interaction is required and was not approved by this client."
                }
            })),
            ProtocolEffect::Fail(ProtocolFailure::user_interaction(
                method,
                self.session_id.as_deref(),
                self.thread_id.as_deref(),
                self.turn_id.as_deref(),
            )),
        ])
    }
}
