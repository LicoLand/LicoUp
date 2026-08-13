use super::super::catalog::target_def;
use super::super::manual::ManualTarget;
use super::super::processes::ScanContext;
use super::super::scan_merge::scan_automatic_virtual_machine_target;
use super::super::scan_merge::scan_target_with_manual;
use super::super::support::display_path;
use super::super::virtual_machine_discovery::AutomaticVmTarget;
use super::test_support::temp_test_dir;
use crate::platform::virtual_machine::SshRuntimeConnection;
use serde_json::json;

#[test]
fn scan_merge_preserves_manual_projection_and_local_model_fixture() {
    let root = temp_test_dir("scan-merge-manual");
    let config_path = root.join("manual-config.json");
    let history_root = root.join("history");
    let manual = ManualTarget {
        target: "opencode".to_string(),
        label: "Manual OpenCode".to_string(),
        kind: "cli".to_string(),
        config_path: Some(config_path.clone()),
        binary_path: None,
        history_roots: vec![history_root.clone()],
        location: "local".to_string(),
        runtime_connection: None,
    };
    let params = json!({
        "homeDir": display_path(root),
        "runningProcessNames": [],
        "includeHistoryModelCatalog": false,
        "modelCatalogFixture": {
            "opencode": {
                "source": "fixture",
                "models": [{"id": "gpt-5.5", "name": "GPT-5.5"}]
            }
        }
    });
    let mut context = ScanContext::from_params(&params);

    let candidate = scan_target_with_manual(
        &target_def("opencode").unwrap(),
        Some(&manual),
        None,
        &mut context,
        &params,
    )
    .unwrap();

    assert!(candidate.manual);
    assert_eq!(candidate.label, "Manual OpenCode");
    assert_eq!(
        candidate.config_path.as_deref(),
        Some(display_path(config_path).as_str())
    );
    assert_eq!(candidate.history_roots, vec![display_path(history_root)]);
    assert_eq!(
        candidate.model_catalog.as_ref().unwrap()["status"],
        "available"
    );
    assert_eq!(
        candidate.model_catalog.as_ref().unwrap()["models"][0]["name"],
        "GPT-5.5"
    );
}

#[test]
fn scan_merge_projects_automatic_vm_as_transient_send_ready_route() {
    let guest_home = format!("/{}", ["users", "agent"].join("/"));
    let guest_python = format!("{guest_home}/.hermes/venv/bin/python");
    let connection = SshRuntimeConnection::from_value(
        Some(&json!({
            "kind": "ssh",
            "host": "orb",
            "user": "test-machine",
            "remoteExecutable": guest_python,
            "workingDirectory": guest_home,
            "runtimeProtocol": "hermes-tui-gateway"
        })),
        "hermes",
    )
    .unwrap()
    .unwrap();
    let candidate = scan_automatic_virtual_machine_target(
        &target_def("hermes").unwrap(),
        &AutomaticVmTarget {
            label: "Hermes Agent - CLI · test-machine".to_string(),
            runtime_connection: connection,
        },
    );

    assert_eq!(candidate.location, "virtual-machine");
    assert_eq!(candidate.status, "detected");
    assert!(candidate.configured);
    assert!(!candidate.manual);
    assert_eq!(
        candidate.scan_source.as_deref(),
        Some("virtual-machine-orbstack")
    );
    assert!(
        candidate
            .supported_actions
            .iter()
            .any(|action| action == "runtime.message.send")
    );
    assert_eq!(
        candidate.adapter_capabilities.conversation_protocol,
        "hermes-tui-gateway-stdio-jsonrpc"
    );
    assert_eq!(
        candidate
            .adapter_capabilities
            .conversation_capability_matrix["laneFamily"],
        "rpc"
    );
    assert_eq!(
        candidate
            .adapter_capabilities
            .conversation_capability_matrix["cancel"],
        false
    );
    assert!(!candidate.detail.contains("test-machine"));
}
