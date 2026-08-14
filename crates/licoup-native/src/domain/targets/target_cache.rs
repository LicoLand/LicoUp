use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use serde_json::Map;

use super::catalog::TargetCandidate;
use crate::platform::client_state::{
    ClientStateStore, TARGET_DISCOVERY_CACHE_SCHEMA as CACHE_SCHEMA, TargetRouteRecord,
};

pub(super) fn persist_discovery_cache(
    store: &ClientStateStore,
    candidates: &[TargetCandidate],
) -> Result<()> {
    let cached_at = now_epoch_seconds();
    let records = candidates
        .iter()
        .filter_map(|candidate| cache_record(candidate, cached_at))
        .collect::<Vec<_>>();
    store.write_target_routes(&records)
}

pub(super) fn upsert_discovery_cache(
    store: &ClientStateStore,
    candidate: &TargetCandidate,
) -> Result<()> {
    let mut records = store.read_target_routes()?;
    records.retain(|record| record.target != candidate.target);
    if let Some(record) = cache_record(candidate, now_epoch_seconds()) {
        records.push(record);
    }
    records.sort_by(|left, right| left.target.cmp(&right.target));
    store.write_target_routes(&records)
}

pub(super) fn cached_runtime_executable(store: &ClientStateStore, target: &str) -> Option<PathBuf> {
    let record = store.target_route(target).ok()??;
    if !record.runtime_ready {
        return None;
    }
    let path = PathBuf::from(record.binary_path?);
    if !path.is_absolute() || !path.is_file() {
        return None;
    }
    fs::canonicalize(path).ok()
}

fn cache_record(candidate: &TargetCandidate, cached_at: u64) -> Option<TargetRouteRecord> {
    if candidate.location != "local" {
        return None;
    }
    let binary_path = candidate.binary_path.clone();
    let config_path = (candidate.configured || candidate.manual)
        .then(|| candidate.config_path.clone())
        .flatten();
    if binary_path.is_none() && config_path.is_none() {
        return None;
    }
    Some(TargetRouteRecord {
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
        extension: Map::new(),
    })
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
    use crate::platform::client_state::TARGET_DISCOVERY_CACHE_COLLECTION as COLLECTION;
    use serde_json::{Value, json};
    use std::fs;
    use std::path::PathBuf;

    fn temp_test_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("lico-targets-{}-{}", name, uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn route(target: &str, binary_path: Option<&str>) -> TargetRouteRecord {
        TargetRouteRecord {
            schema_version: CACHE_SCHEMA.to_string(),
            target: target.to_string(),
            binary_path: binary_path.map(str::to_string),
            config_path: None,
            scan_source: "executable-path".to_string(),
            runtime_ready: true,
            cached_at_epoch_seconds: 1,
            extension: Map::new(),
        }
    }

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
            location: "local".to_string(),
            runtime_connection: None,
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

    #[test]
    fn cached_runtime_executable_resolves_through_the_store_owner() {
        let dir = temp_test_dir("binding-keyed");
        let executable = dir.join("codex");
        fs::write(&executable, "").unwrap();
        let store = ClientStateStore::new(dir.join("client-state")).unwrap();
        store
            .write_target_routes(&[route("codex", Some(executable.to_string_lossy().as_ref()))])
            .unwrap();

        assert_eq!(
            cached_runtime_executable(&store, "codex"),
            Some(fs::canonicalize(&executable).unwrap())
        );
        assert_eq!(
            cached_runtime_executable(&store, "codex"),
            Some(fs::canonicalize(&executable).unwrap())
        );
        assert!(cached_runtime_executable(&store, "missing").is_none());
        // Write-through installs the projection; local writes never reparse.
        assert_eq!(store.target_index_parse_count(), 1);
        store
            .write_target_routes(&[route("codex", Some(executable.to_string_lossy().as_ref()))])
            .unwrap();
        assert_eq!(store.target_index_parse_count(), 1);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn cached_runtime_executable_reparses_once_per_file_generation() {
        let dir = temp_test_dir("binding-reparse");
        let executable = dir.join("codex");
        fs::write(&executable, "").unwrap();
        let writer = ClientStateStore::new(dir.join("client-state")).unwrap();
        writer
            .write_target_routes(&[route("codex", Some(executable.to_string_lossy().as_ref()))])
            .unwrap();

        let reader = ClientStateStore::new(dir.join("client-state")).unwrap();
        assert!(cached_runtime_executable(&reader, "codex").is_some());
        assert!(cached_runtime_executable(&reader, "codex").is_some());
        assert_eq!(reader.target_index_parse_count(), 1);
        assert_eq!(reader.target_index_invalidation_count(), 0);

        writer.write_target_routes(&[]).unwrap();
        assert!(cached_runtime_executable(&reader, "codex").is_none());
        assert_eq!(reader.target_index_parse_count(), 2);
        assert_eq!(reader.target_index_invalidation_count(), 1);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn cached_runtime_executable_rejects_unready_or_unresolvable_routes() {
        let dir = temp_test_dir("binding-reject");
        let executable = dir.join("codex");
        fs::write(&executable, "").unwrap();
        let store = ClientStateStore::new(dir.join("client-state")).unwrap();

        let mut unready = route("codex", Some(executable.to_string_lossy().as_ref()));
        unready.runtime_ready = false;
        store.write_target_routes(&[unready]).unwrap();
        assert!(cached_runtime_executable(&store, "codex").is_none());

        store
            .write_target_routes(&[route("codex", Some(executable.to_string_lossy().as_ref()))])
            .unwrap();
        assert!(cached_runtime_executable(&store, "codex").is_some());

        store
            .write_target_routes(&[route("codex", Some("relative/codex"))])
            .unwrap();
        assert!(cached_runtime_executable(&store, "codex").is_none());

        store
            .write_target_routes(&[route(
                "codex",
                Some(dir.join("absent").to_string_lossy().as_ref()),
            )])
            .unwrap();
        assert!(cached_runtime_executable(&store, "codex").is_none());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn upsert_replaces_and_sorts_through_the_typed_projection() {
        let dir = temp_test_dir("upsert-typed");
        let store = ClientStateStore::new(dir.join("client-state")).unwrap();
        let first = candidate(Some(dir.join("codex").to_string_lossy().into_owned()), None);
        let mut second = candidate(Some(dir.join("alpha").to_string_lossy().into_owned()), None);
        second.target = "alpha".to_string();
        second.id = Some("alpha".to_string());
        persist_discovery_cache(&store, &[first, second]).unwrap();

        let mut replacement =
            candidate(Some(dir.join("codex").to_string_lossy().into_owned()), None);
        replacement.scan_source = Some("manual".to_string());
        upsert_discovery_cache(&store, &replacement).unwrap();

        let document = store.read_collection(COLLECTION).unwrap();
        let items = document["items"].as_array().unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["target"], "alpha");
        assert_eq!(items[1]["target"], "codex");
        assert_eq!(items[1]["scanSource"], "manual");

        let routes = store.read_target_routes().unwrap();
        assert_eq!(routes.len(), 2);
        assert_eq!(routes[0].target, "alpha");
        assert_eq!(routes[1].target, "codex");
        assert_eq!(routes[1].scan_source, "manual");
        assert_eq!(store.target_index_parse_count(), 1);
        let _ = fs::remove_dir_all(dir);
    }
}
