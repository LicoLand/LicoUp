use super::input::{json_text, require_text};
use super::ledger::ledger;
use super::model::{ApprovalDecision, ApprovalLedger, ResolvedApproval};
use super::projection::{is_expired, now_rfc3339, projection, redact_hash};
use super::{
    MAX_TEXT_BYTES, SECURE_MESH_APPROVAL_REQUEST_PROTOCOL, SECURE_MESH_APPROVAL_RESPONSE_PROTOCOL,
};
use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};

use crate::state_machines::security_approval::{
    self, Event as ApprovalEvent, State as ApprovalState,
};

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
    if matches!(
        entry.state,
        ApprovalState::Approved | ApprovalState::Rejected
    ) {
        let existing = entry
            .resolved
            .as_ref()
            .ok_or_else(|| anyhow!("secure mesh approval resolved payload is missing"))?;
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
    if entry.state == ApprovalState::Expired
        || (entry.state == ApprovalState::Pending && is_expired(&entry.expires_at, &now))
    {
        if entry.state == ApprovalState::Pending {
            entry.state = security_approval::transition(entry.state, ApprovalEvent::Expire)
                .ok_or_else(|| {
                    anyhow!("secure mesh approval expiry transition is not configured")
                })?;
        }
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
        entry.state == ApprovalState::Pending,
        "secure mesh approval stored phase is invalid"
    );
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

    let event = match decision {
        ApprovalDecision::Allow => ApprovalEvent::Approve,
        ApprovalDecision::Deny => ApprovalEvent::Reject,
    };
    entry.state = security_approval::transition(entry.state, event)
        .ok_or_else(|| anyhow!("secure mesh approval response transition is not configured"))?;
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

pub(super) fn prune_expired(ledger: &mut ApprovalLedger, now: &str) {
    for entry in ledger.pending.values_mut() {
        if entry.state == ApprovalState::Pending && is_expired(&entry.expires_at, now) {
            entry.state = security_approval::transition(entry.state, ApprovalEvent::Expire)
                .expect("pending approval expiry transition is configured");
        }
    }
    ledger
        .pending
        .retain(|_, entry| entry.state != ApprovalState::Expired);
}
