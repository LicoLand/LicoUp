use super::material_mutation::ensure_mobile_relay_endpoint_material;
use super::state_codec::local_endpoint_state;
use crate::domain::mobile_relay::endpoint_trust::ensure_mobile_relay_key_transparency;
use anyhow::Result;
use serde_json::Value;

pub(in crate::domain::mobile_relay) fn ensure_mobile_relay_endpoint_descriptor(
    config: &mut Value,
    endpoint_kind: &str,
) -> Result<Value> {
    ensure_mobile_relay_endpoint_material(config, endpoint_kind)?;
    ensure_mobile_relay_key_transparency(config)?;
    local_endpoint_state(config)?.public_descriptor()
}
