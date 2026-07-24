use super::super::registration::register_local_relay_endpoint;
use crate::domain::mobile_relay::secret_custody::RuntimeSecretMaterial;
use anyhow::Result;
use serde_json::Value;

#[test]
fn registration_has_one_explicit_challenge_bound_entrypoint() {
    let entrypoint: fn(
        &Value,
        &mut Value,
        &mut RuntimeSecretMaterial,
        &str,
    ) -> Result<(Value, Value)> = register_local_relay_endpoint;
    let _ = entrypoint;
}
