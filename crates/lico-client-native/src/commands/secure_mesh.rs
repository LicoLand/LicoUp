// secure-mesh commands: status, envelope validate, payload seal/open, command policy/evaluate/execute, mls recovery-vector

use super::{CliExecution, CommandTable, cli_params, parse_json_arg};
use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["secure-mesh"],
        handle_secure_mesh,
        "Secure Mesh status|envelope validate|payload seal|open|command policy|evaluate|execute|device-trust evaluate|file route",
    );
}

fn handle_secure_mesh(args: &[String]) -> Result<CliExecution> {
    let noun = args.get(1).map(String::as_str).unwrap_or("status");
    let action = args.get(2).map(String::as_str).unwrap_or("");
    let params = if args.len() > 3 {
        cli_params(&args[3..])
    } else {
        cli_params(&[])
    };
    let result = match (noun, action) {
        ("status", "") => crate::secure_mesh::protocol_status(),
        ("envelope", "validate") => {
            let envelope = params
                .get("secureEnvelope")
                .or_else(|| params.get("envelope"))
                .or_else(|| params.get("body"))
                .cloned()
                .unwrap_or_else(|| params.clone());
            let parsed = envelope.as_str().map(parse_json_arg).unwrap_or(envelope);
            crate::secure_mesh::validate_envelope(&parsed)?
        }
        ("payload", "seal") => seal_payload_cli_json(&params)?,
        ("payload", "open") => open_payload_cli_json(&params)?,
        ("command", "policy") => crate::secure_mesh::command_policy(&params),
        ("command", "evaluate") => {
            let payload = params
                .get("payload")
                .or_else(|| params.get("commandPayload"))
                .or_else(|| params.get("body"))
                .cloned()
                .unwrap_or_else(|| params.clone());
            let context = params
                .get("context")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            let parsed_payload = payload.as_str().map(parse_json_arg).unwrap_or(payload);
            let parsed_context = context.as_str().map(parse_json_arg).unwrap_or(context);
            let mut ledger = crate::secure_mesh_command::SecureCommandReplayLedger::default();
            crate::secure_mesh_command::evaluate_secure_command_json(
                &parsed_payload,
                &parsed_context,
                &mut ledger,
            )?
        }
        ("command", "execute") => {
            let payload = params
                .get("payload")
                .or_else(|| params.get("commandPayload"))
                .or_else(|| params.get("body"))
                .cloned()
                .unwrap_or_else(|| params.clone());
            let context = params
                .get("context")
                .cloned()
                .unwrap_or_else(|| serde_json::json!({}));
            let parsed_payload = payload.as_str().map(parse_json_arg).unwrap_or(payload);
            let parsed_context = context.as_str().map(parse_json_arg).unwrap_or(context);
            let completed_at = params
                .get("completedAt")
                .or_else(|| params.get("completed_at"))
                .and_then(serde_json::Value::as_str)
                .map(ToString::to_string)
                .unwrap_or_else(default_completed_at);
            let ledger_path = params
                .get("ledgerPath")
                .or_else(|| params.get("ledger-path"))
                .and_then(serde_json::Value::as_str)
                .map(std::path::PathBuf::from)
                .map(Ok)
                .unwrap_or_else(crate::secure_mesh_command::default_secure_command_ledger_path)?;
            let mut ledger =
                crate::secure_mesh_command::SecureCommandSqliteReplayLedger::open(ledger_path)?;
            let mut executor = crate::secure_mesh_command::SecureCommandRuntimeExecutor;
            crate::secure_mesh_command::execute_secure_command_json(
                &parsed_payload,
                &parsed_context,
                &mut ledger,
                &mut executor,
                completed_at,
            )?
        }
        ("device-trust", "evaluate") => {
            let mut policy_params = params.clone();
            if let Some(object) = policy_params.as_object_mut() {
                if let Some(identity) = object.get("identity").cloned() {
                    let parsed_identity = identity.as_str().map(parse_json_arg).unwrap_or(identity);
                    object.insert("identity".to_string(), parsed_identity);
                }
                if let Some(previous_identity) = object.get("previousIdentity").cloned() {
                    let parsed_previous = previous_identity
                        .as_str()
                        .map(parse_json_arg)
                        .unwrap_or(previous_identity);
                    object.insert("previousIdentity".to_string(), parsed_previous);
                }
            }
            crate::secure_mesh_trust::evaluate_device_trust_policy_json(&policy_params)?
        }
        ("file", "route") => {
            let mut file_params = params.clone();
            if let Some(object) = file_params.as_object_mut() {
                if let Some(manifest) = object.get("manifest").cloned() {
                    let parsed_manifest = manifest.as_str().map(parse_json_arg).unwrap_or(manifest);
                    object.insert("manifest".to_string(), parsed_manifest);
                }
            }
            crate::secure_mesh_file::evaluate_file_route_json(&file_params)?
        }
        ("mls", "recovery-vector") => crate::secure_mesh_mls::export_mls_recovery_vector_json()?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn seal_payload_cli_json(params: &Value) -> Result<Value> {
    let key = content_key_from_params(params)?;
    let context = content_context_from_params(params)?;
    let kind = payload_kind_from_params(params)?;
    let body = base64url_bytes_from_params(params, &["bodyBase64url", "body"])?;
    let mut plaintext = crate::secure_mesh_crypto::SecureMeshPlaintext::new(kind, body);
    if let Some(content_type) = optional_string(params, &["contentType", "content_type"])? {
        plaintext = plaintext.with_content_type(content_type);
    }
    let sealed = crate::secure_mesh_crypto::seal_payload(&key, &context, &plaintext)?;
    Ok(json!({
        "ok": true,
        "protocolVersion": sealed.protocol_version,
        "cipherSuite": sealed.cipher_suite,
        "payloadKind": kind.as_str(),
        "encryptedHeader": sealed.encrypted_header,
        "ciphertextSize": sealed.ciphertext_size,
        "ciphertext": sealed.ciphertext,
        "bodyRedacted": true
    }))
}

fn open_payload_cli_json(params: &Value) -> Result<Value> {
    let key = content_key_from_params(params)?;
    let context = content_context_from_params(params)?;
    let kind = payload_kind_from_params(params)?;
    let sealed = sealed_payload_from_params(params)?;
    let opened = crate::secure_mesh_crypto::open_payload(&key, &context, &sealed, kind)?;
    Ok(json!({
        "ok": true,
        "protocolVersion": crate::secure_mesh::SECURE_MESH_PROTOCOL_VERSION,
        "cipherSuite": crate::secure_mesh_crypto::SECURE_MESH_CONTENT_CIPHER_SUITE,
        "payloadKind": opened.kind.as_str(),
        "bodyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(opened.body),
        "contentType": opened.content_type,
        "createdAt": opened.created_at,
        "expiresAt": opened.expires_at
    }))
}

fn content_key_from_params(params: &Value) -> Result<crate::secure_mesh_crypto::ContentKey> {
    let encoded = required_string(params, &["keyBase64url", "contentKeyBase64url", "key"])?;
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .context("secure mesh payload content key is not base64url")?;
    ensure!(
        bytes.len() == 32,
        "secure mesh payload content key must be 32 bytes"
    );
    let mut fixed = [0u8; 32];
    fixed.copy_from_slice(&bytes);
    Ok(crate::secure_mesh_crypto::ContentKey::from_bytes(fixed))
}

fn content_context_from_params(
    params: &Value,
) -> Result<crate::secure_mesh_crypto::SecureMeshContentContext> {
    let raw_context = params
        .get("context")
        .cloned()
        .unwrap_or_else(|| params.clone());
    let context = raw_context
        .as_str()
        .map(parse_json_arg)
        .unwrap_or(raw_context);
    Ok(crate::secure_mesh_crypto::SecureMeshContentContext::new(
        required_string(&context, &["envelopeId", "envelope_id"])?,
        required_string(&context, &["messageId", "message_id"])?,
        required_string(&context, &["opaqueMailboxId", "opaque_mailbox_id"])?,
        required_string(&context, &["senderEndpointId", "sender_endpoint_id"])?,
        required_string(&context, &["recipientEndpointId", "recipient_endpoint_id"])?,
        required_string(&context, &["sessionId", "session_id"])?,
        required_string(&context, &["createdAt", "created_at"])?,
        required_string(&context, &["expiresAt", "expires_at"])?,
    ))
}

fn payload_kind_from_params(
    params: &Value,
) -> Result<crate::secure_mesh_crypto::SecureMeshPayloadKind> {
    let kind = required_string(params, &["payloadKind", "kind"])?;
    match kind {
        "command" => Ok(crate::secure_mesh_crypto::SecureMeshPayloadKind::Command),
        "result" | "result_payload" | "resultPayload" => {
            Ok(crate::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload)
        }
        "error" => Ok(crate::secure_mesh_crypto::SecureMeshPayloadKind::Error),
        "file_chunk" | "fileChunk" => {
            Ok(crate::secure_mesh_crypto::SecureMeshPayloadKind::FileChunk)
        }
        "file_manifest" | "fileManifest" => {
            Ok(crate::secure_mesh_crypto::SecureMeshPayloadKind::FileManifest)
        }
        _ => bail!("secure mesh payload kind is unsupported"),
    }
}

fn sealed_payload_from_params(
    params: &Value,
) -> Result<crate::secure_mesh_crypto::SealedSecureMeshPayload> {
    let raw = params
        .get("sealedPayload")
        .or_else(|| params.get("sealed"))
        .or_else(|| params.get("body"))
        .cloned()
        .unwrap_or_else(|| params.clone());
    let sealed = raw.as_str().map(parse_json_arg).unwrap_or(raw);
    let ciphertext_size = sealed
        .get("ciphertextSize")
        .or_else(|| sealed.get("ciphertext_size"))
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure mesh sealed payload ciphertextSize is required"))?;
    Ok(crate::secure_mesh_crypto::SealedSecureMeshPayload {
        protocol_version: required_string(&sealed, &["protocolVersion", "protocol_version"])?
            .to_string(),
        cipher_suite: required_string(&sealed, &["cipherSuite", "cipher_suite"])?.to_string(),
        encrypted_header: required_string(&sealed, &["encryptedHeader", "encrypted_header"])?
            .to_string(),
        ciphertext: required_string(&sealed, &["ciphertext"])?.to_string(),
        ciphertext_size: usize::try_from(ciphertext_size)
            .map_err(|_| anyhow!("secure mesh sealed payload ciphertextSize is too large"))?,
    })
}

fn required_string<'a>(value: &'a Value, names: &[&str]) -> Result<&'a str> {
    for name in names {
        if let Some(result) = value.get(*name).and_then(Value::as_str) {
            ensure!(
                !result.trim().is_empty(),
                "secure mesh field {name} is empty"
            );
            return Ok(result);
        }
    }
    bail!("secure mesh field {} is required", names.join("|"))
}

fn optional_string<'a>(value: &'a Value, names: &[&str]) -> Result<Option<&'a str>> {
    for name in names {
        if let Some(result) = value.get(*name).and_then(Value::as_str) {
            ensure!(
                !result.trim().is_empty(),
                "secure mesh field {name} is empty"
            );
            return Ok(Some(result));
        }
    }
    Ok(None)
}

fn base64url_bytes_from_params(params: &Value, names: &[&str]) -> Result<Vec<u8>> {
    let encoded = required_string(params, names)?;
    general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .context("secure mesh payload body is not base64url")
}

fn default_completed_at() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::CliExecution;
    use crate::paths::set_portable_data_dir_override;
    use base64::engine::general_purpose;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    #[test]
    fn secure_mesh_command_execute_cli_runs_local_activity_after_gate() {
        let env = SecureMeshCommandCliTestEnv::new("execute-activity");
        let result = execute_fixture(&env, command_fixture("cmd-a", "idem-a"), context_fixture());
        assert_eq!(result["evaluation"]["accepted"], true);
        assert_eq!(result["evaluation"]["shouldExecute"], true);
        assert_eq!(result["execution"]["outcome"], "result");
        assert_eq!(result["execution"]["output"]["output"]["ok"], true);
        assert!(result["execution"]["output"]["output"]["events"].is_array());
        assert_eq!(result["bodyRedacted"], true);
        assert!(result.get("body").is_none());
    }

    #[test]
    fn secure_mesh_command_execute_cli_uses_durable_replay_ledger() {
        let env = SecureMeshCommandCliTestEnv::new("execute-replay");
        let first = execute_fixture(&env, command_fixture("cmd-a", "idem-a"), context_fixture());
        assert_eq!(first["execution"]["outcome"], "result");

        let replay = execute_fixture(&env, command_fixture("cmd-a", "idem-b"), context_fixture());
        assert_eq!(replay["evaluation"]["shouldExecute"], false);
        assert_eq!(replay["evaluation"]["replayed"], true);
        assert_eq!(replay["execution"]["outcome"], "error");
        assert_eq!(replay["execution"]["errorCode"], "command_replay_rejected");
    }

    #[test]
    fn secure_mesh_command_execute_cli_rejects_high_risk_web_limited_before_runtime() {
        let env = SecureMeshCommandCliTestEnv::new("execute-high-risk");
        let mut payload = command_fixture("cmd-risk", "idem-risk");
        payload["riskClass"] = json!("high_risk");
        payload["senderIdentity"]["endpointKind"] = json!("web_limited");
        let mut context = context_fixture();
        context["senderEndpointKind"] = json!("web_limited");

        let rejected = execute_fixture(&env, payload, context);
        assert_eq!(rejected["evaluation"]["accepted"], false);
        assert_eq!(rejected["evaluation"]["shouldExecute"], false);
        assert_eq!(rejected["evaluation"]["code"], "high_risk_sender_rejected");
        assert_eq!(rejected["execution"]["outcome"], "error");
        assert_eq!(
            rejected["execution"]["errorCode"],
            "high_risk_sender_rejected"
        );
    }

    #[test]
    fn secure_mesh_device_trust_evaluate_cli_reports_policy_decision() {
        let identity = identity_fixture_json("desktop_gui:alice", 1, 2);
        let previous = identity_fixture_json("desktop_gui:alice", 3, 4);
        let args = vec![
            "secure-mesh".to_string(),
            "device-trust".to_string(),
            "evaluate".to_string(),
            "--identity".to_string(),
            serde_json::to_string(&identity).unwrap(),
            "--previous-identity".to_string(),
            serde_json::to_string(&previous).unwrap(),
            "--trust-state".to_string(),
            "verified".to_string(),
            "--require-verified-device".to_string(),
            "true".to_string(),
        ];
        let result = handle_secure_mesh(&args).unwrap();
        let value = match result {
            CliExecution::Json(value) => value,
            CliExecution::Usage => panic!("secure mesh device-trust evaluate returned usage"),
        };
        assert_eq!(
            value["protocolVersion"],
            crate::secure_mesh_trust::SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION
        );
        assert_eq!(value["keyChangeDetected"], true);
        assert_eq!(value["trustState"], "key_changed");
        assert_eq!(value["decision"]["allowedForPrekey"], false);
        assert_eq!(value["decision"]["code"], "identity_key_changed");
    }

    #[test]
    fn secure_mesh_file_route_cli_reports_default_route_without_metadata() {
        let manifest = json!({
            "fileId": "file-cli-1",
            "fileName": "launch-plan.pdf",
            "mimeType": "application/pdf",
            "relativePath": "workspace/reports",
            "totalSize": 16,
            "chunkSize": 8,
            "chunkCount": 2
        });
        let args = vec![
            "secure-mesh".to_string(),
            "file".to_string(),
            "route".to_string(),
            "--manifest".to_string(),
            serde_json::to_string(&manifest).unwrap(),
        ];
        let result = handle_secure_mesh(&args).unwrap();
        let value = match result {
            CliExecution::Json(value) => value,
            CliExecution::Usage => panic!("secure mesh file route returned usage"),
        };
        assert_eq!(
            value["route"]["uploadOperation"],
            "secure_mesh.file_chunk.upload"
        );
        assert_eq!(
            value["route"]["fetchOperation"],
            "secure_mesh.file_chunk.fetch"
        );
        let serialized = serde_json::to_string(&value).unwrap();
        assert!(!serialized.contains("launch-plan.pdf"));
        assert!(!serialized.contains("application/pdf"));
        assert!(!serialized.contains("workspace/reports"));
    }

    #[test]
    fn secure_mesh_payload_seal_open_cli_round_trips_without_plaintext_echo() {
        let key = general_purpose::URL_SAFE_NO_PAD.encode([7u8; 32]);
        let context = payload_context_fixture("env_cli_payload", "msg_cli_payload");
        let body = br#"{"secret":"do-not-echo"}"#;
        let seal_args = vec![
            "secure-mesh".to_string(),
            "payload".to_string(),
            "seal".to_string(),
            "--key-base64url".to_string(),
            key.clone(),
            "--kind".to_string(),
            "command".to_string(),
            "--context".to_string(),
            serde_json::to_string(&context).unwrap(),
            "--body-base64url".to_string(),
            general_purpose::URL_SAFE_NO_PAD.encode(body),
            "--content-type".to_string(),
            "application/json".to_string(),
        ];
        let sealed = match handle_secure_mesh(&seal_args).unwrap() {
            CliExecution::Json(value) => value,
            CliExecution::Usage => panic!("secure mesh payload seal returned usage"),
        };
        assert_eq!(sealed["ok"], true);
        assert_eq!(sealed["payloadKind"], "command");
        assert_eq!(sealed["bodyRedacted"], true);
        assert!(sealed["encryptedHeader"].as_str().unwrap_or_default().len() > 16);
        assert!(sealed["ciphertext"].as_str().unwrap_or_default().len() > 16);
        let serialized = serde_json::to_string(&sealed).unwrap();
        assert!(!serialized.contains("do-not-echo"));

        let open_args = vec![
            "secure-mesh".to_string(),
            "payload".to_string(),
            "open".to_string(),
            "--key-base64url".to_string(),
            key,
            "--kind".to_string(),
            "command".to_string(),
            "--context".to_string(),
            serde_json::to_string(&context).unwrap(),
            "--sealed-payload".to_string(),
            serde_json::to_string(&sealed).unwrap(),
        ];
        let opened = match handle_secure_mesh(&open_args).unwrap() {
            CliExecution::Json(value) => value,
            CliExecution::Usage => panic!("secure mesh payload open returned usage"),
        };
        assert_eq!(opened["ok"], true);
        assert_eq!(opened["payloadKind"], "command");
        assert_eq!(opened["contentType"], "application/json");
        let opened_body = general_purpose::URL_SAFE_NO_PAD
            .decode(opened["bodyBase64url"].as_str().unwrap())
            .unwrap();
        assert_eq!(opened_body, body);
    }

    #[test]
    fn secure_mesh_mls_recovery_vector_cli_exports_public_wire_artifacts_only() {
        let args = vec![
            "secure-mesh".to_string(),
            "mls".to_string(),
            "recovery-vector".to_string(),
        ];
        let value = match handle_secure_mesh(&args).unwrap() {
            CliExecution::Json(value) => value,
            CliExecution::Usage => panic!("secure mesh MLS recovery-vector returned usage"),
        };
        assert_eq!(value["ok"], true);
        assert_eq!(
            value["vectorSchema"],
            "v0.0.1:secure-mesh:mls-recovery-vector-1"
        );
        assert_eq!(value["checks"]["keyPackageTlsParsed"], true);
        assert_eq!(value["checks"]["secretStorePersistedAndReloaded"], true);
        assert_eq!(
            value["checks"]["externalCrossImplementationComplete"],
            false
        );
        for key in [
            "keyPackage",
            "addCommit",
            "welcome",
            "updateCommit",
            "application",
        ] {
            assert!(
                value["publicArtifacts"][key]["byteLength"]
                    .as_u64()
                    .unwrap_or_default()
                    > 0
            );
            assert!(
                value["publicArtifacts"][key]["sha256"]
                    .as_str()
                    .unwrap_or_default()
                    .starts_with("sha256:")
            );
            assert!(
                value["publicArtifacts"][key]["tlsSerializedBase64url"]
                    .as_str()
                    .unwrap_or_default()
                    .len()
                    > 16
            );
        }
        let serialized = serde_json::to_string(&value).unwrap();
        assert!(!serialized.contains("mls-interop-recovery-secret"));
        assert!(!serialized.contains("canary"));
    }

    fn execute_fixture(env: &SecureMeshCommandCliTestEnv, payload: Value, context: Value) -> Value {
        let args = vec![
            "secure-mesh".to_string(),
            "command".to_string(),
            "execute".to_string(),
            "--payload".to_string(),
            serde_json::to_string(&payload).unwrap(),
            "--context".to_string(),
            serde_json::to_string(&context).unwrap(),
            "--ledger-path".to_string(),
            env.ledger_path.display().to_string(),
            "--completed-at".to_string(),
            "2026-01-01T00:02:00Z".to_string(),
        ];
        let result = handle_secure_mesh(&args).unwrap();
        match result {
            CliExecution::Json(value) => value,
            CliExecution::Usage => panic!("secure mesh command execute returned usage"),
        }
    }

    fn command_fixture(command_id: &str, idempotency_key: &str) -> Value {
        json!({
            "schema": crate::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": command_id,
            "commandKind": "client.activity.sync",
            "senderIdentity": {
                "endpointId": "pc-a",
                "identityFingerprint": "fingerprint-a",
                "trustState": "verified",
                "endpointKind": "desktop_sidecar"
            },
            "targetBinding": {
                "targetEndpointId": "pc-b",
                "targetAgentId": "agent-a",
                "workspaceId": "workspace-a"
            },
            "riskClass": "read_only",
            "requiresUserConfirmation": false,
            "idempotencyKey": idempotency_key,
            "createdAt": "2026-01-01T00:00:00Z",
            "expiresAt": "2026-01-01T00:10:00Z",
            "body": {"limit": 5}
        })
    }

    fn context_fixture() -> Value {
        json!({
            "localEndpointId": "pc-b",
            "senderEndpointId": "pc-a",
            "senderIdentityFingerprint": "fingerprint-a",
            "senderTrustState": "verified",
            "senderEndpointKind": "desktop_sidecar",
            "senderRosterActive": true,
            "targetRosterActive": true,
            "sessionOrEpochValid": true,
            "userConfirmed": false,
            "allowedWorkspaceIds": ["workspace-a"],
            "allowedAgentIds": ["agent-a"],
            "now": "2026-01-01T00:01:00Z"
        })
    }

    fn identity_fixture_json(endpoint_id: &str, identity_byte: u8, signing_byte: u8) -> Value {
        json!({
            "endpointId": endpoint_id,
            "identityPublicKey": general_purpose::URL_SAFE_NO_PAD.encode([identity_byte; 32]),
            "signingPublicKey": general_purpose::URL_SAFE_NO_PAD.encode([signing_byte; 32]),
            "rotationEpoch": 1
        })
    }

    fn payload_context_fixture(envelope_id: &str, message_id: &str) -> Value {
        json!({
            "envelopeId": envelope_id,
            "messageId": message_id,
            "opaqueMailboxId": "mailbox-cli",
            "senderEndpointId": "desktop_gui:alice",
            "recipientEndpointId": "mobile:bob",
            "sessionId": "pairwise-session-cli",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "expiresAt": "2026-01-01T00:10:00.000Z"
        })
    }

    struct SecureMeshCommandCliTestEnv {
        root: PathBuf,
        ledger_path: PathBuf,
        previous_portable: Option<PathBuf>,
    }

    impl SecureMeshCommandCliTestEnv {
        fn new(label: &str) -> Self {
            let root = std::env::temp_dir().join(format!(
                "lico-secure-mesh-command-cli-{}-{}",
                label,
                uuid::Uuid::new_v4()
            ));
            std::fs::create_dir_all(&root).unwrap();
            let ledger_path = root.join("command-ledger.sqlite");
            let previous_portable = set_portable_data_dir_override(Some(root.join("portable")));
            Self {
                root,
                ledger_path,
                previous_portable,
            }
        }
    }

    impl Drop for SecureMeshCommandCliTestEnv {
        fn drop(&mut self) {
            set_portable_data_dir_override(self.previous_portable.take());
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}
