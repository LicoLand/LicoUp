use std::collections::BTreeSet;

use super::support::*;

#[test]
fn canonical_relay_envelope_has_one_strict_outer_schema() {
    let envelope = envelope_fixture();
    let wire = envelope.to_json().unwrap();
    let value: Value = serde_json::from_str(&wire).unwrap();
    let keys = value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect::<BTreeSet<_>>();
    assert_eq!(keys, SECURE_MESH_RELAY_OUTER_FIELDS.into_iter().collect());
    assert_eq!(
        value["schema"],
        Value::String(SECURE_MESH_RELAY_ENVELOPE_SCHEMA.to_string())
    );
    assert_eq!(value["ciphertextBucket"], MIN_PADDING_BUCKET_BYTES);
    let parsed = SecureMeshRelayEnvelope::from_json(&wire).unwrap();
    assert_eq!(parsed, envelope);

    for forbidden in [
        "messageId",
        "envelopeId",
        "sessionId",
        "senderEndpointId",
        "recipientEndpointId",
        "payloadKind",
        "contentType",
        "createdAt",
        "expiresAt",
        "cipherSuite",
        "protocolVersion",
    ] {
        assert!(!value.as_object().unwrap().contains_key(forbidden));
    }
}

#[test]
fn new_envelopes_use_random_nonsemantic_delivery_ids() {
    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    let first = SecureMeshRelayEnvelope::new(
        &mailbox,
        &[0x61; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
        &[0x62; MIN_PADDING_BUCKET_BYTES],
    )
    .unwrap();
    let second = SecureMeshRelayEnvelope::new(
        &mailbox,
        &[0x61; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
        &[0x62; MIN_PADDING_BUCKET_BYTES],
    )
    .unwrap();
    assert_ne!(first.delivery_id(), second.delivery_id());
    assert_eq!(
        general_purpose::URL_SAFE_NO_PAD
            .decode(first.delivery_id())
            .unwrap()
            .len(),
        DELIVERY_ID_BYTES
    );
    assert_eq!(
        first.decoded_encrypted_header().unwrap(),
        vec![0x61; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES]
    );
    assert_eq!(
        first.decoded_ciphertext().unwrap(),
        vec![0x62; MIN_PADDING_BUCKET_BYTES]
    );
}
