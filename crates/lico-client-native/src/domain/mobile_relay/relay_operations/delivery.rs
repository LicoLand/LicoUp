use super::envelope::relay_envelope_from_value;
use crate::core::secure_mesh_relay_envelope::{
    SECURE_MESH_RELAY_OUTER_FIELDS, SecureMeshRelayEnvelope,
};
use crate::domain::mobile_relay::support::SECURE_MESH_ENVELOPE_COMMAND;
use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};

pub(in crate::domain::mobile_relay) fn relay_envelope_from_delivery(
    value: &Value,
) -> Result<SecureMeshRelayEnvelope> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure client relay delivery must be an object"))?;
    let mut envelope = Map::new();
    for field in SECURE_MESH_RELAY_OUTER_FIELDS {
        envelope.insert(
            field.to_string(),
            object
                .get(field)
                .cloned()
                .ok_or_else(|| anyhow!("secure client relay delivery envelope is incomplete"))?,
        );
    }
    relay_envelope_from_value(&Value::Object(envelope))
}

pub(in crate::domain::mobile_relay) fn local_command_from_relay_delivery(
    value: &Value,
) -> Result<Value> {
    let envelope = relay_envelope_from_delivery(value)?;
    Ok(json!({
        "commandId": envelope.delivery_id(),
        "type": SECURE_MESH_ENVELOPE_COMMAND,
        "envelope": serde_json::from_str::<Value>(&envelope.to_json()?)?,
        "leaseId": value.get("leaseId").cloned().unwrap_or(Value::Null),
        "leaseGeneration": value.get("leaseGeneration").cloned().unwrap_or(Value::Null),
        "deliverySequence": value.get("deliverySequence").cloned().unwrap_or(Value::Null)
    }))
}
