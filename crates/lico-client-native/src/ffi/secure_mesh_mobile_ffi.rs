use std::path::PathBuf;
use std::sync::Arc;

use anyhow::ensure;
use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::platform::secure_mesh_secret_store::SecureMeshSecretStore;

pub const FEATURE_PROTOCOL_STATUS: i32 = 1 << 0;
pub const FEATURE_ENVELOPE_VALIDATION: i32 = 1 << 1;
pub const FEATURE_COMMAND_POLICY: i32 = 1 << 2;
pub const FEATURE_CONTENT_CRYPTO: i32 = 1 << 3;
pub const FEATURE_PAIRWISE_RUNTIME: i32 = 1 << 4;
pub const FEATURE_MLS_RUNTIME: i32 = 1 << 5;
pub const FEATURE_DEVICE_TRUST: i32 = 1 << 6;
pub const FEATURE_LIFECYCLE_SERVICE_ACTIONS: i32 = 1 << 7;
pub const EXPECTED_FEATURES: i32 = FEATURE_PROTOCOL_STATUS
    | FEATURE_ENVELOPE_VALIDATION
    | FEATURE_COMMAND_POLICY
    | FEATURE_CONTENT_CRYPTO
    | FEATURE_PAIRWISE_RUNTIME
    | FEATURE_MLS_RUNTIME
    | FEATURE_DEVICE_TRUST
    | FEATURE_LIFECYCLE_SERVICE_ACTIONS;
pub const MOBILE_RELAY_NATIVE_ACTIONS: &[&str] = &[
    "mobile.relay.config.get",
    "mobile.relay.config.set",
    "mobile.relay.pairing.claim",
    "mobile.relay.pairing.status",
    "mobile.relay.commands.createSecure",
    "mobile.relay.commands.resultSecure",
    "mobile.relay.commands.resultReplayProof",
    "mobile.relay.e2ee.status",
    "provider.chat.send",
    "secure_mesh.status",
    "secure_mesh.kt.configureAuthority",
    "secure_mesh.kt.publicationRequest",
    "secure_mesh.kt.revocationRequest",
    "secure_mesh.kt.provision",
    "secure_mesh.kt.gossip",
    "secure_mesh.kt.selfMonitor",
    "secure_mesh.kt.status",
    "secure_mesh.mls.status",
    "secure_mesh.mls.participant.ensure",
    "secure_mesh.mls.keyPackage.create",
    "secure_mesh.mls.group.create",
    "secure_mesh.mls.member.add",
    "secure_mesh.mls.member.remove",
    "secure_mesh.mls.group.join",
    "secure_mesh.mls.commit.process",
    "secure_mesh.mls.payload.seal",
    "secure_mesh.mls.payload.open",
    "secure_mesh.deviceTrust.evaluate",
    "secure_mesh.deviceTrust.verifyQr",
    "secure_mesh.deviceTrust.verifySas",
    "secure_mesh.deviceTrust.rotate",
    "secure_mesh.deviceTrust.revoke",
    "secure_mesh.deviceTrust.recover",
    "secure_mesh.lifecycle.serviceAction",
    "secure_mesh.file.route",
    "secure_mesh.file.receiveDestination",
    "secure_mesh.file.receiveConfirmation",
    "secure_mesh.file.handoffProof",
    "secure_mesh.approval.request",
    "secure_mesh.approval.fanout",
    "secure_mesh.approval.respond",
    "secure_mesh.approval.inbox",
    "secure_mesh.approval.adapterCapability",
];

const MAX_FFI_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_FFI_JSON_DEPTH: usize = 64;
const MAX_FFI_JSON_NODES: usize = 65_536;
const MAX_FFI_OBJECT_FIELDS: usize = 1_024;
const MAX_FFI_ARRAY_ITEMS: usize = 4_096;
const MAX_FFI_STRING_BYTES: usize = 2 * 1024 * 1024;

pub fn runtime_self_test() -> bool {
    runtime_feature_flags() == EXPECTED_FEATURES
}

pub fn runtime_feature_flags() -> i32 {
    let mut flags = 0;
    let status = crate::core::secure_mesh::protocol_status();
    if status.get("protocolVersion").and_then(Value::as_str)
        == Some(crate::core::secure_mesh::SECURE_MESH_PROTOCOL_VERSION)
        && status
            .get("supportedTransports")
            .and_then(Value::as_array)
            .is_some_and(|transports| transports.len() >= 5)
    {
        flags |= FEATURE_PROTOCOL_STATUS;
    }
    if crate::core::secure_mesh::validate_envelope(&native_envelope_fixture()).is_ok() {
        flags |= FEATURE_ENVELOPE_VALIDATION;
    }
    let allowed = crate::core::secure_mesh::command_policy(&json!({
        "commandKind": "agent.message.send"
    }));
    let denied = crate::core::secure_mesh::command_policy(&json!({
        "commandKind": "shell.exec"
    }));
    if allowed.get("allowed").and_then(Value::as_bool) == Some(true)
        && denied.get("allowed").and_then(Value::as_bool) == Some(false)
    {
        flags |= FEATURE_COMMAND_POLICY;
    }
    if crate::core::secure_mesh_crypto::SECURE_MESH_CONTENT_CRYPTO_STATUS
        .contains("content_and_file_aead_available")
        && native_payload_crypto_fixture().is_ok()
        && native_file_route_fixture().is_ok()
        && native_file_receive_destination_fixture().is_ok()
        && native_file_receive_confirmation_fixture().is_ok()
        && native_file_handoff_proof_fixture().is_ok()
    {
        flags |= FEATURE_CONTENT_CRYPTO;
    }
    if crate::core::secure_mesh_pairwise::SECURE_MESH_PAIRWISE_STATUS
        .contains("authenticated_transcript_pqxdh_mlkem1024_triple_ratchet")
        && status["pairwiseKem"]["parameterSet"] == "ML-KEM-1024"
        && status["pairwiseKem"]["standard"] == "FIPS 203"
        && status["pairwiseKem"]["publicKeyBytes"]
            == crate::core::secure_mesh_pqxdh::ML_KEM_1024_PUBLIC_KEY_BYTES
        && status["pairwiseKem"]["ciphertextBytes"]
            == crate::core::secure_mesh_pqxdh::ML_KEM_1024_CIPHERTEXT_BYTES
        && crate::core::secure_mesh_pairwise::runtime_crypto_self_test()
    {
        flags |= FEATURE_PAIRWISE_RUNTIME;
    }
    if crate::domain::secure_mesh_mls::runtime_binding_wired()
        && crate::core::secure_mesh_mls::runtime_crypto_self_test()
    {
        flags |= FEATURE_MLS_RUNTIME;
    }
    if crate::core::secure_mesh_trust::SECURE_MESH_DEVICE_TRUST_STATUS
        .contains("fingerprint_60_digit_safety_number_qr_policy_cli_gui_available")
        && native_device_trust_fixture().is_ok()
    {
        flags |= FEATURE_DEVICE_TRUST;
    }
    if crate::core::secure_mesh_lifecycle::SECURE_MESH_LIFECYCLE_STATUS
        .contains("ttl_delete_screenshot_resend_ack_purge")
        && native_lifecycle_service_action_fixture().is_ok()
    {
        flags |= FEATURE_LIFECYCLE_SERVICE_ACTIONS;
    }
    flags
}

pub fn runtime_protocol_hash() -> i32 {
    let status = crate::core::secure_mesh::protocol_status();
    let digest = Sha256::digest(status.to_string().as_bytes());
    i32::from_be_bytes([digest[0], digest[1], digest[2], digest[3]])
}

pub fn dispatch_json_with_files_dir(
    request_json: &str,
    files_dir: &str,
    unsupported_code: &'static str,
) -> anyhow::Result<Value> {
    validate_ffi_request_bytes(request_json)?;
    let request = serde_json::from_str::<Value>(request_json)?;
    let portable_dir = PathBuf::from(files_dir).join("portable-data");
    let previous = crate::platform::paths::set_portable_data_dir_override(Some(portable_dir));
    let result = dispatch_json(&request, unsupported_code);
    crate::platform::paths::set_portable_data_dir_override(previous);
    result
}

pub fn dispatch_json_with_files_dir_and_pairwise_secret_store(
    request_json: &str,
    files_dir: &str,
    unsupported_code: &'static str,
    pairwise_secret_store: Arc<dyn SecureMeshSecretStore>,
) -> anyhow::Result<Value> {
    validate_ffi_request_bytes(request_json)?;
    let request = serde_json::from_str::<Value>(request_json)?;
    let portable_dir = PathBuf::from(files_dir).join("portable-data");
    let previous = crate::platform::paths::set_portable_data_dir_override(Some(portable_dir));
    let mobile_relay_secret_store = Arc::clone(&pairwise_secret_store);
    let result = crate::domain::mobile_relay::with_pairwise_secret_store_override(
        pairwise_secret_store,
        || {
            crate::domain::mobile_relay::with_mobile_relay_secret_store_override(
                mobile_relay_secret_store,
                || dispatch_json(&request, unsupported_code),
            )
        },
    );
    crate::platform::paths::set_portable_data_dir_override(previous);
    result
}

pub fn dispatch_json(request: &Value, unsupported_code: &'static str) -> anyhow::Result<Value> {
    validate_ffi_json_structure(request)?;
    ensure!(
        request.is_object(),
        "secure mesh native request must be an object"
    );
    let action = request
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if secure_mesh_action_requires_protected_operation_gate(action) {
        crate::domain::mobile_relay::ensure_secure_mesh_protected_operation_allowed()?;
    }
    let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
    match action {
        "mobile.relay.config.get" => crate::domain::mobile_relay::config_get(&params),
        "mobile.relay.config.set" => crate::domain::mobile_relay::config_set(&params),
        "mobile.relay.pairing.claim" => crate::domain::mobile_relay::pairing_claim(&params),
        "mobile.relay.pairing.status" => crate::domain::mobile_relay::pairing_status(&params),
        "mobile.relay.commands.createSecure" => {
            crate::domain::mobile_relay::command_create_secure(&params)
        }
        "mobile.relay.commands.resultSecure" => {
            crate::domain::mobile_relay::command_result_secure(&params)
        }
        "mobile.relay.commands.resultReplayProof" => {
            crate::domain::mobile_relay::command_result_replay_proof(&params)
        }
        "mobile.relay.e2ee.status" => crate::domain::mobile_relay::e2ee_status(&params),
        "provider.chat.send" => crate::domain::forwarding::provider_chat(&params),
        "secure_mesh.status" => {
            let evaluation =
                crate::domain::mobile_relay::selected_mobile_relay_capability_evaluation()?;
            crate::core::secure_mesh::protocol_status_with_capability_evaluation(&evaluation)
        }
        action if crate::domain::mobile_relay::SECURE_MESH_KT_NATIVE_ACTIONS.contains(&action) => {
            crate::domain::mobile_relay::dispatch_key_transparency_action(action, &params)
        }
        action
            if crate::domain::secure_mesh_mls::SECURE_MESH_MLS_NATIVE_ACTIONS.contains(&action) =>
        {
            crate::domain::secure_mesh_mls::dispatch(action, &params)
        }
        "secure_mesh.deviceTrust.evaluate" => {
            crate::core::secure_mesh_trust::evaluate_device_trust_policy_json(&params)
        }
        "secure_mesh.deviceTrust.verifyQr" => {
            crate::core::secure_mesh_trust::evaluate_device_trust_verification_json(&params, "qr")
        }
        "secure_mesh.deviceTrust.verifySas" => {
            crate::core::secure_mesh_trust::evaluate_device_trust_verification_json(&params, "sas")
        }
        "secure_mesh.deviceTrust.rotate" => {
            crate::core::secure_mesh_trust::evaluate_device_trust_lifecycle_json(&params, "rotate")
        }
        "secure_mesh.deviceTrust.revoke" => {
            crate::core::secure_mesh_trust::evaluate_device_trust_lifecycle_json(&params, "revoke")
        }
        "secure_mesh.deviceTrust.recover" => {
            crate::core::secure_mesh_trust::evaluate_device_trust_lifecycle_json(&params, "recover")
        }
        "secure_mesh.lifecycle.serviceAction" => {
            crate::core::secure_mesh_lifecycle::evaluate_service_action_json(&params)
        }
        "secure_mesh.file.route" => {
            crate::core::secure_mesh_file::evaluate_file_route_json(&params)
        }
        "secure_mesh.file.receiveDestination" => {
            crate::core::secure_mesh_file::evaluate_file_receive_destination_json(&params)
        }
        "secure_mesh.file.receiveConfirmation" => {
            crate::core::secure_mesh_file::evaluate_file_receive_confirmation_json(&params)
        }
        "secure_mesh.file.handoffProof" => {
            crate::core::secure_mesh_file::evaluate_file_handoff_proof_json(&params)
        }
        "secure_mesh.approval.request" => {
            crate::core::secure_mesh_approval::evaluate_approval_request_json(&params)
        }
        "secure_mesh.approval.fanout" => {
            crate::core::secure_mesh_approval::evaluate_approval_fanout_json(&params)
        }
        "secure_mesh.approval.respond" => {
            let mut result =
                crate::core::secure_mesh_approval::resolve_approval_response_json(&params)?;
            if result.get("ok").and_then(Value::as_bool) == Some(true) {
                let agent_id = result
                    .get("requesterAgentId")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let token = result
                    .get("adapterCallbackTokenRef")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let allow = result.get("decision").and_then(Value::as_str) == Some("allow");
                if agent_id == "hermes" && !token.is_empty() {
                    match crate::platform::hermes_resolve_parked_permission(token, allow) {
                        Ok(resume) => {
                            if let Some(object) = result.as_object_mut() {
                                object.insert("adapterResume".to_string(), resume);
                            }
                        }
                        Err(code) => {
                            if let Some(object) = result.as_object_mut() {
                                object.insert(
                                    "adapterResume".to_string(),
                                    json!({
                                        "ok": false,
                                        "code": code,
                                        "failClosed": true,
                                    }),
                                );
                            }
                        }
                    }
                }
            }
            Ok(result)
        }
        "secure_mesh.approval.inbox" => {
            crate::core::secure_mesh_approval::list_approval_inbox_json(&params)
        }
        "secure_mesh.approval.adapterCapability" => {
            crate::core::secure_mesh_approval::evaluate_approval_adapter_capability_json(&params)
        }
        _ => Ok(json!({
            "ok": false,
            "code": unsupported_code,
            "action": action
        })),
    }
}

fn validate_ffi_request_bytes(request_json: &str) -> anyhow::Result<()> {
    ensure!(
        request_json.len() <= MAX_FFI_REQUEST_BYTES,
        "secure mesh native request exceeds the byte limit"
    );
    Ok(())
}

fn validate_ffi_json_structure(request: &Value) -> anyhow::Result<()> {
    let mut stack = vec![(request, 1usize)];
    let mut nodes = 0usize;
    while let Some((value, depth)) = stack.pop() {
        ensure!(
            depth <= MAX_FFI_JSON_DEPTH,
            "secure mesh native request exceeds the JSON depth limit"
        );
        nodes = nodes
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("secure mesh native request node count overflow"))?;
        ensure!(
            nodes <= MAX_FFI_JSON_NODES,
            "secure mesh native request exceeds the JSON node limit"
        );
        match value {
            Value::String(value) => ensure!(
                value.len() <= MAX_FFI_STRING_BYTES,
                "secure mesh native request contains an oversized string"
            ),
            Value::Array(values) => {
                ensure!(
                    values.len() <= MAX_FFI_ARRAY_ITEMS,
                    "secure mesh native request contains an oversized array"
                );
                for value in values.iter().rev() {
                    stack.push((value, depth.saturating_add(1)));
                }
            }
            Value::Object(values) => {
                ensure!(
                    values.len() <= MAX_FFI_OBJECT_FIELDS,
                    "secure mesh native request contains an oversized object"
                );
                for (key, value) in values.iter().rev() {
                    ensure!(
                        key.len() <= MAX_FFI_STRING_BYTES,
                        "secure mesh native request contains an oversized object key"
                    );
                    stack.push((value, depth.saturating_add(1)));
                }
            }
            Value::Null | Value::Bool(_) | Value::Number(_) => {}
        }
    }
    Ok(())
}

fn secure_mesh_action_requires_protected_operation_gate(action: &str) -> bool {
    matches!(
        action,
        "mobile.relay.config.set"
            | "mobile.relay.pairing.claim"
            | "mobile.relay.pairing.status"
            | "mobile.relay.commands.createSecure"
            | "mobile.relay.commands.resultSecure"
            | "mobile.relay.commands.resultReplayProof"
            | "secure_mesh.kt.publicationRequest"
            | "secure_mesh.kt.revocationRequest"
            | "secure_mesh.kt.provision"
            | "secure_mesh.kt.gossip"
            | "secure_mesh.kt.selfMonitor"
            | "secure_mesh.mls.participant.ensure"
            | "secure_mesh.mls.keyPackage.create"
            | "secure_mesh.mls.group.create"
            | "secure_mesh.mls.member.add"
            | "secure_mesh.mls.member.remove"
            | "secure_mesh.mls.group.join"
            | "secure_mesh.mls.commit.process"
            | "secure_mesh.mls.payload.seal"
            | "secure_mesh.mls.payload.open"
            | "secure_mesh.deviceTrust.verifyQr"
            | "secure_mesh.deviceTrust.verifySas"
            | "secure_mesh.deviceTrust.rotate"
            | "secure_mesh.deviceTrust.revoke"
            | "secure_mesh.deviceTrust.recover"
            | "secure_mesh.lifecycle.serviceAction"
            | "secure_mesh.file.receiveConfirmation"
            | "secure_mesh.file.handoffProof"
            | "secure_mesh.approval.request"
            | "secure_mesh.approval.respond"
    )
}

fn native_envelope_fixture() -> Value {
    json!({
        "schema": crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
        "deliveryId": general_purpose::URL_SAFE_NO_PAD.encode([1u8; 24]),
        "mailboxToken": general_purpose::URL_SAFE_NO_PAD.encode([2u8; 32]),
        "encryptedHeader": general_purpose::URL_SAFE_NO_PAD.encode(vec![
            3u8;
            crate::core::secure_mesh_relay_envelope::SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
        ]),
        "ciphertextBucket": 256,
        "ciphertext": general_purpose::URL_SAFE_NO_PAD.encode([4u8; 256])
    })
}

fn native_file_manifest_fixture() -> Value {
    json!({
        "fileId": "file_mobile_native_fixture",
        "fileName": "mobile-native-fixture.txt",
        "mimeType": "text/plain",
        "relativePath": "mobile/native",
        "totalSize": 16,
        "chunkSize": 8,
        "chunkCount": 2
    })
}

fn native_payload_crypto_fixture() -> anyhow::Result<Value> {
    let key = crate::core::secure_mesh_crypto::ContentKey::from_bytes([31u8; 32]);
    let context = crate::core::secure_mesh_crypto::SecureMeshContentContext::new(
        "env_mobile_native_payload_fixture",
        "msg_mobile_native_payload_fixture",
        "mailbox_mobile_native_payload_fixture",
        "desktop-native-payload-fixture",
        "mobile-native-payload-fixture",
        "session_mobile_native_payload_fixture",
        "2026-01-01T00:00:00.000Z",
        "2026-01-01T00:10:00.000Z",
    );
    let body = br#"{"op":"native-payload-crypto-fixture"}"#;
    let plaintext = crate::core::secure_mesh_crypto::SecureMeshPlaintext::new(
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        body,
    )
    .with_content_type("application/json");
    let sealed = crate::core::secure_mesh_crypto::seal_payload(&key, &context, &plaintext)?;
    let opened = crate::core::secure_mesh_crypto::open_payload(
        &key,
        &context,
        &sealed,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
    )?;
    ensure!(
        opened.body == body,
        "native payload crypto self-test failed"
    );
    Ok(json!({"ok": true, "bodyRedacted": true}))
}

fn native_file_route_fixture() -> anyhow::Result<Value> {
    crate::core::secure_mesh_file::evaluate_file_route_json(&json!({
        "manifest": native_file_manifest_fixture()
    }))
}

fn native_file_receive_destination_fixture() -> anyhow::Result<Value> {
    crate::core::secure_mesh_file::evaluate_file_receive_destination_json(&json!({
        "manifest": native_file_manifest_fixture(),
        "approvedRoot": std::env::temp_dir().to_string_lossy()
    }))
}

fn native_file_receive_confirmation_fixture() -> anyhow::Result<Value> {
    crate::core::secure_mesh_file::evaluate_file_receive_confirmation_json(&json!({
        "manifest": native_file_manifest_fixture(),
        "approvedRoot": std::env::temp_dir().to_string_lossy()
    }))
}

fn native_file_handoff_proof_fixture() -> anyhow::Result<Value> {
    crate::core::secure_mesh_file::evaluate_file_handoff_proof_json(&json!({}))
}

fn native_device_trust_fixture() -> anyhow::Result<Value> {
    crate::core::secure_mesh_trust::evaluate_device_trust_verification_json(
        &json!({
            "localIdentity": native_device_identity_fixture("desktop-native-fixture", 1),
            "peerIdentity": native_device_identity_fixture("mobile-native-fixture", 2),
            "rosterEpoch": 1
        }),
        "sas",
    )
}

fn native_lifecycle_service_action_fixture() -> anyhow::Result<Value> {
    crate::core::secure_mesh_lifecycle::evaluate_service_action_json(&json!({
        "actionKind": "ack_purge",
        "endpointId": "mobile-native-lifecycle-endpoint",
        "fileTransferId": "mobile-native-lifecycle-file-transfer",
        "acknowledged": true,
        "transferComplete": true
    }))
}

fn native_device_identity_fixture(endpoint_id: &str, byte: u8) -> Value {
    json!({
        "endpointId": endpoint_id,
        "identityPublicKey": hex_bytes(byte),
        "signingPublicKey": hex_bytes(byte.saturating_add(1)),
        "rotationEpoch": 1
    })
}

fn hex_bytes(byte: u8) -> String {
    vec![format!("{byte:02x}"); 32].join(":")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_directory::{
        SecureMeshDirectoryLeafClaim, UntrustedDirectoryResponse,
    };
    use crate::core::secure_mesh_transparency::{SecureMeshKtLog, directory_scope_commitment};
    use crate::platform::secure_mesh_secret_store::EphemeralSecretStore;
    use base64::engine::general_purpose;
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;

    struct CapabilityOnlySecretStore;

    impl SecureMeshSecretStore for CapabilityOnlySecretStore {
        fn backend(&self) -> &'static str {
            "capability-only-test-store"
        }

        fn supported(&self) -> bool {
            true
        }

        fn capability_facts(
            &self,
        ) -> anyhow::Result<Vec<crate::core::secure_mesh_capability::CapabilityFact>> {
            use crate::core::secure_mesh_capability::{
                CapabilityEvidenceKind, CapabilityFact, SecurityCapability,
            };
            Ok(vec![
                CapabilityFact::supported(
                    SecurityCapability::OsSecureStore,
                    CapabilityEvidenceKind::RuntimeOperation,
                ),
                CapabilityFact::supported(
                    SecurityCapability::AppleKeychain,
                    CapabilityEvidenceKind::RuntimeOperation,
                ),
            ])
        }

        fn begin_authorized_session(
            &self,
            _request: &crate::platform::secure_mesh_secret_store::SecretStoreAuthorizationRequest,
        ) -> anyhow::Result<
            crate::platform::secure_mesh_secret_store::SecretStoreAuthorizationSession,
        > {
            panic!("status capability projection must not request authorization")
        }

        fn set_secret(
            &self,
            _handle: &crate::platform::secure_mesh_secret_store::SecretStoreHandle,
            _secret: &str,
        ) -> anyhow::Result<()> {
            panic!("status capability projection must not write secrets")
        }

        fn get_secret(
            &self,
            _handle: &crate::platform::secure_mesh_secret_store::SecretStoreHandle,
        ) -> anyhow::Result<Option<String>> {
            panic!("status capability projection must not read secrets")
        }

        fn delete_secret(
            &self,
            _handle: &crate::platform::secure_mesh_secret_store::SecretStoreHandle,
        ) -> anyhow::Result<()> {
            panic!("status capability projection must not delete secrets")
        }
    }

    #[test]
    fn mobile_ffi_self_test_covers_native_secure_mesh_runtime() {
        let root = std::env::temp_dir().join(format!(
            "lico-mobile-ffi-pure-runtime-probe-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        assert_eq!(runtime_feature_flags(), EXPECTED_FEATURES);
        assert!(runtime_self_test());
        crate::platform::paths::set_portable_data_dir_override(previous);
        assert!(!root.exists());
    }

    #[test]
    fn mobile_ffi_rejects_oversized_text_before_json_parsing() {
        let oversized = "x".repeat(MAX_FFI_REQUEST_BYTES + 1);
        let error = dispatch_json_with_files_dir(&oversized, "/unused", "unsupported")
            .unwrap_err()
            .to_string();
        assert!(error.contains("byte limit"));
        assert!(!error.contains(&oversized[..128]));
    }

    #[test]
    fn mobile_ffi_rejects_deep_wide_and_oversized_string_values() {
        let mut deep = Value::Null;
        for _ in 0..=MAX_FFI_JSON_DEPTH {
            deep = json!({"nested": deep});
        }
        let deep_error = dispatch_json(&deep, "unsupported").unwrap_err().to_string();
        assert!(deep_error.contains("depth limit"));

        let mut fields = serde_json::Map::new();
        for index in 0..=MAX_FFI_OBJECT_FIELDS {
            fields.insert(format!("field-{index}"), Value::Null);
        }
        let wide_error = dispatch_json(&Value::Object(fields), "unsupported")
            .unwrap_err()
            .to_string();
        assert!(wide_error.contains("oversized object"));

        let oversized_string = json!({
            "action": "unsupported",
            "params": {"body": "x".repeat(MAX_FFI_STRING_BYTES + 1)}
        });
        let string_error = dispatch_json(&oversized_string, "unsupported")
            .unwrap_err()
            .to_string();
        assert!(string_error.contains("oversized string"));
    }

    #[test]
    fn mobile_ffi_mls_product_path_exchanges_an_authenticated_payload_between_clients() {
        let root = std::env::temp_dir().join(format!(
            "lico-mls-ffi-product-path-{}",
            uuid::Uuid::new_v4()
        ));
        let alice_dir = root.join("alice");
        let bob_dir = root.join("bob");
        let alice_store = Arc::new(EphemeralSecretStore::new());
        let bob_store = Arc::new(EphemeralSecretStore::new());

        initialize_mls_ffi_client(&alice_dir, alice_store.clone(), "desktop_gui");
        initialize_mls_ffi_client(&bob_dir, bob_store.clone(), "mobile");

        let alice_key_package = call_mls_ffi(
            &alice_dir,
            alice_store.clone(),
            "secure_mesh.mls.keyPackage.create",
            json!({"allowInteraction": true}),
        );
        let alice_identity = alice_key_package["identity"].clone();
        let bob_key_package = call_mls_ffi(
            &bob_dir,
            bob_store.clone(),
            "secure_mesh.mls.keyPackage.create",
            json!({"allowInteraction": true}),
        );
        let bob_identity = bob_key_package["identity"].clone();
        let bob_identity_typed = mls_ffi_identity(&bob_identity);
        let bob_key_package_bytes = general_purpose::URL_SAFE_NO_PAD
            .decode(bob_key_package["keyPackageBase64url"].as_str().unwrap())
            .unwrap();
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(
            alice_dir.join("portable-data"),
        ));
        let selected: Arc<dyn SecureMeshSecretStore> = alice_store.clone();
        let bob_directory_response =
            crate::domain::mobile_relay::with_mobile_relay_secret_store_override(selected, || {
                crate::domain::mobile_relay::secure_mesh_mls_test_directory_response(
                    &bob_identity_typed,
                    &bob_key_package_bytes,
                    2,
                    1,
                )
            })
            .unwrap();
        crate::platform::paths::set_portable_data_dir_override(previous);
        let alice_identity_typed = mls_ffi_identity(&alice_identity);
        let alice_key_package_bytes = general_purpose::URL_SAFE_NO_PAD
            .decode(alice_key_package["keyPackageBase64url"].as_str().unwrap())
            .unwrap();
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(
            bob_dir.join("portable-data"),
        ));
        let selected: Arc<dyn SecureMeshSecretStore> = bob_store.clone();
        let alice_directory_response =
            crate::domain::mobile_relay::with_mobile_relay_secret_store_override(selected, || {
                crate::domain::mobile_relay::secure_mesh_mls_test_directory_response(
                    &alice_identity_typed,
                    &alice_key_package_bytes,
                    2,
                    1,
                )
            })
            .unwrap();
        crate::platform::paths::set_portable_data_dir_override(previous);
        initialize_mls_ffi_peer(&alice_dir, alice_store.clone(), &bob_identity);
        initialize_mls_ffi_peer(&bob_dir, bob_store.clone(), &alice_identity);
        let group_id = general_purpose::URL_SAFE_NO_PAD.encode(b"ffi-product-group");

        let created = call_mls_ffi(
            &alice_dir,
            alice_store.clone(),
            "secure_mesh.mls.group.create",
            json!({
                "groupIdBase64url": group_id,
                "allowInteraction": true
            }),
        );
        assert_eq!(created["memberCount"], 1);
        assert_eq!(created["capabilityNegotiated"], false);

        let added = call_mls_ffi(
            &alice_dir,
            alice_store.clone(),
            "secure_mesh.mls.member.add",
            json!({
                "groupIdBase64url": group_id,
                "memberKeyPackageId": bob_key_package["keyPackageId"],
                "memberKeyPackageBase64url": bob_key_package["keyPackageBase64url"],
                "memberIdentity": bob_identity.clone(),
                "memberCapabilityProof": bob_key_package["capabilityProof"].clone(),
                "memberDirectoryVersion": 2,
                "memberKeyPackageVersion": 1,
                "untrustedDirectoryResponse": bob_directory_response.clone(),
                "allowInteraction": true
            }),
        );
        assert_eq!(added["group"]["memberCount"], 2);
        assert_eq!(added["group"]["capabilityNegotiated"], true);
        let remove_epoch = added["group"]["epoch"].as_u64().unwrap();

        let alice_roster = json!([
            {"identity": alice_identity.clone()},
            {
                "identity": bob_identity.clone(),
                "directoryVersion": 2,
                "keyPackageVersion": 1,
                "keyPackageDigest": bob_key_package["keyPackageId"].clone(),
                "untrustedDirectoryResponse": bob_directory_response,
            }
        ]);
        let bob_roster = json!([
            {
                "identity": alice_identity.clone(),
                "directoryVersion": 2,
                "keyPackageVersion": 1,
                "keyPackageDigest": alice_key_package["keyPackageId"].clone(),
                "untrustedDirectoryResponse": alice_directory_response,
            },
            {"identity": bob_identity.clone()}
        ]);
        let joined = call_mls_ffi(
            &bob_dir,
            bob_store.clone(),
            "secure_mesh.mls.group.join",
            json!({
                "groupIdBase64url": group_id,
                "inviterIdentity": alice_identity.clone(),
                "expectedRosterEndpointIds": [
                    alice_identity["endpointId"],
                    bob_identity["endpointId"]
                ],
                "trustedRoster": bob_roster.clone(),
                "welcomeMessageBase64url": added["welcomeMessageBase64url"],
                "allowInteraction": true
            }),
        );
        assert_eq!(joined["memberCount"], 2);
        assert_eq!(joined["capabilityNegotiated"], true);

        let context = json!({
            "envelopeId": "ffi-env-1",
            "messageId": "ffi-msg-1",
            "opaqueMailboxId": "ffi-mailbox-1",
            "senderEndpointId": alice_identity["endpointId"],
            "recipientEndpointId": bob_identity["endpointId"],
            "sessionId": "ffi-mls-session-1",
            "createdAt": "2026-07-12T00:00:00Z",
            "expiresAt": "2026-07-12T00:10:00Z"
        });
        let sealed = call_mls_ffi(
            &alice_dir,
            alice_store.clone(),
            "secure_mesh.mls.payload.seal",
            json!({
                "groupIdBase64url": group_id,
                "trustedRoster": alice_roster,
                "context": context,
                "payloadKind": "command",
                "bodyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(b"authenticated-ping"),
                "contentType": "application/octet-stream",
                "allowInteraction": true
            }),
        );
        assert_eq!(sealed["bodyRedacted"], true);
        let opened = call_mls_ffi(
            &bob_dir,
            bob_store,
            "secure_mesh.mls.payload.open",
            json!({
                "groupIdBase64url": group_id,
                "trustedSenderIdentity": alice_identity,
                "trustedRoster": bob_roster,
                "context": context,
                "expectedPayloadKind": "command",
                "messageBase64url": sealed["messageBase64url"],
                "allowInteraction": true
            }),
        );
        assert_eq!(
            general_purpose::URL_SAFE_NO_PAD
                .decode(opened["bodyBase64url"].as_str().unwrap())
                .unwrap(),
            b"authenticated-ping"
        );
        assert!(
            !serde_json::to_string(&opened)
                .unwrap()
                .contains("privateKeyBase64url")
        );
        let bob_endpoint_id = bob_identity["endpointId"].clone();
        let removed = call_mls_ffi(
            &alice_dir,
            alice_store,
            "secure_mesh.mls.member.remove",
            json!({
                "groupIdBase64url": group_id,
                "expectedEpoch": remove_epoch,
                "memberIdentity": bob_identity,
                "allowInteraction": true
            }),
        );
        assert_eq!(removed["group"]["memberCount"], 1);
        assert_eq!(removed["memberEndpointId"], bob_endpoint_id);
        let _ = std::fs::remove_dir_all(root);
    }

    fn initialize_mls_ffi_client(
        files_dir: &std::path::Path,
        store: Arc<EphemeralSecretStore>,
        endpoint_kind: &str,
    ) {
        let portable_dir = files_dir.join("portable-data");
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(portable_dir));
        let selected: Arc<dyn SecureMeshSecretStore> = store;
        crate::domain::mobile_relay::with_mobile_relay_secret_store_override(selected, || {
            crate::domain::mobile_relay::initialize_secure_mesh_mls_test_endpoint(endpoint_kind)
        })
        .unwrap();
        crate::platform::paths::set_portable_data_dir_override(previous);
    }

    fn initialize_mls_ffi_peer(
        files_dir: &std::path::Path,
        store: Arc<EphemeralSecretStore>,
        peer: &Value,
    ) {
        let peer_identity = mls_ffi_identity(peer);
        let portable_dir = files_dir.join("portable-data");
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(portable_dir));
        let selected: Arc<dyn SecureMeshSecretStore> = store;
        crate::domain::mobile_relay::with_mobile_relay_secret_store_override(selected, || {
            crate::domain::mobile_relay::initialize_secure_mesh_mls_test_peer(&peer_identity)
        })
        .unwrap();
        crate::platform::paths::set_portable_data_dir_override(previous);
    }

    fn mls_ffi_identity(
        value: &Value,
    ) -> crate::core::secure_mesh_trust::DeviceTrustPublicIdentity {
        let decode_key = |field: &str| -> [u8; 32] {
            general_purpose::URL_SAFE_NO_PAD
                .decode(value[field].as_str().unwrap())
                .unwrap()
                .try_into()
                .unwrap()
        };
        crate::core::secure_mesh_trust::DeviceTrustPublicIdentity::new(
            value["endpointId"].as_str().unwrap(),
            decode_key("identityPublicKeyBase64url"),
            decode_key("signingPublicKeyBase64url"),
            value["rotationEpoch"].as_u64().unwrap(),
        )
        .unwrap()
    }

    fn call_mls_ffi(
        files_dir: &std::path::Path,
        store: Arc<EphemeralSecretStore>,
        action: &str,
        params: Value,
    ) -> Value {
        let selected: Arc<dyn SecureMeshSecretStore> = store;
        dispatch_json_with_files_dir_and_pairwise_secret_store(
            &json!({"action": action, "params": params}).to_string(),
            files_dir.to_string_lossy().as_ref(),
            "test_secure_mesh_action_unsupported",
            selected,
        )
        .unwrap()
    }

    #[test]
    fn mobile_ffi_native_action_contract_is_shared_by_platform_bridges() {
        assert_eq!(
            MOBILE_RELAY_NATIVE_ACTIONS,
            &[
                "mobile.relay.config.get",
                "mobile.relay.config.set",
                "mobile.relay.pairing.claim",
                "mobile.relay.pairing.status",
                "mobile.relay.commands.createSecure",
                "mobile.relay.commands.resultSecure",
                "mobile.relay.commands.resultReplayProof",
                "mobile.relay.e2ee.status",
                "provider.chat.send",
                "secure_mesh.status",
                "secure_mesh.kt.configureAuthority",
                "secure_mesh.kt.publicationRequest",
                "secure_mesh.kt.revocationRequest",
                "secure_mesh.kt.provision",
                "secure_mesh.kt.gossip",
                "secure_mesh.kt.selfMonitor",
                "secure_mesh.kt.status",
                "secure_mesh.mls.status",
                "secure_mesh.mls.participant.ensure",
                "secure_mesh.mls.keyPackage.create",
                "secure_mesh.mls.group.create",
                "secure_mesh.mls.member.add",
                "secure_mesh.mls.member.remove",
                "secure_mesh.mls.group.join",
                "secure_mesh.mls.commit.process",
                "secure_mesh.mls.payload.seal",
                "secure_mesh.mls.payload.open",
                "secure_mesh.deviceTrust.evaluate",
                "secure_mesh.deviceTrust.verifyQr",
                "secure_mesh.deviceTrust.verifySas",
                "secure_mesh.deviceTrust.rotate",
                "secure_mesh.deviceTrust.revoke",
                "secure_mesh.deviceTrust.recover",
                "secure_mesh.lifecycle.serviceAction",
                "secure_mesh.file.route",
                "secure_mesh.file.receiveDestination",
                "secure_mesh.file.receiveConfirmation",
                "secure_mesh.file.handoffProof",
                "secure_mesh.approval.request",
                "secure_mesh.approval.fanout",
                "secure_mesh.approval.respond",
                "secure_mesh.approval.inbox",
                "secure_mesh.approval.adapterCapability",
            ]
        );
        let mut sorted = MOBILE_RELAY_NATIVE_ACTIONS.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), MOBILE_RELAY_NATIVE_ACTIONS.len());
        assert!(
            crate::domain::mobile_relay::SECURE_MESH_KT_NATIVE_ACTIONS
                .iter()
                .all(|action| MOBILE_RELAY_NATIVE_ACTIONS.contains(action))
        );
        assert!(
            crate::domain::secure_mesh_mls::SECURE_MESH_MLS_NATIVE_ACTIONS
                .iter()
                .all(|action| MOBILE_RELAY_NATIVE_ACTIONS.contains(action))
        );
        assert!(secure_mesh_action_requires_protected_operation_gate(
            "secure_mesh.mls.member.remove"
        ));
    }

    #[test]
    fn mobile_ffi_unsupported_action_uses_calling_platform_error_code() {
        let response = dispatch_json(
            &json!({
                "action": "mobile.relay.unknown",
                "params": {}
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(response.get("ok").and_then(Value::as_bool), Some(false));
        assert_eq!(
            response.get("code").and_then(Value::as_str),
            Some("ios_secure_mesh_native_json_action_unsupported")
        );
        assert_eq!(
            response.get("action").and_then(Value::as_str),
            Some("mobile.relay.unknown")
        );
    }

    #[test]
    fn mobile_ffi_kt_status_is_routed_and_rejects_unknown_fields() {
        let root = std::env::temp_dir().join(format!(
            "lico-mobile-ffi-kt-status-{}",
            uuid::Uuid::new_v4()
        ));
        let previous = crate::platform::paths::set_portable_data_dir_override(Some(root.clone()));
        let status = dispatch_json(
            &json!({
                "action": "secure_mesh.kt.status",
                "params": {}
            }),
            "mobile_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(status["ok"], true);
        assert_eq!(status["configured"], false);
        assert!(
            dispatch_json(
                &json!({
                    "action": "secure_mesh.kt.status",
                    "params": {"callerAssertedTrust": "verified"}
                }),
                "mobile_secure_mesh_native_json_action_unsupported",
            )
            .unwrap_err()
            .to_string()
            .contains("unsupported field")
        );
        crate::platform::paths::set_portable_data_dir_override(previous);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn mobile_ffi_kt_product_chain_fails_closed_without_external_gossip_authority() {
        let files_dir = std::env::temp_dir().join(format!(
            "lico-mobile-ffi-kt-product-chain-{}",
            uuid::Uuid::new_v4()
        ));
        let store = Arc::new(EphemeralSecretStore::new());
        let mut log = SecureMeshKtLog::with_identity(
            SigningKey::generate(&mut OsRng),
            "user-configured-test-log",
            "user-configured-test-key",
        );
        let pin = log.pin();
        let scope = directory_scope_commitment("test-tenant", "test-account", "test-workspace");
        let call = |action: &str, params: Value| -> anyhow::Result<Value> {
            let selected: Arc<dyn SecureMeshSecretStore> = store.clone();
            dispatch_json_with_files_dir_and_pairwise_secret_store(
                &json!({"action": action, "params": params}).to_string(),
                files_dir.to_string_lossy().as_ref(),
                "test_secure_mesh_action_unsupported",
                selected,
            )
        };

        let prepare_params = json!({
            "operation": "prepare",
            "directoryScopeCommitment": scope,
            "pin": {
                "logId": pin.log_id(),
                "keyId": pin.key_id(),
                "publicKeyHex": pin.public_key_hex(),
                "provenance": "user-configured-external"
            },
            "maxSthAgeSeconds": 3600,
            "maxFutureSkewSeconds": 300
        });
        let prepared = call("secure_mesh.kt.configureAuthority", prepare_params.clone()).unwrap();
        assert_eq!(prepared["status"], "confirmation_required");
        let mut confirm_params = prepare_params;
        confirm_params["operation"] = json!("confirm");
        confirm_params["authorityChallengeId"] = prepared["authorityChallengeId"].clone();
        confirm_params["confirmAuthorityConfiguration"] = json!(true);
        confirm_params["allowInteraction"] = json!(true);
        let configured = call("secure_mesh.kt.configureAuthority", confirm_params).unwrap();
        assert_eq!(configured["directoryResponseAccepted"], false);
        assert_eq!(configured["productionAuthority"], false);
        assert!(
            call(
                "secure_mesh.kt.publicationRequest",
                json!({"endpointKind": "mobile", "allowInteraction": true}),
            )
            .unwrap_err()
            .to_string()
            .contains("real MLS KeyPackage publication is required")
        );

        let key_package = call(
            "secure_mesh.mls.keyPackage.create",
            json!({"endpointKind": "mobile", "allowInteraction": true}),
        )
        .unwrap();
        assert!(key_package["keyPackageVersion"].as_u64().unwrap() > 0);
        assert_eq!(key_package["directoryPublicationRequired"], true);
        let publication = call(
            "secure_mesh.kt.publicationRequest",
            json!({"endpointKind": "mobile", "allowInteraction": true}),
        )
        .unwrap();
        let claim: SecureMeshDirectoryLeafClaim =
            serde_json::from_value(publication["claim"].clone()).unwrap();
        assert!(claim.key_material.mls_key_package_version > 0);
        assert_ne!(
            claim.key_material.mls_key_package_digest,
            "0000000000000000000000000000000000000000000000000000000000000000"
        );
        let now = u64::try_from(time::OffsetDateTime::now_utc().unix_timestamp()).unwrap();
        let index = log
            .append_hashed_directory_leaf(
                &claim.stable_label(),
                claim.version(),
                claim.revoked(),
                claim.leaf_hash().unwrap(),
            )
            .unwrap();
        let response = UntrustedDirectoryResponse {
            claim: claim.clone(),
            inclusion: log.inclusion_proof_at(index, now).unwrap(),
            latest_map: log.map_proof_at(&claim.stable_label(), now).unwrap(),
            consistency: None,
        };
        let mut mutated = response.clone();
        mutated.claim.key_material.mls_key_package_digest =
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff".to_string();
        assert!(
            call(
                "secure_mesh.kt.provision",
                json!({"response": mutated, "allowInteraction": true}),
            )
            .unwrap_err()
            .to_string()
            .contains("exact pending local claim")
        );
        assert!(
            call(
                "secure_mesh.kt.provision",
                json!({
                    "response": response,
                    "pin": {"caller": "forbidden"},
                    "allowInteraction": true
                }),
            )
            .unwrap_err()
            .to_string()
            .contains("unsupported field")
        );
        let blocked = call(
            "secure_mesh.kt.provision",
            json!({"response": response, "allowInteraction": true}),
        )
        .unwrap_err()
        .to_string();
        assert!(blocked.contains("fresh peer-gossip or witness observation is required"));

        let _ = std::fs::remove_dir_all(files_dir);
    }

    #[test]
    fn mobile_ffi_status_projects_exact_client_capabilities() {
        let store: Arc<dyn SecureMeshSecretStore> = Arc::new(CapabilityOnlySecretStore);
        let response =
            crate::domain::mobile_relay::with_mobile_relay_secret_store_override(store, || {
                dispatch_json(
                    &json!({"action": "secure_mesh.status", "params": {}}),
                    "mobile_secure_mesh_native_json_action_unsupported",
                )
            })
            .unwrap();
        assert_eq!(
            response["capabilityProjection"]["schemaVersion"],
            crate::core::secure_mesh_capability_proof::CLIENT_CAPABILITY_PROJECTION_SCHEMA_VERSION
        );
        assert!(response["capabilityProjection"]["local"]["enabled"].is_array());
        assert!(
            response["capabilityProjection"]["local"]["enabled"]
                .as_array()
                .is_some_and(|enabled| enabled.contains(&json!("custody.os_secure_store")))
        );
        assert!(
            response["capabilityProjection"]["local"]["enabled"]
                .as_array()
                .is_some_and(|enabled| enabled.contains(&json!("custody.apple_keychain")))
        );
        assert!(response["capabilityProjection"]["peer"].is_null());
        assert_eq!(
            response["capabilityProjection"]["negotiatedProtocolCapabilities"],
            json!([])
        );
        assert_eq!(response["pairwiseKem"]["parameterSet"], "ML-KEM-1024");
        assert_eq!(response["pairwiseKem"]["standard"], "FIPS 203");
        assert_eq!(
            response["pairwiseKem"]["publicKeyBytes"],
            crate::core::secure_mesh_pqxdh::ML_KEM_1024_PUBLIC_KEY_BYTES
        );
        assert_eq!(
            response["pairwiseKem"]["ciphertextBytes"],
            crate::core::secure_mesh_pqxdh::ML_KEM_1024_CIPHERTEXT_BYTES
        );
    }

    #[test]
    fn mobile_ffi_exposes_shared_file_route_and_receive_destination_policy() {
        let approved_root = std::env::temp_dir()
            .join("mobile-ffi-approved-root-canary")
            .join(uuid::Uuid::new_v4().to_string());
        let manifest = json!({
            "fileId": "mobile-ffi-file-id-canary",
            "fileName": "mobile-ffi-private-file-canary.pdf",
            "mimeType": "application/x-mobile-ffi-canary",
            "relativePath": "phone/mobile-ffi-private-relative-canary",
            "totalSize": 16,
            "chunkSize": 8,
            "chunkCount": 2
        });
        let route = dispatch_json(
            &json!({
                "action": "secure_mesh.file.route",
                "params": {"manifest": manifest}
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(
            route["route"]["uploadOperation"],
            "secure_mesh.file_chunk.upload"
        );

        let receive_destination = dispatch_json(
            &json!({
                "action": "secure_mesh.file.receiveDestination",
                "params": {
                    "manifest": manifest,
                    "approvedRoot": approved_root.to_string_lossy()
                }
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(
            receive_destination["receivePolicy"]["destinationApproved"],
            true
        );
        assert_eq!(
            receive_destination["receivePolicy"]["destinationPathRedacted"],
            true
        );

        let receive_confirmation = dispatch_json(
            &json!({
                "action": "secure_mesh.file.receiveConfirmation",
                "params": {
                    "manifest": manifest,
                    "approvedRoot": approved_root.to_string_lossy()
                }
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(
            receive_confirmation["receiveConfirmation"]["required"],
            true
        );
        assert_eq!(
            receive_confirmation["receiveConfirmation"]["writeAllowed"],
            false
        );
        assert_eq!(
            receive_confirmation["receiveConfirmation"]["autoPreviewEnabled"],
            false
        );
        assert_eq!(
            receive_confirmation["receiveConfirmation"]["autoIngestionEnabled"],
            false
        );
        let serialized = serde_json::to_string(&receive_destination).unwrap();
        for forbidden in [
            "mobile-ffi-file-id-canary",
            "mobile-ffi-private-file-canary.pdf",
            "application/x-mobile-ffi-canary",
            "mobile-ffi-private-relative-canary",
            "mobile-ffi-approved-root-canary",
            approved_root.to_string_lossy().as_ref(),
        ] {
            assert!(
                !serialized.contains(forbidden),
                "mobile FFI file receive destination leaked {forbidden}"
            );
        }
        let serialized_confirmation = serde_json::to_string(&receive_confirmation).unwrap();
        for forbidden in [
            "mobile-ffi-file-id-canary",
            "mobile-ffi-private-file-canary.pdf",
            "application/x-mobile-ffi-canary",
            "mobile-ffi-private-relative-canary",
            "mobile-ffi-approved-root-canary",
            approved_root.to_string_lossy().as_ref(),
        ] {
            assert!(
                !serialized_confirmation.contains(forbidden),
                "mobile FFI file receive confirmation leaked {forbidden}"
            );
        }
    }

    #[test]
    fn mobile_ffi_exposes_shared_file_handoff_reseal_proof_without_plaintext() {
        let proof = dispatch_json(
            &json!({
                "action": "secure_mesh.file.handoffProof",
                "params": {}
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(proof["ok"], true);
        assert_eq!(proof["sourceOpenedByDesktop"], true);
        assert_eq!(proof["recipientOpenedResealed"], true);
        assert_eq!(proof["wrongRecipientRejected"], true);
        assert_eq!(proof["endpointSpecificResealReady"], true);
        assert_eq!(proof["multiRecipientIndependentResealReady"], true);
        assert_eq!(proof["serverVisibleNoPlaintext"], true);
        assert_eq!(proof["receiveConfirmationPolicyReady"], true);
        assert_eq!(proof["transfer"]["allRecipientTransfersAckPurged"], true);
        assert_eq!(proof["boundedTransferQueueReady"], true);
        assert_eq!(proof["transfer"]["boundedTransferQueueReady"], true);
        assert_eq!(proof["transfer"]["queue"]["activeTransferCount"], 0);
        assert_eq!(proof["transfer"]["queue"]["queuedCiphertextBytes"], 0);
        let serialized = serde_json::to_string(&proof).unwrap();
        for forbidden in [
            "handoff-proof-file-id-private-file-canary",
            "handoff-proof-private-file-canary.pdf",
            "application/x-handoff-private-file-canary",
            "private-relative-canary",
            "file-body-plaintext-secret-canary-content",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "mobile FFI file handoff proof leaked {forbidden}"
            );
        }
    }

    #[test]
    fn mobile_ffi_exposes_shared_device_trust_actions_without_raw_keys() {
        let local = native_device_identity_fixture("desktop-native-trust", 11);
        let peer = native_device_identity_fixture("phone-native-trust", 22);
        let preview = dispatch_json(
            &json!({
                "action": "secure_mesh.deviceTrust.verifySas",
                "params": {
                    "localIdentity": local,
                    "peerIdentity": peer,
                    "rosterEpoch": 3
                }
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(preview["ok"], true);
        assert_eq!(preview["observationMatched"], false);
        assert_eq!(preview["sas"].as_array().map(Vec::len), Some(12));
        let sas = preview["sas"].clone();
        let verified = dispatch_json(
            &json!({
                "action": "secure_mesh.deviceTrust.verifySas",
                "params": {
                    "localIdentity": native_device_identity_fixture("desktop-native-trust", 11),
                    "peerIdentity": native_device_identity_fixture("phone-native-trust", 22),
                    "rosterEpoch": 3,
                    "sas": sas
                }
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(verified["observationMatched"], true);
        assert_eq!(verified["decision"]["allowedForHighRiskCommand"], false);
        assert_eq!(verified["decision"]["requiresPersistedTrustRecord"], true);
        assert_eq!(
            verified["decision"]["code"],
            "verification_observation_requires_persisted_trust_record"
        );

        let revoked = dispatch_json(
            &json!({
                "action": "secure_mesh.deviceTrust.revoke",
                "params": {
                    "identity": native_device_identity_fixture("phone-native-trust", 22)
                }
            }),
            "ios_secure_mesh_native_json_action_unsupported",
        )
        .unwrap();
        assert_eq!(revoked["trustState"], "revoked");
        assert_eq!(revoked["decision"]["allowedForHighRiskCommand"], false);

        let serialized = serde_json::to_string(&json!([preview, verified, revoked])).unwrap();
        for forbidden in [hex_bytes(11), hex_bytes(12), hex_bytes(22), hex_bytes(23)] {
            assert!(
                !serialized.contains(&forbidden),
                "mobile FFI trust response leaked raw public key material"
            );
        }
    }

    #[test]
    fn mobile_ffi_exposes_shared_lifecycle_service_actions_without_plaintext() {
        let outputs = [
            json!({
                "action": "secure_mesh.lifecycle.serviceAction",
                "params": {
                    "actionKind": "resend_request",
                    "endpointId": "mobile-ffi-private-endpoint-canary",
                    "conversationId": "mobile-ffi-private-conversation-canary",
                    "missingMessageIds": ["mobile-ffi-private-missing-message-canary"],
                    "body": "mobile-ffi-private-plaintext-canary"
                }
            }),
            json!({
                "action": "secure_mesh.lifecycle.serviceAction",
                "params": {
                    "actionKind": "typing_state",
                    "endpointId": "mobile-ffi-private-endpoint-canary",
                    "conversationId": "mobile-ffi-private-conversation-canary",
                    "typingState": "started",
                    "body": "mobile-ffi-private-plaintext-canary"
                }
            }),
            json!({
                "action": "secure_mesh.lifecycle.serviceAction",
                "params": {
                    "actionKind": "read_receipt",
                    "endpointId": "mobile-ffi-private-endpoint-canary",
                    "conversationId": "mobile-ffi-private-conversation-canary",
                    "readUpToMessageId": "mobile-ffi-private-read-message-canary",
                    "body": "mobile-ffi-private-plaintext-canary"
                }
            }),
        ]
        .into_iter()
        .map(|request| {
            dispatch_json(&request, "ios_secure_mesh_native_json_action_unsupported").unwrap()
        })
        .collect::<Vec<_>>();
        let output = &outputs[0];
        assert_eq!(output["ok"], true);
        assert_eq!(output["requiresPairwiseOrMlsEnvelope"], true);
        assert_eq!(output["serverVisiblePlaintextAllowed"], false);
        assert_eq!(output["servicePolicy"]["missingMessageIdsRedacted"], true);
        assert_eq!(outputs[1]["servicePolicy"]["typingStateEncrypted"], true);
        assert_eq!(outputs[1]["servicePolicy"]["typingContentIncluded"], false);
        assert_eq!(outputs[2]["servicePolicy"]["readMessageIdsRedacted"], true);
        let serialized = serde_json::to_string(&outputs).unwrap();
        for forbidden in [
            "mobile-ffi-private-endpoint-canary",
            "mobile-ffi-private-conversation-canary",
            "mobile-ffi-private-missing-message-canary",
            "mobile-ffi-private-read-message-canary",
            "mobile-ffi-private-plaintext-canary",
        ] {
            assert!(
                !serialized.contains(forbidden),
                "mobile FFI lifecycle service action leaked {forbidden}"
            );
        }
    }
}
