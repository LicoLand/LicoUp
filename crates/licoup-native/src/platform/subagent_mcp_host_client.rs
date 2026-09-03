//! Bounded client for the already-running private PersistentTurn host.
//!
//! This is not MCP framing and carries no provider policy. It is the one
//! transport used by all Subagent runtime adapters to reach Canonical
//! Conversation execution.

use super::conversation_host_transport;
use anyhow::{Result, anyhow};
use interprocess::local_socket::{Stream, traits::Stream as _};
use serde_json::{Value, json};
use std::io::{self, Read, Write};
use std::thread;
use std::time::{Duration, Instant};

const FRAME_LIMIT: usize = 64 * 1024;
const IO_WAIT: Duration = Duration::from_secs(3);

pub(crate) fn execute(method: &str, params: &Value) -> Result<Value> {
    execute_with_connector(method, params, conversation_host_transport::connect)
}

pub(crate) fn execute_read_only(method: &str, params: &Value) -> Result<Value> {
    execute_existing(method, params)
}

/// Execute through an already-running Conversation host without creating an
/// endpoint or retrying through a process-local ConversationService.
pub(crate) fn execute_existing(method: &str, params: &Value) -> Result<Value> {
    execute_with_connector(
        method,
        params,
        conversation_host_transport::connect_existing,
    )
}

fn execute_with_connector(
    method: &str,
    params: &Value,
    connect: fn() -> io::Result<Stream>,
) -> Result<Value> {
    let mut stream =
        connect().map_err(|_| anyhow!("persistent_conversation_transport_required"))?;
    stream
        .set_nonblocking(true)
        .map_err(|_| anyhow!("subagent_transport_failed"))?;
    let request_id = format!("subagent-{}", uuid::Uuid::new_v4().simple());
    let mut encoded = serde_json::to_vec(&json!({
        "protocol": conversation_host_transport::STDIO_RPC_PROTOCOL,
        "id": request_id,
        "workflowId": request_id,
        "method": method,
        "params": params,
    }))
    .map_err(|_| anyhow!("subagent_transport_failed"))?;
    encoded.push(b'\n');
    if encoded.len() > FRAME_LIMIT {
        return Err(anyhow!("subagent_request_too_large"));
    }
    let deadline = Instant::now() + IO_WAIT;
    let mut written = 0;
    while written < encoded.len() {
        if Instant::now() >= deadline {
            return Err(anyhow!("subagent_transport_timeout"));
        }
        match stream.write(&encoded[written..]) {
            Ok(0) => return Err(anyhow!("subagent_transport_failed")),
            Ok(count) => written += count,
            Err(error) if transient(&error) => thread::sleep(Duration::from_millis(5)),
            Err(_) => return Err(anyhow!("subagent_transport_failed")),
        }
    }
    stream
        .flush()
        .map_err(|_| anyhow!("subagent_transport_failed"))?;

    let mut response = Vec::with_capacity(1024);
    let mut buffer = [0_u8; 4096];
    loop {
        if Instant::now() >= deadline || response.len() >= FRAME_LIMIT {
            return Err(anyhow!("subagent_transport_timeout"));
        }
        match stream.read(&mut buffer) {
            Ok(0) => return Err(anyhow!("subagent_transport_failed")),
            Ok(count) => {
                response.extend_from_slice(&buffer[..count]);
                if let Some(end) = response.iter().position(|byte| *byte == b'\n') {
                    response.truncate(end);
                    break;
                }
            }
            Err(error) if transient(&error) => thread::sleep(Duration::from_millis(5)),
            Err(_) => return Err(anyhow!("subagent_transport_failed")),
        }
    }
    let frame: Value = serde_json::from_slice(&response)
        .map_err(|_| anyhow!("subagent_transport_invalid_response"))?;
    if frame.get("protocol").and_then(Value::as_str)
        != Some(conversation_host_transport::STDIO_RPC_PROTOCOL)
        || frame.get("id").and_then(Value::as_str) != Some(request_id.as_str())
        || frame.get("workflowId").and_then(Value::as_str) != Some(request_id.as_str())
    {
        return Err(anyhow!("subagent_transport_invalid_response"));
    }
    if frame.get("ok").and_then(Value::as_bool) != Some(true) {
        return Err(anyhow!(stable_error_code(
            frame.pointer("/error/code").and_then(Value::as_str)
        )));
    }
    let result = frame
        .get("result")
        .cloned()
        .ok_or_else(|| anyhow!("subagent_transport_invalid_response"))?;
    if result.get("ok").and_then(Value::as_bool) == Some(false) {
        return Err(anyhow!(stable_error_code(
            result.pointer("/error/code").and_then(Value::as_str)
        )));
    }
    Ok(result)
}

fn transient(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
    )
}

fn stable_error_code(code: Option<&str>) -> &'static str {
    match code {
        Some("conversation_not_found") => "conversation_not_found",
        Some("conversation_state_unavailable") => "conversation_state_unavailable",
        Some("invalid_request") => "invalid_request",
        Some("subagent_self_call_rejected") => "subagent_self_call_rejected",
        Some("subagent_caller_membership_inactive") => "subagent_caller_membership_inactive",
        Some("subagent_target_membership_inactive") => "subagent_target_membership_inactive",
        Some("subagent_target_invalid") => "subagent_target_invalid",
        Some("subagent_duplicate_active_edge") => "subagent_duplicate_active_edge",
        Some("subagent_parent_dispatch_unavailable") => "subagent_parent_dispatch_unavailable",
        Some("subagent_cross_conversation_rejected") => "subagent_cross_conversation_rejected",
        Some("subagent_lineage_caller_mismatch") => "subagent_lineage_caller_mismatch",
        Some("subagent_lineage_cycle") => "subagent_lineage_cycle",
        Some("subagent_depth_exceeded") => "subagent_depth_exceeded",
        Some("subagent_dispatch_not_found") => "subagent_dispatch_not_found",
        Some("subagent_dispatch_transition_invalid") => "subagent_dispatch_transition_invalid",
        Some("turn_not_found") => "subagent_turn_not_found",
        Some("turn_not_active") => "subagent_turn_not_active",
        Some("turn_scope_mismatch") => "subagent_turn_scope_mismatch",
        Some("conversation_capacity_exhausted") => "subagent_capacity_exhausted",
        Some("persistent_conversation_transport_required") => {
            "persistent_conversation_transport_required"
        }
        _ => "subagent_transport_failed",
    }
}
