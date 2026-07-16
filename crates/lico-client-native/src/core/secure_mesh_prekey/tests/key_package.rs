use super::super::key_package::key_package_signature_payload;
use super::super::validation::hex_sha256;
use super::super::{
    SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE, sign_key_package_record, verify_key_package_record,
};
use super::support::{
    CREATED_AT, EXPIRES_AT, deterministic_identity_fixture, identity_fixture, now,
};
use crate::core::secure_mesh_trust::DeviceTrustState;

#[test]
fn key_package_verifies_signature_and_rejects_cipher_suite_downgrade() {
    let (signing_key, identity) = identity_fixture("desktop:alice");
    let record = sign_key_package_record(
        &signing_key,
        &identity,
        "kp-1",
        SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
        "credential:alice",
        vec![9; 128],
        CREATED_AT,
        EXPIRES_AT,
    )
    .unwrap();
    verify_key_package_record(&identity, DeviceTrustState::Verified, &record, true, now()).unwrap();

    let mut downgraded = record;
    downgraded.cipher_suite = "licolite.mls-legacy.v0".to_string();
    let error = verify_key_package_record(
        &identity,
        DeviceTrustState::Verified,
        &downgraded,
        true,
        now(),
    )
    .unwrap_err();
    assert!(error.to_string().contains("cipher suite is unsupported"));
}

#[test]
fn key_package_rejects_tampered_public_bytes_and_untrusted_endpoint() {
    let (signing_key, identity) = identity_fixture("desktop:keypackage-tamper");
    let mut record = sign_key_package_record(
        &signing_key,
        &identity,
        "kp-tamper",
        SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
        "credential:tamper",
        vec![3; 128],
        CREATED_AT,
        EXPIRES_AT,
    )
    .unwrap();
    record.public_key_package[0] ^= 1;
    assert!(
        verify_key_package_record(&identity, DeviceTrustState::Verified, &record, true, now(),)
            .unwrap_err()
            .to_string()
            .contains("signature verification failed")
    );
    assert!(
        verify_key_package_record(&identity, DeviceTrustState::Revoked, &record, true, now(),)
            .unwrap_err()
            .to_string()
            .contains("endpoint is revoked")
    );
}

#[test]
fn key_package_signature_payload_and_signature_match_the_stable_vector() {
    let (signing_key, identity) = deterministic_identity_fixture("desktop:vector");
    let record = sign_key_package_record(
        &signing_key,
        &identity,
        "kp-vector-v1",
        SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
        "credential:vector",
        vec![0xa5; 64],
        CREATED_AT,
        EXPIRES_AT,
    )
    .unwrap();
    let payload = key_package_signature_payload(&identity, &record).unwrap();
    assert_eq!(
        hex_sha256(&payload),
        "5a709eef5b9a7cc3bf5d43e5b1a8bec9afd85476800f231d6e130e8abef6e6c5"
    );
    assert_eq!(
        record.signature,
        "q-XcFKDzzUdRTzDs1yg90oRRlBMwPdxTu1atIZs2Pu4MqrKhywjtu0b0lYawv6iUGZ_QO0NdpH6QsGWzIz_yCA"
    );
}
