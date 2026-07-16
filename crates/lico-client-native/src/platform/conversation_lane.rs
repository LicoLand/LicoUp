//! Conversation dispatch lane operations (open/resume, cancel, capabilities).
//!
//! Extends the existing `runtime_adapters::send_message` path without a parallel
//! executor registry. Protocol families stay selected by `RuntimeAdapter`.

use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use super::runtime_adapters::{self, RuntimeAdapter};

const CONVERSATION_READINESS_JSON: &str =
    include_str!("../../resources/agent-conversation-readiness.json");
const CONVERSATION_DRIVER_INVENTORY_JSON: &str =
    include_str!("../../resources/agent-conversation-drivers.json");
const ACCEPTANCE_MODE: &str = "dispatch-lane-unified-1";
const ACCEPTANCE_ENVIRONMENT: &str = "LICO_AGENT_CONVERSATION_ACCEPTANCE";
static SEND_ENABLED_AGENT_IDS: LazyLock<HashSet<String>> = LazyLock::new(|| {
    serde_json::from_str::<Value>(CONVERSATION_READINESS_JSON)
        .ok()
        .and_then(|document| document.get("adapters").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .into_iter()
        .filter(|adapter| {
            adapter.get("status").and_then(Value::as_str) == Some("ready")
                && adapter.get("sendEnabled").and_then(Value::as_bool) == Some(true)
        })
        .filter_map(|adapter| {
            adapter
                .get("agentId")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .collect()
});
static CAPABILITY_MATRIX_BY_AGENT: LazyLock<HashMap<String, Value>> = LazyLock::new(|| {
    serde_json::from_str::<Value>(CONVERSATION_DRIVER_INVENTORY_JSON)
        .ok()
        .and_then(|document| document.get("drivers").and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|driver| {
            let agent_id = driver.get("agentId")?.as_str()?.to_owned();
            let matrix = driver.get("capabilityMatrix")?.clone();
            Some((agent_id, matrix))
        })
        .collect()
});

fn readiness_send_enabled(agent_id: &str) -> bool {
    SEND_ENABLED_AGENT_IDS.contains(agent_id)
}

fn acceptance_send_enabled(params: &Value) -> bool {
    params.get("acceptanceMode").and_then(Value::as_str) == Some(ACCEPTANCE_MODE)
        && std::env::var(ACCEPTANCE_ENVIRONMENT).as_deref() == Ok(ACCEPTANCE_MODE)
}

/// Keep every public send entry point aligned with the reducer-owned support
/// matrix. The live acceptance harness uses an explicit two-part opt-in while
/// gathering the evidence required to promote an adapter; ordinary CLI and UI
/// callers cannot accidentally bypass a fail-closed readiness result.
pub fn enforce_send_readiness(params: &Value) -> Result<()> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    if readiness_send_enabled(adapter.id()) || acceptance_send_enabled(params) {
        return Ok(());
    }
    Err(anyhow!(
        "agent_conversation_send_not_ready: {} is not enabled by canonical readiness",
        adapter.id()
    ))
}

/// Official lane family for an adapter (Architecture strategy key).
pub fn lane_family(adapter: RuntimeAdapter) -> &'static str {
    CAPABILITY_MATRIX_BY_AGENT
        .get(adapter.id())
        .and_then(|matrix| matrix.get("laneFamily"))
        .and_then(Value::as_str)
        .unwrap_or("unavailable")
}

/// Static capability matrix aligned with Evidence.md / drivers inventory.
/// Field names avoid reducer-sensitive fragments (session/path/argv/…).
/// `approvals` means an end-to-end client response bridge, not merely that the
/// native protocol can report and fail closed on an interaction request.
pub fn static_capability_matrix(adapter: RuntimeAdapter) -> Value {
    CAPABILITY_MATRIX_BY_AGENT
        .get(adapter.id())
        .cloned()
        .unwrap_or_else(|| {
            json!({
                "laneFamily": "unavailable",
                "openNew": false,
                "exactResume": false,
                "streaming": false,
                "cancel": false,
                "interruptSteer": false,
                "structuredEvents": false,
                "approvals": false,
                "multimodal": false,
                "usageStatus": false,
                "officialLane": false
            })
        })
}

fn agent_id_param(params: &Value) -> Result<String> {
    runtime_adapters::text_param_public(params, &["agent", "agentId", "target"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("agent conversation request requires an agent identifier"))
}

fn adapter_or_err(agent_id: &str) -> Result<RuntimeAdapter> {
    runtime_adapters::adapter_for_agent_public(agent_id)
        .ok_or_else(|| anyhow!("unsupported runtime adapter: {}", agent_id))
}

/// Open or resume a native conversation binding without sending a prompt.
pub fn open_or_resume(params: &Value) -> Result<Value> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    let native_id = runtime_adapters::text_param_public(params, &["sessionId", "nativeSessionId"])
        .unwrap_or_default();
    let matrix = static_capability_matrix(adapter);
    let profile = runtime_adapters::runtime_driver_profile(&agent_id);
    let blocker = profile.as_ref().and_then(|p| p.blocker.clone());
    let driver_mode = profile
        .as_ref()
        .map(|p| p.driver_status.clone())
        .unwrap_or_else(|| "unknown".to_string());

    if lane_family(adapter) == "unavailable" {
        return Ok(json!({
            "ok": false,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "driverId": adapter.driver_id(),
            "runtimeProtocol": adapter.runtime_protocol(),
            "capabilities": matrix,
            "error": {
                "code": blocker.unwrap_or_else(|| "antigravity_cli_structured_transport_unavailable".to_string()),
                "stage": "capability/transport",
                "message": "No official public conversation transport is available for this adapter."
            }
        }));
    }

    let mut serve_status = Value::Null;
    let mut gateway_status = Value::Null;
    if adapter == RuntimeAdapter::OpenCode {
        // Init/bootstrap owns auto-start. Open discloses serve state and may
        // refresh attach metadata, but must not fail the binding when the
        // binary is absent — send/execute still fail-closed via ensure_attach.
        serve_status = crate::platform::opencode_serve::status(&json!({}))
            .or_else(|_| crate::platform::opencode_serve::ensure(&json!({})))
            .unwrap_or_else(|_| {
                json!({
                    "ok": false,
                    "status": "unavailable",
                    "running": false,
                    "healthy": false,
                    "errorCode": "opencode_serve_unavailable"
                })
            });
        if serve_status.get("running").and_then(Value::as_bool) != Some(true) {
            if let Ok(ensured) = crate::platform::opencode_serve::ensure(&json!({
                "healthTimeoutMs": 8_000
            })) {
                serve_status = ensured;
            }
        }
    }
    if adapter == RuntimeAdapter::OpenClaw {
        // Prefer vendor Gateway attach/reuse (18789); never steal that port.
        // Disclose gateway state on open; send still fail-closes via ensure.
        gateway_status = crate::platform::openclaw_gateway::ensure(&json!({
            "healthTimeoutMs": 8_000
        }))
        .unwrap_or_else(|_| {
            json!({
                "ok": false,
                "status": "unavailable",
                "running": false,
                "healthy": false,
                "errorCode": "openclaw_gateway_unavailable",
                "vendorDefaultPort": crate::platform::openclaw_gateway::VENDOR_DEFAULT_PORT
            })
        });
    }

    if !native_id.is_empty() {
        let exact_resume = matrix.get("exactResume").and_then(Value::as_bool) == Some(true);
        if !exact_resume {
            let code = blocker.unwrap_or_else(|| "exact_session_resume_unavailable".to_string());
            return Ok(json!({
                "ok": false,
                "agentId": adapter.id(),
                "laneFamily": lane_family(adapter),
                "driverId": adapter.driver_id(),
                "runtimeProtocol": adapter.runtime_protocol(),
                "capabilities": matrix,
                "gateway": gateway_status,
                "error": {
                    "code": code,
                    "stage": "session/resume",
                    "message": "Exact native resume is not available on an official lane for this adapter."
                }
            }));
        }
        if adapter == RuntimeAdapter::ClaudeCode
            && !super::claude_code_driver::has_live_session(&native_id)
        {
            return Ok(json!({
                "ok": false,
                "agentId": adapter.id(),
                "laneFamily": lane_family(adapter),
                "driverId": adapter.driver_id(),
                "runtimeProtocol": adapter.runtime_protocol(),
                "capabilities": matrix,
                "error": {
                    "code": "claude_code_live_session_unavailable",
                    "stage": "session/resume",
                    "message": "The exact Claude Code streaming process is not available in this client process."
                }
            }));
        }
    }

    Ok(json!({
        "ok": true,
        "agentId": adapter.id(),
        "laneFamily": lane_family(adapter),
        "driverId": adapter.driver_id(),
        "runtimeProtocol": adapter.runtime_protocol(),
        "nativeSessionId": native_id,
        "sessionId": native_id,
        "threadId": native_id,
        "openMode": if native_id.is_empty() { "new" } else { "resume" },
        "driverStatus": driver_mode,
        "capabilities": matrix,
        "serve": serve_status,
        "gateway": gateway_status,
        "events": []
    }))
}

/// Cancel an in-flight turn when the canonical driver owns a supervised,
/// process-local active-turn handle. Other adapters fail closed.
pub fn cancel_turn(params: &Value) -> Result<Value> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    let matrix = static_capability_matrix(adapter);

    if lane_family(adapter) == "unavailable" {
        return Ok(json!({
            "ok": false,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "status": "blocked",
            "error": {
                "code": "antigravity_cli_structured_transport_unavailable",
                "stage": "turn/cancel",
                "message": "Cancel is unavailable because no official conversation transport exists."
            },
            "capabilities": matrix
        }));
    }

    if matches!(
        adapter,
        RuntimeAdapter::Hermes | RuntimeAdapter::ClaudeCode | RuntimeAdapter::Cursor
    ) {
        let session_id =
            runtime_adapters::text_param_public(params, &["sessionId", "nativeSessionId"])
                .filter(|value| !value.is_empty())
                .ok_or_else(|| {
                    anyhow!("agent cancel requires an exact native session identifier")
                })?;
        let disposition = match adapter {
            RuntimeAdapter::ClaudeCode => match super::claude_code_driver::cancel(&session_id) {
                super::claude_code_driver::ControlDisposition::Accepted => 0,
                super::claude_code_driver::ControlDisposition::NoActiveTurn => 1,
                super::claude_code_driver::ControlDisposition::SessionUnavailable => 2,
                super::claude_code_driver::ControlDisposition::TransportUnavailable => 3,
            },
            RuntimeAdapter::Cursor => match super::cursor_driver::cancel(&session_id) {
                super::acp_session_transport::ControlDisposition::Accepted => 0,
                super::acp_session_transport::ControlDisposition::NoActiveTurn => 1,
                super::acp_session_transport::ControlDisposition::SessionUnavailable => 2,
                super::acp_session_transport::ControlDisposition::TransportUnavailable => 3,
            },
            _ => match super::hermes_driver::cancel(&session_id) {
                super::acp_session_transport::ControlDisposition::Accepted => 0,
                super::acp_session_transport::ControlDisposition::NoActiveTurn => 1,
                super::acp_session_transport::ControlDisposition::SessionUnavailable => 2,
                super::acp_session_transport::ControlDisposition::TransportUnavailable => 3,
            },
        };
        let prefix = match adapter {
            RuntimeAdapter::ClaudeCode => "claude_code",
            RuntimeAdapter::Cursor => "cursor",
            _ => "hermes",
        };
        let label = match adapter {
            RuntimeAdapter::ClaudeCode => "Claude Code",
            RuntimeAdapter::Cursor => "Cursor ACP",
            _ => "Hermes ACP",
        };
        let (ok, status, code, message) = match disposition {
            0 => (
                true,
                "cancel_requested",
                Value::Null,
                "The official lane accepted cancellation for the active native turn.",
            ),
            1 => (
                false,
                "not_active",
                json!(format!("{prefix}_turn_not_active")),
                "The selected native session has no active turn.",
            ),
            2 => (
                false,
                "not_found",
                json!(format!("{prefix}_session_unavailable")),
                "The selected native session is not bound to this client process.",
            ),
            _ => (
                false,
                "unavailable",
                json!(format!("{prefix}_cancel_transport_unavailable")),
                "The supervised native cancel channel is unavailable.",
            ),
        };
        return Ok(json!({
            "ok": ok,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "status": status,
            "transport": label,
            "error": if ok { Value::Null } else { json!({
                "code": code,
                "stage": "turn/cancel",
                "message": message
            }) },
            "capabilities": matrix
        }));
    }

    Ok(json!({
        "ok": false,
        "agentId": adapter.id(),
        "laneFamily": lane_family(adapter),
        "status": "unsupported",
        "error": {
            "code": "dispatch_cancel_unsupported",
            "stage": "turn/cancel",
            "message": "This official lane does not expose a supervised product cancel channel."
        },
        "capabilities": matrix
    }))
}

/// Reclaim adapter-owned conversation resources without deleting arbitrary
/// user history. Cleanup stops only the supervised transport bound to the
/// exact native session in this client process.
pub fn cleanup_conversation(params: &Value) -> Result<Value> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    let matrix = static_capability_matrix(adapter);
    if !matches!(
        adapter,
        RuntimeAdapter::Hermes | RuntimeAdapter::ClaudeCode | RuntimeAdapter::Cursor
    ) {
        return Ok(json!({
            "ok": false,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "status": "unsupported",
            "error": {
                "code": "dispatch_cleanup_unsupported",
                "stage": "session/cleanup",
                "message": "This lane has no process-local supervised cleanup channel."
            },
            "capabilities": matrix
        }));
    }
    let session_id = runtime_adapters::text_param_public(params, &["sessionId", "nativeSessionId"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("cleanup requires an exact native session identifier"))?;
    let disposition = match adapter {
        RuntimeAdapter::ClaudeCode => match super::claude_code_driver::cleanup_session(&session_id)
        {
            super::claude_code_driver::ControlDisposition::Accepted => 0,
            super::claude_code_driver::ControlDisposition::SessionUnavailable => 1,
            _ => 2,
        },
        RuntimeAdapter::Cursor => match super::cursor_driver::cleanup_session(&session_id) {
            super::acp_session_transport::ControlDisposition::Accepted => 0,
            super::acp_session_transport::ControlDisposition::SessionUnavailable => 1,
            _ => 2,
        },
        _ => match super::hermes_driver::cleanup_session(&session_id) {
            super::acp_session_transport::ControlDisposition::Accepted => 0,
            super::acp_session_transport::ControlDisposition::SessionUnavailable => 1,
            _ => 2,
        },
    };
    let prefix = match adapter {
        RuntimeAdapter::ClaudeCode => "claude_code",
        RuntimeAdapter::Cursor => "cursor",
        _ => "hermes",
    };
    let (ok, status, code) = match disposition {
        0 => (true, "cleaned", Value::Null),
        1 => (
            false,
            "not_found",
            json!(format!("{prefix}_session_unavailable")),
        ),
        _ => (
            false,
            "unavailable",
            json!(format!("{prefix}_cleanup_transport_unavailable")),
        ),
    };
    Ok(json!({
        "ok": ok,
        "agentId": adapter.id(),
        "laneFamily": lane_family(adapter),
        "status": status,
        "error": if ok { Value::Null } else { json!({
            "code": code,
            "stage": "session/cleanup",
            "message": "The selected supervised transport could not be cleaned."
        }) },
        "capabilities": matrix
    }))
}

/// Steer is intentionally a distinct lane operation. No packaged driver may
/// alias cancel or a second send into steer; adapters must expose a native,
/// exactly-once in-flight control channel before their inventory capability is
/// promoted.
pub fn steer_turn(params: &Value) -> Result<Value> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    let matrix = static_capability_matrix(adapter);
    let supported = matrix
        .get("interruptSteer")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !supported {
        return Ok(json!({
            "ok": false,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "status": "unsupported",
            "error": {
                "code": "dispatch_steer_unsupported",
                "stage": "turn/steer",
                "message": "This official lane does not expose a native in-flight steer channel."
            },
            "capabilities": matrix
        }));
    }
    Ok(json!({
        "ok": false,
        "agentId": adapter.id(),
        "laneFamily": lane_family(adapter),
        "status": "unavailable",
        "error": {
            "code": "dispatch_steer_transport_unavailable",
            "stage": "turn/steer",
            "message": "The declared native steer channel is not available."
        },
        "capabilities": matrix
    }))
}

/// Emit the per-agent capability matrix (inventory + static family matrix).
pub fn lane_capabilities(params: &Value) -> Result<Value> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    let matrix = runtime_adapters::inventory_capability_matrix(&agent_id)
        .unwrap_or_else(|| static_capability_matrix(adapter));
    let profile = runtime_adapters::runtime_driver_profile(&agent_id);
    let blocker_codes: Vec<String> = profile
        .as_ref()
        .and_then(|p| p.blocker.clone())
        .into_iter()
        .collect();

    Ok(json!({
        "ok": true,
        "agentId": adapter.id(),
        "laneFamily": lane_family(adapter),
        "driverId": adapter.driver_id(),
        "runtimeProtocol": adapter.runtime_protocol(),
        "driverStatus": profile.as_ref().map(|p| p.driver_status.clone()).unwrap_or_default(),
        "readiness": profile.as_ref().map(|p| p.readiness.clone()).unwrap_or_else(|| "unverified".to_string()),
        "blockerCodes": blocker_codes,
        "capabilities": matrix
    }))
}

/// Dispatch a conversation lane RPC/CLI operation by name.
pub fn dispatch_lane_operation(operation: &str, params: &Value) -> Result<Value> {
    match operation {
        "open" | "openOrResume" | "resume" => open_or_resume(params),
        "send" => runtime_adapters::send_message(params),
        "steer" => steer_turn(params),
        "cancel" => cancel_turn(params),
        "cleanup" => cleanup_conversation(params),
        "capabilities" | "caps" => lane_capabilities(params),
        "stream" => Ok(json!({
            "ok": true,
            "agentId": agent_id_param(params).unwrap_or_default(),
            "events": [],
            "streamTransport": "stdio_ndjson_on_send",
            "status": "bound_on_send",
            "hint": "Pass streamEvents=true (or --stream-events true) on agent conversation send to receive progressive agent.message.chunk NDJSON lines before the final result."
        })),
        _ => Err(anyhow!(
            "unsupported agent conversation operation: {}",
            operation
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn lane_families_cover_all_packaged_adapters() {
        assert_eq!(lane_family(RuntimeAdapter::Codex), "app-server");
        assert_eq!(lane_family(RuntimeAdapter::ClaudeCode), "stream-json");
        assert_eq!(lane_family(RuntimeAdapter::OpenCode), "serve-http");
        assert_eq!(lane_family(RuntimeAdapter::KiloCode), "serve-http");
        assert_eq!(lane_family(RuntimeAdapter::Pi), "rpc");
        assert_eq!(lane_family(RuntimeAdapter::Cursor), "acp");
        assert_eq!(lane_family(RuntimeAdapter::Antigravity), "unavailable");
    }

    #[test]
    fn canonical_readiness_blocks_unpromoted_product_send() {
        assert!(!readiness_send_enabled("antigravity"));
        let error = enforce_send_readiness(&json!({"agent": "antigravity"})).unwrap_err();
        assert!(
            error
                .to_string()
                .starts_with("agent_conversation_send_not_ready:")
        );
    }

    #[test]
    fn open_new_session_succeeds_for_ready_candidate_families() {
        let result = open_or_resume(&json!({"agent": "codex"})).unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["openMode"], "new");
        assert_eq!(result["laneFamily"], "app-server");
        assert_eq!(result["capabilities"]["exactResume"], true);
    }

    #[test]
    fn open_resume_requires_a_live_claude_process_and_accepts_cursor_binding() {
        let claude = open_or_resume(&json!({
            "agent": "claude-code",
            "sessionId": "native-1"
        }))
        .unwrap();
        assert_eq!(claude["ok"], false);
        assert_eq!(
            claude["error"]["code"],
            "claude_code_live_session_unavailable"
        );
        assert_eq!(claude["capabilities"]["processLocalContinuation"], true);

        let cursor = open_or_resume(&json!({
            "agent": "cursor",
            "sessionId": "native-2"
        }))
        .unwrap();
        assert_eq!(cursor["ok"], true);
        assert_eq!(cursor["openMode"], "resume");
        assert_eq!(cursor["laneFamily"], "acp");
        assert_eq!(cursor["capabilities"]["exactResume"], true);
    }

    #[test]
    fn antigravity_stays_structurally_blocked() {
        let result = open_or_resume(&json!({"agent": "antigravity"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(
            result["error"]["code"],
            "antigravity_cli_structured_transport_unavailable"
        );
    }

    #[test]
    fn cancel_reports_structured_disposition_per_family() {
        let acp = cancel_turn(&json!({"agent": "opencode", "sessionId": "s1"})).unwrap();
        assert_eq!(acp["ok"], false);
        assert_eq!(acp["status"], "unsupported");
        assert_eq!(acp["capabilities"]["cancel"], false);
        assert_eq!(acp["error"]["code"], "dispatch_cancel_unsupported");

        let claude = cancel_turn(&json!({"agent": "claude-code", "sessionId": "missing"})).unwrap();
        assert_eq!(claude["error"]["code"], "claude_code_session_unavailable");
    }

    #[test]
    fn steer_is_a_distinct_fail_closed_operation_until_a_native_channel_exists() {
        for agent in ["codex", "claude-code", "opencode", "hermes", "cursor"] {
            let result = steer_turn(&json!({
                "agent": agent,
                "sessionId": "native-session",
                "text": "follow-up"
            }))
            .unwrap();
            assert_eq!(result["ok"], false);
            assert_eq!(result["status"], "unsupported");
            assert_eq!(result["error"]["code"], "dispatch_steer_unsupported");
        }
    }

    #[test]
    fn hermes_exact_resume_is_available_on_the_persistent_acp_lane() {
        let result = open_or_resume(&json!({
            "agent": "hermes",
            "sessionId": "native-1"
        }))
        .unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["capabilities"]["exactResume"], true);
        assert_eq!(result["capabilities"]["cancel"], true);
    }

    #[test]
    fn capabilities_emit_matrix_and_blockers() {
        let caps = lane_capabilities(&json!({"agent": "cursor"})).unwrap();
        assert_eq!(caps["ok"], true);
        assert_eq!(caps["laneFamily"], "acp");
        assert_eq!(caps["capabilities"]["exactResume"], true);
        assert_eq!(caps["readiness"], "blocked");
        assert_eq!(caps["blockerCodes"], json!(["safe_cleanup_unavailable"]));
        let claude = lane_capabilities(&json!({"agent": "claude-code"})).unwrap();
        assert_eq!(claude["capabilities"]["exactResume"], true);
        assert_eq!(claude["readiness"], "unverified");
        assert_eq!(claude["blockerCodes"], json!([]));
    }

    #[test]
    fn lane_families_are_official_protocol_labels_only() {
        for family in [
            lane_family(RuntimeAdapter::Codex),
            lane_family(RuntimeAdapter::ClaudeCode),
            lane_family(RuntimeAdapter::OpenCode),
            lane_family(RuntimeAdapter::KiloCode),
            lane_family(RuntimeAdapter::Pi),
            lane_family(RuntimeAdapter::Cursor),
            lane_family(RuntimeAdapter::Antigravity),
        ] {
            assert!(matches!(
                family,
                "acp" | "app-server" | "cli" | "rpc" | "serve-http" | "stream-json" | "unavailable"
            ));
        }
    }
}
