use crate::client_state::ClientStateStore;
use crate::source_queue;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const CONNECTORS_SCHEMA_VERSION: &str = "v0.0.1:client-connectors-1";
const CONNECTORS_DIR: &str = "connectors";
const MIRROR_FILE: &str = "mirror.jsonl";

pub fn list(_params: &Value) -> Result<Value> {
    Ok(json!({
        "ok": true,
        "schemaVersion": CONNECTORS_SCHEMA_VERSION,
        "connectors": [
            {
                "id": "local-directory",
                "label": "Local directory",
                "mode": "client-local",
                "output": "source-queue",
                "requiresPath": true
            },
            {
                "id": "macos-mail",
                "label": "macOS Mail",
                "mode": "swift-helper",
                "output": "source-queue",
                "requiresExplicitScope": true
            },
            {
                "id": "icloud-local-projection",
                "label": "iCloud local projection",
                "mode": "client-local-projection",
                "output": "source-queue",
                "requiresPath": true,
                "remoteApiSupported": false
            },
            {
                "id": "onedrive-local-projection",
                "label": "OneDrive local projection",
                "mode": "client-local-projection",
                "output": "source-queue",
                "requiresPath": true,
                "remoteApiSupported": false
            }
        ]
    }))
}

pub fn sync(params: &Value) -> Result<Value> {
    let connector_id = text_param(params, &["connector", "connectorId", "provider", "target"])
        .unwrap_or_else(|| "local-directory".into());
    match connector_id.as_str() {
        "local-directory" | "icloud-local-projection" | "onedrive-local-projection" => {
            sync_local_projection(params, &connector_id)
        }
        "macos-mail" => Err(anyhow!(
            "macOS Mail sync is exposed through `lico-client mail preview|enqueue` so explicit scope is always captured"
        )),
        _ => Err(anyhow!("unknown connector: {}", connector_id)),
    }
}

pub fn status(params: &Value) -> Result<Value> {
    let mirror = mirror_entries(params)?;
    let queue = source_queue::status(params).unwrap_or_else(|_| json!({ "ok": false }));
    Ok(json!({
        "ok": true,
        "schemaVersion": CONNECTORS_SCHEMA_VERSION,
        "status": "ready",
        "mirrorCount": mirror.len(),
        "sourceQueue": queue,
        "mirrorPath": display_path(&mirror_path(params)?)
    }))
}

pub fn mirror_inspect(params: &Value) -> Result<Value> {
    let limit = number_param(params, &["limit"])
        .unwrap_or(100)
        .clamp(1, 1000) as usize;
    let mut entries = mirror_entries(params)?;
    if entries.len() > limit {
        entries = entries[entries.len() - limit..].to_vec();
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": CONNECTORS_SCHEMA_VERSION,
        "entries": entries,
        "mirrorPath": display_path(&mirror_path(params)?)
    }))
}

fn sync_local_projection(params: &Value, connector_id: &str) -> Result<Value> {
    let path = text_param(params, &["path"])
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("{} sync requires --path", connector_id))?;
    let metadata = fs::metadata(&path).map_err(|error| {
        anyhow!(
            "connector path is not readable: {} ({})",
            path.display(),
            error
        )
    })?;
    if !metadata.is_dir() && !metadata.is_file() {
        return Err(anyhow!(
            "connector path must be a file or directory: {}",
            path.display()
        ));
    }
    let provider_id = provider_for(connector_id);
    let external_id = text_param(params, &["externalId"]).unwrap_or_else(|| {
        format!(
            "projection:{}:{}",
            connector_id,
            sha256_hex(path.display().to_string().as_bytes())
        )
    });
    let enqueue = source_queue::add(&json!({
        "path": path.display().to_string(),
        "sourceType": connector_id,
        "providerId": provider_id,
        "externalId": external_id,
        "serverUrl": text_param(params, &["serverUrl"]).unwrap_or_default(),
        "metadataJson": {
            "connectorId": connector_id,
            "projectionMode": "local",
            "pathKind": if metadata.is_dir() { "directory" } else { "file" },
            "syncedAt": timestamp()
        }
    }))?;
    append_mirror(
        params,
        json!({
            "schemaVersion": CONNECTORS_SCHEMA_VERSION,
            "connectorId": connector_id,
            "providerId": provider_id,
            "externalId": external_id,
            "path": path.display().to_string(),
            "pathKind": if metadata.is_dir() { "directory" } else { "file" },
            "sourceQueueItemId": enqueue.get("item").and_then(|item| item.get("itemId")).cloned().unwrap_or_else(|| json!("")),
            "updatedAt": timestamp()
        }),
    )?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONNECTORS_SCHEMA_VERSION,
        "status": "enqueued",
        "connectorId": connector_id,
        "sourceQueue": enqueue
    }))
}

fn provider_for(connector_id: &str) -> &'static str {
    match connector_id {
        "icloud-local-projection" => "icloud",
        "onedrive-local-projection" => "onedrive",
        "local-directory" => "local-filesystem",
        _ => "client-connector",
    }
}

fn mirror_path(params: &Value) -> Result<PathBuf> {
    let root = if let Some(state_root) = text_param(params, &["stateRoot", "root"]) {
        PathBuf::from(state_root)
    } else {
        ClientStateStore::portable()?.root().to_path_buf()
    };
    Ok(root.join(CONNECTORS_DIR).join(MIRROR_FILE))
}

fn append_mirror(params: &Value, entry: Value) -> Result<()> {
    let path = mirror_path(params)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(file, "{}", serde_json::to_string(&entry)?)?;
    Ok(())
}

fn mirror_entries(params: &Value) -> Result<Vec<Value>> {
    let path = mirror_path(params)?;
    if !path.exists() {
        return Ok(Vec::new());
    }
    let mut entries = Vec::new();
    let file = fs::File::open(path)?;
    for line in BufReader::new(file).lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&line) {
            entries.push(value);
        }
    }
    Ok(entries)
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
