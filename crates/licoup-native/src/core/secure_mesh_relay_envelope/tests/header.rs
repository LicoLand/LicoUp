use super::support::*;

#[test]
fn fixed_private_header_round_trip_authenticates_outer_fields_and_hides_canaries() {
    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
        &mailbox,
        MIN_PADDING_BUCKET_BYTES,
        [0x81; DELIVERY_ID_BYTES],
    )
    .unwrap();
    let key = [0x82u8; RELAY_HEADER_KEY_BYTES];
    let private_header = b"private-endpoint-session-message-file-acp-canary";
    let nonce = [0x83; RELAY_HEADER_NONCE_BYTES];
    let encrypted_header =
        seal_private_relay_header_with_nonce(&draft, &key, private_header, nonce).unwrap();
    assert_eq!(RELAY_HEADER_NONCE_BYTES, 24);
    assert_eq!(&encrypted_header[..RELAY_HEADER_NONCE_BYTES], &nonce);
    let envelope = draft
        .finish(&encrypted_header, &[0x84u8; MIN_PADDING_BUCKET_BYTES])
        .unwrap();
    let opened =
        open_private_relay_header(&envelope, [&[0x85u8; RELAY_HEADER_KEY_BYTES][..], &key[..]])
            .unwrap();
    assert_eq!(opened.as_slice(), private_header);
    assert_eq!(
        envelope.decoded_encrypted_header().unwrap().len(),
        SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
    );
    assert!(!envelope.to_json().unwrap().contains("private-endpoint"));

    let mut changed: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
    changed["deliveryId"] =
        json!(general_purpose::URL_SAFE_NO_PAD.encode([0x86u8; DELIVERY_ID_BYTES]));
    let changed =
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&changed).unwrap()).unwrap();
    assert!(open_private_relay_header(&changed, [&key[..]]).is_err());
}

#[test]
fn private_header_rejects_nonce_ciphertext_and_tag_tampering() {
    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    let draft = SecureMeshRelayEnvelopeDraft::begin_with_delivery_id(
        &mailbox,
        MIN_PADDING_BUCKET_BYTES,
        [0xa1; DELIVERY_ID_BYTES],
    )
    .unwrap();
    let key = [0xa2u8; RELAY_HEADER_KEY_BYTES];
    let encrypted_header = seal_private_relay_header_with_nonce(
        &draft,
        &key,
        b"authenticated-private-header",
        [0xa3; RELAY_HEADER_NONCE_BYTES],
    )
    .unwrap();
    let envelope = draft
        .finish(&encrypted_header, &[0xa4u8; MIN_PADDING_BUCKET_BYTES])
        .unwrap();
    let base: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();

    for offset in [
        0,
        RELAY_HEADER_NONCE_BYTES,
        SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - 1,
    ] {
        let mut tampered = encrypted_header;
        tampered[offset] ^= 1;
        let mut wire = base.clone();
        wire["encryptedHeader"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(tampered));
        let envelope =
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&wire).unwrap()).unwrap();
        assert!(open_private_relay_header(&envelope, [&key[..]]).is_err());
    }
}
