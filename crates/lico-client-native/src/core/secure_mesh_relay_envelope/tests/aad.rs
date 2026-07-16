use super::support::*;

#[test]
fn canonical_outer_aad_binds_every_mutable_routing_field() {
    let envelope = envelope_fixture();
    let baseline = envelope.authenticated_outer_data().unwrap();
    let baseline_again = envelope.authenticated_outer_data().unwrap();
    assert_eq!(baseline, baseline_again);

    let value: Value = serde_json::from_str(&envelope.to_json().unwrap()).unwrap();
    for (field, replacement) in [
        (
            "deliveryId",
            json!(general_purpose::URL_SAFE_NO_PAD.encode([0x91u8; DELIVERY_ID_BYTES])),
        ),
        (
            "mailboxToken",
            json!(general_purpose::URL_SAFE_NO_PAD.encode([0x92u8; MAILBOX_TOKEN_BYTES])),
        ),
        ("ciphertextBucket", json!(MIN_PADDING_BUCKET_BYTES * 2)),
    ] {
        let mut changed = value.clone();
        changed[field] = replacement;
        if field == "ciphertextBucket" {
            changed["ciphertext"] =
                json!(
                    general_purpose::URL_SAFE_NO_PAD
                        .encode(vec![0x44u8; MIN_PADDING_BUCKET_BYTES * 2])
                );
        }
        let changed =
            SecureMeshRelayEnvelope::from_json(&serde_json::to_string(&changed).unwrap()).unwrap();
        assert_ne!(baseline, changed.authenticated_outer_data().unwrap());
    }
}
