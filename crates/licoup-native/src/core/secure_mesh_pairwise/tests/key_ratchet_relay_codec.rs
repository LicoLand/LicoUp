use super::test_support::*;

#[test]
fn relay_codec_round_trips_private_header_and_ciphertext_without_server_plaintext() {
    let (mut alice, mut bob) = pairwise_sessions();
    let context = payload_context(
        &alice,
        "msg-relay-codec",
        &alice.local_endpoint_id,
        &alice.remote_endpoint_id,
    );
    let envelope = alice
        .seal_payload_envelope(
            &context,
            &SecureMeshPlaintext::new(SecureMeshPayloadKind::ResultPayload, b"relay secret"),
        )
        .unwrap();
    assert!(!envelope.ciphertext().contains("relay secret"));
    let opened = bob
        .open_payload_envelope(&envelope, SecureMeshPayloadKind::ResultPayload)
        .unwrap();
    assert_eq!(opened.body, b"relay secret");
}
