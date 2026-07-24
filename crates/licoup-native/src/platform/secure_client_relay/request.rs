use anyhow::{Result, ensure};
use serde_json::{Map, Value, json};

use super::contract::{
    ENDPOINT_KINDS, JSON_SAFE_INTEGER_MAX, LEASE_MS_MAX, LEASE_MS_MIN,
    MAX_OPAQUE_SEQUENCE_LABEL_BYTES, SYNC_LIMIT_MAX, SYNC_LIMIT_MIN,
    SecureClientRelayEndpointRegistration, SecureClientRelayOperation, SecureClientRelayPublicJwk,
    SecureClientRelayRequest, SecureClientRelayScope, TRANSPORT_KINDS,
    validate_canonical_base64url, validate_identifier,
};
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;

pub(super) fn endpoint_challenge(
    scope: &SecureClientRelayScope,
    endpoint_id: &str,
    signing_public_key: &SecureClientRelayPublicJwk,
) -> Result<SecureClientRelayRequest> {
    validate_identifier("endpoint id", endpoint_id)?;
    ensure!(
        signing_public_key.crv == "Ed25519",
        "secure client relay challenge signing key profile is invalid"
    );
    let mut body = scope_body(scope);
    body.insert("endpointId".to_string(), json!(endpoint_id));
    body.insert(
        "signingPublicKey".to_string(),
        serde_json::to_value(signing_public_key)?,
    );
    Ok(request(SecureClientRelayOperation::EndpointChallenge, body))
}

pub(super) fn endpoint_register(
    scope: &SecureClientRelayScope,
    registration: &SecureClientRelayEndpointRegistration,
) -> Result<SecureClientRelayRequest> {
    validate_registration(registration)?;
    let mut body = scope_body(scope);
    body.insert("endpointId".to_string(), json!(registration.endpoint_id));
    body.insert(
        "endpointKind".to_string(),
        json!(registration.endpoint_kind),
    );
    body.insert(
        "identityPublicKey".to_string(),
        serde_json::to_value(&registration.identity_public_key)?,
    );
    body.insert(
        "signingPublicKey".to_string(),
        serde_json::to_value(&registration.signing_public_key)?,
    );
    body.insert(
        "mailboxToken".to_string(),
        json!(registration.mailbox_token),
    );
    body.insert(
        "proof".to_string(),
        json!({
            "challengeId": registration.challenge_id,
            "signature": registration.challenge_signature,
        }),
    );
    if let Some(rotation_epoch) = registration.rotation_epoch {
        body.insert("rotationEpoch".to_string(), json!(rotation_epoch));
    }
    Ok(request(SecureClientRelayOperation::EndpointRegister, body))
}

pub(super) fn envelope_send(
    scope: &SecureClientRelayScope,
    envelope: &SecureMeshRelayEnvelope,
    transport: Option<&str>,
    opaque_sequence_label: Option<&str>,
) -> Result<SecureClientRelayRequest> {
    envelope.validate()?;
    if let Some(transport) = transport {
        ensure!(
            TRANSPORT_KINDS.contains(&transport),
            "secure client relay transport is unsupported"
        );
    }
    if let Some(label) = opaque_sequence_label {
        ensure!(
            label.len() <= MAX_OPAQUE_SEQUENCE_LABEL_BYTES && !label.chars().any(char::is_control),
            "secure client relay opaque sequence label is invalid"
        );
    }
    let mut body = scope_body(scope);
    body.insert(
        "envelope".to_string(),
        serde_json::from_str(&envelope.to_json()?)?,
    );
    if let Some(transport) = transport {
        body.insert("transport".to_string(), json!(transport));
    }
    if let Some(label) = opaque_sequence_label {
        body.insert("opaqueSequenceLabel".to_string(), json!(label));
    }
    Ok(request(SecureClientRelayOperation::EnvelopeSend, body))
}

pub(super) fn envelope_sync(
    scope: &SecureClientRelayScope,
    mailbox_token: &str,
    after_delivery_sequence: Option<u64>,
    limit: Option<u64>,
    lease_ms: Option<u64>,
) -> Result<SecureClientRelayRequest> {
    validate_canonical_base64url("mailbox token", mailbox_token, 43)?;
    if let Some(sequence) = after_delivery_sequence {
        ensure!(
            sequence <= JSON_SAFE_INTEGER_MAX,
            "secure client relay sync cursor is outside the supported range"
        );
    }
    if let Some(limit) = limit {
        ensure!(
            (SYNC_LIMIT_MIN..=SYNC_LIMIT_MAX).contains(&limit),
            "secure client relay sync limit is outside the supported range"
        );
    }
    if let Some(lease_ms) = lease_ms {
        ensure!(
            (LEASE_MS_MIN..=LEASE_MS_MAX).contains(&lease_ms),
            "secure client relay lease duration is outside the supported range"
        );
    }
    let mut body = scope_body(scope);
    body.insert("mailboxToken".to_string(), json!(mailbox_token));
    if let Some(sequence) = after_delivery_sequence {
        body.insert("afterDeliverySequence".to_string(), json!(sequence));
    }
    if let Some(limit) = limit {
        body.insert("limit".to_string(), json!(limit));
    }
    if let Some(lease_ms) = lease_ms {
        body.insert("leaseMs".to_string(), json!(lease_ms));
    }
    Ok(request(SecureClientRelayOperation::EnvelopeSync, body))
}

pub(super) fn envelope_ack(
    scope: &SecureClientRelayScope,
    mailbox_token: &str,
    delivery_id: &str,
    lease_id: &str,
    lease_generation: u64,
) -> Result<SecureClientRelayRequest> {
    validate_canonical_base64url("mailbox token", mailbox_token, 43)?;
    validate_canonical_base64url("delivery id", delivery_id, 32)?;
    validate_identifier("lease id", lease_id)?;
    ensure!(
        (1..=JSON_SAFE_INTEGER_MAX).contains(&lease_generation),
        "secure client relay lease generation is outside the supported range"
    );
    let mut body = scope_body(scope);
    body.insert("mailboxToken".to_string(), json!(mailbox_token));
    body.insert("deliveryId".to_string(), json!(delivery_id));
    body.insert("leaseId".to_string(), json!(lease_id));
    body.insert("leaseGeneration".to_string(), json!(lease_generation));
    Ok(request(SecureClientRelayOperation::EnvelopeAck, body))
}

fn request(
    operation: SecureClientRelayOperation,
    body: Map<String, Value>,
) -> SecureClientRelayRequest {
    SecureClientRelayRequest {
        operation,
        body: Value::Object(body),
    }
}

fn scope_body(scope: &SecureClientRelayScope) -> Map<String, Value> {
    let mut body = Map::new();
    body.insert("tenantId".to_string(), json!(scope.tenant_id));
    body.insert("accountId".to_string(), json!(scope.account_id));
    if let Some(workspace_id) = &scope.workspace_id {
        body.insert("workspaceId".to_string(), json!(workspace_id));
    }
    body
}

fn validate_registration(registration: &SecureClientRelayEndpointRegistration) -> Result<()> {
    validate_identifier("endpoint id", &registration.endpoint_id)?;
    ensure!(
        ENDPOINT_KINDS.contains(&registration.endpoint_kind.as_str()),
        "secure client relay endpoint kind is unsupported"
    );
    ensure!(
        registration.identity_public_key.crv == "X25519"
            && registration.signing_public_key.crv == "Ed25519",
        "secure client relay endpoint key profile is invalid"
    );
    validate_canonical_base64url("mailbox token", &registration.mailbox_token, 43)?;
    validate_identifier("challenge id", &registration.challenge_id)?;
    validate_canonical_base64url("challenge signature", &registration.challenge_signature, 86)?;
    if let Some(rotation_epoch) = registration.rotation_epoch {
        ensure!(
            rotation_epoch <= JSON_SAFE_INTEGER_MAX,
            "secure client relay rotation epoch is outside the supported range"
        );
    }
    Ok(())
}
