use std::collections::BTreeSet;

use anyhow::{Context, Result, anyhow, ensure};
use serde_json::{Map, Value};

use super::contract::{
    DELIVERY_PROTOCOL_VERSION, DEVICE_TRUST_PROTOCOL_VERSION, ENDPOINT_KINDS,
    JSON_SAFE_INTEGER_MAX, MAX_CHALLENGE_BYTES, MAX_ERROR_BYTES, MAX_IDENTIFIER_BYTES,
    SECURE_CLIENT_RELAY_PROTOCOL_VERSION, STORE_SCHEMA_VERSION, SecureClientRelayOperation,
    SecureClientRelayScope, TRANSPORT_KINDS, validate_canonical_base64url,
};
use crate::core::secure_mesh_relay_envelope::{
    SECURE_MESH_RELAY_ENVELOPE_SCHEMA, SECURE_MESH_RELAY_OUTER_FIELDS, SecureMeshRelayEnvelope,
};

pub(super) fn validate_error_response(body: &Value) -> Result<&str> {
    let object = exact_object(
        body,
        "error response",
        &["ok", "schemaVersion", "protocolVersion", "code", "error"],
    )?;
    ensure!(
        !boolean(field(object, "ok")?, "error response ok")?,
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
    Ok(code)
}

pub(super) fn validate_success_response(
    operation: SecureClientRelayOperation,
    body: &Value,
) -> Result<()> {
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
            validate_core_endpoint(field(object, "endpoint")?)?;
            validate_registration_receipt(field(object, "registrationReceipt")?)
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

fn validate_registration_receipt(value: &Value) -> Result<()> {
    let receipt = exact_object(
        value,
        "endpoint registration receipt",
        &["receiptRef", "sequence"],
    )?;
    sha256_hex(
        field(receipt, "receiptRef")?,
        "endpoint registration receipt reference",
    )?;
    unsigned(
        field(receipt, "sequence")?,
        "endpoint registration receipt sequence",
        1,
    )?;
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

pub(super) fn scope_binding(
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

pub(super) fn equal_string(
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

pub(super) fn object<'a>(value: &'a Value, label: &str) -> Result<&'a Map<String, Value>> {
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

pub(super) fn field<'a>(object: &'a Map<String, Value>, name: &str) -> Result<&'a Value> {
    object
        .get(name)
        .ok_or_else(|| anyhow!("secure client relay response field is missing"))
}

fn any_string<'a>(value: &'a Value, label: &str) -> Result<&'a str> {
    value
        .as_str()
        .ok_or_else(|| anyhow!("secure client relay {label} must be a string"))
}

pub(super) fn string<'a>(
    value: &'a Value,
    label: &str,
    minimum: usize,
    maximum: usize,
) -> Result<&'a str> {
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

pub(super) fn boolean(value: &Value, label: &str) -> Result<bool> {
    value
        .as_bool()
        .ok_or_else(|| anyhow!("secure client relay {label} must be boolean"))
}

pub(super) fn unsigned(value: &Value, label: &str, minimum: u64) -> Result<u64> {
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
    validate_canonical_base64url(label, value, encoded_length)
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

pub(super) fn timestamp(value: &str, label: &str) -> Result<()> {
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
        TRANSPORT_KINDS.contains(&value),
        "secure client relay transport is unsupported"
    );
    Ok(value)
}

fn endpoint_kind(value: &Value) -> Result<&str> {
    let value = any_string(value, "endpoint kind")?;
    ensure!(
        ENDPOINT_KINDS.contains(&value),
        "secure client relay endpoint kind is unsupported"
    );
    Ok(value)
}

fn stable_error_code(value: &str) -> bool {
    value
        .bytes()
        .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}
