use crate::platform::client_state::ClientStateStore;
use crate::platform::local_runtime;
use crate::platform::url_security::is_loopback_http_url;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MCP_LOCAL_BRIDGE_SCHEMA_VERSION: &str = "v0.0.1:mcp-local-bridge-1";
const MCP_LOCAL_BRIDGE_DIR: &str = "mcp-local-bridge";
const DEFAULT_PORT: u16 = 17328;
const BRIDGE_PATH: &str = "/api/client-local-runtime/mcp-local-bridge";

pub fn plan(params: &Value) -> Result<Value> {
    Ok(plan_payload(params, None))
}

pub fn start(params: &Value) -> Result<Value> {
    let runtime = local_runtime::start(params)?;
    Ok(plan_payload(params, Some(runtime)))
}

pub fn stop(params: &Value) -> Result<Value> {
    let runtime = local_runtime::stop(params)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": MCP_LOCAL_BRIDGE_SCHEMA_VERSION,
        "status": "stopped",
        "serviceHubBoundary": "http-loopback-bridge-only",
        "directServiceHubStdio": false,
        "runtime": runtime
    }))
}

pub fn status(params: &Value) -> Result<Value> {
    let runtime = local_runtime::status(params)?;
    Ok(plan_payload(params, Some(runtime)))
}

pub fn register(params: &Value) -> Result<Value> {
    let endpoint = bridge_endpoint(params, None);
    if !is_loopback_http_url(&endpoint) {
        return Err(anyhow!(
            "mcp local bridge registration endpoint must use http://127.0.0.1, http://localhost, or http://[::1]"
        ));
    }
    let registration_id = text_param(params, &["registrationId", "id"]).unwrap_or_else(|| {
        let digest = sha256_hex(endpoint.as_bytes());
        format!("mcp-local-bridge-{}", &digest[..16])
    });
    let root = bridge_root(params)?;
    let registrations_dir = root.join("registrations");
    fs::create_dir_all(&registrations_dir)?;
    let registration_path = registrations_dir.join(format!("{}.json", registration_id));
    let document = json!({
        "schemaVersion": MCP_LOCAL_BRIDGE_SCHEMA_VERSION,
        "registrationId": registration_id,
        "status": "planned",
        "serviceHubBoundary": "http-loopback-bridge-only",
        "directServiceHubStdio": false,
        "createdAt": timestamp(),
        "externalService": {
            "kind": "mcp",
            "transport": "streamable-http",
            "url": endpoint,
            "toolsOnly": true,
            "localRuntimeClaimRequired": true,
            "egress": {
                "mode": "loopback-only",
                "allowedHosts": ["127.0.0.1", "localhost"]
            }
        },
        "serviceHub": {
            "operation": "register_external_service",
            "allowedTransports": ["streamable-http", "sse"],
            "forbiddenTransports": ["stdio"],
            "promotionRollbackRequired": true,
            "receiptRequired": true,
            "outputGovernanceRequired": true
        }
    });
    fs::write(&registration_path, serde_json::to_vec_pretty(&document)?)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": MCP_LOCAL_BRIDGE_SCHEMA_VERSION,
        "status": "registration_planned",
        "registration": document,
        "registrationPath": display_path(&registration_path)
    }))
}

fn plan_payload(params: &Value, runtime: Option<Value>) -> Value {
    let endpoint = bridge_endpoint(params, runtime.as_ref());
    json!({
        "ok": true,
        "schemaVersion": MCP_LOCAL_BRIDGE_SCHEMA_VERSION,
        "status": "planned",
        "endpoint": endpoint,
        "transport": "http-loopback",
        "mcpTransport": "streamable-http",
        "serviceHubBoundary": "http-loopback-bridge-only",
        "directServiceHubStdio": false,
        "installCommand": "lico-client local-runtime ensure",
        "startCommand": "lico-client mcp-local-bridge start",
        "registerCommand": "lico-client mcp-local-bridge register",
        "runtime": runtime.unwrap_or_else(|| json!(null))
    })
}

fn bridge_endpoint(params: &Value, runtime: Option<&Value>) -> String {
    if let Some(endpoint) = text_param(params, &["endpoint", "url"]) {
        return endpoint;
    }
    let server_url = runtime
        .and_then(|value| value.get("serverUrl"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .or_else(|| text_param(params, &["serverUrl"]))
        .unwrap_or_else(|| {
            let port = number_param(params, &["port"]).unwrap_or(DEFAULT_PORT as u64);
            format!("http://127.0.0.1:{}", port)
        });
    format!("{}{}", server_url.trim_end_matches('/'), BRIDGE_PATH)
}

fn bridge_root(params: &Value) -> Result<PathBuf> {
    let root = if let Some(state_root) = text_param(params, &["stateRoot", "root"]) {
        PathBuf::from(state_root)
    } else {
        ClientStateStore::portable()?.root().to_path_buf()
    };
    Ok(root.join(MCP_LOCAL_BRIDGE_DIR))
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

fn number_param(params: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse::<u64>().ok()))
        })
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}.{:09}Z", now.as_secs(), now.subsec_nanos())
}

fn display_path(path: &Path) -> String {
    path.display().to_string()
}
