use anyhow::{Result, anyhow, ensure};

use super::contract::{
    MAX_CHALLENGE_BYTES, MAX_IDENTIFIER_BYTES, SECURE_CLIENT_RELAY_PROTOCOL_VERSION,
    SecureClientRelayEndpointRegistration, SecureClientRelayScope,
};
use super::response_schema::{
    boolean, equal_string, field, object, scope_binding, string, timestamp, unsigned,
};
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;

pub(super) fn validate_challenge_response_binding(
    response: &serde_json::Value,
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
    response: &serde_json::Value,
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
            0,
        )? == registration.rotation_epoch.unwrap_or(0),
        "secure client relay registered rotation epoch differs"
    );
    Ok(())
}

pub(super) fn validate_send_response_binding(
    response: &serde_json::Value,
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
    let queue_mode = field(response, "queueMode")?.as_str();
    ensure!(
        persisted == (queue_mode == Some("offline_queue")),
        "secure client relay send persistence mode is inconsistent"
    );
    Ok(())
}

pub(super) fn validate_sync_response_binding(
    response: &serde_json::Value,
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
    for envelope in field(response, "envelopes")?
        .as_array()
        .ok_or_else(|| anyhow!("secure client relay sync envelopes must be an array"))?
    {
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
    response: &serde_json::Value,
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
