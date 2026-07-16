use std::io::{Cursor, Read};

use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};

use super::super::contract::{
    DELIVERY_PROTOCOL_VERSION, DEVICE_TRUST_PROTOCOL_VERSION, MAX_HTTP_ERROR_RESPONSE_BYTES,
    SECURE_CLIENT_RELAY_PROTOCOL_VERSION, STORE_SCHEMA_VERSION,
    SecureClientRelayEndpointRegistration, SecureClientRelayOperation, SecureClientRelayPublicJwk,
    SecureClientRelayScope,
};
use super::super::response_binding::{
    validate_ack_response_binding, validate_challenge_response_binding,
    validate_registration_response_binding,
};
use super::super::response_codec::{decode_error_code, decode_success_response};
use super::super::response_schema::validate_success_response;

#[test]
fn registration_response_rejects_nested_server_owned_trust_fields() {
    let mut response = registration_response();
    validate_success_response(SecureClientRelayOperation::EndpointRegister, &response).unwrap();

    response["endpoint"]["trustState"] = json!("verified");
    assert!(
        validate_success_response(SecureClientRelayOperation::EndpointRegister, &response).is_err()
    );
}

#[test]
fn registration_response_rejects_noncanonical_key_and_scope_substitution() {
    let mut response = registration_response();
    response["endpoint"]["identityPublicKey"]["x"] = json!(format!("{}=", "A".repeat(42)));
    assert!(
        validate_success_response(SecureClientRelayOperation::EndpointRegister, &response).is_err()
    );

    let response = registration_response();
    let scope = SecureClientRelayScope::new("other-tenant", "account", None).unwrap();
    assert!(validate_registration_response_binding(&response, &scope, &registration()).is_err());
}

#[test]
fn challenge_subject_is_bound_to_operation_scope_and_endpoint() {
    let response = json!({
        "ok": true,
        "schemaVersion": STORE_SCHEMA_VERSION,
        "protocolVersion": DEVICE_TRUST_PROTOCOL_VERSION,
        "challengeId": "challenge",
        "challenge": format!(
            "{SECURE_CLIENT_RELAY_PROTOCOL_VERSION}:challenge:tenant:account:endpoint:2026-01-01T00:00:00Z"
        ),
        "challengeEncoding": "utf-8",
        "signatureAlgorithm": "Ed25519",
        "expiresAt": "2026-01-01T00:01:00Z"
    });
    validate_success_response(SecureClientRelayOperation::EndpointChallenge, &response).unwrap();
    let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
    validate_challenge_response_binding(&response, &scope, "endpoint").unwrap();
    assert!(validate_challenge_response_binding(&response, &scope, "substitute").is_err());
}

#[test]
fn sync_response_rejects_impossible_or_overlapping_gap_ranges() {
    let mut response = json!({
        "ok": true,
        "schemaVersion": STORE_SCHEMA_VERSION,
        "protocolVersion": DELIVERY_PROTOCOL_VERSION,
        "queueMode": "offline_queue",
        "mailbox": mailbox(),
        "cursor": {
            "afterDeliverySequence": 0,
            "nextDeliverySequence": 0,
            "highWatermark": 0,
            "hasMore": false
        },
        "gapRanges": [],
        "envelopes": []
    });
    validate_success_response(SecureClientRelayOperation::EnvelopeSync, &response).unwrap();

    response["gapRanges"] = json!([{ "from": 1, "to": 1 }]);
    assert!(
        validate_success_response(SecureClientRelayOperation::EnvelopeSync, &response).is_err()
    );

    response["cursor"]["highWatermark"] = json!(4);
    response["gapRanges"] = json!([
        { "from": 1, "to": 2 },
        { "from": 2, "to": 3 }
    ]);
    assert!(
        validate_success_response(SecureClientRelayOperation::EnvelopeSync, &response).is_err()
    );
}

#[test]
fn ack_response_binds_ack_receipt_and_requested_delivery() {
    let response = json!({
        "ok": true,
        "schemaVersion": STORE_SCHEMA_VERSION,
        "protocolVersion": DELIVERY_PROTOCOL_VERSION,
        "ack": {
            "deliveryId": "A".repeat(32),
            "idempotent": false,
            "ackedAt": "2026-01-01T00:00:00Z",
            "purged": true
        },
        "receipt": {
            "deliveryId": "B".repeat(32),
            "deliverySequence": 1,
            "receiptType": "ack",
            "acknowledgedAt": "2026-01-01T00:00:00Z",
            "purged": true
        },
        "mailbox": mailbox()
    });
    validate_success_response(SecureClientRelayOperation::EnvelopeAck, &response).unwrap();
    let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
    let mailbox_token = canonical_fixture_base64url(3, 32);
    assert!(
        validate_ack_response_binding(&response, &scope, &mailbox_token, &"A".repeat(32)).is_err()
    );
}

#[test]
fn codec_enforces_media_type_error_shape_and_small_error_body_bound() {
    let body = serde_json::to_vec(&json!({
        "ok": false,
        "schemaVersion": STORE_SCHEMA_VERSION,
        "protocolVersion": SECURE_CLIENT_RELAY_PROTOCOL_VERSION,
        "code": "stable_error_code",
        "error": "detail is validated but never projected"
    }))
    .unwrap();
    assert_eq!(
        decode_error_code(
            Some("application/json; charset=utf-8"),
            Cursor::new(body.clone()),
        )
        .unwrap(),
        "stable_error_code"
    );
    assert!(decode_error_code(Some("text/plain"), Cursor::new(body)).is_err());
    let oversized = std::io::repeat(b'x').take((MAX_HTTP_ERROR_RESPONSE_BYTES + 1) as u64);
    assert!(decode_error_code(Some("application/json"), oversized).is_err());
}

#[test]
fn success_codec_rejects_extra_top_level_fields() {
    let mut response = registration_response();
    response["serverTrust"] = json!(true);
    let body = serde_json::to_vec(&response).unwrap();
    assert!(
        decode_success_response(
            SecureClientRelayOperation::EndpointRegister,
            Some("application/json"),
            Cursor::new(body),
        )
        .is_err()
    );
}

fn canonical_fixture_base64url(byte: u8, count: usize) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(vec![byte; count])
}

fn registration() -> SecureClientRelayEndpointRegistration {
    SecureClientRelayEndpointRegistration {
        endpoint_id: "endpoint".to_string(),
        endpoint_kind: "cli".to_string(),
        identity_public_key: SecureClientRelayPublicJwk::x25519(canonical_fixture_base64url(1, 32))
            .unwrap(),
        signing_public_key: SecureClientRelayPublicJwk::ed25519(canonical_fixture_base64url(2, 32))
            .unwrap(),
        mailbox_token: canonical_fixture_base64url(3, 32),
        rotation_epoch: Some(1),
        challenge_id: "challenge".to_string(),
        challenge_signature: canonical_fixture_base64url(4, 64),
    }
}

fn registration_response() -> Value {
    let registration = registration();
    json!({
        "ok": true,
        "schemaVersion": STORE_SCHEMA_VERSION,
        "protocolVersion": DEVICE_TRUST_PROTOCOL_VERSION,
        "endpoint": {
            "tenantId": "tenant",
            "accountId": "account",
            "workspaceId": "",
            "endpointId": registration.endpoint_id,
            "endpointKind": registration.endpoint_kind,
            "mailboxToken": registration.mailbox_token,
            "identityPublicKey": registration.identity_public_key,
            "signingPublicKey": registration.signing_public_key,
            "fingerprint": "a".repeat(64),
            "rotationEpoch": 1,
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "revokedAt": ""
        }
    })
}

fn mailbox() -> Value {
    json!({
        "tenantId": "tenant",
        "accountId": "account",
        "workspaceId": "",
        "endpointId": "endpoint",
        "mailboxToken": canonical_fixture_base64url(3, 32),
        "queueBytes": 0,
        "queuedCount": 0,
        "oldestQueuedAt": "",
        "deliverySequence": 0,
        "receiptCount": 0,
        "ackedCount": 0,
        "updatedAt": "2026-01-01T00:00:00Z"
    })
}
