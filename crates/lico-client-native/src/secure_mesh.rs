use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use crate::secure_mesh_command::SECURE_MESH_COMMAND_SECURITY_STATUS;
use crate::secure_mesh_crypto::{
    SECURE_MESH_CONTENT_CIPHER_SUITE, SECURE_MESH_CONTENT_CRYPTO_STATUS,
};
use crate::secure_mesh_file::{
    SECURE_MESH_FILE_CHUNK_CONTENT_TYPE, SECURE_MESH_FILE_CRYPTO_STATUS,
    SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE,
};
use crate::secure_mesh_mls::{SECURE_MESH_MLS_CIPHER_SUITE, SECURE_MESH_MLS_STATUS};
use crate::secure_mesh_pairwise::{
    SECURE_MESH_PAIRWISE_CIPHER_SUITE, SECURE_MESH_PAIRWISE_PQ_READY_CIPHER_SUITE,
    SECURE_MESH_PAIRWISE_STATUS,
};
use crate::secure_mesh_prekey::{
    SECURE_MESH_KEYPACKAGE_PROTOCOL_VERSION, SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
    SECURE_MESH_PREKEY_PROTOCOL_VERSION, SECURE_MESH_PREKEY_STATUS,
};
use crate::secure_mesh_response::{
    SECURE_MESH_ERROR_CONTENT_TYPE, SECURE_MESH_RESPONSE_CRYPTO_STATUS,
    SECURE_MESH_RESULT_CONTENT_TYPE,
};
use crate::secure_mesh_transparency::SECURE_MESH_TRANSPARENCY_STATUS;
use crate::secure_mesh_trust::{
    SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION, SECURE_MESH_DEVICE_TRUST_STATUS,
};

pub const SECURE_MESH_PROTOCOL_VERSION: &str = "licolite.secure-mesh.v1";
pub const SECURE_MESH_COMMAND_PROTOCOL_VERSION: &str = "v0.0.1:secure-mesh:command-1";
pub const SECURE_MESH_RESULT_PROTOCOL_VERSION: &str = "licolite.secure-mesh.result.v1";
pub const SECURE_MESH_FILE_PROTOCOL_VERSION: &str = "licolite.secure-mesh.file.v1";

pub(crate) const ALLOWED_COMMANDS: &[&str] = &[
    "agent.sessions.list",
    "agent.message.send",
    "client.activity.sync",
    "client.snapshot.request",
    "secure_mesh.device.verify",
    "secure_mesh.group.commit",
];

pub(crate) const DENIED_PREFIXES: &[&str] = &[
    "shell.",
    "filesystem.",
    "process.spawn.",
    "runtime.raw.",
    "mcp.raw.",
    "settings.write.",
    "secrets.",
    "network.raw.",
    "external.unscoped.",
    "tool.unbounded.",
];

pub fn protocol_status() -> Value {
    json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_PROTOCOL_VERSION,
        "commandProtocolVersion": SECURE_MESH_COMMAND_PROTOCOL_VERSION,
        "resultProtocolVersion": SECURE_MESH_RESULT_PROTOCOL_VERSION,
        "fileProtocolVersion": SECURE_MESH_FILE_PROTOCOL_VERSION,
        "deviceTrustProtocolVersion": SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "supportedEndpointKinds": [
            "desktop_gui",
            "desktop_sidecar",
            "mobile",
            "cli",
            "client_local_runtime",
            "agent_host",
            "web_limited"
        ],
        "supportedTransports": [
            "cloud_relay",
            "mobile_relay_compatibility",
            "lan_direct",
            "webrtc_data_channel",
            "loopback_local"
        ],
        "allowedCommands": ALLOWED_COMMANDS,
        "deniedPrefixes": DENIED_PREFIXES,
        "contentCipherSuite": SECURE_MESH_CONTENT_CIPHER_SUITE,
        "contentCryptoStatus": SECURE_MESH_CONTENT_CRYPTO_STATUS,
        "fileManifestContentType": SECURE_MESH_FILE_MANIFEST_CONTENT_TYPE,
        "fileChunkContentType": SECURE_MESH_FILE_CHUNK_CONTENT_TYPE,
        "fileCryptoStatus": SECURE_MESH_FILE_CRYPTO_STATUS,
        "resultContentType": SECURE_MESH_RESULT_CONTENT_TYPE,
        "errorContentType": SECURE_MESH_ERROR_CONTENT_TYPE,
        "responseCryptoStatus": SECURE_MESH_RESPONSE_CRYPTO_STATUS,
        "mlsCipherSuite": SECURE_MESH_MLS_CIPHER_SUITE,
        "mlsCryptoStatus": SECURE_MESH_MLS_STATUS,
        "pairwiseCipherSuite": SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "pairwisePqReadyCipherSuite": SECURE_MESH_PAIRWISE_PQ_READY_CIPHER_SUITE,
        "pairwiseCryptoStatus": SECURE_MESH_PAIRWISE_STATUS,
        "prekeyProtocolVersion": SECURE_MESH_PREKEY_PROTOCOL_VERSION,
        "keyPackageProtocolVersion": SECURE_MESH_KEYPACKAGE_PROTOCOL_VERSION,
        "keyPackageWireCipherSuite": SECURE_MESH_KEYPACKAGE_WIRE_CIPHER_SUITE,
        "prekeyStatus": SECURE_MESH_PREKEY_STATUS,
        "deviceTrustStatus": SECURE_MESH_DEVICE_TRUST_STATUS,
        "transparencyStatus": SECURE_MESH_TRANSPARENCY_STATUS,
        "commandSecurityStatus": SECURE_MESH_COMMAND_SECURITY_STATUS,
        "cryptoCoreStatus": "blocked_until_reviewed_pairwise_signal_audit_android_protocol_runtime_webrtc_transport_interop"
    })
}

pub fn validate_envelope(envelope: &Value) -> Result<Value> {
    let object = envelope
        .as_object()
        .ok_or_else(|| anyhow!("secure envelope must be a JSON object"))?;
    let allowed = [
        "protocolVersion",
        "envelopeId",
        "opaqueMailboxId",
        "messageId",
        "cipherSuite",
        "createdAt",
        "expiresAt",
        "ciphertextSize",
        "encryptedHeader",
        "ciphertext",
    ];
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(anyhow!(
                "secure envelope outer field is not enabled: {}",
                key
            ));
        }
    }
    for key in allowed {
        if key == "ciphertextSize" {
            if object.get(key).and_then(Value::as_u64).unwrap_or(0) == 0 {
                return Err(anyhow!("secure envelope missing {}", key));
            }
            continue;
        }
        if object
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .is_empty()
        {
            return Err(anyhow!("secure envelope missing {}", key));
        }
    }
    if object
        .get("protocolVersion")
        .and_then(Value::as_str)
        .unwrap_or_default()
        != SECURE_MESH_PROTOCOL_VERSION
    {
        return Err(anyhow!("secure envelope protocol version is unsupported"));
    }
    Ok(json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_PROTOCOL_VERSION,
        "envelope": envelope
    }))
}

pub fn command_policy(params: &Value) -> Value {
    let command_kind = params
        .get("commandKind")
        .or_else(|| params.get("command"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let denied_prefix = DENIED_PREFIXES
        .iter()
        .find(|prefix| command_kind.starts_with(**prefix))
        .copied()
        .unwrap_or_default();
    let allowed = denied_prefix.is_empty() && ALLOWED_COMMANDS.contains(&command_kind);
    json!({
        "ok": true,
        "commandKind": command_kind,
        "allowed": allowed,
        "deniedPrefix": denied_prefix,
        "requiresUserConfirmation": command_kind == "secure_mesh.group.commit",
        "protocolVersion": SECURE_MESH_COMMAND_PROTOCOL_VERSION
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secure_mesh_envelope_rejects_extra_outer_fields() {
        let mut envelope = envelope_fixture();
        envelope["payloadKind"] = json!("command");
        let error = validate_envelope(&envelope).unwrap_err();
        assert!(error.to_string().contains("outer field"));
    }

    #[test]
    fn secure_mesh_command_policy_allows_only_registered_commands() {
        assert_eq!(
            command_policy(&json!({"commandKind": "agent.message.send"}))["allowed"],
            true
        );
        assert_eq!(
            command_policy(&json!({"commandKind": "shell.exec"}))["allowed"],
            false
        );
    }

    fn envelope_fixture() -> Value {
        json!({
            "protocolVersion": SECURE_MESH_PROTOCOL_VERSION,
            "envelopeId": "env_test",
            "opaqueMailboxId": "mailbox_test",
            "messageId": "msg_test",
            "cipherSuite": "licolite.signal-x3dh-dr.v1.classical",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "expiresAt": "2026-01-01T00:10:00.000Z",
            "ciphertextSize": 32,
            "encryptedHeader": "header",
            "ciphertext": "ciphertext"
        })
    }
}
