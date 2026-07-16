use super::catalog::{TargetDef, normalize_target, target_def};
use super::parameters::{optional_path, optional_paths, param_paths, param_string, target_param};
use super::support::{client_state_store, display_path, timestamp};
use crate::platform::client_state::ClientStateStore;
use anyhow::Result;
use serde_json::{Value, json};
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub(super) struct ManualTarget {
    pub(super) target: String,
    pub(super) label: String,
    pub(super) kind: String,
    pub(super) config_path: Option<PathBuf>,
    pub(super) binary_path: Option<PathBuf>,
    pub(super) history_roots: Vec<PathBuf>,
}

pub(super) fn add_target(params: &Value) -> Result<Value> {
    let target = target_param(params)?;
    let def = target_def(&target)?;
    let store = client_state_store(params)?;
    let saved = upsert_manual_target(&store, &def, params)?;
    let activity = store.activity_log().append(
        "target.manual.saved",
        json!({
            "target": def.id,
            "configPath": saved.get("configPath").cloned().unwrap_or_else(|| json!("")),
            "binaryPath": saved.get("binaryPath").cloned().unwrap_or_else(|| json!(""))
        }),
    )?;
    Ok(json!({
        "ok": true,
        "status": "accepted",
        "target": def.id,
        "label": def.label,
        "manual": true,
        "record": saved,
        "activity": activity,
    }))
}

pub(super) fn manual_targets(store: &ClientStateStore) -> Result<Vec<ManualTarget>> {
    let document = store.read_collection("targets")?;
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut manual = Vec::new();
    for item in items {
        let Some(target) = item
            .get("target")
            .and_then(Value::as_str)
            .map(normalize_target)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let Ok(def) = target_def(&target) else {
            continue;
        };
        manual.push(ManualTarget {
            target: def.id.to_string(),
            label: item
                .get("label")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(def.label)
                .to_string(),
            kind: item
                .get("kind")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .unwrap_or(def.kind)
                .to_string(),
            config_path: optional_path(&item, "configPath"),
            binary_path: optional_path(&item, "binaryPath"),
            history_roots: optional_paths(&item, "historyRoots")
                .into_iter()
                .chain(optional_path(&item, "historyRoot"))
                .collect(),
        });
    }
    Ok(manual)
}

pub(super) fn upsert_manual_target(
    store: &ClientStateStore,
    def: &TargetDef,
    params: &Value,
) -> Result<Value> {
    let mut document = store.read_collection("targets")?;
    let mut items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let now = timestamp();
    let existing = items.iter().position(|item| {
        item.get("target")
            .and_then(Value::as_str)
            .map(normalize_target)
            .as_deref()
            == Some(def.id)
    });
    let created_at = existing
        .and_then(|index| {
            items[index]
                .get("createdAt")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| now.clone());
    let history_roots = param_paths(params, &["historyRoots", "historyRoot"]);
    let record = json!({
        "target": def.id,
        "label": param_string(params, "label").unwrap_or_else(|| def.label.to_string()),
        "kind": param_string(params, "kind").unwrap_or_else(|| def.kind.to_string()),
        "manual": true,
        "configPath": param_string(params, "configPath"),
        "binaryPath": param_string(params, "binaryPath"),
        "historyRoots": history_roots
            .iter()
            .map(|path| display_path(path.clone()))
            .collect::<Vec<_>>(),
        "createdAt": created_at,
        "updatedAt": now
    });
    match existing {
        Some(index) => items[index] = record.clone(),
        None => items.push(record.clone()),
    }
    document["items"] = Value::Array(items);
    store.write_collection("targets", document)?;
    Ok(record)
}
