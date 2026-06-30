use std::ffi::c_void;

use serde_json::json;
use sha2::{Digest, Sha256};

const FEATURE_PROTOCOL_STATUS: i32 = 1 << 0;
const FEATURE_ENVELOPE_VALIDATION: i32 = 1 << 1;
const FEATURE_COMMAND_POLICY: i32 = 1 << 2;
const FEATURE_CONTENT_CRYPTO: i32 = 1 << 3;
const FEATURE_PAIRWISE_RUNTIME: i32 = 1 << 4;
const FEATURE_MLS_RUNTIME: i32 = 1 << 5;
const EXPECTED_FEATURES: i32 = FEATURE_PROTOCOL_STATUS
    | FEATURE_ENVELOPE_VALIDATION
    | FEATURE_COMMAND_POLICY
    | FEATURE_CONTENT_CRYPTO
    | FEATURE_PAIRWISE_RUNTIME
    | FEATURE_MLS_RUNTIME;

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_example_flutter_1client_MainActivity_nativeSecureMeshRuntimeSelfTest(
    _env: *mut c_void,
    _this: *mut c_void,
) -> i32 {
    i32::from(native_secure_mesh_runtime_feature_flags() == EXPECTED_FEATURES)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_example_flutter_1client_MainActivity_nativeSecureMeshRuntimeFeatureFlags(
    _env: *mut c_void,
    _this: *mut c_void,
) -> i32 {
    native_secure_mesh_runtime_feature_flags()
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_example_flutter_1client_MainActivity_nativeSecureMeshRuntimeProtocolHash(
    _env: *mut c_void,
    _this: *mut c_void,
) -> i32 {
    let status = crate::secure_mesh::protocol_status();
    let digest = Sha256::digest(status.to_string().as_bytes());
    i32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]])
}

fn native_secure_mesh_runtime_feature_flags() -> i32 {
    let mut flags = 0;
    let status = crate::secure_mesh::protocol_status();
    if status
        .get("protocolVersion")
        .and_then(|value| value.as_str())
        == Some(crate::secure_mesh::SECURE_MESH_PROTOCOL_VERSION)
        && status
            .get("supportedTransports")
            .and_then(|value| value.as_array())
            .is_some_and(|transports| transports.len() >= 5)
    {
        flags |= FEATURE_PROTOCOL_STATUS;
    }
    if crate::secure_mesh::validate_envelope(&native_envelope_fixture()).is_ok() {
        flags |= FEATURE_ENVELOPE_VALIDATION;
    }
    let allowed = crate::secure_mesh::command_policy(&json!({
        "commandKind": "agent.message.send"
    }));
    let denied = crate::secure_mesh::command_policy(&json!({
        "commandKind": "shell.exec"
    }));
    if allowed.get("allowed").and_then(|value| value.as_bool()) == Some(true)
        && denied.get("allowed").and_then(|value| value.as_bool()) == Some(false)
    {
        flags |= FEATURE_COMMAND_POLICY;
    }
    if crate::secure_mesh_crypto::SECURE_MESH_CONTENT_CRYPTO_STATUS
        .contains("content_and_file_aead_available")
    {
        flags |= FEATURE_CONTENT_CRYPTO;
    }
    if crate::secure_mesh_pairwise::SECURE_MESH_PAIRWISE_STATUS
        .contains("x3dh_ready_double_ratchet_pairwise_runtime")
    {
        flags |= FEATURE_PAIRWISE_RUNTIME;
    }
    if crate::secure_mesh_mls::SECURE_MESH_MLS_STATUS.contains("openmls_group_add_update_remove") {
        flags |= FEATURE_MLS_RUNTIME;
    }
    flags
}

fn native_envelope_fixture() -> serde_json::Value {
    json!({
        "protocolVersion": crate::secure_mesh::SECURE_MESH_PROTOCOL_VERSION,
        "envelopeId": "env_android_native_runtime_self_test",
        "opaqueMailboxId": "mailbox_android_native_runtime_self_test",
        "messageId": "msg_android_native_runtime_self_test",
        "cipherSuite": crate::secure_mesh_pairwise::SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "createdAt": "2026-01-01T00:00:00.000Z",
        "expiresAt": "2026-01-01T00:10:00.000Z",
        "ciphertextSize": 32,
        "encryptedHeader": "header",
        "ciphertext": "ciphertext"
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn android_ffi_self_test_covers_native_secure_mesh_runtime() {
        assert_eq!(
            native_secure_mesh_runtime_feature_flags(),
            EXPECTED_FEATURES
        );
    }
}
