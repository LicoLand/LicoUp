use super::super::{evaluate_approval_fanout_json, evaluate_approval_request_json};
use super::support::{approval_test_guard, insert_expired_pending};
use serde_json::json;

#[test]
fn approval_fanout_plan_never_exposes_plaintext_operation_detail() {
    let _test_guard = approval_test_guard();
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
fn repeated_expired_fanout_keeps_the_stable_expired_error() {
    let _test_guard = approval_test_guard();
    let operation_id = "op-fanout-expired-repeat";
    insert_expired_pending(operation_id, "nonce-fanout-expired-repeat");

    for _ in 0..2 {
        let error = evaluate_approval_fanout_json(&json!({
            "pendingOperationId": operation_id,
        }))
        .unwrap_err();
        assert_eq!(error.to_string(), "secure mesh approval request is expired");
    }
}
