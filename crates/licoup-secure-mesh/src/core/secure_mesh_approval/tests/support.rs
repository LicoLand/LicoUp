use serde_json::{Value, json};
use std::sync::{Mutex, MutexGuard, OnceLock};

use super::super::ledger::ledger;
use super::super::model::{ApprovalState, PendingApproval};

pub(super) fn approval_test_guard() -> MutexGuard<'static, ()> {
    static TEST_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    let guard = TEST_LOCK
        .get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    ledger()
        .lock()
        .expect("synthetic approval ledger is available")
        .pending
        .clear();
    guard
}

pub(super) fn insert_expired_pending(operation_id: &str, nonce: &str) {
    let entry = PendingApproval {
        state: ApprovalState::Pending,
        pending_operation_id: operation_id.to_owned(),
        requester_agent_id: "synthetic-agent".to_owned(),
        target_client_id: "synthetic-client".to_owned(),
        origin_endpoint_id: "synthetic-origin".to_owned(),
        risk_level: "local_effect".to_owned(),
        display_summary: "Synthetic expired approval".to_owned(),
        policy_reason: "synthetic-test".to_owned(),
        adapter_callback_token_ref: "synthetic-callback".to_owned(),
        adapter_style: "callback".to_owned(),
        expires_at: "2000-01-01T00:00:00Z".to_owned(),
        response_nonce: nonce.to_owned(),
        requested_tools: vec!["synthetic.read".to_owned()],
        trusted_endpoint_ids: vec!["synthetic-origin".to_owned()],
        created_at: "1999-12-31T23:59:00Z".to_owned(),
        resolved: None,
    };
    ledger()
        .lock()
        .expect("synthetic approval ledger is available")
        .pending
        .insert(operation_id.to_owned(), entry);
}

pub(super) fn base_request() -> Value {
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
