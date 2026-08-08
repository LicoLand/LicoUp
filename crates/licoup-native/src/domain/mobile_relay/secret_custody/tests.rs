use super::*;
use crate::core::secure_mesh_secret_store::SecretBytes;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }


#[test]
fn runtime_override_policy_rejects_unredacted_secret_fields() {
    let sv_test_only_synthetic_byte = synthetic_value("test-only-bytes");
    let sv_test_only_synthetic = synthetic_value("test-only-synthetic");
    assert!(contains_unredacted_token_secret_override(&json!({
        "pcToken": sv_test_only_synthetic.as_str()
    })));
    assert!(contains_unredacted_e2ee_secret_override(&json!({
        "privateKeyBase64url": sv_test_only_synthetic_byte.as_str()
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
    let encoded = encode_mobile_relay_e2ee_secret_bundle(
        MobileRelayE2eeSecretBundle::try_from_fields(vec![
            (
                MobileRelayE2eeSecretField::PrivateKey,
                SecretBytes::try_from_bytes(b"test-synthetic".to_vec()).unwrap(),
            ),
            (
                MobileRelayE2eeSecretField::SigningKey,
                SecretBytes::try_from_bytes(b"test-signing".to_vec()).unwrap(),
            ),
        ])
        .unwrap(),
    )
    .unwrap();
    let decoded = decode_mobile_relay_e2ee_secret_bundle(encoded).unwrap();
    assert!(
        decoded
            .secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_some()
    );
    assert!(
        decoded
            .secret(MobileRelayE2eeSecretField::SigningKey)
            .is_some()
    );
}
