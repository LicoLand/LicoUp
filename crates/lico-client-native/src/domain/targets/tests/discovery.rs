use super::super::catalog::target_defs;
use super::super::scan_targets_with_params;
use super::super::support::display_path;
use super::test_support::temp_test_dir;
use crate::platform::runtime_adapters;
use serde_json::json;
use std::collections::BTreeSet;
use std::fs;

#[test]
fn scan_includes_required_first_targets() {
    let dir = temp_test_dir("local-source-catalog");
    let scan = scan_targets_with_params(&json!({
        "portableDir": dir.to_string_lossy(),
        "runningProcessNames": []
    }))
    .unwrap();
    assert_eq!(
        scan["scanScopes"],
        json!([
            "application-store",
            "package-manager",
            "executable-path",
            "local-configuration",
            "running-process"
        ])
    );
    let ids = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["target"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(
        ids,
        vec![
            "openclaw",
            "claude-code",
            "codex",
            "code",
            "antigravity",
            "opencode",
            "copilot",
            "kilo-code",
            "cursor",
            "hermes",
            "kimi",
            "kimi-code",
            "pi"
        ]
    );
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn target_ids_are_unique_and_runtime_projection_matches_packaging_authority() {
    let definitions = target_defs();
    let unique = definitions
        .iter()
        .map(|definition| definition.id)
        .collect::<BTreeSet<_>>();
    assert_eq!(unique.len(), definitions.len());

    let projected = definitions
        .iter()
        .filter_map(|definition| {
            runtime_adapters::runtime_driver_profile(definition.id).map(|_| definition.id)
        })
        .collect::<BTreeSet<_>>();
    let packaged = runtime_adapters::PACKAGED_RUNTIME_ADAPTER_IDS
        .iter()
        .copied()
        .collect::<BTreeSet<_>>();
    assert_eq!(projected, packaged);
}

#[test]
fn scan_candidate_has_adapter_capabilities_and_supported_actions() {
    let dir = temp_test_dir("scan-caps");
    let state_root = dir.join("client-state");
    let scan = scan_targets_with_params(&json!({
        "stateRoot": display_path(state_root)
    }))
    .unwrap();

    let opencode = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["target"] == "opencode")
        .unwrap();
    assert_eq!(opencode["adapterStatus"], "implemented");
    assert_eq!(
        opencode["adapterCapabilities"]["configApply"],
        "unsupported"
    );
    assert_eq!(
        opencode["adapterCapabilities"]["conversationProtocol"],
        runtime_adapters::runtime_driver_profile("opencode")
            .unwrap()
            .protocol
    );
    assert_eq!(
        opencode["adapterCapabilities"]["conversationReadiness"],
        "unverified"
    );
    assert_eq!(
        opencode["adapterCapabilities"]["conversationDriver"],
        "implemented"
    );
    assert!(
        opencode["adapterCapabilities"]["conversationBlocker"].is_null(),
        "unverified readiness must not fabricate a target-specific blocker"
    );
    assert!(
        opencode["adapterCapabilities"]["conversationSummaryCodes"]
            .as_array()
            .is_some_and(|codes| codes.iter().any(|code| code == "evidence_missing")),
        "global evidence status belongs in the canonical reducer summary codes"
    );

    let codex = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["target"] == "codex")
        .unwrap();
    assert_eq!(codex["adapterStatus"], "implemented");
    assert_eq!(codex["adapterCapabilities"]["configApply"], "unsupported");
    assert!(
        codex["supportedActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a == "skill.install")
    );
    assert_eq!(
        codex["adapterCapabilities"]["conversationReadiness"],
        "unverified"
    );
    assert!(
        !codex["supportedActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a == "runtime.message.send")
    );

    let copilot = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["target"] == "copilot")
        .unwrap();
    assert_eq!(
        copilot["adapterCapabilities"]["conversationReadiness"],
        "unverified"
    );
    assert!(
        !copilot["supportedActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a == "runtime.message.send")
    );

    let cursor = scan["candidates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["target"] == "cursor")
        .unwrap();
    assert!(
        !cursor["supportedActions"]
            .as_array()
            .unwrap()
            .iter()
            .any(|a| a == "runtime.message.send")
    );
}
