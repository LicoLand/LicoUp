use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::catalog::TargetCandidate;
use crate::platform::client_state::ClientStateStore;

const COLLECTION: &str = "target-discovery-cache";
const CACHE_SCHEMA: &str = "licoup.target-discovery-cache.v1";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct CachedTargetRoute {
    schema_version: String,
    target: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    binary_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    config_path: Option<String>,
    scan_source: String,
    runtime_ready: bool,
    cached_at_epoch_seconds: u64,
}

pub(super) fn persist_discovery_cache(
    store: &ClientStateStore,
    candidates: &[TargetCandidate],
) -> Result<()> {
    let cached_at = now_epoch_seconds();
    let items = candidates
        .iter()
        .filter_map(|candidate| cache_record(candidate, cached_at))
        .map(serde_json::to_value)
        .collect::<serde_json::Result<Vec<_>>>()?;
    store.write_collection(COLLECTION, json!({ "items": items }))?;
    Ok(())
}

pub(super) fn upsert_discovery_cache(
    store: &ClientStateStore,
    candidate: &TargetCandidate,
) -> Result<()> {
    let mut document = store.read_collection(COLLECTION)?;
    let mut items = parse_records(&document)?;
    items.retain(|item| item.target != candidate.target);
    if let Some(record) = cache_record(candidate, now_epoch_seconds()) {
        items.push(record);
    }
    items.sort_by(|left, right| left.target.cmp(&right.target));
    document["items"] = serde_json::to_value(items)?;
    store.write_collection(COLLECTION, document)?;
    Ok(())
}

pub(super) fn cached_runtime_executable(target: &str) -> Option<PathBuf> {
    let store = ClientStateStore::portable().ok()?;
    let document = store.read_collection(COLLECTION).ok()?;
    let record = parse_records(&document)
        .ok()?
        .into_iter()
        .find(|record| record.target == target && record.runtime_ready)?;
    let path = PathBuf::from(record.binary_path?);
    if !path.is_absolute() || !path.is_file() {
        return None;
    }
    fs::canonicalize(path).ok()
}

fn cache_record(candidate: &TargetCandidate, cached_at: u64) -> Option<CachedTargetRoute> {
    let binary_path = candidate.binary_path.clone();
    let config_path = (candidate.configured || candidate.manual)
        .then(|| candidate.config_path.clone())
        .flatten();
    if binary_path.is_none() && config_path.is_none() {
        return None;
    }
    Some(CachedTargetRoute {
        schema_version: CACHE_SCHEMA.to_string(),
        target: candidate.target.clone(),
        binary_path,
        config_path,
        scan_source: candidate
            .scan_source
            .clone()
            .unwrap_or_else(|| "host-local-discovery".to_string()),
        runtime_ready: candidate
            .supported_actions
            .iter()
            .any(|action| action == "runtime.message.send"),
        cached_at_epoch_seconds: cached_at,
    })
}

fn parse_records(document: &Value) -> Result<Vec<CachedTargetRoute>> {
    let items = document
        .get("items")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    items
        .into_iter()
        .map(|item| {
            let record: CachedTargetRoute = serde_json::from_value(item)?;
            ensure!(
                record.schema_version == CACHE_SCHEMA,
                "target discovery cache schema is invalid"
            );
            Ok(record)
        })
        .collect()
}

fn now_epoch_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::targets::catalog::{AdapterCapabilities, TargetCandidate};

    fn candidate(binary_path: Option<String>, config_path: Option<String>) -> TargetCandidate {
        TargetCandidate {
            id: Some("codex".to_string()),
            target: "codex".to_string(),
            label: "Codex".to_string(),
            kind: "cli".to_string(),
            status: "configured".to_string(),
            configured: config_path.is_some(),
            confidence: 1.0,
            detail: "must-not-be-cached".to_string(),
            config_path,
            binary_path,
            history_roots: vec!["must-not-be-cached".to_string()],
            manual: false,
            adapter_status: "implemented".to_string(),
            adapter_capabilities: AdapterCapabilities {
                detection: "implemented".to_string(),
                config_read: "unsupported".to_string(),
                config_plan: "unsupported".to_string(),
                config_apply: "unsupported".to_string(),
                rollback: "unsupported".to_string(),
                official_cli: "unknown".to_string(),
                conversation_driver: "implemented".to_string(),
                conversation_protocol: "acp".to_string(),
                conversation_readiness: "ready".to_string(),
                conversation_blocker: None,
                conversation_probe: json!({}),
                conversation_capability_matrix: Value::Null,
                conversation_summary_codes: Vec::new(),
                conversation_consecutive_passes: 0,
                conversation_evidence_age: String::new(),
            },
            supported_actions: vec!["runtime.message.send".to_string()],
            scan_source: Some("executable-path".to_string()),
            model_catalog: Some(json!({ "mustNotBeCached": true })),
        }
    }

    #[test]
    fn cache_keeps_only_quick_start_route_fields() {
        let root = std::env::temp_dir().join(format!("lico-target-cache-{}", uuid::Uuid::new_v4()));
        let store = ClientStateStore::new(root.clone()).unwrap();
        persist_discovery_cache(
            &store,
            &[candidate(
                Some(root.join("codex").to_string_lossy().into_owned()),
                Some(root.join("config.toml").to_string_lossy().into_owned()),
            )],
        )
        .unwrap();
        let document = store.read_collection(COLLECTION).unwrap();
        let item = &document["items"][0];
        assert_eq!(item["schemaVersion"], CACHE_SCHEMA);
        assert!(item.get("detail").is_none());
        assert!(item.get("historyRoots").is_none());
        assert!(item.get("modelCatalog").is_none());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn cache_drops_undetected_targets_without_local_routes() {
        let root =
            std::env::temp_dir().join(format!("lico-target-cache-empty-{}", uuid::Uuid::new_v4()));
        let store = ClientStateStore::new(root.clone()).unwrap();
        let mut undetected = candidate(None, None);
        undetected.configured = false;
        undetected.status = "not-detected".to_string();
        persist_discovery_cache(&store, &[undetected]).unwrap();
        assert_eq!(
            store.read_collection(COLLECTION).unwrap()["items"],
            json!([])
        );
        let _ = std::fs::remove_dir_all(root);
    }
}
