use serde_json::{Value, json};
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }


pub(super) fn base_request() -> Value {
    let sv_cb_ref_1 = synthetic_value("cb-ref-1");
    json!({
        "pendingOperationId": "op-1",
        "requesterAgentId": "openclaw",
        "targetClientId": "desktop-a",
        "originEndpointId": "endpoint-origin",
        "riskLevel": "local_effect",
        "displaySummary": "Allow file read in project workspace",
        "policyReason": "ACP session/request_permission",
        "adapterCallbackTokenRef": sv_cb_ref_1.as_str(),
        "adapterStyle": "callback",
        "expiresAt": "2099-01-01T00:00:00Z",
        "responseNonce": "nonce-1",
        "requestedTools": ["fs.read"],
        "trustedEndpointIds": ["endpoint-origin", "endpoint-phone"],
    })
}
