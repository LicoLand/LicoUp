use super::binaries::{cursor_binary_supports_acp, find_target_binary_with_source};
use super::catalog::{
    TargetCandidate, TargetDef, adapter_capabilities_for, candidate_runtime_is_available,
    target_supports_skill_install,
};
use super::manual::ManualTarget;
use super::model_catalog::{empty_model_catalog, model_catalog_for_target};
use super::parameters::{param_bool, param_string};
use super::platform_paths::{default_config_path_with_params, default_detection_path_with_params};
use super::processes::{ScanContext, running_process_for, target_uses_running_process_detection};
use super::support::display_path;
use super::virtual_machine_discovery::AutomaticVmTarget;
use crate::platform::agent_workspace::default_local_agent_workspace;
use crate::platform::runtime_adapters;
use crate::platform::virtual_machine::SshRuntimeConnection;
use anyhow::Result;
use serde_json::{Value, json};
use std::path::PathBuf;

pub(super) fn scan_target_with_manual(
    def: &TargetDef,
    manual: Option<&ManualTarget>,
    automatic_vm: Option<&AutomaticVmTarget>,
    scan_context: &mut ScanContext,
    params: &Value,
) -> Result<TargetCandidate> {
    if let Some(manual) = manual.filter(|item| item.location == "virtual-machine") {
        return Ok(scan_virtual_machine_target(def, manual));
    }
    let config_path = manual
        .and_then(|item| item.config_path.clone())
        .or_else(|| default_config_path_with_params(def.id, params));
    let manual_binary = manual.and_then(|item| item.binary_path.clone());
    let located_binary = manual_binary
        .filter(|path| def.id != "cursor" || cursor_binary_supports_acp(path, params))
        .map(|path| (path, "manual"))
        .or_else(|| find_target_binary_with_source(def, params));
    let binary_path = located_binary.as_ref().map(|(path, _)| path.clone());
    let binary_source = located_binary.as_ref().map(|(_, source)| *source);
    let detection_path = default_detection_path_with_params(def.id, params);
    let history_roots = manual
        .map(|item| item.history_roots.clone())
        .unwrap_or_default();
    let config_exists = config_path
        .as_ref()
        .map(|path| path.exists())
        .unwrap_or(false);
    let detection_exists = detection_path
        .as_ref()
        .map(|path| path.exists())
        .unwrap_or(false);
    let detected_without_process = config_exists || binary_path.is_some() || detection_exists;
    let should_check_process = scan_context.running_processes_injected
        || (!detected_without_process && target_uses_running_process_detection(def.id));
    let running_process = if should_check_process {
        running_process_for(def, scan_context)
    } else {
        None
    };
    let detected =
        config_exists || binary_path.is_some() || detection_exists || running_process.is_some();
    let manual_entry = manual.is_some();
    if manual.is_none()
        && binary_path.is_none()
        && let Some(automatic_vm) = automatic_vm
    {
        return Ok(scan_automatic_virtual_machine_target(def, automatic_vm));
    }
    let configured = config_exists;
    let status = if configured {
        "configured"
    } else if detected {
        "detected"
    } else if manual_entry {
        "manual"
    } else {
        "not-detected"
    };
    let confidence = if configured {
        1.0
    } else if detected {
        0.72
    } else {
        0.15
    };
    let mut detail_parts = Vec::<String>::new();
    detail_parts.push(match (&config_path, &binary_path) {
        (Some(config), Some(binary)) => {
            format!(
                "{}: {}; binary: {}",
                def.config_hint,
                config.display(),
                binary.display()
            )
        }
        (Some(config), None) => format!("{}: {}", def.config_hint, config.display()),
        (None, Some(binary)) => format!("binary: {}", binary.display()),
        (None, None) => def.config_hint.to_string(),
    });
    if let Some(path) = detection_path
        .as_ref()
        .filter(|path| config_path.as_ref() != Some(path))
    {
        detail_parts.push(format!("evidence: {}", path.display()));
    }
    if let Some(process) = running_process.as_deref() {
        detail_parts.push(format!("process: {} running", process));
    }
    let base_detail = detail_parts.join("; ");
    let detail = if manual_entry {
        format!("Manual entry: {}", base_detail)
    } else {
        base_detail
    };
    let mut capabilities = adapter_capabilities_for(def.id);
    if let Some(binary) = binary_path.as_deref()
        && param_bool(params, "probeConversationRuntime") == Some(true)
    {
        let probe_cwd = param_string(params, "workingDirectory")
            .or_else(|| param_string(params, "cwd"))
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .or_else(|| default_local_agent_workspace(def.id));
        if let Some(probe_cwd) = probe_cwd.as_deref() {
            capabilities.conversation_probe =
                runtime_adapters::probe_runtime_driver(def.id, binary, probe_cwd);
        }
    } else if binary_path.is_some() {
        capabilities.conversation_probe = json!({
            "available": true,
            "supported": false,
            "errorCode": "probe_not_run"
        });
    } else {
        capabilities.conversation_probe = json!({
            "available": false,
            "supported": false,
            "errorCode": "runtime_not_detected"
        });
    }

    let runtime_available =
        candidate_runtime_is_available(&mut capabilities, def.id, binary_path.as_deref());
    let adapter_status = "implemented";
    let model_catalog = if detected || manual_entry {
        model_catalog_for_target(def.id, config_path.as_deref(), params)
    } else {
        empty_model_catalog("unavailable", "not-detected")
    };

    let mut supported_actions = Vec::new();
    if target_supports_skill_install(def.id) {
        supported_actions.push("skill.install".to_string());
    }
    if runtime_available {
        supported_actions.push("runtime.message.send".to_string());
    }

    Ok(TargetCandidate {
        id: Some(def.id.to_string()),
        target: def.id.to_string(),
        label: manual
            .map(|item| item.label.clone())
            .unwrap_or_else(|| def.label.to_string()),
        kind: manual
            .map(|item| item.kind.clone())
            .unwrap_or_else(|| def.kind.to_string()),
        status: status.to_string(),
        configured,
        confidence,
        detail,
        config_path: config_path.map(display_path),
        binary_path: binary_path.map(display_path),
        history_roots: history_roots.into_iter().map(display_path).collect(),
        location: "local".to_string(),
        runtime_connection: None,
        manual: manual_entry,
        adapter_status: adapter_status.to_string(),
        adapter_capabilities: capabilities,
        supported_actions,
        scan_source: Some(
            if manual_entry {
                "manual"
            } else if let Some(source) = binary_source {
                source
            } else if config_exists || detection_exists {
                "local-configuration"
            } else if running_process.is_some() {
                "running-process"
            } else {
                "host-local-discovery"
            }
            .to_string(),
        ),
        model_catalog: Some(model_catalog),
    })
}

fn scan_virtual_machine_target(def: &TargetDef, manual: &ManualTarget) -> TargetCandidate {
    project_virtual_machine_target(
        def,
        &manual.label,
        &manual.kind,
        manual.runtime_connection.as_ref(),
        true,
        "Manual virtual machine connection; runtime validation is deferred until use.",
        "Manual virtual machine connection is incomplete.",
        "virtual-machine-ssh",
    )
}

pub(super) fn scan_automatic_virtual_machine_target(
    def: &TargetDef,
    automatic: &AutomaticVmTarget,
) -> TargetCandidate {
    project_virtual_machine_target(
        def,
        &automatic.label,
        def.kind,
        Some(&automatic.runtime_connection),
        false,
        "Detected in an accessible local virtual machine; runtime validation is deferred until use.",
        "Automatic virtual machine connection is unavailable.",
        "virtual-machine-orbstack",
    )
}

#[allow(clippy::too_many_arguments)]
fn project_virtual_machine_target(
    def: &TargetDef,
    label: &str,
    kind: &str,
    runtime_connection: Option<&SshRuntimeConnection>,
    manual: bool,
    ready_detail: &str,
    unavailable_detail: &str,
    scan_source: &str,
) -> TargetCandidate {
    let mut capabilities = adapter_capabilities_for(def.id);
    let runtime_ready =
        runtime_connection.is_some() && runtime_adapters::runtime_driver_profile(def.id).is_some();
    let uses_hermes_gateway =
        runtime_connection.is_some_and(SshRuntimeConnection::is_hermes_tui_gateway);
    if uses_hermes_gateway {
        capabilities.conversation_protocol =
            crate::platform::hermes_tui_gateway::RUNTIME_PROTOCOL.to_string();
        if let Some(matrix) = capabilities.conversation_capability_matrix.as_object_mut() {
            matrix.insert("laneFamily".to_string(), json!("rpc"));
            matrix.insert("cancel".to_string(), json!(false));
            matrix.insert("interruptSteer".to_string(), json!(false));
        }
    }
    capabilities.conversation_probe = if runtime_ready {
        json!({
            "available": true,
            "supported": false,
            "errorCode": "probe_not_run",
            "transport": "ssh-stdio",
            "protocol": if uses_hermes_gateway {
                crate::platform::hermes_tui_gateway::RUNTIME_PROTOCOL
            } else {
                "acp"
            }
        })
    } else {
        json!({
            "available": false,
            "supported": false,
            "errorCode": "virtual_machine_connection_invalid"
        })
    };
    if runtime_ready {
        capabilities.conversation_blocker = None;
    }
    let supported_actions = runtime_ready
        .then(|| vec!["runtime.message.send".to_string()])
        .unwrap_or_default();
    TargetCandidate {
        id: Some(def.id.to_string()),
        target: def.id.to_string(),
        label: label.to_string(),
        kind: kind.to_string(),
        status: if runtime_ready {
            if manual { "configured" } else { "detected" }
        } else {
            if manual { "manual" } else { "not-detected" }
        }
        .to_string(),
        configured: runtime_ready,
        confidence: if runtime_ready {
            if manual { 1.0 } else { 0.92 }
        } else {
            0.15
        },
        detail: if runtime_ready {
            ready_detail
        } else {
            unavailable_detail
        }
        .to_string(),
        config_path: None,
        binary_path: runtime_connection
            .map(|connection| connection.remote_executable().to_string()),
        history_roots: Vec::new(),
        location: "virtual-machine".to_string(),
        runtime_connection: runtime_connection.map(|connection| connection.to_value()),
        manual,
        adapter_status: "implemented".to_string(),
        adapter_capabilities: capabilities,
        supported_actions,
        scan_source: Some(scan_source.to_string()),
        model_catalog: Some(empty_model_catalog(
            "unavailable",
            "virtual-machine-runtime-deferred",
        )),
    }
}
