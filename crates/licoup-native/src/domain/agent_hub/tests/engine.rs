use super::super::*;
use super::support::{portable_params, test_store};
use crate::domain::agent_hub::argv::RecordingArgvRunner;
use crate::domain::agent_hub::engine::{apply_with, plan_with, HubContext};
use serde_json::{json, Value};
use std::sync::Arc;

fn macos_params(name: &str) -> Value {
    portable_params(name).1
}

#[test]
fn plan_returns_selected_channel_and_apply_requires_confirmation_token() {
    let params = macos_params("plan-apply");
    let mut install = params.clone();
    install["agentId"] = json!("codex");
    let ctx = HubContext::with_runner(&install, Arc::new(RecordingArgvRunner::new())).unwrap();
    let planned = plan_with(&ctx, &install).unwrap();
    assert_eq!(planned["status"], "planned");
    assert_eq!(planned["selectedChannel"]["id"], "homebrew");
    assert_eq!(planned["selectedChannel"]["kind"], "homebrew");
    assert_eq!(
        planned["selectedChannel"]["argv"],
        json!(["brew", "install", "--cask", "codex"])
    );
    assert!(apply_with(&ctx, &install).is_err());

    let mut confirmed = install;
    confirmed["confirmation"] = planned["confirmation"].clone();
    let applied = apply_with(&ctx, &confirmed).unwrap();
    assert_eq!(applied["ok"], true);
    assert_eq!(applied["ownership"], "owned");
    assert_eq!(applied["status"], "needs-login");
    assert_eq!(applied["channelId"], "homebrew");
}

#[test]
fn apply_is_argv_only_and_records_fixed_package_manager_arguments() {
    let runner = RecordingArgvRunner::new();
    let mut params = macos_params("argv-only");
    params["agentId"] = json!("pi");
    let ctx = HubContext::with_runner(&params, Arc::new(runner.clone())).unwrap();
    let planned = plan_with(&ctx, &params).unwrap();
    assert_eq!(planned["selectedChannel"]["id"], "npm");
    let mut confirmed = params;
    confirmed["confirmation"] = planned["confirmation"].clone();
    apply_with(&ctx, &confirmed).unwrap();
    let recorded = runner.recorded();
    assert_eq!(recorded[0].0, "npm");
    assert_eq!(
        recorded[0].1,
        vec![
            "install".to_string(),
            "-g".to_string(),
            "@mariozechner/pi-coding-agent".to_string()
        ]
    );
    assert!(recorded
        .iter()
        .all(|(_, args)| !args.join(" ").contains('|')));
}

#[test]
fn external_discovery_is_not_taken_over_and_owned_lifecycle_stays_on_channel() {
    let mut params = macos_params("external");
    params["agentId"] = json!("opencode");
    params["discoveryCandidates"] = json!([{
        "target": "opencode",
        "status": "detected",
        "present": true,
        "location": "local"
    }]);
    let runner = RecordingArgvRunner::new();
    let ctx = HubContext::with_runner(&params, Arc::new(runner.clone())).unwrap();
    let planned = plan_with(&ctx, &params).unwrap();
    assert_eq!(planned["status"], "external_protected");
    assert_eq!(planned["ownership"], "external");
    assert_eq!(runner.recorded().len(), 0);

    let mut owned_params = macos_params("owned");
    owned_params["agentId"] = json!("opencode");
    let owned_ctx =
        HubContext::with_runner(&owned_params, Arc::new(RecordingArgvRunner::new())).unwrap();
    let install_plan = plan_with(&owned_ctx, &owned_params).unwrap();
    let mut confirmed = owned_params.clone();
    confirmed["confirmation"] = install_plan["confirmation"].clone();
    apply_with(&owned_ctx, &confirmed).unwrap();

    confirmed["operation"] = json!("update");
    let update_plan = plan_with(&owned_ctx, &confirmed).unwrap();
    assert_eq!(update_plan["selectedChannel"]["id"], "homebrew");
    assert_eq!(
        update_plan["selectedChannel"]["argv"],
        json!(["brew", "upgrade", "anomalyco/tap/opencode"])
    );
}

#[test]
fn cancel_before_runner_does_not_record_ownership() {
    let mut params = macos_params("cancel");
    params["agentId"] = json!("claude-code");
    let store = test_store("cancel");
    params["stateRoot"] = json!(store.root().to_string_lossy());
    let runner = RecordingArgvRunner::new();
    let ctx = HubContext {
        store,
        capabilities: crate::domain::agent_hub::contract::PlatformInstallCapabilities {
            os: "macos".to_string(),
            architecture: "aarch64".to_string(),
            managers: vec!["homebrew".to_string()],
            scan_generation: 1,
        },
        runner: Arc::new(runner.clone()),
    };
    let planned = plan_with(&ctx, &params).unwrap();
    let mut cancelled = params;
    cancelled["confirmation"] = planned["confirmation"].clone();
    cancelled["cancel"] = json!(true);
    let result = apply_with(&ctx, &cancelled).unwrap();
    assert_eq!(result["status"], "cancelled");
    assert!(runner.recorded().is_empty());
}

#[test]
fn public_plan_entry_selects_cursor_official_artifact_without_shell_pipe() {
    let mut params = macos_params("cursor-artifact");
    params["agentId"] = json!("cursor");
    params["platformCapabilities"] = json!({
        "os": "linux",
        "architecture": "x86_64",
        "managers": [],
        "scanGeneration": 3
    });
    let planned = plan(&params).unwrap();
    assert_eq!(planned["selectedChannel"]["kind"], "official-artifact");
    let argv = planned["selectedChannel"]["argv"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>();
    assert_eq!(argv[0], "tar");
    assert!(!argv.join(" ").contains('|'));
}
