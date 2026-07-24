use super::super::context::canonical_relay_context;
use super::super::delivery::relay_envelope_from_delivery;
use super::super::mailbox::local_canonical_mailbox_token;
use super::poll_complete::commands_poll_with_config;
use crate::core::secure_mesh_crypto::SecureMeshPayloadKind;
use crate::domain::mobile_relay::endpoint_trust::ensure_peer_verified;
use crate::domain::mobile_relay::pairing::refresh_pairwise_acceptance_if_pending;
use crate::domain::mobile_relay::pairwise_session::{
    mobile_relay_pairwise_operation_with_runtime_secret_context,
    open_mobile_relay_payload_with_pairwise_operation,
    result_envelope_replay_proof_with_pairwise_operation, secure_result_response_summary,
};
use crate::domain::mobile_relay::secret_custody::{
    RuntimeSecretMaterial, load_config_with_runtime_secret_context,
    load_config_with_runtime_secret_context_for_operation,
    mobile_relay_e2ee_secret_store_authorization_batch_operation_count,
};
use crate::domain::mobile_relay::support::{CONFIG_SCHEMA_VERSION, text_param};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub fn command_result(params: &Value) -> Result<Value> {
    let (config, secret_context) = load_config_with_runtime_secret_context(params)?;
    command_result_with_config(params, &config, &secret_context.material)
}

pub(in crate::domain::mobile_relay) fn command_result_with_config(
    params: &Value,
    config: &Value,
    secret_material: &RuntimeSecretMaterial,
) -> Result<Value> {
    let synced = commands_poll_with_config(params, config, secret_material)?;
    let deliveries = synced
        .get("envelopes")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("secure client relay sync response is missing envelopes"))?;
    let requested_delivery_id = text_param(params, &["deliveryId"]);
    let delivery = deliveries
        .iter()
        .find(|delivery| {
            requested_delivery_id.as_deref().is_none_or(|expected| {
                delivery.get("deliveryId").and_then(Value::as_str) == Some(expected)
            })
        })
        .ok_or_else(|| anyhow!("secure client relay result envelope is not available"))?;
    let envelope = relay_envelope_from_delivery(delivery)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "command": {
            "resultEnvelope": serde_json::from_str::<Value>(&envelope.to_json()?)?,
            "deliveryId": envelope.delivery_id(),
            "leaseId": delivery.get("leaseId").cloned().unwrap_or(Value::Null),
            "leaseGeneration": delivery.get("leaseGeneration").cloned().unwrap_or(Value::Null)
        },
        "cursor": synced.get("cursor").cloned().unwrap_or(Value::Null)
    }))
}

pub fn command_result_secure(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay secure result operation authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(3),
    )?;
    refresh_pairwise_acceptance_if_pending(params, &mut config, &mut secret_context)?;
    let response = command_result_with_config(params, &config, &secret_context.material)?;
    let Some(envelope) = response
        .get("command")
        .and_then(|command| command.get("resultEnvelope"))
        .filter(|value| value.is_object())
    else {
        return Err(anyhow!(
            "mobile relay secure result missing encrypted result envelope"
        ));
    };
    ensure_peer_verified(&config)?;
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Mobile Relay secure result operation authorization batch",
        3,
        &mut secret_context,
    )?;
    let opened = open_mobile_relay_payload_with_pairwise_operation(
        &config,
        &secret_context.material,
        envelope,
        SecureMeshPayloadKind::ResultPayload,
        &mut pairwise_operation,
    )?;
    let result_payload = serde_json::from_slice::<Value>(&opened)
        .map_err(|error| anyhow!("mobile relay secure result payload is not JSON: {error}"))?;
    let command = response
        .get("command")
        .ok_or_else(|| anyhow!("secure client relay result delivery metadata is missing"))?;
    let delivery_id = command
        .get("deliveryId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure client relay result delivery id is missing"))?;
    let lease_id = command
        .get("leaseId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure client relay result lease id is missing"))?;
    let lease_generation = command
        .get("leaseGeneration")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure client relay result lease generation is missing"))?;
    let relay = canonical_relay_context(params, &config)?;
    let ack = relay.transport.envelope_ack(
        &relay.scope,
        &local_canonical_mailbox_token(&config, &secret_context.material)?,
        delivery_id,
        lease_id,
        lease_generation,
    )?;
    let response_summary = secure_result_response_summary(&response);
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "response": response_summary,
        "ack": ack,
        "openedResult": result_payload,
        "bodyRedacted": true
    }))
}

pub fn command_result_replay_proof(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay secure result replay proof authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(5),
    )?;
    refresh_pairwise_acceptance_if_pending(params, &mut config, &mut secret_context)?;
    let response = command_result_with_config(params, &config, &secret_context.material)?;
    let Some(envelope) = response
        .get("command")
        .and_then(|command| command.get("resultEnvelope"))
        .filter(|value| value.is_object())
    else {
        return Err(anyhow!(
            "mobile relay secure result replay proof missing encrypted result envelope"
        ));
    };
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Mobile Relay secure result replay proof authorization batch",
        5,
        &mut secret_context,
    )?;
    result_envelope_replay_proof_with_pairwise_operation(
        &config,
        &secret_context.material,
        envelope,
        secure_result_response_summary(&response),
        &mut pairwise_operation,
    )
}
