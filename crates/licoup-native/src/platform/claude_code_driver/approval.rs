//! External approval for Claude Code permission requests.
//!
//! When Claude Code emits a `control_request` with subtype
//! `permission_request`, the driver must not fail the turn: it parks the
//! request in the shared approval registry, emits `agent.approval.needed`,
//! and suspends the turn until the client resolves the park (allow/deny).
//! The decision is written back as a `permission_response` control response
//! so the CLI continues or aborts the turn itself.

use super::errors::ProtocolFailure;
use super::io::write_message;
use super::transport::PersistentTransport;
use serde_json::{Value, json};
use std::sync::mpsc::{self, RecvTimeoutError};
use uuid::Uuid;

/// Poll cadence while waiting for the external approval decision.
const APPROVAL_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(200);

/// Extract the permission request fields from a Claude Code control request.
///
/// Shape (Claude Code stream-json):
/// `{"type":"control_request","request_id":"<uuid>","request":{...}}` where
/// `request` carries the `permission_request` subtype plus the display prompt
/// and the tool use that needs approval.
pub(super) fn permission_request_details(message: &Value) -> Option<PermissionRequest> {
    let request_id = message.get("request_id").and_then(Value::as_str)?;
    let request = message.get("request")?;
    let subtype = request
        .get("subtype")
        .or_else(|| request.get("type"))
        .and_then(Value::as_str)?;
    if subtype != "permission_request" {
        return None;
    }
    let tool_use = request.get("toolUse").or_else(|| request.get("tool_use"));
    let tool_use_id = tool_use
        .and_then(|value| value.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string);
    let tool_name = tool_use
        .and_then(|value| value.get("name"))
        .and_then(Value::as_str)
        .map(|name| name.chars().take(64).collect::<String>());
    let prompt = request
        .get("prompt")
        .or_else(|| request.get("message"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let summary = prompt
        .or_else(|| {
            tool_name
                .as_ref()
                .map(|name| format!("Claude Code requests permission for: {name}"))
        })
        .unwrap_or_else(|| "Claude Code requests permission to continue.".to_string());
    Some(PermissionRequest {
        request_id: request_id.to_string(),
        tool_use_id,
        tool_name,
        summary,
    })
}

#[derive(Debug)]
pub(super) struct PermissionRequest {
    pub(super) request_id: String,
    pub(super) tool_use_id: Option<String>,
    pub(super) tool_name: Option<String>,
    pub(super) summary: String,
}

/// Suspend the turn until the client resolves the parked approval.
///
/// Never returns a timeout failure: the approval wait is unbounded by design
/// (developer-mandated rule — sending to an agent is never time-limited).
/// Returns `Ok(true)` when allowed (turn continues), `Ok(false)` when denied
/// (caller ends the turn with an interaction failure), and `Err` on transport
/// or park failures.
pub(super) fn await_external_approval(
    transport: &mut PersistentTransport,
    session_id: &str,
    turn_id: &str,
    request: &PermissionRequest,
) -> Result<bool, ProtocolFailure> {
    let (decision_tx, decision_rx) = mpsc::sync_channel(1);
    let token = Uuid::new_v4().to_string();
    let tools = request.tool_name.clone().into_iter().collect::<Vec<_>>();
    if let Err(failure) = crate::platform::acp_session_transport::register_park_and_inbox(
        &token,
        session_id,
        turn_id,
        "claude-code",
        &json!({ "request_id": request.request_id }),
        &request.summary,
        None,
        &tools,
        decision_tx,
    ) {
        let mut converted = ProtocolFailure::new(failure.code, failure.message, failure.stage);
        if let Some(turn_id) = failure.turn_id.as_deref() {
            converted = converted.with_turn(turn_id);
        }
        return Err(converted);
    }
    loop {
        match decision_rx.recv_timeout(APPROVAL_POLL_INTERVAL) {
            Ok(true) => {
                if write_message(
                    &mut transport.stdin,
                    &permission_response(&request.request_id, request.tool_use_id.as_deref(), true),
                )
                .is_err()
                {
                    return Err(ProtocolFailure::new(
                        "claude_code_write_failed",
                        "Claude Code stopped accepting the approval response.",
                        "protocol/write",
                    ));
                }
                return Ok(true);
            }
            Ok(false) => {
                let _ = write_message(
                    &mut transport.stdin,
                    &permission_response(
                        &request.request_id,
                        request.tool_use_id.as_deref(),
                        false,
                    ),
                );
                return Ok(false);
            }
            Err(RecvTimeoutError::Timeout) => continue,
            Err(RecvTimeoutError::Disconnected) => {
                return Err(ProtocolFailure::new(
                    "claude_code_approval_park_disconnected",
                    "Claude Code approval park channel disconnected.",
                    "server/request",
                ));
            }
        }
    }
}

fn permission_response(request_id: &str, tool_use_id: Option<&str>, allow: bool) -> Value {
    let mut response = serde_json::Map::new();
    response.insert("subtype".to_string(), json!("permission_response"));
    response.insert("request_id".to_string(), json!(request_id));
    if let Some(tool_use_id) = tool_use_id {
        response.insert("tool_use_id".to_string(), json!(tool_use_id));
    }
    response.insert(
        "response".to_string(),
        json!(if allow { "allow" } else { "deny" }),
    );
    json!({
        "type": "control_response",
        "response": response,
    })
}
