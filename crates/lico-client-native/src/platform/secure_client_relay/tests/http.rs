use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::super::{
    SecureClientRelayAuth, SecureClientRelayEndpointRegistration, SecureClientRelayHttpError,
    SecureClientRelayOperation, SecureClientRelayPublicJwk, SecureClientRelayScope,
    SecureClientRelayTransport,
};
use super::support::{
    CapturedRequest, canonical_bytes, object_keys, read_request, set, success_fixture,
    write_json_response,
};
use crate::core::secure_mesh_relay_envelope::{SecureMeshMailboxToken, SecureMeshRelayEnvelope};

#[test]
fn application_error_preserves_core_retry_policy_without_server_detail() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let _request = read_request(&mut stream);
        write_json_response(
            &mut stream,
            "429 Too Many Requests",
            &json!({
                "ok": false,
                "schemaVersion": "licomesh.secure-mesh.store-schema.v2",
                "protocolVersion": "licomesh.secure-mesh.v1",
                "code": "secure_mesh_mailbox_backpressure",
                "error": "server detail must not cross the adapter"
            }),
            &[("retry-after", "3")],
        );
    });
    let transport = SecureClientRelayTransport::new(
        format!("http://{address}"),
        SecureClientRelayAuth::new("test-session", "test-csrf").unwrap(),
    )
    .unwrap();
    let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
    let mailbox = SecureMeshMailboxToken::from_base64url(canonical_bytes(7, 32)).unwrap();
    let envelope = SecureMeshRelayEnvelope::new(&mailbox, &[0u8; 4096], &[0u8; 256]).unwrap();
    let error = transport
        .envelope_send(&scope, &envelope, None, None)
        .unwrap_err();
    server.join().unwrap();
    let relay_error = error.downcast_ref::<SecureClientRelayHttpError>().unwrap();
    assert_eq!(relay_error.operation, "envelopeSend");
    assert_eq!(relay_error.status, 429);
    assert_eq!(relay_error.code, "secure_mesh_mailbox_backpressure");
    assert!(relay_error.retryable);
    assert_eq!(
        relay_error.retry_strategy,
        "exponential_backoff_with_jitter"
    );
    assert_eq!(relay_error.retry_after_seconds, Some(3));
    assert!(!error.to_string().contains("server detail"));
}

#[test]
fn adapter_emits_only_canonical_paths_headers_and_request_fields() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let captured = Arc::new(Mutex::new(Vec::<CapturedRequest>::new()));
    let thread_captured = Arc::clone(&captured);
    let server = thread::spawn(move || {
        for stream in listener.incoming().take(5) {
            let mut stream = stream.unwrap();
            let request = read_request(&mut stream);
            let response = success_fixture(&request);
            thread_captured.lock().unwrap().push(request);
            write_json_response(&mut stream, "200 OK", &response, &[]);
        }
    });

    let transport = SecureClientRelayTransport::new(
        format!("http://{address}"),
        SecureClientRelayAuth::new("test-session", "test-csrf").unwrap(),
    )
    .unwrap();
    let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
    let signing = SecureClientRelayPublicJwk::ed25519(canonical_bytes(1, 32)).unwrap();
    let mailbox_token = canonical_bytes(3, 32);
    transport
        .endpoint_challenge(&scope, "endpoint", &signing)
        .unwrap();
    transport
        .endpoint_register(
            &scope,
            &SecureClientRelayEndpointRegistration {
                endpoint_id: "endpoint".to_string(),
                endpoint_kind: "cli".to_string(),
                identity_public_key: SecureClientRelayPublicJwk::x25519(canonical_bytes(2, 32))
                    .unwrap(),
                signing_public_key: signing,
                mailbox_token: mailbox_token.clone(),
                rotation_epoch: Some(1),
                challenge_id: "challenge".to_string(),
                challenge_signature: canonical_bytes(4, 64),
            },
        )
        .unwrap();
    let mailbox = SecureMeshMailboxToken::from_base64url(mailbox_token).unwrap();
    let envelope = SecureMeshRelayEnvelope::new(&mailbox, &[0u8; 4096], &[0u8; 256]).unwrap();
    transport
        .envelope_send(&scope, &envelope, Some("mobile_relay"), None)
        .unwrap();
    transport
        .envelope_sync(&scope, mailbox.as_str(), Some(0), Some(10), Some(30_000))
        .unwrap();
    transport
        .envelope_ack(&scope, mailbox.as_str(), envelope.delivery_id(), "lease", 1)
        .unwrap();
    server.join().unwrap();

    let captured = captured.lock().unwrap();
    assert_eq!(captured.len(), 5);
    assert_eq!(
        captured
            .iter()
            .map(|request| request.path.as_str())
            .collect::<Vec<_>>(),
        SecureClientRelayOperation::ALL
            .iter()
            .map(|operation| operation.path())
            .collect::<Vec<_>>()
    );
    for request in captured.iter() {
        assert_eq!(
            request.headers["cookie"],
            "lico_console_session=test-session"
        );
        assert_eq!(request.headers["x-lico-csrf"], "test-csrf");
        assert_eq!(request.headers["x-lico-safety-confirm"], "true");
        assert_eq!(request.headers["content-type"], "application/json");
        let serialized = request.body.to_string();
        assert!(!serialized.contains("pairingId"));
        assert!(!serialized.contains("commandId"));
        assert!(!serialized.contains("plaintext"));
    }
    assert_eq!(
        object_keys(&captured[0].body),
        set(&["tenantId", "accountId", "endpointId", "signingPublicKey"])
    );
    assert_eq!(
        object_keys(&captured[1].body),
        set(&[
            "tenantId",
            "accountId",
            "endpointId",
            "endpointKind",
            "identityPublicKey",
            "signingPublicKey",
            "mailboxToken",
            "proof",
            "rotationEpoch",
        ])
    );
    assert_eq!(
        object_keys(&captured[2].body),
        set(&["tenantId", "accountId", "envelope", "transport"])
    );
    assert_eq!(
        object_keys(&captured[2].body["envelope"]),
        set(&[
            "schema",
            "deliveryId",
            "mailboxToken",
            "encryptedHeader",
            "ciphertextBucket",
            "ciphertext",
        ])
    );
    assert_eq!(
        object_keys(&captured[3].body),
        set(&[
            "tenantId",
            "accountId",
            "mailboxToken",
            "afterDeliverySequence",
            "limit",
            "leaseMs",
        ])
    );
    assert_eq!(
        object_keys(&captured[4].body),
        set(&[
            "tenantId",
            "accountId",
            "mailboxToken",
            "deliveryId",
            "leaseId",
            "leaseGeneration",
        ])
    );
}
