use std::collections::BTreeSet;
use std::io::Read;

use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Map, Value};

use super::secure_client_relay_transport::{
    SECURE_CLIENT_RELAY_PROTOCOL_VERSION, SecureClientRelayEndpointRegistration,
    SecureClientRelayOperation, SecureClientRelayScope,
};
use crate::core::secure_mesh_relay_envelope::{
    SECURE_MESH_RELAY_ENVELOPE_SCHEMA, SECURE_MESH_RELAY_OUTER_FIELDS, SecureMeshRelayEnvelope,
};

const STORE_SCHEMA_VERSION: &str = "licolite.secure-mesh.store-schema.v2";
const DEVICE_TRUST_PROTOCOL_VERSION: &str = "licolite.secure-mesh.device-trust.v2";
const DELIVERY_PROTOCOL_VERSION: &str = "licolite.secure-mesh.delivery.v1";
const MAX_HTTP_RESPONSE_BYTES: usize = 24 * 1024 * 1024;
const MAX_IDENTIFIER_BYTES: usize = 255;
const MAX_ERROR_BYTES: usize = 4 * 1024;
const MAX_CHALLENGE_BYTES: usize = 2 * 1024;
const JSON_SAFE_INTEGER_MAX: u64 = 9_007_199_254_740_991;

pub(super) fn read_success_response(
    operation: SecureClientRelayOperation,
    response: ureq::Response,
) -> Result<Value> {
    ensure_json_content_type(&response)?;
    let body = read_json_response(response)?;
    validate_success_response(operation, &body)?;
    Ok(body)
}

pub(super) fn read_error_response(response: ureq::Response) -> Result<Value> {
    ensure_json_content_type(&response)?;
    let body = read_json_response(response)?;
    let object = exact_object(
        &body,
        "error response",
        &["ok", "schemaVersion", "protocolVersion", "code", "error"],
    )?;
    ensure!(
        boolean(field(object, "ok")?, "error response ok")? == false,
        "secure client relay error response ok flag is invalid"
    );
    constant_string(
        field(object, "schemaVersion")?,
        "error response schema version",
        STORE_SCHEMA_VERSION,
    )?;
    constant_string(
        field(object, "protocolVersion")?,
        "error response protocol version",
        SECURE_CLIENT_RELAY_PROTOCOL_VERSION,
    )?;
    let code = string(
        field(object, "code")?,
        "error response code",
        1,
        MAX_IDENTIFIER_BYTES,
    )?;
    ensure!(
        stable_error_code(code),
        "secure client relay error response code is invalid"
    );
    string(
        field(object, "error")?,
        "error response message",
        1,
        MAX_ERROR_BYTES,
    )?;
    Ok(body)
}

pub(super) fn validate_challenge_response_binding(
    response: &Value,
    scope: &SecureClientRelayScope,
    endpoint_id: &str,
) -> Result<()> {
    let object = object(response, "endpoint challenge response")?;
    let challenge_id = string(
        field(object, "challengeId")?,
        "endpoint challenge id",
        1,
        MAX_IDENTIFIER_BYTES,
    )?;
    let challenge = string(
        field(object, "challenge")?,
        "endpoint challenge",
        1,
        MAX_CHALLENGE_BYTES,
    )?;
    let expected_prefix = format!(
        "{SECURE_CLIENT_RELAY_PROTOCOL_VERSION}:{challenge_id}:{}:{}:{endpoint_id}:",
        scope.tenant_id, scope.account_id
    );
    let issued_at = challenge
        .strip_prefix(&expected_prefix)
        .ok_or_else(|| anyhow!("secure client relay endpoint challenge subject binding differs"))?;
    timestamp(issued_at, "endpoint challenge issued at")?;
    Ok(())
}

pub(super) fn validate_registration_response_binding(
    response: &Value,
    scope: &SecureClientRelayScope,
    registration: &SecureClientRelayEndpointRegistration,
) -> Result<()> {
    let response = object(response, "endpoint registration response")?;
    let endpoint = object(
        field(response, "endpoint")?,
        "endpoint registration response endpoint",
    )?;
    scope_binding(endpoint, scope, "endpoint registration response")?;
    equal_string(
        endpoint,
        "endpointId",
        &registration.endpoint_id,
        "registered endpoint id",
    )?;
    equal_string(
        endpoint,
        "endpointKind",
        &registration.endpoint_kind,
        "registered endpoint kind",
    )?;
    equal_string(
        endpoint,
        "mailboxToken",
        &registration.mailbox_token,
        "registered mailbox token",
    )?;
    ensure!(
        field(endpoint, "identityPublicKey")?
            == &serde_json::to_value(&registration.identity_public_key)?,
        "secure client relay registered identity public key differs"
    );
    ensure!(
        field(endpoint, "signingPublicKey")?
            == &serde_json::to_value(&registration.signing_public_key)?,
        "secure client relay registered signing public key differs"
    );
    ensure!(
        unsigned(
            field(endpoint, "rotationEpoch")?,
            "registered rotation epoch",
            0
        )? == registration.rotation_epoch.unwrap_or(0),
        "secure client relay registered rotation epoch differs"
    );
    Ok(())
}

pub(super) fn validate_send_response_binding(
    response: &Value,
    scope: &SecureClientRelayScope,
    envelope: &SecureMeshRelayEnvelope,
    requested_transport: Option<&str>,
    opaque_sequence_label: Option<&str>,
) -> Result<()> {
    let response = object(response, "envelope send response")?;
    let queued = object(field(response, "queued")?, "queued envelope response")?;
    let metadata = object(field(queued, "envelope")?, "queued envelope metadata")?;
    equal_string(
        metadata,
        "schema",
        envelope.schema(),
        "queued envelope schema",
    )?;
    equal_string(
        metadata,
        "deliveryId",
        envelope.delivery_id(),
        "queued delivery id",
    )?;
    equal_string(
        metadata,
        "mailboxToken",
        envelope.mailbox_token(),
        "queued mailbox token",
    )?;
    ensure!(
        unsigned(
            field(metadata, "ciphertextBucket")?,
            "queued ciphertext bucket",
            0,
        )? == envelope.ciphertext_bucket() as u64,
        "secure client relay queued ciphertext bucket differs"
    );
    let mailbox = object(field(queued, "mailbox")?, "queued mailbox")?;
    scope_binding(mailbox, scope, "queued mailbox")?;
    equal_string(
        mailbox,
        "mailboxToken",
        envelope.mailbox_token(),
        "queued mailbox token",
    )?;
    if let Some(expected) = requested_transport {
        equal_string(queued, "transport", expected, "queued transport")?;
    }
    ensure!(
        boolean(
            field(queued, "opaqueSequenceLabelPresent")?,
            "opaque sequence label presence",
        )? == opaque_sequence_label.is_some(),
        "secure client relay opaque sequence label presence differs"
    );
    let persisted = boolean(field(response, "persisted")?, "send persisted flag")?;
    let queue_mode = queue_mode(field(response, "queueMode")?)?;
    ensure!(
        persisted == (queue_mode == "offline_queue"),
        "secure client relay send persistence mode is inconsistent"
    );
    Ok(())
}

pub(super) fn validate_sync_response_binding(
    response: &Value,
    scope: &SecureClientRelayScope,
    mailbox_token: &str,
    requested_after_delivery_sequence: Option<u64>,
) -> Result<()> {
    let response = object(response, "envelope sync response")?;
    let mailbox = object(field(response, "mailbox")?, "sync mailbox")?;
    scope_binding(mailbox, scope, "sync mailbox")?;
    equal_string(mailbox, "mailboxToken", mailbox_token, "sync mailbox token")?;
    let cursor = object(field(response, "cursor")?, "sync cursor")?;
    ensure!(
        unsigned(
            field(cursor, "afterDeliverySequence")?,
            "sync after delivery sequence",
            0,
        )? == requested_after_delivery_sequence.unwrap_or(0),
        "secure client relay sync cursor does not bind the requested position"
    );
    let envelopes = array(field(response, "envelopes")?, "sync envelopes")?;
    for envelope in envelopes {
        let envelope = object(envelope, "leased envelope")?;
        equal_string(
            envelope,
            "mailboxToken",
            mailbox_token,
            "leased envelope mailbox token",
        )?;
    }
    Ok(())
}

pub(super) fn validate_ack_response_binding(
    response: &Value,
    scope: &SecureClientRelayScope,
    mailbox_token: &str,
    delivery_id: &str,
) -> Result<()> {
    let response = object(response, "envelope ack response")?;
    let ack = object(field(response, "ack")?, "envelope ack")?;
    let receipt = object(field(response, "receipt")?, "envelope receipt")?;
    let mailbox = object(field(response, "mailbox")?, "ack mailbox")?;
    equal_string(ack, "deliveryId", delivery_id, "acked delivery id")?;
    equal_string(receipt, "deliveryId", delivery_id, "receipt delivery id")?;
    ensure!(
        field(ack, "purged")? == field(receipt, "purged")?,
        "secure client relay ack and receipt purge states differ"
    );
    scope_binding(mailbox, scope, "ack mailbox")?;
    equal_string(mailbox, "mailboxToken", mailbox_token, "ack mailbox token")?;
    Ok(())
}

fn validate_success_response(operation: SecureClientRelayOperation, body: &Value) -> Result<()> {
    let object = exact_object(body, operation.key(), operation.success_fields())?;
    ensure!(
        boolean(field(object, "ok")?, "success response ok")?,
        "secure client relay success response ok flag is invalid"
    );
    constant_string(
        field(object, "schemaVersion")?,
        "success response schema version",
        STORE_SCHEMA_VERSION,
    )?;
    let expected_protocol = match operation {
        SecureClientRelayOperation::EndpointChallenge
        | SecureClientRelayOperation::EndpointRegister => DEVICE_TRUST_PROTOCOL_VERSION,
        SecureClientRelayOperation::EnvelopeSend
        | SecureClientRelayOperation::EnvelopeSync
        | SecureClientRelayOperation::EnvelopeAck => DELIVERY_PROTOCOL_VERSION,
    };
    constant_string(
        field(object, "protocolVersion")?,
        "success response protocol version",
        expected_protocol,
    )?;
    match operation {
        SecureClientRelayOperation::EndpointChallenge => validate_challenge_success(object),
        SecureClientRelayOperation::EndpointRegister => {
            validate_core_endpoint(field(object, "endpoint")?)
        }
        SecureClientRelayOperation::EnvelopeSend => validate_send_success(object),
        SecureClientRelayOperation::EnvelopeSync => validate_sync_success(object),
        SecureClientRelayOperation::EnvelopeAck => validate_ack_success(object),
    }
}

fn validate_challenge_success(object: &Map<String, Value>) -> Result<()> {
    string(
        field(object, "challengeId")?,
        "endpoint challenge id",
        1,
        MAX_IDENTIFIER_BYTES,
    )?;
    string(
        field(object, "challenge")?,
        "endpoint challenge",
        1,
        MAX_CHALLENGE_BYTES,
    )?;
    constant_string(
        field(object, "challengeEncoding")?,
        "endpoint challenge encoding",
        "utf-8",
    )?;
    constant_string(
        field(object, "signatureAlgorithm")?,
        "endpoint challenge signature algorithm",
        "Ed25519",
    )?;
    timestamp_value(field(object, "expiresAt")?, "endpoint challenge expiry")
}

fn validate_send_success(object: &Map<String, Value>) -> Result<()> {
    let queued = exact_object(
        field(object, "queued")?,
        "queued envelope",
        &[
            "deliverySequence",
            "queuedAt",
            "transport",
            "envelope",
            "opaqueSequenceLabelHash",
            "opaqueSequenceLabelPresent",
            "mailbox",
            "metadataOnly",
        ],
    )?;
    unsigned(
        field(queued, "deliverySequence")?,
        "queued delivery sequence",
        1,
    )?;
    timestamp_value(field(queued, "queuedAt")?, "queued at")?;
    transport(field(queued, "transport")?)?;
    validate_envelope_metadata(field(queued, "envelope")?)?;
    any_string(
        field(queued, "opaqueSequenceLabelHash")?,
        "opaque sequence label hash",
    )?;
    boolean(
        field(queued, "opaqueSequenceLabelPresent")?,
        "opaque sequence label presence",
    )?;
    validate_public_mailbox(field(queued, "mailbox")?)?;
    ensure!(
        boolean(field(queued, "metadataOnly")?, "queued metadata-only flag")?,
        "secure client relay queued response disclosed non-metadata state"
    );
    boolean(field(object, "persisted")?, "send persisted flag")?;
    queue_mode(field(object, "queueMode")?)?;
    Ok(())
}

fn validate_sync_success(object: &Map<String, Value>) -> Result<()> {
    queue_mode(field(object, "queueMode")?)?;
    validate_public_mailbox(field(object, "mailbox")?)?;
    let cursor = exact_object(
        field(object, "cursor")?,
        "sync cursor",
        &[
            "afterDeliverySequence",
            "nextDeliverySequence",
            "highWatermark",
            "hasMore",
        ],
    )?;
    let after = unsigned(
        field(cursor, "afterDeliverySequence")?,
        "sync after delivery sequence",
        0,
    )?;
    let next = unsigned(
        field(cursor, "nextDeliverySequence")?,
        "sync next delivery sequence",
        0,
    )?;
    let high = unsigned(field(cursor, "highWatermark")?, "sync high watermark", 0)?;
    boolean(field(cursor, "hasMore")?, "sync has-more flag")?;
    ensure!(
        next >= after,
        "secure client relay sync cursor is not monotonic"
    );
    let mut previous_to = after;
    for range in array(field(object, "gapRanges")?, "sync gap ranges")? {
        let range = exact_object(range, "sync gap range", &["from", "to"])?;
        let from = unsigned(field(range, "from")?, "sync gap from", 1)?;
        let to = unsigned(field(range, "to")?, "sync gap to", 1)?;
        ensure!(
            from <= to && from > previous_to && to <= high,
            "secure client relay sync gap ranges are invalid or overlap"
        );
        previous_to = to;
    }
    for envelope in array(field(object, "envelopes")?, "sync envelopes")? {
        validate_leased_envelope(envelope)?;
    }
    Ok(())
}

fn validate_ack_success(object: &Map<String, Value>) -> Result<()> {
    let ack = exact_object(
        field(object, "ack")?,
        "envelope ack",
        &["deliveryId", "idempotent", "ackedAt", "purged"],
    )?;
    canonical_base64url(field(ack, "deliveryId")?, "acked delivery id", 32)?;
    boolean(field(ack, "idempotent")?, "ack idempotent flag")?;
    timestamp_value(field(ack, "ackedAt")?, "ack time")?;
    boolean(field(ack, "purged")?, "ack purged flag")?;

    let receipt = exact_object(
        field(object, "receipt")?,
        "envelope receipt",
        &[
            "deliveryId",
            "deliverySequence",
            "receiptType",
            "acknowledgedAt",
            "purged",
        ],
    )?;
    canonical_base64url(field(receipt, "deliveryId")?, "receipt delivery id", 32)?;
    unsigned(
        field(receipt, "deliverySequence")?,
        "receipt delivery sequence",
        1,
    )?;
    constant_string(field(receipt, "receiptType")?, "receipt type", "ack")?;
    timestamp_value(
        field(receipt, "acknowledgedAt")?,
        "receipt acknowledgement time",
    )?;
    boolean(field(receipt, "purged")?, "receipt purged flag")?;
    validate_public_mailbox(field(object, "mailbox")?)
}

fn validate_core_endpoint(value: &Value) -> Result<()> {
    let endpoint = exact_object(
        value,
        "core endpoint",
        &[
            "tenantId",
            "accountId",
            "workspaceId",
            "endpointId",
            "endpointKind",
            "mailboxToken",
            "identityPublicKey",
            "signingPublicKey",
            "fingerprint",
            "rotationEpoch",
            "createdAt",
            "updatedAt",
            "revokedAt",
        ],
    )?;
    for name in ["tenantId", "accountId", "workspaceId", "endpointId"] {
        any_string(field(endpoint, name)?, name)?;
    }
    endpoint_kind(field(endpoint, "endpointKind")?)?;
    canonical_base64url(field(endpoint, "mailboxToken")?, "mailbox token", 43)?;
    validate_public_jwk(field(endpoint, "identityPublicKey")?, "X25519")?;
    validate_public_jwk(field(endpoint, "signingPublicKey")?, "Ed25519")?;
    sha256_hex(field(endpoint, "fingerprint")?, "endpoint fingerprint")?;
    unsigned(
        field(endpoint, "rotationEpoch")?,
        "endpoint rotation epoch",
        0,
    )?;
    timestamp_value(field(endpoint, "createdAt")?, "endpoint created at")?;
    timestamp_value(field(endpoint, "updatedAt")?, "endpoint updated at")?;
    any_string(field(endpoint, "revokedAt")?, "endpoint revoked at")?;
    Ok(())
}

fn validate_public_mailbox(value: &Value) -> Result<()> {
    let mailbox = exact_object(
        value,
        "public mailbox",
        &[
            "tenantId",
            "accountId",
            "workspaceId",
            "endpointId",
            "mailboxToken",
            "queueBytes",
            "queuedCount",
            "oldestQueuedAt",
            "deliverySequence",
            "receiptCount",
            "ackedCount",
            "updatedAt",
        ],
    )?;
    for name in ["tenantId", "accountId", "workspaceId", "endpointId"] {
        any_string(field(mailbox, name)?, name)?;
    }
    canonical_base64url(field(mailbox, "mailboxToken")?, "mailbox token", 43)?;
    for name in [
        "queueBytes",
        "queuedCount",
        "deliverySequence",
        "receiptCount",
        "ackedCount",
    ] {
        unsigned(field(mailbox, name)?, name, 0)?;
    }
    any_string(
        field(mailbox, "oldestQueuedAt")?,
        "mailbox oldest queued at",
    )?;
    any_string(field(mailbox, "updatedAt")?, "mailbox updated at")?;
    Ok(())
}

fn validate_envelope_metadata(value: &Value) -> Result<()> {
    let envelope = exact_object(
        value,
        "envelope metadata",
        &["schema", "deliveryId", "mailboxToken", "ciphertextBucket"],
    )?;
    constant_string(
        field(envelope, "schema")?,
        "envelope schema",
        SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
    )?;
    canonical_base64url(field(envelope, "deliveryId")?, "delivery id", 32)?;
    canonical_base64url(field(envelope, "mailboxToken")?, "mailbox token", 43)?;
    unsigned(field(envelope, "ciphertextBucket")?, "ciphertext bucket", 1)?;
    Ok(())
}

fn validate_leased_envelope(value: &Value) -> Result<()> {
    let envelope = exact_object(
        value,
        "leased envelope",
        &[
            "schema",
            "deliveryId",
            "mailboxToken",
            "encryptedHeader",
            "ciphertextBucket",
            "ciphertext",
            "deliverySequence",
            "queuedAt",
            "transport",
            "deliveryAttempts",
            "leaseId",
            "leaseGeneration",
            "leasedAt",
            "leaseExpiresAt",
            "opaqueSequenceLabelHash",
            "opaqueSequenceLabelPresent",
        ],
    )?;
    let mut relay_envelope = Map::new();
    for name in SECURE_MESH_RELAY_OUTER_FIELDS {
        relay_envelope.insert(name.to_string(), field(envelope, name)?.clone());
    }
    let wire = serde_json::to_string(&Value::Object(relay_envelope))
        .context("secure client relay leased envelope serialization failed")?;
    SecureMeshRelayEnvelope::from_json(&wire)
        .context("secure client relay leased envelope is invalid")?;
    unsigned(
        field(envelope, "deliverySequence")?,
        "leased delivery sequence",
        1,
    )?;
    timestamp_value(field(envelope, "queuedAt")?, "leased queued at")?;
    transport(field(envelope, "transport")?)?;
    unsigned(field(envelope, "deliveryAttempts")?, "delivery attempts", 1)?;
    string(
        field(envelope, "leaseId")?,
        "lease id",
        1,
        MAX_IDENTIFIER_BYTES,
    )?;
    unsigned(field(envelope, "leaseGeneration")?, "lease generation", 1)?;
    timestamp_value(field(envelope, "leasedAt")?, "leased at")?;
    timestamp_value(field(envelope, "leaseExpiresAt")?, "lease expiry")?;
    any_string(
        field(envelope, "opaqueSequenceLabelHash")?,
        "opaque sequence label hash",
    )?;
    boolean(
        field(envelope, "opaqueSequenceLabelPresent")?,
        "opaque sequence label presence",
    )?;
    Ok(())
}

fn validate_public_jwk(value: &Value, expected_curve: &str) -> Result<()> {
    let jwk = exact_object(value, "public JWK", &["kty", "crv", "x"])?;
    constant_string(field(jwk, "kty")?, "public JWK type", "OKP")?;
    constant_string(field(jwk, "crv")?, "public JWK curve", expected_curve)?;
    canonical_base64url(field(jwk, "x")?, "public JWK x", 43)
}

fn scope_binding(
    object: &Map<String, Value>,
    scope: &SecureClientRelayScope,
    label: &str,
) -> Result<()> {
    equal_string(object, "tenantId", &scope.tenant_id, label)?;
    equal_string(object, "accountId", &scope.account_id, label)?;
    equal_string(
        object,
        "workspaceId",
        scope.workspace_id.as_deref().unwrap_or(""),
        label,
    )
}

fn equal_string(
    object: &Map<String, Value>,
    name: &str,
    expected: &str,
    label: &str,
) -> Result<()> {
    ensure!(
        field(object, name)?.as_str() == Some(expected),
        "secure client relay {label} differs"
    );
    Ok(())
}

fn ensure_json_content_type(response: &ureq::Response) -> Result<()> {
    ensure!(
        response
            .header("content-type")
            .is_some_and(|value| value.to_ascii_lowercase().starts_with("application/json")),
        "secure client relay response content type is invalid"
    );
    Ok(())
}

fn read_json_response(response: ureq::Response) -> Result<Value> {
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take((MAX_HTTP_RESPONSE_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .context("secure client relay response read failed")?;
    ensure!(
        bytes.len() <= MAX_HTTP_RESPONSE_BYTES,
        "secure client relay response body is too large"
    );
    serde_json::from_slice(&bytes).context("secure client relay response JSON is invalid")
}

fn exact_object<'a>(
    value: &'a Value,
    label: &str,
    expected_fields: &[&str],
) -> Result<&'a Map<String, Value>> {
    let object = object(value, label)?;
    let actual = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected = expected_fields.iter().copied().collect::<BTreeSet<_>>();
    ensure!(
        actual == expected,
        "secure client relay {label} shape is invalid"
    );
    Ok(object)
}

fn object<'a>(value: &'a Value, label: &str) -> Result<&'a Map<String, Value>> {
    value
        .as_object()
        .ok_or_else(|| anyhow!("secure client relay {label} must be an object"))
}

fn array<'a>(value: &'a Value, label: &str) -> Result<&'a [Value]> {
    value
        .as_array()
        .map(Vec::as_slice)
        .ok_or_else(|| anyhow!("secure client relay {label} must be an array"))
}

fn field<'a>(object: &'a Map<String, Value>, name: &str) -> Result<&'a Value> {
    object
        .get(name)
        .ok_or_else(|| anyhow!("secure client relay response field is missing"))
}

fn any_string<'a>(value: &'a Value, label: &str) -> Result<&'a str> {
    value
        .as_str()
        .ok_or_else(|| anyhow!("secure client relay {label} must be a string"))
}

fn string<'a>(value: &'a Value, label: &str, minimum: usize, maximum: usize) -> Result<&'a str> {
    let value = any_string(value, label)?;
    ensure!(
        (minimum..=maximum).contains(&value.len()),
        "secure client relay {label} length is invalid"
    );
    Ok(value)
}

fn constant_string(value: &Value, label: &str, expected: &str) -> Result<()> {
    ensure!(
        value.as_str() == Some(expected),
        "secure client relay {label} is unsupported"
    );
    Ok(())
}

fn boolean(value: &Value, label: &str) -> Result<bool> {
    value
        .as_bool()
        .ok_or_else(|| anyhow!("secure client relay {label} must be boolean"))
}

fn unsigned(value: &Value, label: &str, minimum: u64) -> Result<u64> {
    let value = value
        .as_u64()
        .ok_or_else(|| anyhow!("secure client relay {label} must be an unsigned integer"))?;
    ensure!(
        (minimum..=JSON_SAFE_INTEGER_MAX).contains(&value),
        "secure client relay {label} is outside the supported range"
    );
    Ok(value)
}

fn canonical_base64url(value: &Value, label: &str, encoded_length: usize) -> Result<()> {
    let value = string(value, label, encoded_length, encoded_length)?;
    ensure!(
        value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'),
        "secure client relay {label} is not canonical base64url"
    );
    let decoded = base64::Engine::decode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, value)
        .map_err(|_| anyhow!("secure client relay {label} is not canonical base64url"))?;
    ensure!(
        base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, decoded) == value,
        "secure client relay {label} is not canonical base64url"
    );
    Ok(())
}

fn sha256_hex(value: &Value, label: &str) -> Result<()> {
    let value = string(value, label, 64, 64)?;
    ensure!(
        value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "secure client relay {label} is not canonical sha256 hex"
    );
    Ok(())
}

fn timestamp_value(value: &Value, label: &str) -> Result<()> {
    timestamp(any_string(value, label)?, label)
}

fn timestamp(value: &str, label: &str) -> Result<()> {
    let bytes = value.as_bytes();
    let layout = bytes.len() == 20 && bytes.get(19) == Some(&b'Z')
        || bytes.len() == 24
            && bytes.get(19) == Some(&b'.')
            && bytes[20..23].iter().all(u8::is_ascii_digit)
            && bytes.get(23) == Some(&b'Z');
    ensure!(
        layout
            && bytes[0..4].iter().all(u8::is_ascii_digit)
            && bytes.get(4) == Some(&b'-')
            && bytes[5..7].iter().all(u8::is_ascii_digit)
            && bytes.get(7) == Some(&b'-')
            && bytes[8..10].iter().all(u8::is_ascii_digit)
            && bytes.get(10) == Some(&b'T')
            && bytes[11..13].iter().all(u8::is_ascii_digit)
            && bytes.get(13) == Some(&b':')
            && bytes[14..16].iter().all(u8::is_ascii_digit)
            && bytes.get(16) == Some(&b':')
            && bytes[17..19].iter().all(u8::is_ascii_digit),
        "secure client relay {label} timestamp is invalid"
    );
    Ok(())
}

fn queue_mode(value: &Value) -> Result<&str> {
    let value = any_string(value, "queue mode")?;
    ensure!(
        matches!(value, "offline_queue" | "zero_persistence"),
        "secure client relay queue mode is unsupported"
    );
    Ok(value)
}

fn transport(value: &Value) -> Result<&str> {
    let value = any_string(value, "transport")?;
    ensure!(
        matches!(
            value,
            "cloud_relay"
                | "mobile_relay"
                | "lan_direct"
                | "webrtc_data_channel"
                | "loopback_local"
        ),
        "secure client relay transport is unsupported"
    );
    Ok(value)
}

fn endpoint_kind(value: &Value) -> Result<&str> {
    let value = any_string(value, "endpoint kind")?;
    ensure!(
        matches!(
            value,
            "desktop_gui"
                | "desktop_sidecar"
                | "mobile"
                | "cli"
                | "client_local_runtime"
                | "agent_host"
                | "web_limited"
        ),
        "secure client relay endpoint kind is unsupported"
    );
    Ok(value)
}

fn stable_error_code(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn registration_response_rejects_nested_server_owned_trust_fields() {
        let mut response = registration_response();
        validate_success_response(SecureClientRelayOperation::EndpointRegister, &response).unwrap();

        response["endpoint"]["trustState"] = json!("verified");
        assert!(
            validate_success_response(SecureClientRelayOperation::EndpointRegister, &response)
                .is_err()
        );
    }

    #[test]
    fn registration_response_rejects_noncanonical_key_and_scope_substitution() {
        let mut response = registration_response();
        response["endpoint"]["identityPublicKey"]["x"] = json!(format!("{}=", "A".repeat(42)));
        assert!(
            validate_success_response(SecureClientRelayOperation::EndpointRegister, &response)
                .is_err()
        );

        let response = registration_response();
        let scope = SecureClientRelayScope::new("other-tenant", "account", None).unwrap();
        assert!(
            validate_registration_response_binding(&response, &scope, &registration()).is_err()
        );
    }

    #[test]
    fn challenge_subject_is_bound_to_operation_scope_and_endpoint() {
        let response = json!({
            "ok": true,
            "schemaVersion": STORE_SCHEMA_VERSION,
            "protocolVersion": DEVICE_TRUST_PROTOCOL_VERSION,
            "challengeId": "challenge",
            "challenge": format!(
                "{SECURE_CLIENT_RELAY_PROTOCOL_VERSION}:challenge:tenant:account:endpoint:2026-01-01T00:00:00Z"
            ),
            "challengeEncoding": "utf-8",
            "signatureAlgorithm": "Ed25519",
            "expiresAt": "2026-01-01T00:01:00Z"
        });
        validate_success_response(SecureClientRelayOperation::EndpointChallenge, &response)
            .unwrap();
        let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
        validate_challenge_response_binding(&response, &scope, "endpoint").unwrap();
        assert!(validate_challenge_response_binding(&response, &scope, "substitute").is_err());
    }

    #[test]
    fn sync_response_rejects_impossible_or_overlapping_gap_ranges() {
        let mut response = json!({
            "ok": true,
            "schemaVersion": STORE_SCHEMA_VERSION,
            "protocolVersion": DELIVERY_PROTOCOL_VERSION,
            "queueMode": "offline_queue",
            "mailbox": mailbox(),
            "cursor": {
                "afterDeliverySequence": 0,
                "nextDeliverySequence": 0,
                "highWatermark": 0,
                "hasMore": false
            },
            "gapRanges": [],
            "envelopes": []
        });
        validate_success_response(SecureClientRelayOperation::EnvelopeSync, &response).unwrap();

        response["gapRanges"] = json!([{ "from": 1, "to": 1 }]);
        assert!(
            validate_success_response(SecureClientRelayOperation::EnvelopeSync, &response).is_err()
        );

        response["cursor"]["highWatermark"] = json!(4);
        response["gapRanges"] = json!([
            { "from": 1, "to": 2 },
            { "from": 2, "to": 3 }
        ]);
        assert!(
            validate_success_response(SecureClientRelayOperation::EnvelopeSync, &response).is_err()
        );
    }

    #[test]
    fn ack_response_binds_ack_receipt_and_requested_delivery() {
        let response = json!({
            "ok": true,
            "schemaVersion": STORE_SCHEMA_VERSION,
            "protocolVersion": DELIVERY_PROTOCOL_VERSION,
            "ack": {
                "deliveryId": "A".repeat(32),
                "idempotent": false,
                "ackedAt": "2026-01-01T00:00:00Z",
                "purged": true
            },
            "receipt": {
                "deliveryId": "B".repeat(32),
                "deliverySequence": 1,
                "receiptType": "ack",
                "acknowledgedAt": "2026-01-01T00:00:00Z",
                "purged": true
            },
            "mailbox": mailbox()
        });
        validate_success_response(SecureClientRelayOperation::EnvelopeAck, &response).unwrap();
        let scope = SecureClientRelayScope::new("tenant", "account", None).unwrap();
        let mailbox_token = canonical_fixture_base64url(3, 32);
        assert!(
            validate_ack_response_binding(&response, &scope, &mailbox_token, &"A".repeat(32),)
                .is_err()
        );
    }

    fn canonical_fixture_base64url(byte: u8, count: usize) -> String {
        base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            vec![byte; count],
        )
    }

    fn registration() -> SecureClientRelayEndpointRegistration {
        SecureClientRelayEndpointRegistration {
            endpoint_id: "endpoint".to_string(),
            endpoint_kind: "cli".to_string(),
            identity_public_key:
                super::super::secure_client_relay_transport::SecureClientRelayPublicJwk::x25519(
                    canonical_fixture_base64url(1, 32),
                )
                .unwrap(),
            signing_public_key:
                super::super::secure_client_relay_transport::SecureClientRelayPublicJwk::ed25519(
                    canonical_fixture_base64url(2, 32),
                )
                .unwrap(),
            mailbox_token: canonical_fixture_base64url(3, 32),
            rotation_epoch: Some(1),
            challenge_id: "challenge".to_string(),
            challenge_signature: canonical_fixture_base64url(4, 64),
        }
    }

    fn registration_response() -> Value {
        let registration = registration();
        json!({
            "ok": true,
            "schemaVersion": STORE_SCHEMA_VERSION,
            "protocolVersion": DEVICE_TRUST_PROTOCOL_VERSION,
            "endpoint": {
                "tenantId": "tenant",
                "accountId": "account",
                "workspaceId": "",
                "endpointId": registration.endpoint_id,
                "endpointKind": registration.endpoint_kind,
                "mailboxToken": registration.mailbox_token,
                "identityPublicKey": registration.identity_public_key,
                "signingPublicKey": registration.signing_public_key,
                "fingerprint": "a".repeat(64),
                "rotationEpoch": 1,
                "createdAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
                "revokedAt": ""
            }
        })
    }

    fn mailbox() -> Value {
        json!({
            "tenantId": "tenant",
            "accountId": "account",
            "workspaceId": "",
            "endpointId": "endpoint",
            "mailboxToken": canonical_fixture_base64url(3, 32),
            "queueBytes": 0,
            "queuedCount": 0,
            "oldestQueuedAt": "",
            "deliverySequence": 0,
            "receiptCount": 0,
            "ackedCount": 0,
            "updatedAt": "2026-01-01T00:00:00Z"
        })
    }
}
