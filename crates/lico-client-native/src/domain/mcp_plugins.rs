use crate::domain::targets;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

const LICO_PLUGIN_ID: &str = "lico-mcp";

pub fn plugin_status(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let inspected = targets::inspect_target_with_params(params)?;
    let target_info = inspected
        .get("target")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let configured = target_info
        .get("configured")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({
        "ok": true,
        "pluginId": LICO_PLUGIN_ID,
        "pluginRole": "peer",
        "privilegedHost": false,
        "target": target,
        "status": if configured { "configured" } else { "not-configured" },
        "targetNative": {
            "configured": configured,
            "configPath": target_info.get("configPath").cloned().unwrap_or_else(|| json!(null)),
            "fields": inspected.get("fields").cloned().unwrap_or_else(|| json!([])),
            "writePolicy": inspected.get("writePolicy").cloned().unwrap_or_else(|| json!({}))
        },
        "actions": ["status", "update", "rollback"]
    }))
}

pub fn plugin_update(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    if bool_param(params, "dryRun").unwrap_or(false) || bool_param(params, "plan").unwrap_or(false)
    {
        let plan = targets::mcp_config_plan(params)?;
        return Ok(json!({
            "ok": true,
            "pluginId": LICO_PLUGIN_ID,
            "pluginRole": "peer",
            "target": target,
            "status": "planned",
            "plan": plan
        }));
    }
    let applied = targets::mcp_config_apply(params)?;
    let apply_ok = applied.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let status = if apply_ok {
        "updated".to_string()
    } else {
        applied
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("failed")
            .to_string()
    };
    Ok(json!({
        "ok": apply_ok,
        "pluginId": LICO_PLUGIN_ID,
        "pluginRole": "peer",
        "target": target,
        "status": status,
        "apply": applied
    }))
}

pub fn plugin_rollback(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let rollback = targets::mcp_config_rollback(params)?;
    let rollback_ok = rollback.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let status = if rollback_ok {
        "rolled_back".to_string()
    } else {
        rollback
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("failed")
            .to_string()
    };
    Ok(json!({
        "ok": rollback_ok,
        "pluginId": LICO_PLUGIN_ID,
        "pluginRole": "peer",
        "target": target,
        "status": status,
        "rollback": rollback
    }))
}

fn target_param(params: &Value) -> Result<String> {
    params
        .get("target")
        .and_then(Value::as_str)
        .or_else(|| {
            params
                .get("positionals")
                .and_then(Value::as_array)
                .and_then(|items| items.first())
                .and_then(Value::as_str)
        })
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("MCP plugin command requires --target <target>"))
}

fn bool_param(params: &Value, key: &str) -> Option<bool> {
    params.get(key).and_then(|value| {
        value.as_bool().or_else(|| {
            value.as_str().map(|raw| {
                matches!(
                    raw.trim().to_ascii_lowercase().as_str(),
                    "1" | "true" | "yes" | "on"
                )
            })
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn signed_receipt_discovery(endpoint: &str, path: &Path) {
        use rand::RngCore;
        let mut bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);
        let secret_bytes = bytes;
        let mcp_url = format!("{}/mcp", endpoint.trim_end_matches('/'));
        let (receipt, public_key) = crate::domain::mcp_trust::test_signed_receipt(
            endpoint,
            &mcp_url,
            "test-key",
            "2026-06-09T00:00:00Z",
            "2099-01-01T00:00:00Z",
            &secret_bytes,
        );
        let doc = serde_json::json!({
            "url": endpoint,
            "trustReceipt": receipt,
            "pinnedPublicKey": public_key
        });
        fs::write(path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    }

    #[test]
    fn mcp_plugins_status_reports_lico_mcp_as_peer_plugin() {
        let status = plugin_status(&json!({"target": "opencode"})).unwrap();
        assert_eq!(status["ok"], true);
        assert_eq!(status["pluginId"], LICO_PLUGIN_ID);
        assert_eq!(status["pluginRole"], "peer");
        assert_eq!(status["privilegedHost"], false);
        assert!(
            status["targetNative"]["fields"]
                .as_array()
                .unwrap()
                .iter()
                .any(|field| field["path"] == "mcp.lico.url")
        );
    }

    #[test]
    fn mcp_plugins_opencode_update_writes_remote_connector_shape() {
        let dir = temp_test_dir("opencode-update");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("lico-client");
        fs::write(&config_path, r#"{"mcp":{"other":{"enabled":true}}}"#).unwrap();

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let update = plugin_update(&json!({
            "target": "opencode",
            "configPath": config_path.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "discoveryFile": discovery_file.to_string_lossy(),
            "token": "peer-token"
        }))
        .unwrap();

        assert_eq!(update["ok"], true);
        assert_eq!(update["status"], "updated");
        assert_eq!(update["pluginRole"], "peer");
        let updated: Value =
            serde_json::from_str(&fs::read_to_string(&config_path).unwrap()).unwrap();
        assert_eq!(updated["mcp"]["lico"]["type"], "remote");
        assert_eq!(updated["mcp"]["lico"]["url"], "http://127.0.0.1:7228/mcp");
        assert_eq!(
            updated["mcp"]["lico"]["headers"]["X-LicoLite-Api-Key"],
            "peer-token"
        );
        assert_eq!(updated["mcp"]["lico"]["enabled"], true);
    }

    #[test]
    fn mcp_plugins_rollback_restores_target_native_config() {
        let dir = temp_test_dir("opencode-rollback");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("lico-client");
        let original = r#"{"mcp":{"other":{"enabled":true}}}"#;
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("mcp-discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let update = plugin_update(&json!({
            "target": "opencode",
            "configPath": config_path.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "discoveryFile": discovery_file.to_string_lossy(),
            "token": (["rollback", "token"].join("-"))
        }))
        .unwrap();
        let snapshot_id = update["apply"]["snapshotId"].as_str().unwrap();
        assert_ne!(fs::read_to_string(&config_path).unwrap(), original);

        let rollback = plugin_rollback(&json!({
            "target": "opencode",
            "configPath": config_path.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "snapshotId": snapshot_id
        }))
        .unwrap();

        assert_eq!(rollback["ok"], true);
        assert_eq!(rollback["status"], "rolled_back");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn mcp_plugins_target_positionals_and_dry_run_supports_config_plan() {
        let result = plugin_update(&json!({
            "positionals": ["opencode", "plan"],
            "dryRun": true,
            "stateRoot": temp_test_dir("positionals").join("lico-client").to_string_lossy(),
        }))
        .unwrap();
        assert_eq!(result["status"], "planned");
        assert_eq!(result["plan"]["status"], "planned");
    }

    #[test]
    fn mcp_plugins_respects_plan_string_toggle() {
        let result = plugin_update(&json!({
            "target": "opencode",
            "plan": "on",
            "stateRoot": temp_test_dir("plan-string").join("lico-client").to_string_lossy(),
        }))
        .unwrap();
        assert_eq!(result["status"], "planned");
        assert_eq!(result["plan"]["plan"]["operation"], "mcp.config.apply");
    }

    #[test]
    fn mcp_plugins_status_accepts_positionals_target() {
        let status = plugin_status(&json!({
            "positionals": ["opencode"]
        }))
        .unwrap();
        assert!(status["status"] == "configured" || status["status"] == "not-configured");
    }

    #[test]
    fn plugin_update_unverified_returns_verification_required() {
        let dir = temp_test_dir("plugin-no-verify");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("lico-client");
        let original = r#"{"mcp":{"other":{"enabled":true}}}"#;
        fs::write(&config_path, original).unwrap();

        let result = plugin_update(&json!({
            "target": "opencode",
            "configPath": config_path.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "baseUrl": "http://127.0.0.1:7228"
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "verification_required");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    #[test]
    fn plugin_update_unsupported_target_returns_unsupported() {
        let result = plugin_update(&json!({
            "target": "codex",
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "unsupported_adapter_action");
    }

    #[test]
    fn plugin_update_field_conflict_returns_field_conflict() {
        let dir = temp_test_dir("plugin-field-conflict");
        let config_path = dir.join("opencode.jsonc");
        let state_root = dir.join("lico-client");
        let original = r#"{"mcp": 1}"#;
        fs::write(&config_path, original).unwrap();

        let discovery_file = dir.join("discovery.json");
        signed_receipt_discovery("http://127.0.0.1:7228", &discovery_file);

        let result = plugin_update(&json!({
            "target": "opencode",
            "configPath": config_path.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "discoveryFile": discovery_file.to_string_lossy(),
            "token": "test-token"
        }))
        .unwrap();

        assert_eq!(result["ok"], false);
        assert_eq!(result["status"], "field_conflict");
        assert_eq!(fs::read_to_string(&config_path).unwrap(), original);
    }

    fn temp_test_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let dir = env::temp_dir().join(format!(
            "lico-mcp-plugin-{}-{}-{}",
            name,
            now.as_secs(),
            now.subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
