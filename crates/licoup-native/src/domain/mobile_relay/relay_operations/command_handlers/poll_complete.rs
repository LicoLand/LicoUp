use super::super::context::canonical_relay_context;
use super::super::envelope::{relay_envelope_from_value, validate_secure_envelope};
use super::super::mailbox::local_canonical_mailbox_token;
use crate::domain::mobile_relay::secret_custody::{
    RuntimeSecretMaterial, load_config_with_runtime_secret_context,
};
use crate::domain::mobile_relay::support::{CONFIG_SCHEMA_VERSION, text_param};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub fn commands_poll(params: &Value) -> Result<Value> {
    let (config, secret_context) = load_config_with_runtime_secret_context(params)?;
    commands_poll_with_config(params, &config, &secret_context.material)
}

pub(in crate::domain::mobile_relay) fn commands_poll_with_config(
    params: &Value,
    config: &Value,
    secret_material: &RuntimeSecretMaterial,
) -> Result<Value> {
    let relay = canonical_relay_context(params, config)?;
    relay.transport.envelope_sync(
        &relay.scope,
        &local_canonical_mailbox_token(config, secret_material)?,
        params.get("afterDeliverySequence").and_then(Value::as_u64),
        Some(params.get("limit").and_then(Value::as_u64).unwrap_or(10)),
        Some(
            params
                .get("leaseMs")
                .and_then(Value::as_u64)
                .unwrap_or(30_000),
        ),
    )
}

pub fn command_complete(params: &Value) -> Result<Value> {
    let (config, secret_context) = load_config_with_runtime_secret_context(params)?;
    command_complete_with_config(params, &config, &secret_context.material)
}

pub(in crate::domain::mobile_relay) fn command_complete_with_config(
    params: &Value,
    config: &Value,
    secret_material: &RuntimeSecretMaterial,
) -> Result<Value> {
    let command_id = text_param(params, &["commandId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command complete requires --command-id"))?;
    let result_envelope = params
        .get("resultEnvelope")
        .filter(|value| validate_secure_envelope(value).is_ok())
        .cloned()
        .ok_or_else(|| anyhow!("mobile relay command complete requires --result-envelope"))?;
    let lease_id = text_param(params, &["leaseId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command complete requires --lease-id"))?;
    let lease_generation = params
        .get("leaseGeneration")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .ok_or_else(|| anyhow!("mobile relay command complete requires --lease-generation"))?;
    let relay = canonical_relay_context(params, config)?;
    let result_envelope = relay_envelope_from_value(&result_envelope)?;
    let send = relay.transport.envelope_send(
        &relay.scope,
        &result_envelope,
        Some("mobile_relay"),
        None,
    )?;
    let ack = relay.transport.envelope_ack(
        &relay.scope,
        &local_canonical_mailbox_token(config, secret_material)?,
        &command_id,
        &lease_id,
        lease_generation,
    )?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "resultSend": send,
        "ack": ack
    }))
}
