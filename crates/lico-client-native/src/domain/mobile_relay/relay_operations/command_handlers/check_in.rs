use super::super::registration::register_local_relay_endpoint;
use crate::domain::mobile_relay::secret_custody::{
    RuntimeSecretContext, load_config_with_runtime_secret_context,
    save_config_with_runtime_secret_context,
};
use anyhow::Result;
use serde_json::Value;

pub fn pc_check_in(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    pc_check_in_with_context(params, &mut config, &mut secret_context)
}

pub(in crate::domain::mobile_relay) fn pc_check_in_with_context(
    params: &Value,
    config: &mut Value,
    secret_context: &mut RuntimeSecretContext,
) -> Result<Value> {
    let (response, _) = register_local_relay_endpoint(params, config, "desktop_sidecar")?;
    save_config_with_runtime_secret_context(config, secret_context)?;
    Ok(response)
}
