use super::super::catalog::normalize_target;
use super::super::manual::manual_targets;
use super::super::parameters::target_param;
use super::super::platform_paths::default_config_path;
use super::super::support::{client_state_store, display_path};
use super::super::{
    add_target, inspect_target, inspect_target_with_params, scan_targets_with_params,
};
use super::test_support::{temp_test_dir, test_store};
use serde_json::json;
use std::fs;

fn guest_path(segments: &[&str]) -> String {
    format!("/{}", segments.join("/"))
}

#[test]
fn targets_add_persists_manual_entry_and_scan_uses_it() {
    let dir = temp_test_dir("manual-target");
    let state_root = dir.join("client-state");
    let config_path = dir.join("openclaw-runtime.json");
    let history_root = dir.join("openclaw-history");

    let added = add_target(&json!({
        "target": "openclaw",
        "stateRoot": display_path(state_root.clone()),
        "configPath": display_path(config_path.clone()),
        "historyRoot": display_path(history_root.clone()),
        "label": "OpenClaw VM"
    }))
    .unwrap();

    assert_eq!(added["ok"], true);
    assert_eq!(added["record"]["target"], "openclaw");
    assert_eq!(added["activity"]["type"], "target.manual.saved");

    let store = crate::platform::client_state::ClientStateStore::new(state_root.clone()).unwrap();
    let saved = store.read_collection("targets").unwrap();
    assert_eq!(saved["items"][0]["target"], "openclaw");
    assert_eq!(saved["items"][0]["manual"], true);
    assert_eq!(
        saved["items"][0]["historyRoots"][0],
        display_path(history_root.clone())
    );

    let scan = scan_targets_with_params(&json!({
        "stateRoot": display_path(state_root.clone())
    }))
    .unwrap();
    let openclaw = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["target"] == "openclaw")
        .unwrap();
    assert_eq!(openclaw["manual"], true);
    assert_eq!(openclaw["label"], "OpenClaw VM");
    assert_eq!(openclaw["status"], "manual");
    assert_eq!(openclaw["configPath"], display_path(config_path.clone()));
    assert_eq!(
        openclaw["historyRoots"][0],
        display_path(history_root.clone())
    );

    let inspected = inspect_target_with_params(&json!({
        "target": "openclaw",
        "stateRoot": display_path(state_root.clone())
    }))
    .unwrap();
    assert_eq!(inspected["target"]["manual"], true);
    assert_eq!(
        inspected["target"]["configPath"],
        display_path(config_path.clone())
    );
    assert_eq!(
        inspected["target"]["historyRoots"][0],
        display_path(history_root)
    );

    assert_eq!(inspected["target"]["configPath"], display_path(config_path));
}

#[test]
fn targets_add_projects_supported_virtual_machine_connection_without_local_paths() {
    let dir = temp_test_dir("manual-vm-target");
    let state_root = dir.join("client-state");
    let executable = guest_path(&["opt", "hermes", "bin", "hermes"]);
    let working_directory = guest_path(&["srv", "project"]);
    let added = add_target(&json!({
        "target": "hermes",
        "stateRoot": display_path(state_root.clone()),
        "location": "virtual-machine",
        "runtimeConnection": {
            "kind": "ssh",
            "host": "vm.example",
            "port": 2222,
            "user": "agent-user",
            "remoteExecutable": executable,
            "workingDirectory": working_directory
        }
    }))
    .unwrap();
    assert_eq!(added["record"]["location"], "virtual-machine");
    assert!(added["record"]["configPath"].is_null());
    assert!(
        added["record"]["historyRoots"]
            .as_array()
            .unwrap()
            .is_empty()
    );

    let scan = scan_targets_with_params(&json!({
        "stateRoot": display_path(state_root)
    }))
    .unwrap();
    let hermes = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["target"] == "hermes")
        .unwrap();
    assert_eq!(hermes["location"], "virtual-machine");
    assert_eq!(hermes["runtimeConnection"]["kind"], "ssh");
    assert_eq!(
        hermes["binaryPath"],
        guest_path(&["opt", "hermes", "bin", "hermes"])
    );
    assert_eq!(hermes["supportedActions"][0], "runtime.message.send");
    assert!(!hermes["detail"].as_str().unwrap().contains("vm.example"));
}

#[test]
fn targets_public_inspect_entrypoint_uses_default_scan_path() {
    let inspected = inspect_target("opencode").unwrap();
    assert_eq!(inspected["target"]["target"], "opencode");
}

#[test]
fn targets_target_params_and_aliases_are_normalized() {
    assert_eq!(
        target_param(&json!({"positionals": ["open_code"]})).unwrap(),
        "opencode"
    );
    assert_eq!(normalize_target("vscode"), "code");
    assert_eq!(normalize_target("claude"), "claude-code");
    assert_eq!(normalize_target("kilo-code"), "kilo-code");
    assert_eq!(normalize_target("kimi_code"), "kimi-code");
    assert_eq!(normalize_target("kimi-code"), "kimi-code");
    assert_eq!(normalize_target("moonshot"), "moonshot");
    assert_eq!(normalize_target("moonshot"), "moonshot");
    assert_eq!(normalize_target("kimi"), "kimi");
}

#[test]
fn targets_add_updates_existing_manual_entry_created_at() {
    let dir = temp_test_dir("manual-update");
    let state_root = dir.join("client-state");
    let first = add_target(&json!({
        "target": "opencode",
        "stateRoot": display_path(state_root.clone()),
        "label": "First"
    }))
    .unwrap();
    let second = add_target(&json!({
        "target": "opencode",
        "stateRoot": display_path(state_root),
        "label": "Second"
    }))
    .unwrap();
    assert_eq!(first["record"]["createdAt"], second["record"]["createdAt"]);
    assert_eq!(second["record"]["label"], "Second");
}

#[test]
fn targets_manual_target_filter_skips_invalid_items() {
    let store = test_store("manual-targets-invalid");
    let items = json!({
        "collection": "targets",
        "items": [
            {"target": "", "label": "bad-target"},
            {"target": "non-existent", "label": "missing"},
            {"target": "opencode", "label": "OpenCode"}
        ]
    });
    store.write_collection("targets", items).unwrap();

    let items = manual_targets(&store).unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].target, "opencode");
}

#[test]
fn targets_uses_portable_dir_state_root_and_default_config_path_fallback() {
    let dir = temp_test_dir("portable-state-root");
    let portable_root = dir.join("portable");
    fs::create_dir_all(&portable_root).unwrap();
    let store = client_state_store(&json!({
        "portableDir": portable_root.to_string_lossy()
    }))
    .unwrap();
    assert_eq!(store.root(), portable_root.join("client-state"));

    assert!(default_config_path("openclaw").is_none());
}
