use std::collections::BTreeSet;

use base64::{Engine as _, engine::general_purpose};
use serde_json::Value;

use super::super::contract::{
    ENDPOINT_KINDS, LEASE_MS_MAX, LEASE_MS_MIN, SECURE_CLIENT_RELAY_CORE_CONFORMANCE,
    SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST, SECURE_CLIENT_RELAY_CORE_CONTRACT,
    SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST, SECURE_CLIENT_RELAY_PROTOCOL_VERSION, SYNC_LIMIT_MAX,
    SYNC_LIMIT_MIN, SecureClientRelayAuth, SecureClientRelayEndpointRegistration,
    SecureClientRelayOperation, SecureClientRelayPublicJwk, SecureClientRelayScope,
};
use super::super::{SecureClientRelayTransport, request};
use crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_OUTER_FIELDS;

#[test]
fn operation_registry_is_exact_and_has_no_arbitrary_path_surface() {
    let artifact: Value = serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONTRACT).unwrap();
    let contract = artifact["contract"].as_object().unwrap();
    let operations = contract["coreOperations"].as_object().unwrap();
    assert_eq!(operations.len(), SecureClientRelayOperation::ALL.len());
    for operation in SecureClientRelayOperation::ALL {
        let pinned = &operations[operation.key()];
        assert_eq!(pinned["method"], "POST");
        assert_eq!(pinned["path"], operation.path());
        let required = pinned["success"]["responseSchema"]["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|field| field.as_str().unwrap())
            .collect::<BTreeSet<_>>();
        assert_eq!(
            required,
            operation
                .success_fields()
                .iter()
                .copied()
                .collect::<BTreeSet<_>>()
        );
    }
    assert_eq!(contract["limits"]["syncPage"]["minimum"], SYNC_LIMIT_MIN);
    assert_eq!(contract["limits"]["syncPage"]["maximum"], SYNC_LIMIT_MAX);
    assert_eq!(contract["limits"]["leaseMs"]["minimum"], LEASE_MS_MIN);
    assert_eq!(contract["limits"]["leaseMs"]["maximum"], LEASE_MS_MAX);
    assert_eq!(
        contract["endpointKinds"],
        serde_json::to_value(ENDPOINT_KINDS).unwrap()
    );
    assert_eq!(
        contract["envelope"]["fields"],
        serde_json::to_value(SECURE_MESH_RELAY_OUTER_FIELDS).unwrap()
    );
}

#[test]
fn vendored_core_conformance_is_digest_bound_to_the_core_contract() {
    let contract: Value = serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONTRACT).unwrap();
    let conformance: Value = serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONFORMANCE).unwrap();
    assert_eq!(
        contract["canonicalDigest"],
        Value::String(SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST.to_string())
    );
    assert_eq!(
        conformance["canonicalDigest"],
        Value::String(SECURE_CLIENT_RELAY_CORE_CONFORMANCE_DIGEST.to_string())
    );
    assert_eq!(
        conformance["contractDigest"],
        Value::String(SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST.to_string())
    );
    assert_eq!(
        conformance["protocolVersion"],
        Value::String(SECURE_CLIENT_RELAY_PROTOCOL_VERSION.to_string())
    );
}

#[test]
fn auth_rejects_header_injection_and_debug_output_is_redacted() {
    assert!(SecureClientRelayAuth::new("session\r\nforged", "csrf").is_err());
    assert!(SecureClientRelayAuth::new("session;forged=1", "csrf").is_err());
    let auth = SecureClientRelayAuth::new("session", "csrf").unwrap();
    assert_eq!(auth.to_string(), "SecureClientRelayAuth([redacted])");
    assert!(!format!("{auth:?}").contains("session"));
}

#[test]
fn base_url_requires_tls_except_for_strict_loopback_origins() {
    let auth = || SecureClientRelayAuth::new("session", "csrf").unwrap();
    assert!(SecureClientRelayTransport::new("https://relay.example", auth()).is_ok());
    assert!(SecureClientRelayTransport::new("http://127.0.0.1:8080", auth()).is_ok());
    assert!(SecureClientRelayTransport::new("http://[::1]:8080", auth()).is_ok());
    assert!(SecureClientRelayTransport::new("http://relay.example", auth()).is_err());
    assert!(SecureClientRelayTransport::new("https://relay.example/path", auth()).is_err());
    assert!(SecureClientRelayTransport::new("https://user@relay.example", auth()).is_err());
    assert!(SecureClientRelayTransport::new("https://relay.example?token=x", auth()).is_err());
    assert!(SecureClientRelayTransport::new("https://relay.example/", auth()).is_err());
}

#[test]
fn request_validation_rejects_unknown_kinds_and_unbounded_labels() {
    let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
    let mut registration = SecureClientRelayEndpointRegistration {
        endpoint_id: "endpoint".to_string(),
        endpoint_kind: "agent_host".to_string(),
        identity_public_key: SecureClientRelayPublicJwk::x25519(canonical_bytes(1, 32)).unwrap(),
        signing_public_key: SecureClientRelayPublicJwk::ed25519(canonical_bytes(2, 32)).unwrap(),
        mailbox_token: canonical_bytes(3, 32),
        rotation_epoch: Some(1),
        challenge_id: "challenge".to_string(),
        challenge_signature: canonical_bytes(4, 64),
    };
    assert!(request::endpoint_register(&scope, &registration).is_ok());
    registration.endpoint_kind = "unknown".to_string();
    assert!(request::endpoint_register(&scope, &registration).is_err());
}

fn canonical_bytes(byte: u8, count: usize) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(vec![byte; count])
}
