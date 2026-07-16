use super::super::context::canonical_relay_context;
use super::super::envelope::{relay_envelope_from_value, secure_envelope_param};
use crate::core::secure_mesh_crypto::SecureMeshPayloadKind;
use crate::domain::mobile_relay::endpoint_trust::ensure_peer_verified;
use crate::domain::mobile_relay::pairwise_session::{
    mobile_relay_pairwise_operation_with_runtime_secret_context,
    seal_mobile_relay_payload_with_pairwise_operation, secure_command_payload,
};
use crate::domain::mobile_relay::secret_custody::{
    ensure_secure_mesh_protected_operation_allowed, load_config,
    load_config_with_runtime_secret_context_for_operation,
    mobile_relay_e2ee_secret_store_authorization_batch_operation_count,
};
use crate::domain::mobile_relay::support::{json_param, text_param};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub fn command_create(params: &Value) -> Result<Value> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let config = load_config()?;
    let secure_envelope = secure_envelope_param(params)
        .ok_or_else(|| anyhow!("mobile relay command create requires --secure-envelope"))?;
    let envelope = relay_envelope_from_value(&secure_envelope)?;
    let relay = canonical_relay_context(params, &config)?;
    relay
        .transport
        .envelope_send(&relay.scope, &envelope, Some("mobile_relay"), None)
}

pub fn command_create_secure(params: &Value) -> Result<Value> {
    let (config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay secure command create authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(3),
    )?;
    ensure_peer_verified(&config)?;
    let body = json_param(params, "body")
        .or_else(|| json_param(params, "payload"))
        .unwrap_or_else(|| json!({}));
    let command_kind = text_param(params, &["commandKind", "type", "command"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "agent.message.send".to_string());
    let target_agent_id = text_param(params, &["targetAgentId", "agentId", "agent", "target"]);
    let workspace_id = text_param(params, &["workspaceId", "workspace"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());
    let payload = secure_command_payload(
        &config,
        &command_kind,
        target_agent_id.as_deref(),
        &workspace_id,
        body,
    )?;
    let payload_command_id = payload
        .get("commandId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let payload_idempotency_key = payload
        .get("idempotencyKey")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Mobile Relay secure command create authorization batch",
        3,
        &mut secret_context,
    )?;
    let envelope = seal_mobile_relay_payload_with_pairwise_operation(
        &config,
        SecureMeshPayloadKind::Command,
        &payload,
        &mut pairwise_operation,
    )?;
    let relay = canonical_relay_context(params, &config)?;
    let relay_envelope = relay_envelope_from_value(&envelope)?;
    let mut response =
        relay
            .transport
            .envelope_send(&relay.scope, &relay_envelope, Some("mobile_relay"), None)?;
    response
        .as_object_mut()
        .ok_or_else(|| anyhow!("mobile relay secure command response is invalid"))?
        .insert(
            "secureCommandBinding".to_string(),
            json!({
                "payloadCommandId": payload_command_id,
                "idempotencyKey": payload_idempotency_key,
                "commandKind": command_kind,
            }),
        );
    Ok(response)
}
