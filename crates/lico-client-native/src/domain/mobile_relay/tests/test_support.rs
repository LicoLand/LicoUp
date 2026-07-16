pub(super) use super::super::{
    command_sync::*, config::*, endpoint_trust::*, key_transparency::*, pairing::*,
    pairwise_session::*, relay_operations::*, secret_custody::*, support::*,
};
pub(super) use crate::core::secure_mesh_capability::{
    CapabilityEvidenceKind, CapabilityFact, capability_catalog, mandatory_protocol_facts,
};
pub(super) use crate::platform::paths::set_portable_data_dir_override;
pub(super) use crate::platform::secure_client_relay::SecureClientRelayOperation;
pub(super) use crate::platform::secure_mesh_secret_store::EphemeralSecretStore;
pub(super) use std::env;
pub(super) use std::io::{BufRead, BufReader, Read, Write};
pub(super) use std::net::{TcpListener, TcpStream};
pub(super) use std::sync::{Arc, Mutex};
pub(super) use std::thread;

pub(super) fn secure_envelope_fixture() -> Value {
    let ciphertext = vec![9u8; 32];
    let header = vec![
                7u8;
                crate::core::secure_mesh_relay_envelope::SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
            ];
    json!({
        "schema": crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
        "deliveryId": general_purpose::URL_SAFE_NO_PAD.encode(vec![1u8; 24]),
        "mailboxToken": general_purpose::URL_SAFE_NO_PAD.encode(vec![2u8; 32]),
        "encryptedHeader": general_purpose::URL_SAFE_NO_PAD.encode(&header),
        "ciphertextBucket": 256u64,
        "ciphertext": general_purpose::URL_SAFE_NO_PAD.encode(pad_to_bucket(&ciphertext, 256)),
    })
}

pub(super) fn pad_to_bucket(data: &[u8], bucket: usize) -> Vec<u8> {
    let mut padded = Vec::with_capacity(bucket);
    padded.extend_from_slice(data);
    padded.resize(bucket, 0);
    padded
}

pub(super) fn append_test_directory_state(
    descriptor: &mut Value,
    directory_state: &str,
) -> Result<()> {
    ensure!(
        matches!(directory_state, "active" | "revoked"),
        "test directory state is unsupported"
    );
    let response_value = descriptor
        .get("preKeyBundle")
        .and_then(|bundle| bundle.get("keyTransparency"))
        .cloned()
        .ok_or_else(|| anyhow!("test descriptor KT response is missing"))?;
    let mut response: UntrustedDirectoryResponse = serde_json::from_value(response_value)?;
    let previous_tree_size = response.inclusion.signed_tree_head.tree_size;
    response.claim.endpoint.directory_state = directory_state.to_string();
    response.claim.endpoint.updated_at = now_iso();
    response.claim.directory_version = response
        .claim
        .directory_version
        .checked_add(1)
        .ok_or_else(|| anyhow!("test directory version overflow"))?;
    let now_epoch_seconds = mobile_relay_trust_record_now_epoch()?;
    response = with_mobile_relay_test_kt_log(|log| {
        let index = log.append_hashed_directory_leaf(
            &response.claim.stable_label(),
            response.claim.version(),
            response.claim.revoked(),
            response.claim.leaf_hash()?,
        )?;
        Ok(UntrustedDirectoryResponse {
            claim: response.claim.clone(),
            inclusion: log.inclusion_proof_at(index, now_epoch_seconds)?,
            latest_map: log.map_proof_at(&response.claim.stable_label(), now_epoch_seconds)?,
            consistency: (previous_tree_size < log.tree_size())
                .then(|| log.consistency_proof_at(previous_tree_size, now_epoch_seconds))
                .transpose()?,
        })
    })?;
    descriptor["preKeyBundle"]["keyTransparency"] = serde_json::to_value(response)?;
    Ok(())
}

pub(super) fn pair_mobile_relay_configs(pc_config: &mut Value, mobile_config: &mut Value) {
    let shared_delivery_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);
    pc_config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(shared_delivery_secret.clone());
    mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(shared_delivery_secret);
    let pc_descriptor =
        ensure_mobile_relay_endpoint_descriptor(pc_config, "desktop_sidecar").unwrap();
    ensure_mobile_relay_endpoint_descriptor(mobile_config, "mobile").unwrap();
    apply_peer_secure_mesh_descriptor(mobile_config, &pc_descriptor, true).unwrap();
    let mobile_descriptor =
        ensure_mobile_relay_endpoint_descriptor(mobile_config, "mobile").unwrap();
    apply_peer_secure_mesh_descriptor(pc_config, &mobile_descriptor, true).unwrap();
    let pc_accepted_descriptor =
        ensure_mobile_relay_endpoint_descriptor(pc_config, "desktop_sidecar").unwrap();
    apply_peer_secure_mesh_descriptor(mobile_config, &pc_accepted_descriptor, true).unwrap();
    let mobile_finished_descriptor =
        ensure_mobile_relay_endpoint_descriptor(mobile_config, "mobile").unwrap();
    assert!(mobile_finished_descriptor["pairwiseFinished"].is_object());
    apply_peer_secure_mesh_descriptor(pc_config, &mobile_finished_descriptor, true).unwrap();
    let protected_payload = seal_mobile_relay_payload(
        mobile_config,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
        &json!({"action": "pairwise_finished_confirmed"}),
    )
    .unwrap();
    let opened = open_mobile_relay_payload(
        pc_config,
        &protected_payload,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
    )
    .unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&opened).unwrap()["action"],
        "pairwise_finished_confirmed"
    );
}

pub(super) fn paired_command_envelope_fixture() -> (Value, Value, Value) {
    let mut pc_config = default_config();
    let mut mobile_config = default_config();
    pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
    let mobile_endpoint = local_endpoint_state(&mobile_config).unwrap();
    let pc_endpoint = local_endpoint_state(&pc_config).unwrap();
    let command_payload = json!({
        "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
        "commandId": "cmd_mobile_relay_replay_fixture",
        "commandKind": "agent.sessions.list",
        "senderIdentity": {
            "endpointId": mobile_endpoint.endpoint_id,
            "identityFingerprint": mobile_endpoint.fingerprint,
            "trustState": "verified",
            "endpointKind": mobile_endpoint.endpoint_kind
        },
        "targetBinding": {
            "targetEndpointId": pc_endpoint.endpoint_id,
            "targetAgentId": null,
            "workspaceId": "default"
        },
        "riskClass": "read_only",
        "requiresUserConfirmation": false,
        "idempotencyKey": "idem_mobile_relay_replay_fixture",
        "createdAt": now_iso(),
        "expiresAt": timestamp_after_seconds(MOBILE_RELAY_COMMAND_TTL_SECONDS).unwrap(),
        "body": {
            "agent": "codex",
            "limit": 1
        }
    });
    let envelope = seal_mobile_relay_payload(
        &mobile_config,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        &command_payload,
    )
    .unwrap();
    (pc_config, mobile_config, envelope)
}

pub(super) fn opened_result_payload(mobile_config: &Value, envelope: &Value) -> Value {
    let opened = open_mobile_relay_payload(
        mobile_config,
        envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
    )
    .unwrap();
    serde_json::from_slice::<Value>(&opened).unwrap()
}

pub(super) fn temp_dir(name: &str) -> PathBuf {
    let dir = env::temp_dir().join(format!("lico-client-{}-{}", name, Uuid::new_v4()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[derive(Clone, Debug)]
pub(super) struct CapturedHttpRequest {
    pub(super) path: String,
    pub(super) body: String,
}

pub(super) struct CanonicalRelayGateway {
    pub(super) address: String,
    pub(super) captured: Arc<Mutex<Vec<CapturedHttpRequest>>>,
    pub(super) handle: thread::JoinHandle<()>,
}

impl CanonicalRelayGateway {
    pub(super) fn start(expected_requests: usize, sync_envelopes: Vec<Value>) -> Self {
        Self::start_with(expected_requests, move |request| {
            canonical_relay_response(request, &sync_envelopes)
        })
    }

    pub(super) fn start_with<F>(expected_requests: usize, responder: F) -> Self
    where
        F: Fn(&CapturedHttpRequest) -> Value + Send + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap().to_string();
        let captured = Arc::new(Mutex::new(Vec::<CapturedHttpRequest>::new()));
        let thread_captured = Arc::clone(&captured);
        let handle = thread::spawn(move || {
            for stream in listener.incoming().take(expected_requests) {
                let mut stream = stream.unwrap();
                let request = read_http_request(&mut stream);
                let response = responder(&request);
                thread_captured.lock().unwrap().push(request);
                write_http_json_response(&mut stream, &response);
            }
        });
        Self {
            address,
            captured,
            handle,
        }
    }

    pub(super) fn url(&self) -> String {
        format!("http://{}", self.address)
    }

    pub(super) fn request_body(&self, index: usize) -> String {
        self.captured
            .lock()
            .unwrap()
            .get(index)
            .map(|request| request.body.clone())
            .unwrap_or_default()
    }

    pub(super) fn request_paths(&self) -> Vec<String> {
        self.captured
            .lock()
            .unwrap()
            .iter()
            .map(|request| request.path.clone())
            .collect()
    }

    pub(super) fn assert_operations(&self, operations: &[SecureClientRelayOperation]) {
        assert_eq!(
            self.request_paths(),
            operations
                .iter()
                .map(|operation| operation.path().to_string())
                .collect::<Vec<_>>()
        );
    }

    pub(super) fn join(self) {
        self.handle.join().unwrap();
    }
}

pub(super) fn read_http_request(stream: &mut TcpStream) -> CapturedHttpRequest {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    reader.read_line(&mut request_line).unwrap();
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let trimmed = line.trim_end();
        if trimmed.is_empty() {
            break;
        }
        if let Some((name, value)) = trimmed.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse::<usize>().unwrap_or(0);
            }
        }
    }
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body).unwrap();
    CapturedHttpRequest {
        path,
        body: String::from_utf8(body).unwrap(),
    }
}

pub(super) fn with_canonical_relay_params(mut params: Value) -> Value {
    params["relaySessionToken"] = json!("test-session-token");
    params["relayCsrfToken"] = json!("test-csrf-token");
    params["relayTenantId"] = json!("tenant-test");
    params["relayAccountId"] = json!("account-test");
    params
}

pub(super) fn captured_body(request: &CapturedHttpRequest) -> Value {
    serde_json::from_str(&request.body).unwrap()
}

pub(super) fn canonical_relay_response(
    request: &CapturedHttpRequest,
    sync_envelopes: &[Value],
) -> Value {
    match request.path.as_str() {
        path if path == SecureClientRelayOperation::EndpointChallenge.path() => {
            canonical_challenge_response(request)
        }
        path if path == SecureClientRelayOperation::EndpointRegister.path() => {
            canonical_register_response(request)
        }
        path if path == SecureClientRelayOperation::EnvelopeSend.path() => {
            canonical_send_response(request)
        }
        path if path == SecureClientRelayOperation::EnvelopeSync.path() => {
            canonical_sync_response(request, sync_envelopes)
        }
        path if path == SecureClientRelayOperation::EnvelopeAck.path() => {
            canonical_ack_response(request)
        }
        _ => panic!("unexpected non-canonical relay operation"),
    }
}

pub(super) fn canonical_challenge_response(request: &CapturedHttpRequest) -> Value {
    let body = captured_body(request);
    let challenge_id = "challenge-test";
    let challenge = format!(
        "{}:{challenge_id}:{}:{}:{}:2026-01-01T00:00:00Z",
        crate::platform::secure_client_relay::SECURE_CLIENT_RELAY_PROTOCOL_VERSION,
        body["tenantId"].as_str().unwrap(),
        body["accountId"].as_str().unwrap(),
        body["endpointId"].as_str().unwrap(),
    );
    json!({
        "ok": true,
        "schemaVersion": "licolite.secure-mesh.store-schema.v2",
        "protocolVersion": "licolite.secure-mesh.device-trust.v2",
        "challengeId": challenge_id,
        "challenge": challenge,
        "challengeEncoding": "utf-8",
        "signatureAlgorithm": "Ed25519",
        "expiresAt": "2026-01-01T00:05:00Z"
    })
}

pub(super) fn canonical_register_response(request: &CapturedHttpRequest) -> Value {
    let body = captured_body(request);
    let endpoint_id = body["endpointId"].as_str().unwrap_or("endpoint-test");
    json!({
        "ok": true,
        "schemaVersion": "licolite.secure-mesh.store-schema.v2",
        "protocolVersion": "licolite.secure-mesh.device-trust.v2",
        "endpoint": {
            "tenantId": body["tenantId"],
            "accountId": body["accountId"],
            "workspaceId": body.get("workspaceId").cloned().unwrap_or_else(|| json!("")),
            "endpointId": endpoint_id,
            "endpointKind": body["endpointKind"],
            "mailboxToken": body["mailboxToken"],
            "identityPublicKey": body["identityPublicKey"],
            "signingPublicKey": body["signingPublicKey"],
            "fingerprint": sha256_hex(endpoint_id.as_bytes()),
            "rotationEpoch": body.get("rotationEpoch").cloned().unwrap_or_else(|| json!(0)),
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z",
            "revokedAt": ""
        }
    })
}

pub(super) fn canonical_public_mailbox(request: &Value, mailbox_token: &str) -> Value {
    json!({
        "tenantId": request["tenantId"],
        "accountId": request["accountId"],
        "workspaceId": request.get("workspaceId").cloned().unwrap_or_else(|| json!("")),
        "endpointId": "endpoint-test",
        "mailboxToken": mailbox_token,
        "queueBytes": 0,
        "queuedCount": 0,
        "oldestQueuedAt": "",
        "deliverySequence": 1,
        "receiptCount": 0,
        "ackedCount": 0,
        "updatedAt": "2026-01-01T00:00:00Z"
    })
}

pub(super) fn canonical_send_response(request: &CapturedHttpRequest) -> Value {
    let body = captured_body(request);
    let envelope = &body["envelope"];
    let mailbox_token = envelope["mailboxToken"].as_str().unwrap();
    json!({
        "ok": true,
        "schemaVersion": "licolite.secure-mesh.store-schema.v2",
        "protocolVersion": "licolite.secure-mesh.delivery.v1",
        "queued": {
            "deliverySequence": 1,
            "queuedAt": "2026-01-01T00:00:00Z",
            "transport": body.get("transport").cloned().unwrap_or_else(|| json!("mobile_relay")),
            "envelope": {
                "schema": envelope["schema"],
                "deliveryId": envelope["deliveryId"],
                "mailboxToken": envelope["mailboxToken"],
                "ciphertextBucket": envelope["ciphertextBucket"]
            },
            "opaqueSequenceLabelHash": "",
            "opaqueSequenceLabelPresent": body.get("opaqueSequenceLabel").is_some(),
            "mailbox": canonical_public_mailbox(&body, mailbox_token),
            "metadataOnly": true
        },
        "persisted": true,
        "queueMode": "offline_queue"
    })
}

pub(super) fn canonical_leased_envelope(
    envelope: &Value,
    mailbox_token: &str,
    index: usize,
) -> Value {
    let sequence = u64::try_from(index).unwrap().saturating_add(1);
    json!({
        "schema": envelope["schema"],
        "deliveryId": envelope["deliveryId"],
        "mailboxToken": mailbox_token,
        "encryptedHeader": envelope["encryptedHeader"],
        "ciphertextBucket": envelope["ciphertextBucket"],
        "ciphertext": envelope["ciphertext"],
        "deliverySequence": sequence,
        "queuedAt": "2026-01-01T00:00:00Z",
        "transport": "mobile_relay",
        "deliveryAttempts": 1,
        "leaseId": format!("lease-test-{sequence}"),
        "leaseGeneration": 1,
        "leasedAt": "2026-01-01T00:00:01Z",
        "leaseExpiresAt": "2026-01-01T00:00:31Z",
        "opaqueSequenceLabelHash": "",
        "opaqueSequenceLabelPresent": false
    })
}

pub(super) fn canonical_sync_response(request: &CapturedHttpRequest, envelopes: &[Value]) -> Value {
    let body = captured_body(request);
    let mailbox_token = body["mailboxToken"].as_str().unwrap();
    let leased = envelopes
        .iter()
        .enumerate()
        .map(|(index, envelope)| canonical_leased_envelope(envelope, mailbox_token, index))
        .collect::<Vec<_>>();
    let high_watermark = u64::try_from(leased.len()).unwrap();
    json!({
        "ok": true,
        "schemaVersion": "licolite.secure-mesh.store-schema.v2",
        "protocolVersion": "licolite.secure-mesh.delivery.v1",
        "queueMode": "offline_queue",
        "mailbox": canonical_public_mailbox(&body, mailbox_token),
        "cursor": {
            "afterDeliverySequence": body.get("afterDeliverySequence").and_then(Value::as_u64).unwrap_or(0),
            "nextDeliverySequence": high_watermark,
            "highWatermark": high_watermark,
            "hasMore": false
        },
        "gapRanges": [],
        "envelopes": leased
    })
}

pub(super) fn canonical_ack_response(request: &CapturedHttpRequest) -> Value {
    let body = captured_body(request);
    let delivery_id = body["deliveryId"].as_str().unwrap();
    let mailbox_token = body["mailboxToken"].as_str().unwrap();
    json!({
        "ok": true,
        "schemaVersion": "licolite.secure-mesh.store-schema.v2",
        "protocolVersion": "licolite.secure-mesh.delivery.v1",
        "ack": {
            "deliveryId": delivery_id,
            "idempotent": false,
            "ackedAt": "2026-01-01T00:00:02Z",
            "purged": true
        },
        "receipt": {
            "deliveryId": delivery_id,
            "deliverySequence": 1,
            "receiptType": "ack",
            "acknowledgedAt": "2026-01-01T00:00:02Z",
            "purged": true
        },
        "mailbox": canonical_public_mailbox(&body, mailbox_token)
    })
}

pub(super) fn write_http_json_response(stream: &mut TcpStream, body: &Value) {
    let serialized = serde_json::to_string(body).unwrap();
    write!(
            stream,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            serialized.len(),
            serialized
        )
        .unwrap();
}
