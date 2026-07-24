use crate::platform::url_security::{
    canonical_https_or_loopback_http_origin, https_or_loopback_http_host,
};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::env;
use uuid::Uuid;

use super::endpoint_trust::{
    clear_mobile_relay_pairing_state, public_config, reset_incompatible_local_pairwise_protocol,
};
use super::secret_custody::{
    CONFIG_SCHEMA_VERSION, apply_selected_paired_device_credentials,
    delete_mobile_relay_pairing_token_secrets, is_unredacted_secret, load_config_for_read,
    load_config_with_runtime_secret_context, save_config_with_runtime_secret_context,
};
use super::support::{bool_param, text_param};

const EPHEMERAL_CUSTOM_GATEWAY_HOST_SUFFIXES: &[&str] = &[".trycloudflare.com"];

/// Read the public, redacted relay configuration without opening secret custody.
pub fn config_get(params: &Value) -> Result<Value> {
    let (config, _) = load_config_for_read(params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "config": public_config(&config)
    }))
}

/// Apply user-controlled relay configuration through one custody authorization context.
pub fn config_set(params: &Value) -> Result<Value> {
    // Validate external gateway input before opening secret custody, resetting
    // pairing state, or performing any durable write.
    let requested_default_gateway = text_param(params, &["defaultGatewayUrl"])
        .map(|value| validated_optional_gateway(&value))
        .transpose()?;
    let requested_custom_gateway = text_param(params, &["customGatewayUrl", "gatewayUrl"])
        .map(|value| validated_optional_custom_gateway(&value))
        .transpose()?;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let reset_pairing = bool_param(params, &["resetPairing"]).unwrap_or(false);
    if reset_pairing {
        delete_mobile_relay_pairing_token_secrets(&config, &mut secret_context.secret_store_batch)?;
        clear_mobile_relay_pairing_state(&mut config)?;
    }
    if let Some(value) = requested_default_gateway {
        config["defaultGatewayUrl"] = json!(value);
    }
    if let Some(value) = requested_custom_gateway {
        config["customGatewayUrl"] = json!(value);
    }
    if let Some(value) = bool_param(params, &["useCustomGateway"]) {
        config["useCustomGateway"] = json!(value);
    }
    if let Some(value) = bool_param(params, &["relayEnabled"]) {
        config["relayEnabled"] = json!(value);
    }
    if let Some(value) = text_param(params, &["pcClientId"]) {
        config["pcClientId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["pcClientName"]) {
        config["pcClientName"] = json!(value);
    }
    if let Some(value) = text_param(params, &["pairingId"]) {
        config["pairingId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["relayTenantId"]) {
        config["relayTenantId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["relayAccountId"]) {
        config["relayAccountId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["relayWorkspaceId"]) {
        config["relayWorkspaceId"] = json!(value);
    }
    if let Some(value) =
        text_param(params, &["mobileToken"]).filter(|value| is_unredacted_secret(value))
    {
        config["mobileToken"] = json!(value);
    }
    apply_selected_paired_device_credentials(&mut config);
    if let Some(value) = bool_param(params, &["paired"]) {
        config["paired"] = json!(value);
    }
    normalize_gateway_fields(&mut config);
    if bool_param(params, &["relayEnabled"]) == Some(true) {
        effective_gateway_url(&config)?;
    }
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(json!({
        "ok": true,
        "status": "saved",
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "config": public_config(&config)
    }))
}

pub(super) fn normalize_config(value: Value) -> Value {
    let defaults = default_config();
    let object = value.as_object().cloned().unwrap_or_default();
    let mut merged = defaults.as_object().cloned().unwrap_or_default();
    for (key, value) in object {
        merged.insert(key, value);
    }
    merged.insert("schemaVersion".to_string(), json!(CONFIG_SCHEMA_VERSION));
    let mut config = Value::Object(merged);
    normalize_gateway_fields(&mut config);
    reset_incompatible_local_pairwise_protocol(&mut config);
    if let Some(object) = config.as_object_mut() {
        object.insert("lastPairingCode".to_string(), json!(""));
        object.insert("lastPairingExpiresAt".to_string(), json!(""));
        object.remove("mobileRelayPairingInvite");
        object.remove("authorizedProviders");
        object.remove("desktopAuthorizedProviders");
        object.remove("modelProviders");
        if let Some(devices) = object
            .get_mut("pairedDevices")
            .and_then(Value::as_array_mut)
        {
            for device in devices {
                if let Some(device) = device.as_object_mut() {
                    device.remove("authorizedProviders");
                }
            }
        }
    }
    config
}

pub(super) fn normalize_gateway_fields(config: &mut Value) {
    let default_gateway_value = config
        .get("defaultGatewayUrl")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    config["defaultGatewayUrl"] = json!(sanitized_optional_gateway(&default_gateway_value));
    let custom_gateway = config
        .get("customGatewayUrl")
        .and_then(Value::as_str)
        .and_then(canonical_https_or_loopback_http_origin)
        .unwrap_or_default();
    if custom_gateway.is_empty() || is_ephemeral_custom_gateway(&custom_gateway) {
        config["customGatewayUrl"] = json!("");
        config["useCustomGateway"] = json!(false);
    } else {
        config["customGatewayUrl"] = json!(custom_gateway);
    }
    if effective_gateway_url(config).is_err() {
        config["relayEnabled"] = json!(false);
    }
}

pub(super) fn default_config() -> Value {
    json!({
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "configGeneration": 0,
        "securityAuthorityGeneration": 0,
        "defaultGatewayUrl": sanitized_optional_gateway(
            &env::var("LICO_MOBILE_RELAY_GATEWAY_URL").unwrap_or_default()
        ),
        "useCustomGateway": false,
        "customGatewayUrl": "",
        "pcClientId": format!("pc_{}", Uuid::new_v4()),
        "pcClientName": "LicoUp",
        "pairingId": "",
        "relayTenantId": "",
        "relayAccountId": "",
        "relayWorkspaceId": "",
        "pcToken": "",
        "lastPairingCode": "",
        "lastPairingExpiresAt": "",
        "paired": false,
        "relayEnabled": false,
        "pollIntervalSeconds": 5
    })
}

pub(super) fn effective_gateway_url(config: &Value) -> Result<String> {
    let fallback_value = config
        .get("defaultGatewayUrl")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let fallback = validated_optional_gateway(fallback_value)?;
    let url = if config
        .get("useCustomGateway")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let custom = validated_optional_custom_gateway(
            config
                .get("customGatewayUrl")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )?;
        if custom.is_empty() || is_ephemeral_custom_gateway(&custom) {
            fallback
        } else {
            custom
        }
    } else {
        fallback
    };
    if url.is_empty() {
        Err(anyhow!(
            "mobile relay gateway is not configured; configure a gateway before enabling relay"
        ))
    } else {
        Ok(url)
    }
}

pub(super) fn validated_gateway(value: &str) -> Result<String> {
    canonical_https_or_loopback_http_origin(value).ok_or_else(|| {
        anyhow!(
            "mobile relay gateway must be a canonical HTTPS origin or exact loopback HTTP origin"
        )
    })
}

fn validated_optional_custom_gateway(value: &str) -> Result<String> {
    if value.trim().is_empty() {
        Ok(String::new())
    } else {
        validated_gateway(value)
    }
}

fn validated_optional_gateway(value: &str) -> Result<String> {
    if value.trim().is_empty() {
        Ok(String::new())
    } else {
        validated_gateway(value)
    }
}

fn sanitized_optional_gateway(value: &str) -> String {
    validated_optional_gateway(value).unwrap_or_default()
}

pub(super) fn prepare_gateway_fields_for_persistence(config: &mut Value) -> Result<()> {
    let default_gateway = validated_optional_gateway(
        config
            .get("defaultGatewayUrl")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )?;
    let custom_gateway = validated_optional_custom_gateway(
        config
            .get("customGatewayUrl")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )?;
    config["defaultGatewayUrl"] = json!(default_gateway);
    if custom_gateway.is_empty() || is_ephemeral_custom_gateway(&custom_gateway) {
        config["customGatewayUrl"] = json!("");
        config["useCustomGateway"] = json!(false);
    } else {
        config["customGatewayUrl"] = json!(custom_gateway);
    }
    if config
        .get("relayEnabled")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        effective_gateway_url(config)?;
    }
    Ok(())
}

fn is_ephemeral_custom_gateway(value: &str) -> bool {
    let host = https_or_loopback_http_host(value)
        .unwrap_or_default()
        .to_ascii_lowercase();
    EPHEMERAL_CUSTOM_GATEWAY_HOST_SUFFIXES
        .iter()
        .any(|suffix| host.ends_with(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gateway_policy_accepts_only_canonical_secure_or_loopback_origins() {
        assert_eq!(
            validated_gateway("HTTPS://Relay.Example.Test:443/").unwrap(),
            "https://relay.example.test"
        );
        assert_eq!(
            validated_gateway("http://127.0.0.1:8787/").unwrap(),
            "http://127.0.0.1:8787"
        );
        assert!(validated_gateway("http://relay.example.test").is_err());
        assert!(validated_gateway("https://relay.example.test/path").is_err());
    }

    #[test]
    fn persistence_policy_removes_ephemeral_custom_gateways() {
        let mut config = json!({
            "defaultGatewayUrl": "https://relay.example.test",
            "customGatewayUrl": "https://temporary.trycloudflare.com",
            "useCustomGateway": true
        });

        prepare_gateway_fields_for_persistence(&mut config).unwrap();

        assert_eq!(config["customGatewayUrl"], json!(""));
        assert_eq!(config["useCustomGateway"], json!(false));
        assert_eq!(
            config["defaultGatewayUrl"],
            json!("https://relay.example.test")
        );
    }
}
