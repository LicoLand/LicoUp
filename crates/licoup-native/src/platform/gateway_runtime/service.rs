//! Managed lifecycle facade for the unified Gateway Runtime.

use crate::platform::file_security::ensure_private_dir;
use crate::platform::gateway_runtime::channels;
use crate::platform::paths;
use anyhow::Result;
use serde_json::{Value, json};
use std::path::PathBuf;

pub const REPORT_SCHEMA: &str = "licoup.gateway-runtime.v1";
/// Canonical default gateway port, derived from the single configuration
/// source at `config/gateway-runtime.json` (schema `licoup.gateway-runtime.v1`).
/// Runtime, clients and integration tools all consume that one document.
const GATEWAY_RUNTIME_CONFIG_JSON: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../config/gateway-runtime.json"));

fn gateway_default_port() -> u16 {
    static PORT: std::sync::LazyLock<u16> = std::sync::LazyLock::new(|| {
        serde_json::from_str::<serde_json::Value>(GATEWAY_RUNTIME_CONFIG_JSON)
            .expect("gateway runtime config must parse")["gateway_runtime"]["default_port"]
            .as_u64()
            .expect("gateway_runtime.default_port must be an integer") as u16
    });
    *PORT
}
const RUNTIME_STATE: &str = "gateway";

pub fn state_directory() -> Result<PathBuf> {
    let root = paths::portable_data_dir()?.join(RUNTIME_STATE);
    ensure_private_dir(&root)?;
    Ok(root)
}

/// Start the unified runtime (LLM layer + Communication Channel layer).
pub fn service_start(port: u16) -> Result<Value> {
    let _ = state_directory()?;
    let started = crate::platform::llm_gateway_service::service_start(port)?;
    layered_status(port, started)
}

pub fn service_stop(port: u16) -> Result<Value> {
    let stopped = crate::platform::llm_gateway_service::service_stop(port)?;
    let _ = channels::telegram::clear_ready();
    layered_status(port, stopped)
}

pub fn service_status(port: u16) -> Result<Value> {
    let base = crate::platform::llm_gateway_service::service_status(port)?;
    layered_status(port, base)
}

pub fn service_initialize(port: u16) -> Result<Value> {
    let _ = state_directory()?;
    let initialized = crate::platform::llm_gateway_service::service_initialize(port)?;
    layered_status(port, initialized)
}

/// Hot-reload verified conversation readiness into the running Gateway Runtime.
pub fn reload_conversation_inventory(readiness_json: &str) -> Result<Value> {
    let _ = state_directory()?;
    crate::platform::llm_gateway_service::reload_conversation_inventory(readiness_json)
}

fn layered_status(port: u16, base: Value) -> Result<Value> {
    let channels = channels::channel_layer_status()?;
    let llm_state = base
        .get("state")
        .and_then(Value::as_str)
        .unwrap_or("stopped");
    Ok(json!({
        "ok": true,
        "schemaVersion": REPORT_SCHEMA,
        "state": base.get("state").cloned().unwrap_or(json!("stopped")),
        "managed": base.get("managed").cloned().unwrap_or(json!(false)),
        "pid": base.get("pid").cloned().unwrap_or(Value::Null),
        "processName": base.get("processName").cloned().unwrap_or(Value::Null),
        "port": port,
        "credentialsLoaded": base.get("credentialsLoaded").cloned().unwrap_or(json!(false)),
        "credentialsApplied": base.get("credentialsApplied").cloned().unwrap_or(json!(false)),
        "modelReady": base.get("modelReady").cloned().unwrap_or(json!(false)),
        "layers": {
            "llm": {
                "layer": "llm-gateway",
                "state": llm_state,
                "port": port,
                "configPath": base.get("configPath").cloned().unwrap_or(Value::Null),
                "logPath": base.get("logPath").cloned().unwrap_or(Value::Null),
            },
            "channels": channels,
        },
        "stateDirectory": state_directory()?,
        "message": base.get("message").cloned().unwrap_or(Value::Null),
    }))
}
