use super::super::artifact::{
    runtime_artifact_digest, runtime_executable, runtime_executable_with_discovery,
};
use super::super::params::timestamp;
use super::super::{RuntimeAdapter, RuntimeAdapterError};
use crate::platform::client_state::{
    ClientStateStore, TARGET_DISCOVERY_CACHE_SCHEMA, TargetRouteRecord,
};
use serde_json::{Map, json};
use std::fs;

#[test]
fn runtime_artifact_digest_tracks_the_opened_file_identity_and_content() {
    let root = std::env::temp_dir().join(format!(
        "lico-runtime-artifact-{}-{}",
        std::process::id(),
        timestamp()
    ));
    fs::create_dir_all(&root).unwrap();
    let executable = root.join("runtime-canary");
    fs::write(&executable, b"accepted-runtime").unwrap();
    let first = runtime_artifact_digest(&executable).unwrap();
    fs::write(&executable, b"different-runtime").unwrap();
    let second = runtime_artifact_digest(&executable).unwrap();
    let _ = fs::remove_dir_all(root);

    assert!(first.starts_with("sha256:"));
    assert_ne!(first, second);
}

#[test]
fn kilo_default_command_uses_the_native_discovery_binding_for_group_turns() {
    let root = std::env::temp_dir().join(format!(
        "lico-runtime-binding-{}-{}",
        std::process::id(),
        timestamp()
    ));
    let executable = root.join("extension/bin/kilo");
    fs::create_dir_all(executable.parent().unwrap()).unwrap();
    fs::write(&executable, b"fixture").unwrap();
    let previous =
        licoup_foundation::platform::paths::set_portable_data_dir_override(Some(root.clone()));
    let store = ClientStateStore::portable().unwrap();
    store
        .write_target_routes(&[TargetRouteRecord {
            schema_version: TARGET_DISCOVERY_CACHE_SCHEMA.to_string(),
            target: "kilo-code".to_string(),
            binary_path: Some(executable.to_string_lossy().into_owned()),
            config_path: None,
            scan_source: "fixture-extension".to_string(),
            runtime_ready: true,
            cached_at_epoch_seconds: 1,
            extension: Map::new(),
        }])
        .unwrap();

    let resolved = runtime_executable(RuntimeAdapter::KiloCode, "kilo").unwrap();
    licoup_foundation::platform::paths::set_portable_data_dir_override(previous);

    assert_eq!(
        resolved,
        fs::canonicalize(&executable)
            .unwrap()
            .to_string_lossy()
            .into_owned()
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn codex_default_command_prefers_fresh_bundled_discovery_over_cached_wrapper() {
    let root = std::env::temp_dir().join(format!(
        "lico-codex-runtime-precedence-{}-{}",
        std::process::id(),
        timestamp()
    ));
    let bundled = root.join("ChatGPT.app/Contents/Resources/codex-cli/bin/codex");
    let cached_wrapper = root.join("old-cache/codex");
    fs::create_dir_all(bundled.parent().unwrap()).unwrap();
    fs::create_dir_all(cached_wrapper.parent().unwrap()).unwrap();
    fs::write(&bundled, b"bundled codex").unwrap();
    fs::write(&cached_wrapper, b"cached wrapper").unwrap();

    let resolved = runtime_executable_with_discovery(
        RuntimeAdapter::Codex,
        "codex",
        |_| Ok(None),
        |_| Some(bundled.clone()),
        |_| Some(cached_wrapper),
    )
    .unwrap();
    assert_eq!(resolved, bundled.to_string_lossy());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn explicit_codex_executable_is_not_replaced_by_automatic_discovery() {
    let root = std::env::temp_dir().join(format!(
        "lico-codex-explicit-runtime-{}-{}",
        std::process::id(),
        timestamp()
    ));
    let explicit = root.join("selected/codex");
    fs::create_dir_all(explicit.parent().unwrap()).unwrap();
    fs::write(&explicit, b"explicit codex").unwrap();

    let resolved = runtime_executable_with_discovery(
        RuntimeAdapter::Codex,
        explicit.to_str().unwrap(),
        |_| panic!("explicit path must bypass manual selection"),
        |_| panic!("explicit path must bypass discovery"),
        |_| panic!("explicit path must bypass cache lookup"),
    )
    .unwrap();
    assert_eq!(
        resolved,
        fs::canonicalize(&explicit).unwrap().to_string_lossy()
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn codex_saved_manual_binary_path_precedes_the_bundled_default() {
    let root = std::env::temp_dir().join(format!(
        "lico-codex-manual-runtime-{}-{}",
        std::process::id(),
        timestamp()
    ));
    let state_root = root.join("client-state");
    let store = ClientStateStore::new(state_root.clone()).unwrap();
    let manual = root.join("selected/codex-custom");
    let bundled = root.join("ChatGPT.app/Contents/Resources/codex-cli/bin/codex");
    let stale = root.join("old-cache/codex");
    for path in [&manual, &bundled, &stale] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"synthetic Codex executable").unwrap();
    }
    crate::domain::targets::add_target(
        &crate::domain::target_port::agent_target_port(),
        &json!({
            "target": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "binaryPath": manual.to_string_lossy(),
        }),
    )
    .unwrap();

    let resolved = runtime_executable_with_discovery(
        RuntimeAdapter::Codex,
        "codex",
        |_| {
            crate::domain::targets::manual_runtime_executable_from_store(&store, "codex")
                .map_err(|_| RuntimeAdapterError::ExecutableUnavailable)
        },
        |_| Some(bundled),
        |_| Some(stale),
    )
    .unwrap();
    assert_eq!(resolved, manual.to_string_lossy());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn metadata_only_codex_entry_does_not_hide_a_bundled_default_from_stale_route() {
    let root = std::env::temp_dir().join(format!(
        "lico-codex-metadata-only-runtime-{}-{}",
        std::process::id(),
        timestamp()
    ));
    let state_root = root.join("client-state");
    let store = ClientStateStore::new(state_root.clone()).unwrap();
    let bundled = root.join("ChatGPT.app/Contents/Resources/codex-cli/bin/codex");
    let stale = root.join("old-cache/codex");
    for path in [&bundled, &stale] {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"synthetic Codex executable").unwrap();
    }
    crate::domain::targets::add_target(
        &crate::domain::target_port::agent_target_port(),
        &json!({
            "target": "codex",
            "stateRoot": state_root.to_string_lossy(),
            "label": "Metadata-only Codex entry",
        }),
    )
    .unwrap();
    assert_eq!(
        crate::domain::targets::manual_runtime_executable_from_store(&store, "codex").unwrap(),
        None,
    );

    let resolved = runtime_executable_with_discovery(
        RuntimeAdapter::Codex,
        "codex",
        |_| {
            crate::domain::targets::manual_runtime_executable_from_store(&store, "codex")
                .map_err(|_| RuntimeAdapterError::ExecutableUnavailable)
        },
        |_| Some(bundled.clone()),
        |_| Some(stale),
    )
    .unwrap();
    assert_eq!(resolved, bundled.to_string_lossy());

    let _ = fs::remove_dir_all(root);
}

#[test]
fn malformed_manual_codex_collection_blocks_automatic_and_cached_fallbacks() {
    let root = std::env::temp_dir().join(format!(
        "lico-codex-malformed-manual-runtime-{}-{}",
        std::process::id(),
        timestamp()
    ));
    let store = ClientStateStore::new(root.join("client-state")).unwrap();
    let targets_collection = store.collection_path("targets").unwrap();
    fs::write(targets_collection, b"{ malformed collection").unwrap();

    let resolved = runtime_executable_with_discovery(
        RuntimeAdapter::Codex,
        "codex",
        |_| {
            crate::domain::targets::manual_runtime_executable_from_store(&store, "codex")
                .map_err(|_| RuntimeAdapterError::ExecutableUnavailable)
        },
        |_| panic!("manual authority read failure must stop automatic discovery"),
        |_| panic!("manual authority read failure must stop cached fallback"),
    );
    assert_eq!(
        resolved.unwrap_err(),
        RuntimeAdapterError::ExecutableUnavailable
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn explicit_relative_command_is_not_replaced_by_discovery() {
    assert_eq!(
        runtime_executable(RuntimeAdapter::KiloCode, "custom-kilo").unwrap(),
        "custom-kilo"
    );
}
