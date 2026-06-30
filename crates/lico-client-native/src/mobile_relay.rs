use crate::url_security::is_https_or_loopback_http_url;
use crate::{client_state::ClientStateStore, conversations, runtime_adapters, targets};
use anyhow::{Result, anyhow};
use serde_json::{Map, Value, json};
use std::env;
use std::fs;
use std::path::PathBuf;
use uuid::Uuid;

const CONFIG_SCHEMA_VERSION: u32 = 1;
const DEFAULT_GATEWAY_URL: &str = "https://relay.licolite.com";
const SECURE_MESH_PROTOCOL_VERSION: &str = "licolite.secure-mesh.v1";
const SECURE_MESH_ENVELOPE_COMMAND: &str = "secure_mesh.envelope";
const AGENT_MESSAGE_SEND_PAYLOAD_FIELDS: &[&str] = &[
    "agent",
    "agentId",
    "target",
    "text",
    "message",
    "prompt",
    "sessionId",
    "nativeSessionId",
    "cwd",
    "workingDirectory",
    "timeoutMs",
    "maxStdoutBytes",
    "maxStderrBytes",
];
const AGENT_MESSAGE_SEND_LOCAL_RUNTIME_FIELDS: &[&str] = &[
    "command",
    "args",
    "stdin",
    "executable",
    "binaryPath",
    "commandPath",
    "env",
    "environment",
    "shell",
];

pub fn config_get() -> Result<Value> {
    let config = load_config()?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "config": config
    }))
}

pub fn config_set(params: &Value) -> Result<Value> {
    let mut config = load_config()?;
    if let Some(value) = text_param(params, &["defaultGatewayUrl"]) {
        config["defaultGatewayUrl"] = json!(non_empty_gateway(&value, DEFAULT_GATEWAY_URL));
    }
    if let Some(value) = text_param(params, &["customGatewayUrl", "gatewayUrl"]) {
        config["customGatewayUrl"] = json!(normalize_gateway(&value));
    }
    if let Some(value) = bool_param(params, &["useCustomGateway"]) {
        config["useCustomGateway"] = json!(value);
    }
    if let Some(value) = bool_param(params, &["relayEnabled"]) {
        config["relayEnabled"] = json!(value);
    }
    save_config(&config)?;
    Ok(json!({
        "ok": true,
        "status": "saved",
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "config": config
    }))
}

pub fn pairing_create(params: &Value) -> Result<Value> {
    let mut config = load_config()?;
    let targets = relay_targets(params)?;
    let response = post_json(
        &config,
        "/api/mobile-relay/pairings",
        "",
        json!({
            "pcClientId": config.get("pcClientId").and_then(Value::as_str).unwrap_or_default(),
            "pcClientName": config.get("pcClientName").and_then(Value::as_str).unwrap_or("LicoLite PC Client"),
            "targets": targets,
            "capabilities": relay_capabilities()
        }),
    )?;
    apply_pairing_response(&mut config, &response);
    config["relayEnabled"] = json!(true);
    save_config(&config)?;
    Ok(with_config(response, &config))
}

pub fn pairing_claim(params: &Value) -> Result<Value> {
    let config = load_config()?;
    let pairing_id = text_param(params, &["pairingId", "pairing_id"])
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            config
                .get("pairingId")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires --pairing-id"))?;
    let code = text_param(params, &["pairingCode", "code"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires --pairing-code"))?;
    post_json(
        &config,
        "/api/mobile-relay/pairings/claim",
        "",
        json!({
            "pairingId": pairing_id,
            "pairingCode": code,
            "mobileDeviceName": text_param(params, &["mobileDeviceName", "deviceName"]).unwrap_or_else(|| "LicoLite Mobile CLI".to_string()),
            "mobileDeviceId": text_param(params, &["mobileDeviceId", "deviceId"]).unwrap_or_else(|| format!("mobile_{}", Uuid::new_v4())),
            "platform": text_param(params, &["platform"]).unwrap_or_else(|| "cli".to_string())
        }),
    )
}

pub fn pairing_status(params: &Value) -> Result<Value> {
    let mut config = load_config()?;
    let response = post_json(
        &config,
        "/api/mobile-relay/pairings/status",
        &pc_token(params, &config)?,
        json!({
            "pairingId": pairing_id(params, &config)?
        }),
    )?;
    apply_pairing_status(&mut config, &response);
    save_config(&config)?;
    Ok(with_config(response, &config))
}

pub fn pairing_revoke(params: &Value) -> Result<Value> {
    let mut config = load_config()?;
    let token = text_param(params, &["token", "mobileToken"]).unwrap_or(pc_token(params, &config)?);
    let response = post_json(
        &config,
        "/api/mobile-relay/pairings/revoke",
        &token,
        json!({
            "pairingId": pairing_id(params, &config)?
        }),
    )?;
    config["paired"] = json!(false);
    config["relayEnabled"] = json!(false);
    save_config(&config)?;
    Ok(with_config(response, &config))
}

pub fn pc_check_in(params: &Value) -> Result<Value> {
    let config = load_config()?;
    post_json(
        &config,
        "/api/mobile-relay/pc/check-in",
        &pc_token(params, &config)?,
        json!({
            "pairingId": pairing_id(params, &config)?,
            "targets": relay_targets(params)?,
            "clientVersion": "lico-client-native",
            "capabilities": relay_capabilities()
        }),
    )
}

pub fn commands_poll(params: &Value) -> Result<Value> {
    let config = load_config()?;
    post_json(
        &config,
        "/api/mobile-relay/commands/poll",
        &pc_token(params, &config)?,
        json!({
            "pairingId": pairing_id(params, &config)?,
            "limit": params.get("limit").and_then(Value::as_u64).unwrap_or(10),
            "leaseMs": params.get("leaseMs").and_then(Value::as_u64).unwrap_or(30_000)
        }),
    )
}

pub fn command_complete(params: &Value) -> Result<Value> {
    let config = load_config()?;
    let command_id = text_param(params, &["commandId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command complete requires --command-id"))?;
    let ok = bool_param(params, &["ok"]).unwrap_or(true);
    let result_envelope = secure_envelope_param(params)
        .ok_or_else(|| anyhow!("mobile relay command complete requires --secure-envelope"))?;
    post_json(
        &config,
        &format!("/api/mobile-relay/commands/{}/complete", command_id),
        &pc_token(params, &config)?,
        json!({
            "pairingId": pairing_id(params, &config)?,
            "ok": ok,
            "secureEnvelope": result_envelope
        }),
    )
}

pub fn command_create(params: &Value) -> Result<Value> {
    let config = load_config()?;
    let command_type = text_param(params, &["type", "commandType"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| SECURE_MESH_ENVELOPE_COMMAND.to_string());
    let secure_envelope = secure_envelope_param(params)
        .ok_or_else(|| anyhow!("mobile relay command create requires --secure-envelope"))?;
    let token = text_param(params, &["mobileToken", "token"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command create requires --mobile-token"))?;
    post_json(
        &config,
        "/api/mobile-relay/commands",
        &token,
        json!({
            "pairingId": pairing_id(params, &config)?,
            "type": command_type,
            "payload": {
                "envelope": secure_envelope
            }
        }),
    )
}

pub fn command_result(params: &Value) -> Result<Value> {
    let config = load_config()?;
    let command_id = text_param(params, &["commandId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command result requires --command-id"))?;
    let token = text_param(params, &["mobileToken", "token"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command result requires --mobile-token"))?;
    post_json(
        &config,
        &format!("/api/mobile-relay/commands/{}/result", command_id),
        &token,
        json!({
            "pairingId": pairing_id(params, &config)?
        }),
    )
}

pub fn commands_sync(params: &Value) -> Result<Value> {
    let check_in = pc_check_in(params)?;
    let polled = commands_poll(params)?;
    let commands = polled
        .get("commands")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut completed = Vec::<Value>::new();
    for command in &commands {
        let execution = execute_command(command);
        let command_id = command
            .get("commandId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let (ok, result, error) = match execution {
            Ok(value) => (true, value, String::new()),
            Err(error) => (
                false,
                json!({
                    "commandId": command_id,
                    "type": command.get("type").cloned().unwrap_or_else(|| json!(""))
                }),
                error.to_string(),
            ),
        };
        completed.push(json!({
            "command": command,
            "ok": ok,
            "result": result,
            "error": error,
            "completion": {
                "ok": false,
                "code": "secure_mesh_endpoint_crypto_runtime_required"
            }
        }));
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "checkIn": check_in,
        "commands": commands,
        "completed": completed
    }))
}

fn execute_command(command: &Value) -> Result<Value> {
    let command_type = command
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload = command.get("payload").cloned().unwrap_or_else(|| json!({}));
    match command_type {
        "secure_mesh.envelope" | "secure-mesh.envelope" => Err(anyhow!(
            "secure mesh relay envelope requires endpoint cryptographic runtime"
        )),
        "targets.scan" => targets::scan_targets_with_params(&json!({})),
        "agent.sessions.list" => {
            require_dev_plaintext_compat(command_type)?;
            let agent = text_param(&payload, &["agentId", "target"])
                .filter(|value| !value.is_empty())
                .ok_or_else(|| anyhow!("agent.sessions.list requires agentId"))?;
            let mut params = json!({
                "agent": agent
            });
            if let Some(root) = text_param(&payload, &["root", "historyRoot"]) {
                params["root"] = json!(root);
            }
            conversations::conversation_list(&params)
        }
        "agent.message.send" => {
            require_dev_plaintext_compat(command_type)?;
            let safe_payload = relay_agent_message_payload(&payload)?;
            runtime_adapters::send_message(&safe_payload)
        }
        _ => Err(anyhow!(
            "unsupported mobile relay command: {}",
            command_type
        )),
    }
}

fn relay_agent_message_payload(payload: &Value) -> Result<Value> {
    for key in AGENT_MESSAGE_SEND_LOCAL_RUNTIME_FIELDS {
        if payload.get(*key).is_some() {
            return Err(anyhow!(
                "mobile relay agent.message.send cannot carry local runtime execution field: {}",
                key
            ));
        }
    }
    let mut safe = Map::new();
    if let Some(object) = payload.as_object() {
        for key in AGENT_MESSAGE_SEND_PAYLOAD_FIELDS {
            if let Some(value) = object.get(*key) {
                safe.insert((*key).to_string(), value.clone());
            }
        }
    }
    Ok(Value::Object(safe))
}

fn require_dev_plaintext_compat(command_type: &str) -> Result<()> {
    if env::var("LICO_MOBILE_RELAY_DEV_PLAINTEXT_COMPAT")
        .ok()
        .as_deref()
        == Some("1")
    {
        return Ok(());
    }
    Err(anyhow!(
        "mobile relay command {} requires SecureEnvelope transport",
        command_type
    ))
}

fn secure_envelope_param(params: &Value) -> Option<Value> {
    let envelope = json_param(params, "secureEnvelope")
        .or_else(|| json_param(params, "envelope"))
        .or_else(|| {
            json_param(params, "payload").and_then(|payload| {
                payload
                    .get("envelope")
                    .cloned()
                    .or_else(|| payload.get("secureEnvelope").cloned())
            })
        })?;
    if validate_secure_envelope(&envelope).is_ok() {
        Some(envelope)
    } else {
        None
    }
}

fn validate_secure_envelope(envelope: &Value) -> Result<()> {
    let object = envelope
        .as_object()
        .ok_or_else(|| anyhow!("secure envelope must be a JSON object"))?;
    let protocol = object
        .get("protocolVersion")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if protocol != SECURE_MESH_PROTOCOL_VERSION {
        return Err(anyhow!("secure envelope protocol version is unsupported"));
    }
    for key in [
        "envelopeId",
        "opaqueMailboxId",
        "messageId",
        "cipherSuite",
        "createdAt",
        "expiresAt",
        "encryptedHeader",
        "ciphertext",
    ] {
        if object
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .is_empty()
        {
            return Err(anyhow!("secure envelope missing {}", key));
        }
    }
    if object
        .get("ciphertextSize")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        == 0
    {
        return Err(anyhow!("secure envelope missing ciphertextSize"));
    }
    Ok(())
}

fn relay_capabilities() -> Value {
    json!({
        "commands": [
            SECURE_MESH_ENVELOPE_COMMAND
        ],
        "transports": [
            "MobileRelayCompatibilityTransport"
        ],
        "protocolVersion": SECURE_MESH_PROTOCOL_VERSION
    })
}

fn load_config() -> Result<Value> {
    let path = config_path()?;
    let raw = if path.exists() {
        fs::read_to_string(&path).unwrap_or_default()
    } else {
        String::new()
    };
    let parsed = serde_json::from_str::<Value>(&raw).unwrap_or_else(|_| json!({}));
    let config = normalize_config(parsed);
    if !path.exists() {
        save_config(&config)?;
    }
    Ok(config)
}

fn save_config(config: &Value) -> Result<()> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", Uuid::new_v4()));
    fs::write(&tmp, format!("{}\n", serde_json::to_string_pretty(config)?))?;
    fs::rename(tmp, path)?;
    Ok(())
}

fn config_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("config.json"))
}

fn normalize_config(value: Value) -> Value {
    let defaults = default_config();
    let object = value.as_object().cloned().unwrap_or_default();
    let mut merged = defaults.as_object().cloned().unwrap_or_default();
    for (key, value) in object {
        merged.insert(key, value);
    }
    merged.insert("schemaVersion".to_string(), json!(CONFIG_SCHEMA_VERSION));
    let default_gateway = merged
        .get("defaultGatewayUrl")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_GATEWAY_URL)
        .to_string();
    merged.insert(
        "defaultGatewayUrl".to_string(),
        json!(non_empty_gateway(&default_gateway, DEFAULT_GATEWAY_URL)),
    );
    if let Some(custom) = merged.get("customGatewayUrl").and_then(Value::as_str) {
        merged.insert(
            "customGatewayUrl".to_string(),
            json!(normalize_gateway(custom)),
        );
    }
    Value::Object(merged)
}

fn default_config() -> Value {
    json!({
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "defaultGatewayUrl": non_empty_gateway(
            &env::var("LICO_MOBILE_RELAY_GATEWAY_URL").unwrap_or_default(),
            DEFAULT_GATEWAY_URL
        ),
        "useCustomGateway": false,
        "customGatewayUrl": "",
        "pcClientId": format!("pc_{}", Uuid::new_v4()),
        "pcClientName": host_name(),
        "pairingId": "",
        "pcToken": "",
        "lastPairingCode": "",
        "lastPairingExpiresAt": "",
        "paired": false,
        "relayEnabled": false,
        "pollIntervalSeconds": 5
    })
}

fn host_name() -> String {
    env::var("HOSTNAME")
        .or_else(|_| env::var("COMPUTERNAME"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "LicoLite PC Client".to_string())
}

fn effective_gateway_url(config: &Value) -> Result<String> {
    let custom = config
        .get("customGatewayUrl")
        .and_then(Value::as_str)
        .map(normalize_gateway)
        .unwrap_or_default();
    let fallback = config
        .get("defaultGatewayUrl")
        .and_then(Value::as_str)
        .map(|value| non_empty_gateway(value, DEFAULT_GATEWAY_URL))
        .unwrap_or_else(|| DEFAULT_GATEWAY_URL.to_string());
    let url = if config
        .get("useCustomGateway")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && !custom.is_empty()
    {
        custom
    } else {
        fallback
    };
    validate_gateway(&url)?;
    Ok(url)
}

fn validate_gateway(url: &str) -> Result<()> {
    if is_https_or_loopback_http_url(url) {
        return Ok(());
    }
    Err(anyhow!(
        "mobile relay gateway must use https://, http://127.0.0.1, or http://localhost"
    ))
}

fn post_json(config: &Value, path: &str, token: &str, body: Value) -> Result<Value> {
    let url = format!("{}{}", effective_gateway_url(config)?, path);
    let mut request = ureq::post(&url)
        .set("accept", "application/json")
        .set("content-type", "application/json");
    if !token.trim().is_empty() {
        request = request.set("authorization", &format!("Bearer {}", token.trim()));
    }
    match request.send_json(body) {
        Ok(response) => Ok(response.into_json::<Value>().unwrap_or_else(|_| json!({}))),
        Err(ureq::Error::Status(status, response)) => {
            let payload = response.into_json::<Value>().unwrap_or_else(|_| json!({}));
            Err(anyhow!(
                "mobile relay request failed with status {}: {}",
                status,
                payload
            ))
        }
        Err(error) => Err(anyhow!("mobile relay request failed: {}", error)),
    }
}

fn relay_targets(params: &Value) -> Result<Value> {
    if let Some(targets) = params.get("targets").filter(|value| value.is_array()) {
        return Ok(targets.clone());
    }
    if let Some(targets) = json_param(params, "targetsJson").filter(|value| value.is_array()) {
        return Ok(targets);
    }
    let scan = targets::scan_targets_with_params(&json!({}))?;
    Ok(scan.get("candidates").cloned().unwrap_or_else(|| json!([])))
}

fn apply_pairing_response(config: &mut Value, response: &Value) {
    if let Some(pairing_id) = response.get("pairingId").and_then(Value::as_str) {
        config["pairingId"] = json!(pairing_id);
    }
    if let Some(pc_token) = response.get("pcToken").and_then(Value::as_str) {
        config["pcToken"] = json!(pc_token);
    }
    if let Some(code) = response.get("pairingCode").and_then(Value::as_str) {
        config["lastPairingCode"] = json!(code);
    }
    if let Some(expires_at) = response.get("expiresAt").and_then(Value::as_str) {
        config["lastPairingExpiresAt"] = json!(expires_at);
    }
    apply_pairing_status(config, response);
}

fn apply_pairing_status(config: &mut Value, response: &Value) {
    let status = response
        .get("pairing")
        .and_then(|pairing| pairing.get("status"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !status.is_empty() {
        config["paired"] = json!(status == "paired");
    }
}

fn with_config(mut response: Value, config: &Value) -> Value {
    if let Some(object) = response.as_object_mut() {
        object.insert("config".to_string(), config.clone());
        return response;
    }
    json!({
        "ok": true,
        "response": response,
        "config": config
    })
}

fn pairing_id(params: &Value, config: &Value) -> Result<String> {
    text_param(params, &["pairingId"])
        .or_else(|| {
            config
                .get("pairingId")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay pairing id is missing"))
}

fn pc_token(params: &Value, config: &Value) -> Result<String> {
    text_param(params, &["pcToken", "token"])
        .or_else(|| {
            config
                .get("pcToken")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay PC token is missing"))
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

fn bool_param(params: &Value, keys: &[&str]) -> Option<bool> {
    for key in keys {
        if let Some(value) = params.get(*key) {
            if let Some(bool_value) = value.as_bool() {
                return Some(bool_value);
            }
            if let Some(text) = value.as_str() {
                return match text.trim().to_lowercase().as_str() {
                    "true" | "1" | "yes" | "on" => Some(true),
                    "false" | "0" | "no" | "off" => Some(false),
                    _ => None,
                };
            }
        }
    }
    None
}

fn json_param(params: &Value, key: &str) -> Option<Value> {
    let value = params.get(key)?;
    if value.is_object() || value.is_array() {
        return Some(value.clone());
    }
    value
        .as_str()
        .and_then(|text| serde_json::from_str::<Value>(text).ok())
}

fn normalize_gateway(value: &str) -> String {
    value.trim().trim_end_matches('/').to_string()
}

fn non_empty_gateway(value: &str, fallback: &str) -> String {
    let normalized = normalize_gateway(value);
    if normalized.is_empty() {
        fallback.to_string()
    } else {
        normalized
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::set_portable_data_dir_override;
    use std::env;

    #[test]
    fn mobile_relay_config_defaults_and_private_gateway() {
        let dir = temp_dir("mobile-relay");
        let previous = set_portable_data_dir_override(Some(dir));

        let config = config_get().unwrap();
        assert_eq!(
            config["config"]["defaultGatewayUrl"],
            json!(DEFAULT_GATEWAY_URL)
        );
        assert_eq!(config["config"]["relayEnabled"], false);

        let saved = config_set(&json!({
            "useCustomGateway": "true",
            "customGatewayUrl": "https://relay.example.test/",
            "relayEnabled": "true"
        }))
        .unwrap();
        assert_eq!(saved["config"]["useCustomGateway"], true);
        assert_eq!(
            saved["config"]["customGatewayUrl"],
            "https://relay.example.test"
        );
        assert_eq!(saved["config"]["relayEnabled"], true);

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn invalid_gateway_is_rejected_before_network_call() {
        let dir = temp_dir("mobile-relay-invalid");
        let previous = set_portable_data_dir_override(Some(dir));
        config_set(&json!({
            "useCustomGateway": true,
            "customGatewayUrl": "http://example.test"
        }))
        .unwrap();
        let result = pairing_create(&json!({"targets": []}));
        assert!(result.unwrap_err().to_string().contains("https://"));
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_capabilities_advertise_phone_pairing_runtime_commands() {
        let capabilities = relay_capabilities();
        let commands = capabilities["commands"].as_array().unwrap();
        assert!(
            commands
                .iter()
                .any(|command| command == SECURE_MESH_ENVELOPE_COMMAND)
        );
        assert_eq!(
            capabilities["protocolVersion"],
            json!(SECURE_MESH_PROTOCOL_VERSION)
        );
    }

    #[test]
    fn relay_rejects_unknown_command_types() {
        let error = execute_command(&json!({
            "type": "agent.local.delete",
            "payload": {
                "agentId": "codex"
            }
        }))
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("unsupported mobile relay command")
        );
    }

    #[test]
    fn legacy_agent_sessions_list_is_not_production_default() {
        let dir = temp_dir("mobile-relay-history");
        fs::write(
            dir.join("history.jsonl"),
            r#"{"sessionId":"phone-session","role":"user","content":"Phone lists Codex history"}"#,
        )
        .unwrap();

        let error = execute_command(&json!({
            "type": "agent.sessions.list",
            "payload": {
                "agentId": "codex",
                "root": dir.to_string_lossy()
            }
        }))
        .unwrap_err();

        assert!(error.to_string().contains("requires SecureEnvelope"));
    }

    #[test]
    fn relayed_agent_message_send_requires_secure_envelope() {
        let error = execute_command(&json!({
            "type": "agent.message.send",
            "payload": {
                "agentId": "codex",
                "text": "from-phone",
                "command": "printf",
                "args": ["phone:%s", "{prompt}"],
                "timeoutMs": 5_000
            }
        }))
        .unwrap_err();
        assert!(error.to_string().contains("requires SecureEnvelope"));
    }

    #[test]
    fn secure_mesh_envelope_command_is_transport_only() {
        let error = execute_command(&json!({
            "type": SECURE_MESH_ENVELOPE_COMMAND,
            "payload": {
                "envelope": secure_envelope_fixture()
            }
        }))
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("requires endpoint cryptographic runtime")
        );
        assert!(
            secure_envelope_param(&json!({
                "secureEnvelope": secure_envelope_fixture()
            }))
            .is_some()
        );
    }

    fn secure_envelope_fixture() -> Value {
        json!({
            "protocolVersion": SECURE_MESH_PROTOCOL_VERSION,
            "envelopeId": "env_test",
            "opaqueMailboxId": "mailbox_test",
            "messageId": "msg_test",
            "cipherSuite": "licolite.signal-x3dh-dr.v1.classical",
            "createdAt": "2026-01-01T00:00:00.000Z",
            "expiresAt": "2026-01-01T00:10:00.000Z",
            "ciphertextSize": 32,
            "encryptedHeader": "header",
            "ciphertext": "ciphertext"
        })
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("lico-client-{}-{}", name, Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
