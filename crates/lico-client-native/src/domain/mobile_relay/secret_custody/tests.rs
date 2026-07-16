use super::*;

#[test]
fn runtime_override_policy_rejects_unredacted_secret_fields() {
    assert!(contains_unredacted_token_secret_override(&json!({
        "pcToken": "test-only-token"
    })));
    assert!(contains_unredacted_e2ee_secret_override(&json!({
        "privateKeyBase64url": "test-only-private-material"
    })));
    assert!(!contains_unredacted_token_secret_override(&json!({
        "pcToken": "redacted"
    })));
    assert!(!contains_unredacted_e2ee_secret_override(&json!({
        "privateKeyBase64url": "***"
    })));
}

#[test]
fn native_secret_bundle_roundtrip_is_field_allowlisted() {
    let encoded = serialize_native_e2ee_secret_bundle(&[
        ("privateKeyBase64url", "test-private".to_string()),
        ("signingKeyBase64url", "test-signing".to_string()),
    ])
    .unwrap();
    let decoded = parse_native_e2ee_secret_bundle(&encoded).unwrap();

    assert_eq!(decoded.len(), 2);
    assert!(
        decoded
            .iter()
            .any(|(field, _)| *field == "privateKeyBase64url")
    );
    assert!(
        decoded
            .iter()
            .any(|(field, _)| *field == "signingKeyBase64url")
    );
    assert!(
            parse_native_e2ee_secret_bundle(
                r#"{"schemaVersion":"licolite.mobile-relay.e2ee-secret-bundle.v1","secrets":{"unknownField":"value"}}"#
            )
            .is_err()
        );
}
