use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use super::endpoint_trust::{ensure_peer_verified, now_iso};
#[cfg(test)]
use super::pairwise_session::mobile_relay_pairwise_operation;
use super::pairwise_session::{
    MobileRelayPairwiseOperation, mobile_relay_pairwise_operation_with_runtime_secret_context,
    open_mobile_relay_payload_with_pairwise_operation,
    seal_mobile_relay_payload_with_pairwise_operation, secure_command_context,
};
use super::relay_operations::{
    command_complete_with_config, commands_poll_with_config, local_command_from_relay_delivery,
    pc_check_in_with_context, validate_secure_envelope,
};
#[cfg(test)]
use super::secret_custody::load_config_with_runtime_secret_context;
use super::secret_custody::{
    CONFIG_SCHEMA_VERSION, RUNTIME_SECRET_OVERRIDE_TRANSPORT, RuntimeSecretMaterial,
    load_config_with_runtime_secret_context_for_operation,
    mobile_relay_e2ee_secret_store_authorization_batch_operation_count,
};
use super::support::{
    SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE,
    SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
};

/// Synchronize relay deliveries using one bounded secret-store authorization context.
pub fn commands_sync(params: &Value) -> Result<Value> {
    let command_limit = params.get("limit").and_then(Value::as_u64).unwrap_or(10) as usize;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay commands sync operation authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
            .saturating_add(command_limit.saturating_mul(4))
            .saturating_add(4),
    )?;
    let check_in = pc_check_in_with_context(params, &mut config, &mut secret_context)?;
    let polled = commands_poll_with_config(params, &config, &secret_context.material)?;
    let deliveries = polled
        .get("envelopes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let commands = deliveries
        .iter()
        .map(local_command_from_relay_delivery)
        .collect::<Result<Vec<_>>>()?;
    let secure_command_count = commands
        .iter()
        .filter(|command| {
            let command_type = command
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            command_type == "secure_mesh.envelope" || command_type == "secure-mesh.envelope"
        })
        .count();
    let pairwise_operation_count = secure_command_count.saturating_mul(4).saturating_add(2);
    let mut pairwise_operation = None;
    let mut completed = Vec::<Value>::new();
    let mut visible_commands = Vec::<Value>::new();
    for command in &commands {
        let command_id = command
            .get("commandId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let command_type = command
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let redacted_command = redacted_relay_command(command);
        visible_commands.push(redacted_command.clone());
        if command_type == "secure_mesh.envelope" || command_type == "secure-mesh.envelope" {
            if pairwise_operation.is_none() {
                match mobile_relay_pairwise_operation_with_runtime_secret_context(
                    &config,
                    "Mobile Relay commands sync operation authorization batch",
                    pairwise_operation_count,
                    &mut secret_context,
                ) {
                    Ok(operation) => {
                        pairwise_operation = Some(operation);
                    }
                    Err(_error) => {
                        completed.push(json!({
                            "command": redacted_command,
                            "ok": false,
                            "bodyRedacted": true,
                            "error": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
                            "completion": {
                                "ok": false,
                                "code": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE
                            }
                        }));
                        continue;
                    }
                }
            }
            let operation = pairwise_operation
                .as_mut()
                .ok_or_else(|| anyhow!("mobile relay commands sync authorization batch missing"))?;
            match execute_secure_envelope_command_with_pairwise_operation(
                command,
                params,
                &config,
                &secret_context.material,
                operation,
            ) {
                Ok(result_envelope) => {
                    let mut completion_params = json!({
                        "commandId": command_id,
                        "ok": true,
                        "resultEnvelope": result_envelope,
                        "leaseId": command.get("leaseId").cloned().unwrap_or(Value::Null),
                        "leaseGeneration": command.get("leaseGeneration").cloned().unwrap_or(Value::Null)
                    });
                    attach_runtime_secret_overrides_param(&mut completion_params, params);
                    attach_canonical_relay_params(&mut completion_params, params);
                    let completion = command_complete_with_config(
                        &completion_params,
                        &config,
                        &secret_context.material,
                    )?;
                    completed.push(json!({
                        "command": redacted_command,
                        "ok": true,
                        "bodyRedacted": true,
                        "resultEnvelope": result_envelope,
                        "completion": completion
                    }));
                }
                Err(_error) => {
                    completed.push(json!({
                        "command": redacted_command,
                        "ok": false,
                        "bodyRedacted": true,
                        "error": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
                        "completion": {
                            "ok": false,
                            "code": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE
                        }
                    }));
                }
            }
            continue;
        }
        let mut rejection = reject_plaintext_relay_command(command);
        if let Some(object) = rejection.as_object_mut() {
            object.insert("command".to_string(), redacted_command);
        }
        completed.push(rejection);
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "checkIn": check_in,
        "commands": visible_commands,
        "completed": completed
    }))
}

fn reject_plaintext_relay_command(command: &Value) -> Value {
    let command_type = command
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let command_label = if command_type.is_empty() {
        "<missing>"
    } else {
        command_type
    };
    json!({
        "ok": false,
        "bodyRedacted": true,
        "error": format!(
            "mobile relay plaintext command {} requires SecureEnvelope transport",
            command_label
        ),
        "completion": {
            "ok": false,
            "code": "mobile_relay_plaintext_command_rejected"
        }
    })
}

pub(super) fn redacted_relay_command(command: &Value) -> Value {
    json!({
        "commandId": command.get("commandId").and_then(Value::as_str).unwrap_or_default(),
        "type": command.get("type").and_then(Value::as_str).unwrap_or_default(),
        "bodyRedacted": true,
        "secureEnvelopePresent": command_has_secure_envelope(command)
    })
}

fn command_has_secure_envelope(command: &Value) -> bool {
    command.get("envelope").is_some_and(Value::is_object)
        || command
            .get("payload")
            .and_then(|payload| payload.get("envelope"))
            .is_some_and(Value::is_object)
}

fn attach_runtime_secret_overrides_param(target: &mut Value, source: &Value) {
    if source
        .get("secretOverrideTransport")
        .and_then(Value::as_str)
        .map(str::trim)
        != Some(RUNTIME_SECRET_OVERRIDE_TRANSPORT)
    {
        return;
    }
    if let Some(overrides) = source
        .get("secretOverrides")
        .filter(|value| value.is_object())
    {
        target["secretOverrideTransport"] = json!(RUNTIME_SECRET_OVERRIDE_TRANSPORT);
        target["secretOverrides"] = overrides.clone();
    }
}

fn attach_canonical_relay_params(target: &mut Value, source: &Value) {
    for key in [
        "relaySessionToken",
        "relayCsrfToken",
        "relayTenantId",
        "relayAccountId",
        "relayWorkspaceId",
    ] {
        if let Some(value) = source.get(key).and_then(Value::as_str) {
            target[key] = json!(value);
        }
    }
}

#[cfg(test)]
pub(super) fn execute_secure_envelope_command(command: &Value, params: &Value) -> Result<Value> {
    let (config, secret_context) = load_config_with_runtime_secret_context(params)?;
    ensure_peer_verified(&config)?;
    let mut pairwise_operation = mobile_relay_pairwise_operation(
        &config,
        &secret_context.material,
        "Mobile Relay secure command operation authorization batch",
        5,
    )?;
    execute_secure_envelope_command_with_pairwise_operation(
        command,
        params,
        &config,
        &secret_context.material,
        &mut pairwise_operation,
    )
}

fn execute_secure_envelope_command_with_pairwise_operation(
    command: &Value,
    params: &Value,
    config: &Value,
    secret_material: &RuntimeSecretMaterial,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
) -> Result<Value> {
    ensure_peer_verified(config)?;
    let envelope = command
        .get("envelope")
        .cloned()
        .ok_or_else(|| anyhow!("secure mesh relay command is missing envelope"))?;
    validate_secure_envelope(&envelope)?;
    let opened = open_mobile_relay_payload_with_pairwise_operation(
        config,
        secret_material,
        &envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        pairwise_operation,
    )?;
    let payload: Value = serde_json::from_slice(&opened)
        .map_err(|error| anyhow!("secure mesh command payload is not JSON: {}", error))?;
    let context = secure_command_context(config, secret_material, params, &payload)?;
    let ledger_path =
        crate::domain::secure_mesh_command_runtime::default_secure_command_ledger_path()?;
    let mut ledger =
        crate::core::secure_mesh_command::SecureCommandSqliteReplayLedger::open(ledger_path)?;
    let mut executor = crate::domain::secure_mesh_command_runtime::SecureCommandRuntimeExecutor;
    let completed_at = now_iso();
    let execution = crate::core::secure_mesh_command::execute_secure_command_json(
        &payload,
        &context,
        &mut ledger,
        &mut executor,
        completed_at,
    )
    .unwrap_or_else(|_error| {
        json!({
            "ok": false,
            "protocolVersion": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "code": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE,
            "error": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
            "bodyRedacted": true
        })
    });
    seal_mobile_relay_payload_with_pairwise_operation(
        config,
        secret_material,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        &execution,
        pairwise_operation,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_visibility_policy_redacts_plaintext_and_reports_envelope_presence() {
        let command = json!({
            "commandId": "cmd-test",
            "type": "plaintext.command",
            "payload": {
                "sensitive": "must-not-escape",
                "envelope": {}
            }
        });

        let visible = redacted_relay_command(&command);
        let rejection = reject_plaintext_relay_command(&command);

        assert_eq!(visible["commandId"], json!("cmd-test"));
        assert_eq!(visible["secureEnvelopePresent"], json!(true));
        assert!(visible.get("payload").is_none());
        assert_eq!(
            rejection["completion"]["code"],
            json!("mobile_relay_plaintext_command_rejected")
        );
        assert_eq!(rejection["bodyRedacted"], json!(true));
    }

    #[test]
    fn runtime_secret_overrides_require_the_memory_transport_marker() {
        let mut without_marker = json!({});
        attach_runtime_secret_overrides_param(
            &mut without_marker,
            &json!({"secretOverrides": {"pcToken": "test-only"}}),
        );
        assert!(without_marker.get("secretOverrides").is_none());

        let mut with_marker = json!({});
        attach_runtime_secret_overrides_param(
            &mut with_marker,
            &json!({
                "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                "secretOverrides": {"pcToken": "test-only"}
            }),
        );
        assert!(with_marker["secretOverrides"].is_object());
    }
}
