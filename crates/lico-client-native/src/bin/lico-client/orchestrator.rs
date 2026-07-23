//! Thin CLI projection of the orchestrator IPC contract.

use anyhow::Result;
use lico_client_native::platform::orchestrator_control_plane::build_cli_orchestrator_request;
use lico_client_native::platform::orchestrator_ipc::{
    OrchestratorIpcClient, OrchestratorIpcReceipt, OrchestratorIpcRequest,
};
use lico_client_native::platform::orchestrator_service::{
    OrchestratorServiceLifecycle, OrchestratorServiceOptions, default_orchestrator_state_root,
};
use std::{fs, path::PathBuf, time::Duration};

pub fn is_orchestrator_command(args: &[String]) -> bool {
    args.first().is_some_and(|value| value == "orchestrator")
}

pub fn execute(args: &[String]) -> Result<i32> {
    let command = args.get(1).map(String::as_str).unwrap_or_default();
    let explicit_state_root = option(args, "--state-root").map(PathBuf::from);
    let state_root = match explicit_state_root.clone() {
        Some(path) => path,
        None => match default_orchestrator_state_root() {
            Ok(path) => path,
            Err(_) => return emit_error("request", "service_unavailable"),
        },
    };
    if command == "serve" {
        let options = OrchestratorServiceOptions {
            state_root,
            ready_file: cfg!(debug_assertions)
                .then(|| option(args, "--ready-file").map(PathBuf::from))
                .flatten(),
            acceptance_control_root: cfg!(debug_assertions)
                .then(|| option(args, "--acceptance-control-root").map(PathBuf::from))
                .flatten(),
        };
        return match OrchestratorServiceLifecycle::serve_foreground(options) {
            Ok(()) => Ok(0),
            Err(failure) => emit_error("serve", failure.code),
        };
    }
    let expected = match command {
        "status" => "service.status",
        "stop" => "service.stop",
        "register-policy" => "policy.register",
        "activate-policy" => "policy.activate",
        "submit" => "workflow.submit",
        "workflow-status" => "workflow.status",
        "cancel" => "workflow.cancel",
        "approve" => "workflow.approve",
        "events" => "workflow.events",
        "wait" => "workflow.wait",
        "message" => "workflow.message",
        _ => return emit_error("command", "invalid_request"),
    };
    // Discovery intentionally precedes capability validation so an absent service
    // has one stable result independent of client-side handles.
    let request: OrchestratorIpcRequest = match option(args, "--request-file") {
        Some(request_file) => match fs::read(&request_file)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        {
            Some(request) => request,
            None => return emit_error("request", "invalid_request"),
        },
        None => match build_cli_orchestrator_request(&args[1..]) {
            Ok(request) => request,
            Err(_) => return emit_error("request", "invalid_request"),
        },
    };
    if request.method != expected {
        return emit_error(&request.request_id, "invalid_request");
    }
    let acceptance_mode = cfg!(debug_assertions) && explicit_state_root.is_some();
    let timeout = request
        .params
        .get("timeoutMs")
        .and_then(serde_json::Value::as_u64)
        .map(|millis| Duration::from_millis(millis.saturating_add(2_000)))
        .unwrap_or(Duration::from_secs(10));
    let client = OrchestratorIpcClient::new(state_root)
        .with_timeout(timeout)
        .with_acceptance_controls(
            acceptance_mode,
            option(args, "--capability-handle"),
            option(args, "--acceptance-hold-id"),
        );
    emit(client.execute(&request))
}

fn option(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|value| value == name)
        .and_then(|index| args.get(index + 1))
        .filter(|value| !value.starts_with("--"))
        .cloned()
}

fn emit(receipt: OrchestratorIpcReceipt) -> Result<i32> {
    println!("{}", serde_json::to_string(&receipt)?);
    Ok(if receipt.ok { 0 } else { 2 })
}

fn emit_error(request_id: &str, code: &'static str) -> Result<i32> {
    emit(OrchestratorIpcReceipt::failure(request_id, code))
}
