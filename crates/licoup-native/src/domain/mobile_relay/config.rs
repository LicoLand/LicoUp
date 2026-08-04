use crate::platform::url_security::canonical_https_or_loopback_http_origin;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::env;
use uuid::Uuid;

use super::endpoint_trust::{
    clear_mobile_relay_pairing_state, force_reset_local_pairwise_protocol, public_config,
    reset_incompatible_local_pairwise_protocol,
};
use super::secret_custody::{
    CONFIG_SCHEMA_VERSION, apply_selected_paired_device_credentials,
    delete_mobile_relay_pairing_token_secrets, is_unredacted_secret, load_config_for_read,
    load_config_with_runtime_secret_context, save_config_with_runtime_secret_context,
};
use super::support::{bool_param, text_param};

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
    // Validate external station input before opening secret custody, resetting
    // pairing state, or performing any durable write.
    let requested_station_base_url = text_param(params, &["stationBaseUrl"])
        .map(|value| validated_optional_station_base_url(&value))
        .transpose()?;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let reset_pairing = bool_param(params, &["resetPairing"]).unwrap_or(false);
    if reset_pairing {
        delete_mobile_relay_pairing_token_secrets(&config, &mut secret_context.secret_store_batch)?;
        clear_mobile_relay_pairing_state(&mut config)?;
    }
    if let Some(value) = requested_station_base_url {
        config["stationBaseUrl"] = json!(value);
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
    if let Some(value) =
        text_param(params, &["mobileToken"]).filter(|value| is_unredacted_secret(value))
    {
        config["mobileToken"] = json!(value);
    }
    apply_selected_paired_device_credentials(&mut config);
    if let Some(value) = bool_param(params, &["paired"]) {
        config["paired"] = json!(value);
    }
    normalize_station_fields(&mut config);
    if bool_param(params, &["relayEnabled"]) == Some(true) {
        effective_station_base_url(&config)?;
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
    let current_schema = object.get("schemaVersion").and_then(Value::as_u64)
        == Some(u64::from(CONFIG_SCHEMA_VERSION));
    if !current_schema {
        let mut config = defaults;
        force_reset_local_pairwise_protocol(&mut config);
        return config;
    }
    let mut merged = defaults.as_object().cloned().unwrap_or_default();
    for (key, value) in object {
        merged.insert(key, value);
    }
    merged.insert("schemaVersion".to_string(), json!(CONFIG_SCHEMA_VERSION));
    let mut config = Value::Object(merged);
    normalize_station_fields(&mut config);
    let _ = reset_incompatible_local_pairwise_protocol(&mut config);
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

pub(super) fn normalize_station_fields(config: &mut Value) {
    let station_base_url = config
        .get("stationBaseUrl")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    config["stationBaseUrl"] = json!(sanitized_optional_station_base_url(&station_base_url));
    if effective_station_base_url(config).is_err() {
        config["relayEnabled"] = json!(false);
    }
}

pub(super) fn default_config() -> Value {
    json!({
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "configGeneration": 0,
        "securityAuthorityGeneration": 0,
        "stationBaseUrl": sanitized_optional_station_base_url(
            &env::var("LICO_MOBILE_RELAY_STATION_BASE_URL").unwrap_or_default()
        ),
        "pcClientId": format!("pc_{}", Uuid::new_v4()),
        "pcClientName": "LicoUp",
        "pairingId": "",
        "pcToken": "",
        "lastPairingCode": "",
        "lastPairingExpiresAt": "",
        "paired": false,
        "relayEnabled": false,
        "pollIntervalSeconds": 5
    })
}

pub(super) fn effective_station_base_url(config: &Value) -> Result<String> {
    let value = config
        .get("stationBaseUrl")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let url = validated_optional_station_base_url(value)?;
    if url.is_empty() {
        Err(anyhow!(
            "mobile relay station is not configured; configure a station before enabling relay"
        ))
    } else {
        Ok(url)
    }
}

pub(super) fn validated_station_base_url(value: &str) -> Result<String> {
    canonical_https_or_loopback_http_origin(value).ok_or_else(|| {
        anyhow!(
            "mobile relay station must be a canonical HTTPS origin or exact loopback HTTP origin"
        )
    })
}

fn validated_optional_station_base_url(value: &str) -> Result<String> {
    if value.trim().is_empty() {
        Ok(String::new())
    } else {
        validated_station_base_url(value)
    }
}

fn sanitized_optional_station_base_url(value: &str) -> String {
    validated_optional_station_base_url(value).unwrap_or_default()
}

pub(super) fn prepare_station_fields_for_persistence(config: &mut Value) -> Result<()> {
    let station_base_url = validated_optional_station_base_url(
        config
            .get("stationBaseUrl")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )?;
    config["stationBaseUrl"] = json!(station_base_url);
    if config
        .get("relayEnabled")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        effective_station_base_url(config)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn station_policy_accepts_only_canonical_secure_or_loopback_origins() {
        assert_eq!(
            validated_station_base_url("HTTPS://Station.LicoUp.Net:443/").unwrap(),
            "https://station.licoup.net"
        );
        assert_eq!(
            validated_station_base_url("http://127.0.0.1:8787/").unwrap(),
            "http://127.0.0.1:8787"
        );
        assert!(validated_station_base_url("http://station.licoup.net").is_err());
        assert!(validated_station_base_url("https://station.licoup.net/path").is_err());
    }

    #[test]
    fn previous_schema_initializes_fresh_current_state() {
        let mut config = json!({
            "schemaVersion": 1,
            "stationBaseUrl": "https://must-not-migrate.example.test",
            "pcClientName": "must not migrate",
            "mobileRelayE2ee": {"protocolVersion": "retired"}
        });

        config = normalize_config(config);

        assert_eq!(config["schemaVersion"], json!(CONFIG_SCHEMA_VERSION));
        assert_eq!(config["stationBaseUrl"], json!(""));
        assert_eq!(config["pcClientName"], json!("LicoUp"));
        assert_eq!(config["mobileRelayE2ee"], json!({}));
    }

    #[test]
    fn current_schema_preserves_the_canonical_station_base_url() {
        let config = normalize_config(json!({
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "stationBaseUrl": "HTTPS://Station.LicoUp.Net:443/",
            "relayEnabled": true
        }));

        assert_eq!(
            config["stationBaseUrl"],
            json!("https://station.licoup.net")
        );
        assert_eq!(config["relayEnabled"], json!(true));
    }
}
