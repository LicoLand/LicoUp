use super::super::adapter::adapter_for_agent;
use super::super::registry::{
    DRIVER_INVENTORY_JSON, READINESS_JSON, adapter_management_catalog,
    parse_runtime_driver_registry, runtime_driver_profile,
};
use super::super::{PACKAGED_RUNTIME_ADAPTER_IDS, RuntimeAdapter};
use crate::platform::opencode_driver;
use serde_json::{Value, json};

#[test]
fn packaged_dispatch_ids_are_unique_and_complete() {
    let unique = PACKAGED_RUNTIME_ADAPTER_IDS
        .iter()
        .copied()
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(unique.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());
    for id in PACKAGED_RUNTIME_ADAPTER_IDS {
        assert_eq!(adapter_for_agent(id).map(RuntimeAdapter::id), Some(*id));
        assert!(runtime_driver_profile(id).is_some());
    }
}

#[test]
fn management_catalog_distinguishes_bundled_native_and_installable_bridges() {
    let catalog = adapter_management_catalog(false);
    let adapters = catalog["adapters"].as_array().unwrap();
    assert_eq!(adapters.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());

    let by_id = adapters
        .iter()
        .map(|entry| (entry["agentId"].as_str().unwrap(), entry))
        .collect::<std::collections::BTreeMap<_, _>>();
    assert_eq!(by_id["kimi-code"]["managementKind"], "bundled-acp");
    assert_eq!(by_id["codex"]["managementKind"], "native");
    assert_eq!(by_id["antigravity"]["managementKind"], "managed-bridge");
    assert_eq!(by_id["antigravity"]["lifecycleActions"], json!(["install"]));

    let installed = adapter_management_catalog(true);
    let antigravity = installed["adapters"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["agentId"] == "antigravity")
        .unwrap();
    assert_eq!(antigravity["installationState"], "installed");
    assert_eq!(antigravity["lifecycleActions"], json!(["uninstall"]));
}

#[test]
fn canonical_resources_are_the_only_runtime_profile_source() {
    let registry = parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, READINESS_JSON).unwrap();
    assert_eq!(registry.drivers.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());
    assert_eq!(registry.readiness.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());

    let opencode = registry.profile("opencode").unwrap();
    assert_eq!(opencode.driver_status, "implemented");
    assert_eq!(opencode.protocol, opencode_driver::RUNTIME_PROTOCOL);
    assert_eq!(opencode.blocker, None);
    assert_eq!(
        opencode
            .capability_matrix
            .as_ref()
            .and_then(|matrix| matrix.get("laneFamily"))
            .and_then(Value::as_str),
        Some("serve-http")
    );

    let antigravity = registry.profile("antigravity").unwrap();
    assert_eq!(antigravity.driver_status, "implemented");
    assert_eq!(antigravity.readiness, "unverified");
    assert_eq!(antigravity.blocker, None);
    assert_eq!(antigravity.evidence_age_class, "stale");
    assert!(
        antigravity
            .summary_codes
            .contains(&"evidence_stale_or_incomplete".to_string())
    );
    assert_eq!(
        antigravity
            .capability_matrix
            .as_ref()
            .and_then(|matrix| matrix.get("laneFamily"))
            .and_then(Value::as_str),
        Some("cli")
    );

    let cursor = registry.profile("cursor").unwrap();
    assert_eq!(cursor.driver_status, "implemented");
    assert_eq!(cursor.blocker, None);
}

#[test]
fn malformed_or_set_drifted_resources_fail_closed() {
    assert!(parse_runtime_driver_registry("{}", READINESS_JSON).is_err());
    assert!(parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, "{}").is_err());

    let mut inventory = serde_json::from_str::<Value>(DRIVER_INVENTORY_JSON).unwrap();
    inventory["drivers"].as_array_mut().unwrap().pop();
    let drifted_inventory = serde_json::to_string(&inventory).unwrap();
    assert!(parse_runtime_driver_registry(&drifted_inventory, READINESS_JSON).is_err());

    let mut readiness = serde_json::from_str::<Value>(READINESS_JSON).unwrap();
    readiness["adapters"].as_array_mut().unwrap().pop();
    let drifted_readiness = serde_json::to_string(&readiness).unwrap();
    assert!(parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, &drifted_readiness).is_err());
}

#[test]
fn protocol_drift_and_incomplete_ready_claims_fail_closed() {
    let mut inventory = serde_json::from_str::<Value>(DRIVER_INVENTORY_JSON).unwrap();
    inventory["drivers"][0]["runtimeProtocol"] = json!("drifted-protocol");
    let drifted_inventory = serde_json::to_string(&inventory).unwrap();
    assert!(parse_runtime_driver_registry(&drifted_inventory, READINESS_JSON).is_err());

    let mut readiness = serde_json::from_str::<Value>(READINESS_JSON).unwrap();
    let claude = readiness["adapters"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|entry| entry["agentId"] == "claude-code")
        .unwrap();
    claude["status"] = json!("ready");
    claude["sendEnabled"] = json!(true);
    let invalid_ready = serde_json::to_string(&readiness).unwrap();
    let profile = parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, &invalid_ready)
        .ok()
        .and_then(|registry| registry.profile("claude-code"));
    assert!(profile.is_none());
}
