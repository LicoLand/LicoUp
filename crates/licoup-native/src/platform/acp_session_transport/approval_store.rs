use super::capabilities::{APPROVAL_WAIT_TIMEOUT, MAX_PARKED_PERMISSIONS};
use super::errors::ProtocolFailure;
use super::protocol::SessionProtocol;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::mpsc::SyncSender;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use time::OffsetDateTime;
use uuid::Uuid;

static PARKED_PERMISSIONS: OnceLock<Mutex<HashMap<String, ParkedPermission>>> = OnceLock::new();

#[derive(Debug)]
pub(super) struct ParkedPermission {
    #[allow(dead_code)]
    request_id: Value,
    session_id: String,
    turn_id: String,
    #[allow(dead_code)]
    display_summary: String,
    #[allow(dead_code)]
    option_id: Option<String>,
    decision_tx: SyncSender<bool>,
    created_at: Instant,
}

pub(super) fn parked_permissions() -> &'static Mutex<HashMap<String, ParkedPermission>> {
    PARKED_PERMISSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Resolve one in-process, one-shot Hermes permission request.
///
/// Portable files are intentionally not an authorization channel: another
/// local process must never be able to forge an ACP allow decision by writing a
/// predictable file. If the GUI and transport do not share this authenticated
/// process boundary, the request fails closed until a trusted IPC broker exists.
pub fn resolve_parked_permission(token: &str, allow: bool) -> Result<Value, &'static str> {
    let trimmed = token.trim();
    if trimmed.is_empty() {
        return Err("hermes_approval_token_missing");
    }
    // Prefer in-process channel when the park lives in this process.
    let parked = {
        let mut guard = parked_permissions()
            .lock()
            .map_err(|_| "hermes_approval_park_unavailable")?;
        guard.remove(trimmed)
    };
    if let Some(parked) = parked {
        if parked.created_at.elapsed() >= APPROVAL_WAIT_TIMEOUT {
            return Err("hermes_approval_park_expired");
        }
        let _ = parked.decision_tx.send(allow);
        return Ok(json!({
            "ok": true,
            "agentId": "hermes",
            "adapterCallbackTokenRef": trimmed,
            "decision": if allow { "allow" } else { "deny" },
            "sessionId": parked.session_id,
            "turnId": parked.turn_id,
            "parkAgeMs": parked.created_at.elapsed().as_millis() as u64,
            "signal": "in-process-one-shot",
        }));
    }
    Err("hermes_approval_park_missing")
}

pub(super) fn permission_request_display_safe(
    params: &Value,
) -> (String, Option<String>, Vec<String>) {
    let mut tools = Vec::new();
    if let Some(tool_calls) = params.get("toolCalls").and_then(Value::as_array) {
        for call in tool_calls {
            if let Some(name) = call
                .get("title")
                .or_else(|| call.get("kind"))
                .or_else(|| call.pointer("/toolCall/title"))
                .and_then(Value::as_str)
            {
                let trimmed = name.trim();
                if !trimmed.is_empty() && tools.len() < 8 {
                    tools.push(trimmed.chars().take(64).collect());
                }
            }
        }
    }
    if let Some(options) = params.get("options").and_then(Value::as_array) {
        for option in options {
            let kind = option.get("kind").and_then(Value::as_str).unwrap_or("");
            let option_id = option.get("optionId").and_then(Value::as_str);
            if matches!(kind, "allow_once" | "allow_always" | "allow")
                || option_id.is_some_and(|id| id.contains("allow"))
            {
                let summary = if tools.is_empty() {
                    "Hermes Agent requests permission to continue.".to_string()
                } else {
                    format!("Hermes Agent requests permission for: {}", tools.join(", "))
                };
                return (summary, option_id.map(str::to_string), tools);
            }
        }
    }
    let summary = if tools.is_empty() {
        "Hermes Agent requests permission to continue.".to_string()
    } else {
        format!("Hermes Agent requests permission for: {}", tools.join(", "))
    };
    let option_id = params
        .get("options")
        .and_then(Value::as_array)
        .and_then(|options| options.first())
        .and_then(|option| option.get("optionId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    (summary, option_id, tools)
}

pub(super) fn register_park_and_inbox(
    token: &str,
    protocol: &SessionProtocol,
    request_id: &Value,
    display_summary: &str,
    option_id: Option<&str>,
    requested_tools: &[String],
    decision_tx: SyncSender<bool>,
) -> Result<(), ProtocolFailure> {
    let session_id = protocol.session_id.clone().ok_or_else(|| {
        ProtocolFailure::user_interaction(
            "session/request_permission",
            None,
            Some(&protocol.config.turn_id),
        )
    })?;
    {
        let mut guard = parked_permissions().lock().map_err(|_| {
            ProtocolFailure::new(
                "hermes_approval_park_unavailable",
                "Hermes approval park state is unavailable.",
                "server/request",
            )
        })?;
        guard.retain(|_, parked| parked.created_at.elapsed() < APPROVAL_WAIT_TIMEOUT);
        if guard.len() >= MAX_PARKED_PERMISSIONS {
            return Err(ProtocolFailure::new(
                "hermes_approval_park_capacity",
                "Hermes approval park capacity was exceeded.",
                "server/request",
            ));
        }
        guard.insert(
            token.to_string(),
            ParkedPermission {
                request_id: request_id.clone(),
                session_id: session_id.clone(),
                turn_id: protocol.config.turn_id.clone(),
                display_summary: display_summary.to_string(),
                option_id: option_id.map(str::to_string),
                decision_tx,
                created_at: Instant::now(),
            },
        );
    }
    let expires_at = (OffsetDateTime::now_utc() + time::Duration::seconds(300))
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_else(|_| "2099-01-01T00:00:00Z".to_string());
    let nonce = Uuid::new_v4().to_string();
    let pending_operation_id = format!("hermes-park-{token}");
    let register = crate::core::secure_mesh_approval::evaluate_approval_request_json(&json!({
        "pendingOperationId": pending_operation_id,
        "requesterAgentId": "hermes",
        "targetClientId": "local-desktop",
        "originEndpointId": "local-desktop",
        "displaySummary": display_summary,
        "policyReason": "ACP session/request_permission",
        "adapterCallbackTokenRef": token,
        "adapterStyle": "callback",
        "expiresAt": expires_at,
        "responseNonce": nonce,
        "trustedEndpointIds": ["local-desktop"],
        "requestedTools": requested_tools,
        "riskLevel": "local_effect",
    }));
    if register.is_err() {
        // Inbox registration failure must not leave an unresolvable park.
        let _ = parked_permissions()
            .lock()
            .ok()
            .and_then(|mut guard| guard.remove(token));
        return Err(ProtocolFailure::new(
            "hermes_approval_inbox_register_failed",
            "Hermes could not register an in-process one-shot approval handle.",
            "server/request",
        ));
    }
    let _ = crate::core::secure_mesh_approval::evaluate_approval_fanout_json(&json!({
        "pendingOperationId": format!("hermes-park-{token}"),
    }));
    super::super::turn_event_emit::emit_turn_event(
        "agent.approval.needed",
        &session_id,
        &protocol.config.turn_id,
        json!({
            "agentId": "hermes",
            "adapterCallbackTokenRef": token,
            "pendingOperationId": format!("hermes-park-{token}"),
            "displaySummary": display_summary,
            "requestedTools": requested_tools,
            "adapterStyle": "callback",
            "responseNonce": nonce,
            "expiresAt": expires_at,
            "originEndpointId": "local-desktop",
            "trustedEndpointIds": ["local-desktop"],
        }),
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn insert_test_park(token: &str, created_at: Instant) -> mpsc::Receiver<bool> {
        let (decision_tx, decision_rx) = mpsc::sync_channel(1);
        parked_permissions().lock().unwrap().insert(
            token.to_string(),
            ParkedPermission {
                request_id: json!("request"),
                session_id: "session".to_string(),
                turn_id: "turn".to_string(),
                display_summary: "summary".to_string(),
                option_id: Some("allow-once".to_string()),
                decision_tx,
                created_at,
            },
        );
        decision_rx
    }

    #[test]
    fn approval_ticket_is_in_process_and_consumed_once() {
        let token = format!("test-one-shot-{}", Uuid::new_v4());
        let decision_rx = insert_test_park(&token, Instant::now());

        let resolved = resolve_parked_permission(&token, true).unwrap();

        assert_eq!(resolved["signal"], "in-process-one-shot");
        assert_eq!(decision_rx.recv_timeout(Duration::from_secs(1)), Ok(true));
        assert_eq!(
            resolve_parked_permission(&token, true),
            Err("hermes_approval_park_missing")
        );
    }

    #[test]
    fn expired_ticket_fails_closed_without_signalling_transport() {
        let token = format!("test-expired-{}", Uuid::new_v4());
        let created_at = Instant::now()
            .checked_sub(APPROVAL_WAIT_TIMEOUT + Duration::from_secs(1))
            .unwrap();
        let decision_rx = insert_test_park(&token, created_at);

        assert_eq!(
            resolve_parked_permission(&token, true),
            Err("hermes_approval_park_expired")
        );
        assert!(decision_rx.try_recv().is_err());
    }

    #[test]
    fn arbitrary_cross_process_style_token_never_authorizes() {
        let token = format!("forged-file-token-{}", Uuid::new_v4());
        assert_eq!(
            resolve_parked_permission(&token, true),
            Err("hermes_approval_park_missing")
        );
    }
}
