use super::errors::ProtocolFailure;
use super::model::{HOOK_NAMESPACE, RECEIPT_ENV};
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const HOOK_SCRIPT_NAME: &str = "session-receipt-hook.sh";

pub(super) fn ensure_hook_bridge() -> Result<(), ProtocolFailure> {
    let script_path = hook_script_path()?;
    write_hook_script(&script_path)?;
    install_global_hook(&script_path)?;
    Ok(())
}

pub(crate) fn hook_bridge_status() -> Value {
    let config_dir = gemini_config_dir().ok();
    let hooks_path = config_dir.as_ref().map(|path| path.join("hooks.json"));
    let script_path = hook_script_path().ok();
    let hook_registered = hooks_path
        .as_ref()
        .and_then(|path| fs::read_to_string(path).ok())
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|root| root.get(HOOK_NAMESPACE).cloned())
        .is_some();
    let script_installed = script_path
        .as_ref()
        .map(|path| path.is_file())
        .unwrap_or(false);
    let installed = hook_registered && script_installed;
    json!({
        "ok": true,
        "adapterId": "antigravity",
        "driverId": super::model::DRIVER_ID,
        "runtimeProtocol": super::model::RUNTIME_PROTOCOL,
        "installed": installed,
        "hookRegistered": hook_registered,
        "scriptInstalled": script_installed,
        "hookNamespace": HOOK_NAMESPACE,
    })
}

pub(crate) fn install_hook_bridge() -> Result<Value, &'static str> {
    ensure_hook_bridge().map_err(|failure| failure.code)?;
    let mut status = hook_bridge_status();
    if let Some(object) = status.as_object_mut() {
        object.insert("action".to_string(), json!("install"));
    }
    Ok(status)
}

pub(crate) fn uninstall_hook_bridge_report() -> Result<Value, &'static str> {
    uninstall_hook_bridge().map_err(|failure| failure.code)?;
    let mut status = hook_bridge_status();
    if let Some(object) = status.as_object_mut() {
        object.insert("action".to_string(), json!("uninstall"));
    }
    Ok(status)
}

/// Remove only the Lico-owned hook namespace and helper script.
///
/// Leaves unrelated user hooks untouched. Safe to call when detaching or
/// updating this adapter module.
pub(in crate::platform) fn uninstall_hook_bridge() -> Result<(), ProtocolFailure> {
    let config_dir = gemini_config_dir()?;
    let hooks_path = config_dir.join("hooks.json");
    if hooks_path.exists() {
        let text = fs::read_to_string(&hooks_path).map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hooks configuration could not be read.",
                "capability/hooks",
            )
        })?;
        let mut root = serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({}));
        if let Some(object) = root.as_object_mut() {
            object.remove(HOOK_NAMESPACE);
            if object.is_empty() {
                let _ = fs::remove_file(&hooks_path);
            } else {
                let encoded = serde_json::to_vec_pretty(&root).map_err(|_| {
                    ProtocolFailure::new(
                        "antigravity_hook_bridge_unavailable",
                        "Antigravity hooks configuration could not be encoded.",
                        "capability/hooks",
                    )
                })?;
                let temporary = hooks_path.with_extension("json.tmp");
                fs::write(&temporary, encoded).map_err(|_| {
                    ProtocolFailure::new(
                        "antigravity_hook_bridge_unavailable",
                        "Antigravity hooks configuration could not be written.",
                        "capability/hooks",
                    )
                })?;
                fs::rename(&temporary, &hooks_path).map_err(|_| {
                    ProtocolFailure::new(
                        "antigravity_hook_bridge_unavailable",
                        "Antigravity hooks configuration could not be updated.",
                        "capability/hooks",
                    )
                })?;
            }
        }
    }
    let script_path = hook_script_path()?;
    let _ = fs::remove_file(&script_path);
    if let Some(parent) = script_path.parent() {
        let _ = fs::remove_dir(parent);
    }
    Ok(())
}

pub(super) fn receipt_path_for_turn() -> Result<PathBuf, ProtocolFailure> {
    let root = receipt_root()?.join("receipts");
    fs::create_dir_all(&root).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity session receipt directory could not be created.",
            "capability/hooks",
        )
    })?;
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(root.join(format!("receipt-{}-{}.json", std::process::id(), nonce)))
}

pub(super) fn read_conversation_id(receipt: &Path) -> Option<String> {
    let text = fs::read_to_string(receipt).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    value
        .get("conversationId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
}

fn receipt_root() -> Result<PathBuf, ProtocolFailure> {
    let root = crate::platform::paths::portable_data_dir()
        .map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hook bridge data root is unavailable.",
                "capability/hooks",
            )
        })?
        .join("antigravity");
    fs::create_dir_all(&root).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hook bridge data root could not be created.",
            "capability/hooks",
        )
    })?;
    Ok(root)
}

fn hook_script_path() -> Result<PathBuf, ProtocolFailure> {
    // Keep the executable hook outside disposable portable roots so temporary
    // gate workspaces cannot leave ~/.gemini/config/hooks.json pointing at a
    // deleted script path after cleanup.
    let root = gemini_config_dir()?.join("lico-arc-antigravity");
    fs::create_dir_all(&root).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hook script directory could not be created.",
            "capability/hooks",
        )
    })?;
    Ok(root.join(HOOK_SCRIPT_NAME))
}

fn gemini_config_dir() -> Result<PathBuf, ProtocolFailure> {
    if let Ok(override_dir) = std::env::var("LICO_ANTIGRAVITY_GEMINI_CONFIG_DIR") {
        let trimmed = override_dir.trim();
        if !trimmed.is_empty() {
            return Ok(PathBuf::from(trimmed));
        }
    }
    let home = std::env::var_os("HOME").ok_or_else(|| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hook bridge could not resolve the user home directory.",
            "capability/hooks",
        )
    })?;
    Ok(PathBuf::from(home).join(".gemini").join("config"))
}

fn write_hook_script(path: &Path) -> Result<(), ProtocolFailure> {
    // Build `${ENV:?}` without treating `:?` as a Rust format specifier.
    let receipt_expansion = format!("${{{}{}}}", RECEIPT_ENV, ":?");
    let script = format!(
        r#"#!/bin/sh
set -eu
out="{receipt_expansion}"
python3 - "$out" <<'PY'
import json, os, sys
out = sys.argv[1]
raw = sys.stdin.read()
data = {{}}
try:
    data = json.loads(raw) if raw.strip() else {{}}
except Exception:
    data = {{}}
cid = ""
if isinstance(data, dict):
    for key in ("conversationId", "conversation_id", "sessionId", "session_id"):
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            cid = value.strip()
            break
if not cid:
    cid = (os.environ.get("ANTIGRAVITY_CONVERSATION_ID") or "").strip()
if not cid:
    try:
        previous = json.load(open(out, encoding="utf-8"))
        prior = previous.get("conversationId") if isinstance(previous, dict) else ""
        if isinstance(prior, str) and prior.strip():
            cid = prior.strip()
    except Exception:
        pass
payload = {{"conversationId": cid}}
with open(out, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
print("{{}}")
PY
"#
    );
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hook script directory could not be created.",
                "capability/hooks",
            )
        })?;
    }
    {
        let mut file = fs::File::create(path).map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hook script could not be written.",
                "capability/hooks",
            )
        })?;
        file.write_all(script.as_bytes()).map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hook script could not be written.",
                "capability/hooks",
            )
        })?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(path)
            .map_err(|_| {
                ProtocolFailure::new(
                    "antigravity_hook_bridge_unavailable",
                    "Antigravity hook script permissions could not be read.",
                    "capability/hooks",
                )
            })?
            .permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(path, permissions).map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hook script permissions could not be set.",
                "capability/hooks",
            )
        })?;
    }
    Ok(())
}

fn install_global_hook(script_path: &Path) -> Result<(), ProtocolFailure> {
    let config_dir = gemini_config_dir()?;
    fs::create_dir_all(&config_dir).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hooks configuration directory could not be created.",
            "capability/hooks",
        )
    })?;
    let hooks_path = config_dir.join("hooks.json");
    let mut root = if hooks_path.exists() {
        let text = fs::read_to_string(&hooks_path).map_err(|_| {
            ProtocolFailure::new(
                "antigravity_hook_bridge_unavailable",
                "Antigravity hooks configuration could not be read.",
                "capability/hooks",
            )
        })?;
        serde_json::from_str::<Value>(&text).unwrap_or_else(|_| json!({}))
    } else {
        json!({})
    };
    if !root.is_object() {
        root = json!({});
    }
    let command = script_path.to_string_lossy().into_owned();
    // Only Stop is required for print-mode session receipt. Avoid earlier
    // lifecycle hooks that can overwrite the receipt with an empty id.
    let entry = json!({
        "enabled": true,
        "Stop": [
            {
                "type": "command",
                "command": command,
                "timeout": 10
            }
        ]
    });
    root.as_object_mut()
        .expect("hooks root object")
        .insert(HOOK_NAMESPACE.to_string(), entry);
    let encoded = serde_json::to_vec_pretty(&root).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hooks configuration could not be encoded.",
            "capability/hooks",
        )
    })?;
    let temporary = hooks_path.with_extension("json.tmp");
    fs::write(&temporary, encoded).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hooks configuration could not be written.",
            "capability/hooks",
        )
    })?;
    fs::rename(&temporary, &hooks_path).map_err(|_| {
        ProtocolFailure::new(
            "antigravity_hook_bridge_unavailable",
            "Antigravity hooks configuration could not be installed.",
            "capability/hooks",
        )
    })?;
    Ok(())
}
