use std::collections::BTreeSet;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;

use base64::{Engine as _, engine::general_purpose};
use serde_json::{Map, Value, json};

#[derive(Clone, Debug)]
pub(super) struct CapturedRequest {
    pub path: String,
    pub headers: Map<String, Value>,
    pub body: Value,
}

pub(super) fn read_request(stream: &mut TcpStream) -> CapturedRequest {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    reader.read_line(&mut request_line).unwrap();
    let path = request_line
        .split_whitespace()
        .nth(1)
        .expect("request path")
        .to_string();
    let mut headers = Map::new();
    let mut content_length = 0usize;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            let name = name.trim().to_ascii_lowercase();
            let value = value.trim();
            if name == "content-length" {
                content_length = value.parse().unwrap();
            }
            headers.insert(name, json!(value));
        }
    }
    let mut body = vec![0u8; content_length];
    reader.read_exact(&mut body).unwrap();
    CapturedRequest {
        path,
        headers,
        body: serde_json::from_slice(&body).unwrap(),
    }
}

pub(super) fn write_json_response(
    stream: &mut TcpStream,
    status: &str,
    body: &Value,
    extra_headers: &[(&str, &str)],
) {
    let bytes = serde_json::to_vec(body).unwrap();
    write!(
        stream,
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n",
        bytes.len()
    )
    .unwrap();
    for (name, value) in extra_headers {
        write!(stream, "{name}: {value}\r\n").unwrap();
    }
    write!(stream, "\r\n").unwrap();
    stream.write_all(&bytes).unwrap();
}

pub(super) fn success_fixture(request: &CapturedRequest) -> Value {
    match request.path.as_str() {
        "/api/secure-mesh/v1/endpoints/challenge" => json!({
            "ok": true,
            "schemaVersion": "licomesh.secure-mesh.store-schema.v2",
            "protocolVersion": "licomesh.secure-mesh.device-trust.v2",
            "challengeId": "challenge",
            "challenge": format!(
                "licomesh.secure-mesh.v1:challenge:{}:{}:{}:2026-01-01T00:00:00Z",
                request.body["tenantId"].as_str().unwrap(),
                request.body["accountId"].as_str().unwrap(),
                request.body["endpointId"].as_str().unwrap(),
            ),
            "challengeEncoding": "utf-8",
            "signatureAlgorithm": "Ed25519",
            "expiresAt": "2026-01-01T00:00:00Z"
        }),
        "/api/secure-mesh/v1/endpoints/register" => json!({
            "ok": true,
            "schemaVersion": "licomesh.secure-mesh.store-schema.v2",
            "protocolVersion": "licomesh.secure-mesh.device-trust.v2",
            "endpoint": {
                "tenantId": request.body["tenantId"],
                "accountId": request.body["accountId"],
                "workspaceId": request.body.get("workspaceId").cloned().unwrap_or(json!("")),
                "endpointId": request.body["endpointId"],
                "endpointKind": request.body["endpointKind"],
                "mailboxToken": request.body["mailboxToken"],
                "identityPublicKey": request.body["identityPublicKey"],
                "signingPublicKey": request.body["signingPublicKey"],
                "fingerprint": "a".repeat(64),
                "rotationEpoch": request.body.get("rotationEpoch").cloned().unwrap_or(json!(0)),
                "createdAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
                "revokedAt": ""
            },
            "registrationReceipt": {
                "receiptRef": "b".repeat(64),
                "sequence": 1
            }
        }),
        "/api/secure-mesh/v1/envelopes/send" => json!({
            "ok": true,
            "schemaVersion": "licomesh.secure-mesh.store-schema.v2",
            "protocolVersion": "licomesh.secure-mesh.delivery.v1",
            "queued": {
                "deliverySequence": 1,
                "queuedAt": "2026-01-01T00:00:00Z",
                "transport": request.body.get("transport").cloned().unwrap_or(json!("cloud_relay")),
                "envelope": {
                    "schema": request.body["envelope"]["schema"],
                    "deliveryId": request.body["envelope"]["deliveryId"],
                    "mailboxToken": request.body["envelope"]["mailboxToken"],
                    "ciphertextBucket": request.body["envelope"]["ciphertextBucket"]
                },
                "opaqueSequenceLabelHash": "",
                "opaqueSequenceLabelPresent": request.body.get("opaqueSequenceLabel").is_some(),
                "mailbox": mailbox_fixture(
                    &request.body,
                    request.body["envelope"]["mailboxToken"].as_str().unwrap(),
                ),
                "metadataOnly": true
            },
            "persisted": true,
            "queueMode": "offline_queue"
        }),
        "/api/secure-mesh/v1/envelopes/sync" => json!({
            "ok": true,
            "schemaVersion": "licomesh.secure-mesh.store-schema.v2",
            "protocolVersion": "licomesh.secure-mesh.delivery.v1",
            "queueMode": "offline_queue",
            "mailbox": mailbox_fixture(
                &request.body,
                request.body["mailboxToken"].as_str().unwrap(),
            ),
            "cursor": {
                "afterDeliverySequence": request.body.get("afterDeliverySequence").cloned().unwrap_or(json!(0)),
                "nextDeliverySequence": request.body.get("afterDeliverySequence").cloned().unwrap_or(json!(0)),
                "highWatermark": request.body.get("afterDeliverySequence").cloned().unwrap_or(json!(0)),
                "hasMore": false
            },
            "gapRanges": [],
            "envelopes": []
        }),
        "/api/secure-mesh/v1/envelopes/ack" => json!({
            "ok": true,
            "schemaVersion": "licomesh.secure-mesh.store-schema.v2",
            "protocolVersion": "licomesh.secure-mesh.delivery.v1",
            "ack": {
                "deliveryId": request.body["deliveryId"],
                "idempotent": false,
                "ackedAt": "2026-01-01T00:00:00Z",
                "purged": true
            },
            "receipt": {
                "deliveryId": request.body["deliveryId"],
                "deliverySequence": 1,
                "receiptType": "ack",
                "acknowledgedAt": "2026-01-01T00:00:00Z",
                "purged": true
            },
            "mailbox": mailbox_fixture(
                &request.body,
                request.body["mailboxToken"].as_str().unwrap(),
            )
        }),
        _ => panic!("unexpected canonical operation path"),
    }
}

pub(super) fn canonical_bytes(byte: u8, count: usize) -> String {
    general_purpose::URL_SAFE_NO_PAD.encode(vec![byte; count])
}

pub(super) fn object_keys(value: &Value) -> BTreeSet<&str> {
    value
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect()
}

pub(super) fn set<'a>(values: &'a [&'a str]) -> BTreeSet<&'a str> {
    values.iter().copied().collect()
}

fn mailbox_fixture(scope: &Value, mailbox_token: &str) -> Value {
    json!({
        "tenantId": scope["tenantId"],
        "accountId": scope["accountId"],
        "workspaceId": scope.get("workspaceId").cloned().unwrap_or(json!("")),
        "endpointId": "endpoint",
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
