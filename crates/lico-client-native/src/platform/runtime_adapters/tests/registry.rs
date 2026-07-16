use super::super::adapter::adapter_for_agent;
use super::super::registry::{
    DRIVER_INVENTORY_JSON, READINESS_JSON, parse_runtime_driver_registry, runtime_driver_profile,
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
fn canonical_resources_are_the_only_runtime_profile_source() {
    let registry = parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, READINESS_JSON).unwrap();
    assert_eq!(registry.drivers.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());
    assert_eq!(registry.readiness.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());

    let opencode = registry.profile("opencode").unwrap();
    assert_eq!(opencode.driver_status, "implemented");
    assert_eq!(opencode.readiness, "unverified");
    assert_eq!(opencode.protocol, opencode_driver::RUNTIME_PROTOCOL);
    assert_eq!(opencode.blocker, None);
    assert_eq!(opencode.evidence_age_class, "missing");
    assert!(
        opencode
            .summary_codes
            .contains(&"evidence_missing".to_string())
    );
    assert_eq!(
        opencode
            .capability_matrix
            .as_ref()
            .and_then(|matrix| matrix.get("laneFamily"))
            .and_then(Value::as_str),
        Some("serve-http")
    );

    let antigravity = registry.profile("antigravity").unwrap();
    assert_eq!(antigravity.driver_status, "blocked");
    assert_eq!(antigravity.readiness, "blocked");
    assert_eq!(
        antigravity.blocker.as_deref(),
        Some("antigravity_cli_structured_transport_unavailable")
    );
    assert_eq!(
        antigravity
            .capability_matrix
            .as_ref()
            .and_then(|matrix| matrix.get("laneFamily"))
            .and_then(Value::as_str),
        Some("unavailable")
    );
    assert!(registry.readiness.values().all(|entry| !entry.send_enabled));

    let cursor = registry.profile("cursor").unwrap();
    assert_eq!(cursor.driver_status, "blocked");
    assert_eq!(cursor.blocker.as_deref(), Some("safe_cleanup_unavailable"));
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
    let codex = readiness["adapters"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|entry| entry["agentId"] == "codex")
        .unwrap();
    codex["status"] = json!("ready");
    codex["sendEnabled"] = json!(true);
    let invalid_ready = serde_json::to_string(&readiness).unwrap();
    let profile = parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, &invalid_ready)
        .ok()
        .and_then(|registry| registry.profile("codex"));
    assert!(profile.is_none());
}
