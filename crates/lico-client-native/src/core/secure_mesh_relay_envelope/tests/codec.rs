use super::support::*;

#[test]
fn canonical_relay_envelope_rejects_forbidden_and_unknown_outer_fields() {
    let base: Value = serde_json::from_str(&envelope_fixture().to_json().unwrap()).unwrap();
    for field in [
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
        "unknownCompatibilityField",
    ] {
        let mut candidate = base.clone();
        candidate[field] = json!("forbidden");
        let wire = serde_json::to_string(&candidate).unwrap();
        assert!(SecureMeshRelayEnvelope::from_json(&wire).is_err());
    }
}

#[test]
fn canonical_relay_envelope_rejects_duplicate_json_keys() {
    let wire = envelope_fixture().to_json().unwrap();
    let duplicate = wire.replacen(
        '{',
        &format!("{{\"schema\":\"{}\",", SECURE_MESH_RELAY_ENVELOPE_SCHEMA),
        1,
    );
    assert!(SecureMeshRelayEnvelope::from_json(&duplicate).is_err());
}

#[test]
fn canonical_relay_envelope_enforces_base64_sizes_and_bucket_match() {
    let base: Value = serde_json::from_str(&envelope_fixture().to_json().unwrap()).unwrap();

    let mut padded_delivery_id = base.clone();
    padded_delivery_id["deliveryId"] = json!(format!("{}=", base["deliveryId"].as_str().unwrap()));
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&padded_delivery_id).unwrap())
            .is_err()
    );

    let mut short_mailbox = base.clone();
    short_mailbox["mailboxToken"] = json!(general_purpose::URL_SAFE_NO_PAD.encode([1u8; 31]));
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&short_mailbox).unwrap())
            .is_err()
    );

    let mut invalid_header = base.clone();
    invalid_header["encryptedHeader"] = json!("not+base64url");
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&invalid_header).unwrap())
            .is_err()
    );

    let mut unsupported_bucket = base.clone();
    unsupported_bucket["ciphertextBucket"] = json!(300);
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&unsupported_bucket).unwrap())
            .is_err()
    );

    let mut short_header = base.clone();
    short_header["encryptedHeader"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(vec![
        2u8;
        SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
            - 1
    ]));
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&short_header).unwrap()).is_err()
    );

    let mut oversized_header = base.clone();
    oversized_header["encryptedHeader"] = json!(general_purpose::URL_SAFE_NO_PAD.encode(vec![
            3u8;
            SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
                + 1
        ]));
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&oversized_header).unwrap())
            .is_err()
    );

    let mut invalid_ciphertext = base.clone();
    invalid_ciphertext["ciphertext"] = json!("not+base64url");
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&invalid_ciphertext).unwrap())
            .is_err()
    );

    let mut mismatched_bucket = base.clone();
    mismatched_bucket["ciphertextBucket"] = json!(MIN_PADDING_BUCKET_BYTES * 2);
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&mismatched_bucket).unwrap())
            .is_err()
    );

    let mut oversized_integer = base;
    oversized_integer["ciphertextBucket"] = json!(JSON_SAFE_INTEGER_MAX + 1);
    assert!(
        SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&oversized_integer).unwrap())
            .is_err()
    );

    let mailbox = schedule(SecureMeshMailboxDirection::PairwiseInitiatorToResponder)
        .token_for_unix_seconds(VECTOR_TIME_SECONDS)
        .unwrap();
    assert!(
        SecureMeshRelayEnvelope::new(
            &mailbox,
            &[0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - 1],
            &[0u8; MIN_PADDING_BUCKET_BYTES],
        )
        .is_err()
    );
    assert!(
        SecureMeshRelayEnvelope::new(
            &mailbox,
            &[0u8; SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES],
            &[0u8; MIN_PADDING_BUCKET_BYTES + 1],
        )
        .is_err()
    );
}

#[test]
fn authenticated_ciphertext_bucket_validator_covers_every_protocol_bucket() {
    let mut bucket = MIN_PADDING_BUCKET_BYTES;
    while bucket <= POWER_OF_TWO_PADDING_LIMIT_BYTES {
        validate_authenticated_padding_bucket(bucket).unwrap();
        if bucket > MIN_PADDING_BUCKET_BYTES {
            assert!(validate_authenticated_padding_bucket(bucket - 1).is_err());
        }
        assert!(validate_authenticated_padding_bucket(bucket + 1).is_err());
        bucket = bucket.checked_mul(2).unwrap();
    }

    bucket = POWER_OF_TWO_PADDING_LIMIT_BYTES + LARGE_PADDING_BUCKET_STEP_BYTES;
    while bucket <= MAX_PADDING_BUCKET_BYTES {
        validate_authenticated_padding_bucket(bucket).unwrap();
        assert!(validate_authenticated_padding_bucket(bucket - 1).is_err());
        if bucket < MAX_PADDING_BUCKET_BYTES {
            assert!(validate_authenticated_padding_bucket(bucket + 1).is_err());
        }
        bucket += LARGE_PADDING_BUCKET_STEP_BYTES;
    }
    assert!(validate_authenticated_padding_bucket(MIN_PADDING_BUCKET_BYTES - 1).is_err());
    assert!(validate_authenticated_padding_bucket(MAX_PADDING_BUCKET_BYTES + 1).is_err());
}

#[test]
fn envelope_json_allocation_bound_rejects_oversize_before_parse() {
    let oversized = "x".repeat(MAX_RELAY_ENVELOPE_JSON_BYTES + 1);
    let error = SecureMeshRelayEnvelope::from_json(&oversized)
        .unwrap_err()
        .to_string();
    assert!(error.contains("JSON is too large"));
}

#[test]
fn constant_time_equality_requires_equal_length_and_content() {
    assert!(constant_time_equal(b"same", b"same"));
    assert!(!constant_time_equal(b"same", b"diff"));
    assert!(!constant_time_equal(b"same", b"short"));
}
