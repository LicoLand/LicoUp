//! Secure Mesh remote-approval request/response envelopes and pending-operation CAS.
//!
//! Approval detail stays encrypted on the wire. Local projections expose only
//! display-safe summaries. Relay stores must never receive plaintext operation
//! detail, prompts, file paths, or tool arguments.

use anyhow::{Result, anyhow, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub const SECURE_MESH_APPROVAL_REQUEST_PROTOCOL: &str = "secure_mesh.approval_request.v1";
pub const SECURE_MESH_APPROVAL_RESPONSE_PROTOCOL: &str = "secure_mesh.approval_response.v1";
pub const SECURE_MESH_APPROVAL_CONTENT_TYPE: &str =
    "application/licolite.secure-mesh.approval.v1+json";
pub const SECURE_MESH_APPROVAL_STATUS: &str =
    "approval_request_response_cas_fanout_available_plaintext_relay_blocked";

const MAX_TEXT_BYTES: usize = 512;
const MAX_SUMMARY_BYTES: usize = 1_024;
const MAX_TOOL_NAME_BYTES: usize = 128;
const MAX_TOOL_NAMES: usize = 32;
const MAX_PENDING: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ApprovalDecision {
    Allow,
    Deny,
}

impl ApprovalDecision {
    fn as_str(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Deny => "deny",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value.trim() {
            "allow" | "approve" | "approved" => Ok(Self::Allow),
            "deny" | "denied" | "reject" | "rejected" => Ok(Self::Deny),
            _ => bail!("secure mesh approval decision is unsupported"),
        }
    }
}

#[derive(Clone, Debug)]
struct PendingApproval {
    pending_operation_id: String,
    requester_agent_id: String,
    target_client_id: String,
    origin_endpoint_id: String,
    risk_level: String,
    display_summary: String,
    policy_reason: String,
    adapter_callback_token_ref: String,
    adapter_style: String,
    expires_at: String,
    response_nonce: String,
    requested_tools: Vec<String>,
    trusted_endpoint_ids: Vec<String>,
    created_at: String,
    resolved: Option<ResolvedApproval>,
}

#[derive(Clone, Debug)]
struct ResolvedApproval {
    decision: ApprovalDecision,
    responding_endpoint_id: String,
    resolved_at: String,
    #[allow(dead_code)]
    response_nonce: String,
}

#[derive(Default)]
struct ApprovalLedger {
    pending: HashMap<String, PendingApproval>,
}

fn ledger() -> &'static Mutex<ApprovalLedger> {
    static LEDGER: OnceLock<Mutex<ApprovalLedger>> = OnceLock::new();
    LEDGER.get_or_init(|| Mutex::new(ApprovalLedger::default()))
}

fn now_rfc3339() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn require_text(field: &str, value: &str, max_bytes: usize) -> Result<String> {
    let trimmed = value.trim();
    ensure!(
        !trimmed.is_empty(),
        "secure mesh approval {field} is required"
    );
    ensure!(
        trimmed.len() <= max_bytes,
        "secure mesh approval {field} exceeds the byte limit"
    );
    ensure!(
        !trimmed.contains('\0'),
        "secure mesh approval {field} contains a NUL byte"
    );
    Ok(trimmed.to_string())
}

fn optional_text(value: Option<&str>, max_bytes: usize) -> Result<String> {
    match value {
        Some(raw) => {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                return Ok(String::new());
            }
            ensure!(
                trimmed.len() <= max_bytes,
                "secure mesh approval text exceeds the byte limit"
            );
            Ok(trimmed.to_string())
        }
        None => Ok(String::new()),
    }
}

fn json_text(params: &Value, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn json_string_list(params: &Value, keys: &[&str]) -> Result<Vec<String>> {
    for key in keys {
        if let Some(Value::Array(items)) = params.get(*key) {
            ensure!(
                items.len() <= MAX_TOOL_NAMES,
                "secure mesh approval tool list exceeds the item limit"
            );
            let mut out = Vec::with_capacity(items.len());
            for item in items {
                let text = item
                    .as_str()
                    .ok_or_else(|| anyhow!("secure mesh approval tool name must be a string"))?;
                out.push(require_text("toolName", text, MAX_TOOL_NAME_BYTES)?);
            }
            return Ok(out);
        }
    }
    Ok(Vec::new())
}

fn parse_risk_level(value: &str) -> Result<String> {
    let normalized = value.trim();
    ensure!(
        matches!(
            normalized,
            "read_only" | "safe_write" | "local_effect" | "high_risk"
        ),
        "secure mesh approval risk level is unsupported"
    );
    Ok(normalized.to_string())
}

fn parse_adapter_style(value: &str) -> Result<String> {
    let normalized = value.trim();
    ensure!(
        matches!(
            normalized,
            "callback" | "polling" | "cli" | "unavailable" | "runtime-owned"
        ),
        "secure mesh approval adapter style is unsupported"
    );
    Ok(normalized.to_string())
}

fn is_expired(expires_at: &str, now: &str) -> bool {
    match (
        OffsetDateTime::parse(expires_at, &Rfc3339),
        OffsetDateTime::parse(now, &Rfc3339),
    ) {
        (Ok(expiry), Ok(current)) => current >= expiry,
        _ => true,
    }
}

fn redact_hash(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    format!(
        "sha256:{}",
        digest
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    )
}

fn projection(entry: &PendingApproval) -> Value {
    let status = if let Some(resolved) = &entry.resolved {
        json!({
            "state": "resolved",
            "decision": resolved.decision.as_str(),
            "respondingEndpointIdHash": redact_hash(&resolved.responding_endpoint_id),
            "resolvedAt": resolved.resolved_at,
        })
    } else if is_expired(&entry.expires_at, &now_rfc3339()) {
        json!({
            "state": "expired",
            "decision": Value::Null,
        })
    } else {
        json!({
            "state": "pending",
            "decision": Value::Null,
        })
    };
    json!({
        "protocolVersion": SECURE_MESH_APPROVAL_REQUEST_PROTOCOL,
        "pendingOperationId": entry.pending_operation_id,
        "requesterAgentId": entry.requester_agent_id,
        "targetClientId": entry.target_client_id,
        "originEndpointIdHash": redact_hash(&entry.origin_endpoint_id),
        "riskLevel": entry.risk_level,
        "displaySummary": entry.display_summary,
        "policyReason": entry.policy_reason,
        "adapterCallbackTokenRef": entry.adapter_callback_token_ref,
        "adapterStyle": entry.adapter_style,
        "expiresAt": entry.expires_at,
        "requestedTools": entry.requested_tools,
        "trustedEndpointCount": entry.trusted_endpoint_ids.len(),
        "createdAt": entry.created_at,
        "status": status,
        "detailCiphertextPresent": false,
        "plaintextRelayBlocked": true,
    })
}

/// Evaluate and register a remote approval request (fail-closed validation).
pub fn evaluate_approval_request_json(params: &Value) -> Result<Value> {
    let pending_operation_id = require_text(
        "pendingOperationId",
        &json_text(
            params,
            &["pendingOperationId", "pending_operation_id", "operationId"],
        )
        .ok_or_else(|| anyhow!("secure mesh approval pending operation id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let requester_agent_id = require_text(
        "requesterAgentId",
        &json_text(
            params,
            &["requesterAgentId", "requester_agent_id", "agentId"],
        )
        .ok_or_else(|| anyhow!("secure mesh approval requester agent id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let target_client_id = require_text(
        "targetClientId",
        &json_text(params, &["targetClientId", "target_client_id", "clientId"])
            .ok_or_else(|| anyhow!("secure mesh approval target client id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let origin_endpoint_id = require_text(
        "originEndpointId",
        &json_text(
            params,
            &["originEndpointId", "origin_endpoint_id", "sourceEndpointId"],
        )
        .ok_or_else(|| anyhow!("secure mesh approval origin endpoint id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let risk_level = parse_risk_level(
        &json_text(params, &["riskLevel", "risk_level", "minimumRiskClass"])
            .unwrap_or_else(|| "local_effect".to_string()),
    )?;
    let display_summary = require_text(
        "displaySummary",
        &json_text(params, &["displaySummary", "display_summary", "summary"])
            .ok_or_else(|| anyhow!("secure mesh approval display summary is required"))?,
        MAX_SUMMARY_BYTES,
    )?;
    ensure!(
        !looks_like_plaintext_secret(&display_summary),
        "secure mesh approval display summary must not contain plaintext secrets"
    );
    let policy_reason = optional_text(
        json_text(params, &["policyReason", "policy_reason", "reason"]).as_deref(),
        MAX_SUMMARY_BYTES,
    )?;
    let adapter_callback_token_ref = require_text(
        "adapterCallbackTokenRef",
        &json_text(
            params,
            &[
                "adapterCallbackTokenRef",
                "adapter_callback_token_ref",
                "callbackTokenRef",
            ],
        )
        .ok_or_else(|| anyhow!("secure mesh approval adapter callback token ref is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let adapter_style = parse_adapter_style(
        &json_text(
            params,
            &["adapterStyle", "adapter_style", "permissionSelection"],
        )
        .unwrap_or_else(|| "callback".to_string()),
    )?;
    ensure!(
        adapter_style != "unavailable",
        "secure mesh approval adapter style is unavailable"
    );
    let expires_at = require_text(
        "expiresAt",
        &json_text(params, &["expiresAt", "expires_at"])
            .ok_or_else(|| anyhow!("secure mesh approval expiry is required"))?,
        MAX_TEXT_BYTES,
    )?;
    OffsetDateTime::parse(&expires_at, &Rfc3339)
        .map_err(|_| anyhow!("secure mesh approval expiry must be RFC3339"))?;
    let now = now_rfc3339();
    ensure!(
        !is_expired(&expires_at, &now),
        "secure mesh approval request is already expired"
    );
    let response_nonce = require_text(
        "responseNonce",
        &json_text(params, &["responseNonce", "response_nonce", "nonce"])
            .ok_or_else(|| anyhow!("secure mesh approval response nonce is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let requested_tools =
        json_string_list(params, &["requestedTools", "requested_tools", "tools"])?;
    let trusted_endpoint_ids = json_string_list(
        params,
        &["trustedEndpointIds", "trusted_endpoint_ids", "endpoints"],
    )?;
    ensure!(
        !trusted_endpoint_ids.is_empty(),
        "secure mesh approval fanout requires at least one trusted endpoint"
    );
    ensure!(
        params.get("operationDetail").is_none()
            && params.get("toolArguments").is_none()
            && params.get("prompt").is_none()
            && params.get("plaintextDetail").is_none(),
        "secure mesh approval request must not carry plaintext operation detail"
    );

    let entry = PendingApproval {
        pending_operation_id: pending_operation_id.clone(),
        requester_agent_id,
        target_client_id,
        origin_endpoint_id,
        risk_level,
        display_summary,
        policy_reason,
        adapter_callback_token_ref,
        adapter_style,
        expires_at,
        response_nonce,
        requested_tools,
        trusted_endpoint_ids: trusted_endpoint_ids.clone(),
        created_at: now,
        resolved: None,
    };

    let mut guard = ledger()
        .lock()
        .map_err(|_| anyhow!("secure mesh approval ledger is poisoned"))?;
    if let Some(existing) = guard.pending.get(&pending_operation_id) {
        if existing.resolved.is_some() {
            bail!("secure mesh approval pending operation is already resolved");
        }
        bail!("secure mesh approval pending operation id already exists");
    }
    if guard.pending.len() >= MAX_PENDING {
        prune_expired(&mut guard, &now_rfc3339());
        ensure!(
            guard.pending.len() < MAX_PENDING,
            "secure mesh approval ledger is full"
        );
    }
    guard
        .pending
        .insert(pending_operation_id.clone(), entry.clone());

    Ok(json!({
        "ok": true,
        "approvalProtocolVersion": SECURE_MESH_APPROVAL_REQUEST_PROTOCOL,
        "approvalContentType": SECURE_MESH_APPROVAL_CONTENT_TYPE,
        "approvalStatus": SECURE_MESH_APPROVAL_STATUS,
        "pendingOperationId": pending_operation_id,
        "fanout": {
            "transport": "SecureEnvelopeDeliveryMailbox",
            "sealPerTrustedEndpoint": true,
            "trustedEndpointCount": trusted_endpoint_ids.len(),
            "trustedEndpointIdHashes": trusted_endpoint_ids
                .iter()
                .map(|id| Value::String(redact_hash(id)))
                .collect::<Vec<_>>(),
            "plaintextRelayBlocked": true,
        },
        "request": projection(&entry),
    }))
}

/// Plan encrypted fanout of a pending approval to trusted endpoints.
pub fn evaluate_approval_fanout_json(params: &Value) -> Result<Value> {
    let pending_operation_id = require_text(
        "pendingOperationId",
        &json_text(
            params,
            &["pendingOperationId", "pending_operation_id", "operationId"],
        )
        .ok_or_else(|| anyhow!("secure mesh approval pending operation id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let guard = ledger()
        .lock()
        .map_err(|_| anyhow!("secure mesh approval ledger is poisoned"))?;
    let entry = guard
        .pending
        .get(&pending_operation_id)
        .ok_or_else(|| anyhow!("secure mesh approval pending operation was not found"))?;
    if let Some(resolved) = &entry.resolved {
        return Ok(json!({
            "ok": true,
            "pendingOperationId": pending_operation_id,
            "fanoutRequired": false,
            "state": "resolved",
            "decision": resolved.decision.as_str(),
            "plaintextRelayBlocked": true,
        }));
    }
    let now = now_rfc3339();
    ensure!(
        !is_expired(&entry.expires_at, &now),
        "secure mesh approval request is expired"
    );
    Ok(json!({
        "ok": true,
        "pendingOperationId": pending_operation_id,
        "fanoutRequired": true,
        "sealPerTrustedEndpoint": true,
        "trustedEndpointCount": entry.trusted_endpoint_ids.len(),
        "trustedEndpointIdHashes": entry
            .trusted_endpoint_ids
            .iter()
            .map(|id| Value::String(redact_hash(id)))
            .collect::<Vec<_>>(),
        "requestProtocolVersion": SECURE_MESH_APPROVAL_REQUEST_PROTOCOL,
        "responseProtocolVersion": SECURE_MESH_APPROVAL_RESPONSE_PROTOCOL,
        "plaintextRelayBlocked": true,
        "payloadClass": "permission_payload",
    }))
}

/// Resolve a pending approval with first-valid-response CAS semantics.
pub fn resolve_approval_response_json(params: &Value) -> Result<Value> {
    let pending_operation_id = require_text(
        "pendingOperationId",
        &json_text(
            params,
            &["pendingOperationId", "pending_operation_id", "operationId"],
        )
        .ok_or_else(|| anyhow!("secure mesh approval pending operation id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let decision = ApprovalDecision::parse(
        &json_text(params, &["decision", "response", "outcome"])
            .ok_or_else(|| anyhow!("secure mesh approval decision is required"))?,
    )?;
    let responding_endpoint_id = require_text(
        "respondingEndpointId",
        &json_text(
            params,
            &[
                "respondingEndpointId",
                "responding_endpoint_id",
                "endpointId",
                "userEndpointId",
            ],
        )
        .ok_or_else(|| anyhow!("secure mesh approval responding endpoint id is required"))?,
        MAX_TEXT_BYTES,
    )?;
    let response_nonce = require_text(
        "responseNonce",
        &json_text(params, &["responseNonce", "response_nonce", "nonce"])
            .ok_or_else(|| anyhow!("secure mesh approval response nonce is required"))?,
        MAX_TEXT_BYTES,
    )?;
    ensure!(
        params.get("operationDetail").is_none()
            && params.get("toolArguments").is_none()
            && params.get("prompt").is_none(),
        "secure mesh approval response must not carry plaintext operation detail"
    );

    let mut guard = ledger()
        .lock()
        .map_err(|_| anyhow!("secure mesh approval ledger is poisoned"))?;
    let entry = guard
        .pending
        .get_mut(&pending_operation_id)
        .ok_or_else(|| anyhow!("secure mesh approval pending operation was not found"))?;
    if let Some(existing) = &entry.resolved {
        return Ok(json!({
            "ok": false,
            "code": "secure_mesh_approval_already_resolved",
            "pendingOperationId": pending_operation_id,
            "state": "resolved",
            "decision": existing.decision.as_str(),
            "duplicateRejected": true,
            "plaintextRelayBlocked": true,
            "request": projection(entry),
        }));
    }
    let now = now_rfc3339();
    if is_expired(&entry.expires_at, &now) {
        return Ok(json!({
            "ok": false,
            "code": "secure_mesh_approval_expired",
            "pendingOperationId": pending_operation_id,
            "state": "expired",
            "duplicateRejected": false,
            "plaintextRelayBlocked": true,
            "request": projection(entry),
        }));
    }
    ensure!(
        entry.response_nonce == response_nonce,
        "secure mesh approval response nonce mismatch"
    );
    ensure!(
        entry
            .trusted_endpoint_ids
            .iter()
            .any(|id| id == &responding_endpoint_id)
            || entry.origin_endpoint_id == responding_endpoint_id,
        "secure mesh approval responding endpoint is not trusted"
    );

    entry.resolved = Some(ResolvedApproval {
        decision: decision.clone(),
        responding_endpoint_id: responding_endpoint_id.clone(),
        resolved_at: now.clone(),
        response_nonce: response_nonce.clone(),
    });

    Ok(json!({
        "ok": true,
        "approvalProtocolVersion": SECURE_MESH_APPROVAL_RESPONSE_PROTOCOL,
        "pendingOperationId": pending_operation_id,
        "state": "resolved",
        "decision": decision.as_str(),
        "respondingEndpointIdHash": redact_hash(&responding_endpoint_id),
        "resolvedAt": now,
        "adapterCallbackTokenRef": entry.adapter_callback_token_ref,
        "adapterStyle": entry.adapter_style,
        "requesterAgentId": entry.requester_agent_id,
        "fanoutConvergence": {
            "firstValidResponseWins": true,
            "laterResponsesShowResolvedState": true,
        },
        "plaintextRelayBlocked": true,
        "request": projection(entry),
        "response": {
            "protocolVersion": SECURE_MESH_APPROVAL_RESPONSE_PROTOCOL,
            "pendingOperationId": pending_operation_id,
            "decision": decision.as_str(),
            "responseNonceBound": true,
            "expiresAt": entry.expires_at,
        }
    }))
}

/// List pending/resolved approval projections for the inbox UI.
pub fn list_approval_inbox_json(params: &Value) -> Result<Value> {
    let include_resolved = params
        .get("includeResolved")
        .or_else(|| params.get("include_resolved"))
        .and_then(Value::as_bool)
        .unwrap_or(true);
    let now = now_rfc3339();
    let mut guard = ledger()
        .lock()
        .map_err(|_| anyhow!("secure mesh approval ledger is poisoned"))?;
    prune_expired(&mut guard, &now);
    let mut items = Vec::new();
    for entry in guard.pending.values() {
        let expired = is_expired(&entry.expires_at, &now);
        if entry.resolved.is_some() && !include_resolved {
            continue;
        }
        if expired && entry.resolved.is_none() && !include_resolved {
            continue;
        }
        items.push(projection(entry));
    }
    items.sort_by(|left, right| {
        let left_created = left.get("createdAt").and_then(Value::as_str).unwrap_or("");
        let right_created = right.get("createdAt").and_then(Value::as_str).unwrap_or("");
        right_created.cmp(left_created)
    });
    Ok(json!({
        "ok": true,
        "approvalProtocolVersion": SECURE_MESH_APPROVAL_REQUEST_PROTOCOL,
        "plaintextRelayBlocked": true,
        "items": items,
        "pendingCount": items
            .iter()
            .filter(|item| item.pointer("/status/state").and_then(Value::as_str) == Some("pending"))
            .count(),
    }))
}

/// Adapter capability projection for remote-approval bridges.
pub fn evaluate_approval_adapter_capability_json(params: &Value) -> Result<Value> {
    let agent_id =
        json_text(params, &["agentId", "agent_id", "requesterAgentId"]).unwrap_or_default();
    let (style, supported) = match agent_id.as_str() {
        "openclaw" | "hermes" | "copilot" | "cursor" | "kimi-code" => ("callback", true),
        "codex" | "claude-code" | "pi" => ("callback", true),
        "opencode" | "kilo-code" => ("polling", true),
        "antigravity" => ("unavailable", false),
        "" => ("", false),
        _ => ("unavailable", false),
    };
    Ok(json!({
        "ok": true,
        "agentId": agent_id,
        "approvalsSupported": supported,
        "permissionSelection": if style.is_empty() { Value::Null } else { Value::String(style.to_string()) },
        "remoteApprovalBridge": supported,
        "failClosedWithoutUserDecision": true,
        "localMachinePermissionIsNotUserApproval": true,
        "driversRegistryApprovalsEnabled": false,
        "note": "Adapter bridges may serialize and resume only after an explicit user decision; drivers.json approvals remain false until live evidence exists.",
    }))
}

fn prune_expired(ledger: &mut ApprovalLedger, now: &str) {
    ledger.pending.retain(|_, entry| {
        if entry.resolved.is_some() {
            return true;
        }
        !is_expired(&entry.expires_at, now)
    });
}

fn looks_like_plaintext_secret(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    lower.contains("authorization:")
        || lower.contains("bearer ")
        || lower.contains("api_key=")
        || lower.contains("-----begin ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base_request() -> Value {
        json!({
            "pendingOperationId": "op-1",
            "requesterAgentId": "openclaw",
            "targetClientId": "desktop-a",
            "originEndpointId": "endpoint-origin",
            "riskLevel": "local_effect",
            "displaySummary": "Allow file read in project workspace",
            "policyReason": "ACP session/request_permission",
            "adapterCallbackTokenRef": "cb-ref-1",
            "adapterStyle": "callback",
            "expiresAt": "2099-01-01T00:00:00Z",
            "responseNonce": "nonce-1",
            "requestedTools": ["fs.read"],
            "trustedEndpointIds": ["endpoint-origin", "endpoint-phone"],
        })
    }

    #[test]
    fn approval_request_registers_and_lists_without_plaintext_detail() {
        let _ = evaluate_approval_request_json(&base_request()).unwrap();
        let inbox = list_approval_inbox_json(&json!({})).unwrap();
        assert_eq!(inbox["ok"], true);
        assert!(inbox["pendingCount"].as_u64().unwrap_or(0) >= 1);
        let serialized = serde_json::to_string(&inbox).unwrap();
        assert!(!serialized.contains("toolArguments"));
        assert!(!serialized.contains("plaintextDetail"));
    }

    #[test]
    fn first_valid_response_wins_and_duplicate_is_rejected() {
        let request = json!({
            "pendingOperationId": "op-cas-1",
            "requesterAgentId": "hermes",
            "targetClientId": "desktop-a",
            "originEndpointId": "endpoint-origin",
            "riskLevel": "high_risk",
            "displaySummary": "Approve terminal command",
            "adapterCallbackTokenRef": "cb-ref-2",
            "adapterStyle": "callback",
            "expiresAt": "2099-01-01T00:00:00Z",
            "responseNonce": "nonce-cas",
            "trustedEndpointIds": ["endpoint-origin", "endpoint-phone"],
        });
        let _ = evaluate_approval_request_json(&request).unwrap();
        let first = resolve_approval_response_json(&json!({
            "pendingOperationId": "op-cas-1",
            "decision": "allow",
            "respondingEndpointId": "endpoint-phone",
            "responseNonce": "nonce-cas",
        }))
        .unwrap();
        assert_eq!(first["ok"], true);
        assert_eq!(first["decision"], "allow");

        let second = resolve_approval_response_json(&json!({
            "pendingOperationId": "op-cas-1",
            "decision": "deny",
            "respondingEndpointId": "endpoint-origin",
            "responseNonce": "nonce-cas",
        }))
        .unwrap();
        assert_eq!(second["ok"], false);
        assert_eq!(second["code"], "secure_mesh_approval_already_resolved");
        assert_eq!(second["decision"], "allow");
        assert_eq!(second["duplicateRejected"], true);
    }

    #[test]
    fn expired_and_untrusted_endpoint_fail_closed() {
        let request = json!({
            "pendingOperationId": "op-exp-1",
            "requesterAgentId": "openclaw",
            "targetClientId": "desktop-a",
            "originEndpointId": "endpoint-origin",
            "riskLevel": "safe_write",
            "displaySummary": "Approve edit",
            "adapterCallbackTokenRef": "cb-ref-3",
            "adapterStyle": "callback",
            "expiresAt": "2000-01-01T00:00:00Z",
            "responseNonce": "nonce-exp",
            "trustedEndpointIds": ["endpoint-origin"],
        });
        assert!(evaluate_approval_request_json(&request).is_err());

        let live = json!({
            "pendingOperationId": "op-trust-1",
            "requesterAgentId": "openclaw",
            "targetClientId": "desktop-a",
            "originEndpointId": "endpoint-origin",
            "riskLevel": "safe_write",
            "displaySummary": "Approve edit",
            "adapterCallbackTokenRef": "cb-ref-4",
            "adapterStyle": "callback",
            "expiresAt": "2099-01-01T00:00:00Z",
            "responseNonce": "nonce-trust",
            "trustedEndpointIds": ["endpoint-origin"],
        });
        let _ = evaluate_approval_request_json(&live).unwrap();
        assert!(
            resolve_approval_response_json(&json!({
                "pendingOperationId": "op-trust-1",
                "decision": "allow",
                "respondingEndpointId": "endpoint-evil",
                "responseNonce": "nonce-trust",
            }))
            .is_err()
        );
    }

    #[test]
    fn plaintext_detail_fields_are_rejected() {
        let mut request = base_request();
        request
            .as_object_mut()
            .unwrap()
            .insert("pendingOperationId".into(), json!("op-plain-1"));
        request
            .as_object_mut()
            .unwrap()
            .insert("toolArguments".into(), json!({"path": "/secret"}));
        assert!(evaluate_approval_request_json(&request).is_err());
    }

    #[test]
    fn adapter_capability_reports_callback_agents_without_enabling_drivers_flag() {
        let capability = evaluate_approval_adapter_capability_json(&json!({
            "agentId": "openclaw"
        }))
        .unwrap();
        assert_eq!(capability["approvalsSupported"], true);
        assert_eq!(capability["permissionSelection"], "callback");
        assert_eq!(capability["driversRegistryApprovalsEnabled"], false);
        assert_eq!(capability["failClosedWithoutUserDecision"], true);
    }

    #[test]
    fn approval_fanout_plan_never_exposes_plaintext_operation_detail() {
        let request = json!({
            "pendingOperationId": "op-fanout-plain-1",
            "requesterAgentId": "hermes",
            "targetClientId": "desktop-a",
            "originEndpointId": "endpoint-origin",
            "riskLevel": "local_effect",
            "displaySummary": "Allow hermes tool",
            "adapterCallbackTokenRef": "cb-fanout-1",
            "adapterStyle": "callback",
            "expiresAt": "2099-01-01T00:00:00Z",
            "responseNonce": "nonce-fanout",
            "requestedTools": ["fs.read"],
            "trustedEndpointIds": ["endpoint-origin", "endpoint-phone", "endpoint-tablet"],
        });
        let registered = evaluate_approval_request_json(&request).unwrap();
        assert_eq!(registered["fanout"]["plaintextRelayBlocked"], true);
        let fanout = evaluate_approval_fanout_json(&json!({
            "pendingOperationId": "op-fanout-plain-1",
        }))
        .unwrap();
        assert_eq!(fanout["ok"], true);
        assert_eq!(fanout["fanoutRequired"], true);
        assert_eq!(fanout["plaintextRelayBlocked"], true);
        assert_eq!(fanout["payloadClass"], "permission_payload");
        assert_eq!(fanout["sealPerTrustedEndpoint"], true);
        assert_eq!(fanout["trustedEndpointCount"], 3);
        let wire = serde_json::to_string(&fanout).unwrap();
        for canary in [
            "toolArguments",
            "plaintextDetail",
            "operationDetail",
            "prompt",
            "/secret",
            "Authorization:",
        ] {
            assert!(
                !wire.contains(canary),
                "fanout plan must not contain canary {canary}"
            );
        }
        // Hashes only — never raw endpoint identifiers on the fanout projection.
        assert!(wire.contains("trustedEndpointIdHashes"));
        assert!(!wire.contains("endpoint-phone"));
        assert!(!wire.contains("endpoint-tablet"));
    }

    #[test]
    fn multi_client_resolve_cas_converges_first_valid_response() {
        let request = json!({
            "pendingOperationId": "op-cas-multi-1",
            "requesterAgentId": "hermes",
            "targetClientId": "desktop-a",
            "originEndpointId": "endpoint-origin",
            "riskLevel": "high_risk",
            "displaySummary": "Approve remote effect",
            "adapterCallbackTokenRef": "cb-cas-multi",
            "adapterStyle": "callback",
            "expiresAt": "2099-01-01T00:00:00Z",
            "responseNonce": "nonce-cas-multi",
            "trustedEndpointIds": [
                "endpoint-origin",
                "endpoint-phone",
                "endpoint-tablet"
            ],
        });
        let _ = evaluate_approval_request_json(&request).unwrap();

        let phone_allow = resolve_approval_response_json(&json!({
            "pendingOperationId": "op-cas-multi-1",
            "decision": "allow",
            "respondingEndpointId": "endpoint-phone",
            "responseNonce": "nonce-cas-multi",
        }))
        .unwrap();
        assert_eq!(phone_allow["ok"], true);
        assert_eq!(phone_allow["decision"], "allow");
        assert_eq!(
            phone_allow["fanoutConvergence"]["firstValidResponseWins"],
            true
        );

        let tablet_deny = resolve_approval_response_json(&json!({
            "pendingOperationId": "op-cas-multi-1",
            "decision": "deny",
            "respondingEndpointId": "endpoint-tablet",
            "responseNonce": "nonce-cas-multi",
        }))
        .unwrap();
        assert_eq!(tablet_deny["ok"], false);
        assert_eq!(tablet_deny["duplicateRejected"], true);
        assert_eq!(tablet_deny["decision"], "allow");
        assert_eq!(tablet_deny["plaintextRelayBlocked"], true);

        let origin_retry = resolve_approval_response_json(&json!({
            "pendingOperationId": "op-cas-multi-1",
            "decision": "allow",
            "respondingEndpointId": "endpoint-origin",
            "responseNonce": "nonce-cas-multi",
        }))
        .unwrap();
        assert_eq!(origin_retry["ok"], false);
        assert_eq!(origin_retry["duplicateRejected"], true);
        assert_eq!(origin_retry["decision"], "allow");

        let inbox = list_approval_inbox_json(&json!({ "includeResolved": true })).unwrap();
        let serialized = serde_json::to_string(&inbox).unwrap();
        assert!(!serialized.contains("toolArguments"));
        assert!(!serialized.contains("plaintextDetail"));
        assert!(serialized.contains("plaintextRelayBlocked"));
    }
}
