//! Local Agent Hub ownership records. Existing installs stay external.

use super::contract::{InstallOwnership, OWNERSHIP_EXTERNAL, OWNERSHIP_NONE, OWNERSHIP_OWNED};
use crate::platform::client_state::ClientStateStore;
use crate::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, read_private_text_bounded,
};
use anyhow::{ensure, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

const OWNERSHIP_FILE: &str = "ownership.json";
const MAX_OWNERSHIP_BYTES: usize = 256 * 1024;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnershipDocument {
    #[serde(default)]
    items: Vec<InstallOwnership>,
}

pub fn hub_dir(store: &ClientStateStore) -> PathBuf {
    store.root().join("agent-hub")
}

fn ownership_path(store: &ClientStateStore) -> PathBuf {
    hub_dir(store).join(OWNERSHIP_FILE)
}

pub fn load(store: &ClientStateStore) -> Result<Vec<InstallOwnership>> {
    let path = ownership_path(store);
    if !path.is_file() {
        return Ok(Vec::new());
    }
    let Some(raw) = read_private_text_bounded(&path, MAX_OWNERSHIP_BYTES)? else {
        return Ok(Vec::new());
    };
    let document: OwnershipDocument = serde_json::from_str(&raw).unwrap_or_default();
    Ok(document.items)
}

pub fn get(store: &ClientStateStore, agent_id: &str) -> Result<Option<InstallOwnership>> {
    Ok(load(store)?
        .into_iter()
        .find(|item| item.agent_id == agent_id))
}

pub fn save(store: &ClientStateStore, record: InstallOwnership) -> Result<()> {
    ensure_private_dir(&hub_dir(store))?;
    let mut items = load(store)?;
    items.retain(|item| item.agent_id != record.agent_id);
    items.push(record);
    persist(store, items)
}

pub fn remove(store: &ClientStateStore, agent_id: &str) -> Result<()> {
    let mut items = load(store)?;
    items.retain(|item| item.agent_id != agent_id);
    persist(store, items)
}

fn persist(store: &ClientStateStore, items: Vec<InstallOwnership>) -> Result<()> {
    ensure_private_dir(&hub_dir(store))?;
    let document = OwnershipDocument { items };
    let raw = serde_json::to_string_pretty(&document)?;
    ensure!(
        raw.len() <= MAX_OWNERSHIP_BYTES,
        "agent hub ownership document exceeds its bounded size"
    );
    atomic_write_private_text(&ownership_path(store), &raw)
}

pub fn resolve_ownership(record: Option<&InstallOwnership>, present: bool) -> &'static str {
    if record.map(|item| item.ownership.as_str()) == Some(OWNERSHIP_OWNED) {
        OWNERSHIP_OWNED
    } else if present {
        OWNERSHIP_EXTERNAL
    } else {
        OWNERSHIP_NONE
    }
}

pub fn store_from_params(params: &Value) -> Result<ClientStateStore> {
    if let Some(root) = params
        .get("stateRoot")
        .or_else(|| params.get("clientStateRoot"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return ClientStateStore::new(PathBuf::from(root));
    }
    if let Some(portable_dir) = params
        .get("portableDir")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return ClientStateStore::new(PathBuf::from(portable_dir).join("client-state"));
    }
    ClientStateStore::portable()
}
