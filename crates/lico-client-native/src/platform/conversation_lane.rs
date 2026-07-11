//! Conversation dispatch lane operations (open/resume, cancel, capabilities).
//!
//! Extends the existing `runtime_adapters::send_message` path without a parallel
//! executor registry. Protocol families stay selected by `RuntimeAdapter`.

use anyhow::{Result, anyhow};
use serde_json::{Value, json};

use super::runtime_adapters::{self, RuntimeAdapter};

/// Official lane family for an adapter (Architecture strategy key).
pub fn lane_family(adapter: RuntimeAdapter) -> &'static str {
    match adapter {
        RuntimeAdapter::OpenCode
        | RuntimeAdapter::Copilot
        | RuntimeAdapter::Cursor
        | RuntimeAdapter::KiloCode
        | RuntimeAdapter::KimiCode
        | RuntimeAdapter::OpenClaw
        | RuntimeAdapter::Hermes => "acp",
        RuntimeAdapter::Codex => "app-server",
        RuntimeAdapter::ClaudeCode => "stream-json",
        RuntimeAdapter::Antigravity => "unavailable",
    }
}

/// Static capability matrix aligned with Evidence.md / drivers inventory.
/// Field names avoid reducer-sensitive fragments (session/path/argv/…).
pub fn static_capability_matrix(adapter: RuntimeAdapter) -> Value {
    match adapter {
        RuntimeAdapter::OpenClaw
        | RuntimeAdapter::OpenCode
        | RuntimeAdapter::Copilot
        | RuntimeAdapter::KiloCode
        | RuntimeAdapter::Hermes
        | RuntimeAdapter::KimiCode => json!({
            "laneFamily": "acp",
            "openNew": true,
            "exactResume": true,
            "streaming": true,
            "cancel": true,
            "structuredEvents": true,
            "approvals": true,
            "multimodal": false,
            "usageStatus": false,
            "officialLane": true
        }),
        RuntimeAdapter::Cursor => json!({
            "laneFamily": "acp",
            "openNew": true,
            "exactResume": false,
            "streaming": true,
            "cancel": true,
            "structuredEvents": true,
            "approvals": true,
            "multimodal": false,
            "usageStatus": false,
            "officialLane": true
        }),
        RuntimeAdapter::Codex => json!({
            "laneFamily": "app-server",
            "openNew": true,
            "exactResume": true,
            "streaming": true,
            "cancel": true,
            "structuredEvents": true,
            "approvals": false,
            "multimodal": false,
            "usageStatus": false,
            "officialLane": true
        }),
        RuntimeAdapter::ClaudeCode => json!({
            "laneFamily": "stream-json",
            "openNew": true,
            "exactResume": false,
            "streaming": true,
            "cancel": false,
            "structuredEvents": true,
            "approvals": false,
            "multimodal": false,
            "usageStatus": false,
            "officialLane": false
        }),
        RuntimeAdapter::Antigravity => json!({
            "laneFamily": "unavailable",
            "openNew": false,
            "exactResume": false,
            "streaming": false,
            "cancel": false,
            "structuredEvents": false,
            "approvals": false,
            "multimodal": false,
            "usageStatus": false,
            "officialLane": false
        }),
    }
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
                "code": blocker.unwrap_or_else(|| "antigravity_public_transport_unavailable".to_string()),
                "stage": "capability/transport",
                "message": "No official public conversation transport is available for this adapter."
            }
        }));
    }

    if !native_id.is_empty() {
        let exact_resume = matrix.get("exactResume").and_then(Value::as_bool) == Some(true);
        if !exact_resume {
            let code = blocker.unwrap_or_else(|| match adapter {
                RuntimeAdapter::ClaudeCode => "official_native_lane_missing".to_string(),
                RuntimeAdapter::Cursor => "exact_session_resume_unavailable".to_string(),
                _ => "exact_session_resume_unavailable".to_string(),
            });
            return Ok(json!({
                "ok": false,
                "agentId": adapter.id(),
                "laneFamily": lane_family(adapter),
                "driverId": adapter.driver_id(),
                "runtimeProtocol": adapter.runtime_protocol(),
                "capabilities": matrix,
                "error": {
                    "code": code,
                    "stage": "session/resume",
                    "message": "Exact native resume is not available on an official lane for this adapter."
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
        "events": []
    }))
}

/// Cancel an in-flight turn. One-shot process lanes report structured disposition;
/// ACP/app-server families advertise cancel support for active-turn supervision.
pub fn cancel_turn(params: &Value) -> Result<Value> {
    let agent_id = agent_id_param(params)?;
    let adapter = adapter_or_err(&agent_id)?;
    let native_id = runtime_adapters::text_param_public(params, &["sessionId", "nativeSessionId"])
        .unwrap_or_default();
    let turn_id = runtime_adapters::text_param_public(params, &["turnId"]).unwrap_or_default();
    let matrix = static_capability_matrix(adapter);
    let cancel_supported = matrix.get("cancel").and_then(Value::as_bool) == Some(true);

    if lane_family(adapter) == "unavailable" {
        return Ok(json!({
            "ok": false,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "status": "blocked",
            "error": {
                "code": "antigravity_public_transport_unavailable",
                "stage": "turn/cancel",
                "message": "Cancel is unavailable because no official conversation transport exists."
            },
            "capabilities": matrix
        }));
    }

    if !cancel_supported {
        return Ok(json!({
            "ok": false,
            "agentId": adapter.id(),
            "laneFamily": lane_family(adapter),
            "status": "unsupported",
            "error": {
                "code": "dispatch_cancel_unsupported",
                "stage": "turn/cancel",
                "message": "This official lane does not expose a cancel channel that keeps identifiers off argv."
            },
            "capabilities": matrix
        }));
    }

    // Product sends are one-shot today; without a live supervised handle there is
    // no in-process turn to cancel. Report an actionable structured result so UI
    // and harnesses share one cancel contract (ACP session/cancel during execute
    // remains the in-turn path inside the shared ACP machine).
    Ok(json!({
        "ok": false,
        "agentId": adapter.id(),
        "laneFamily": lane_family(adapter),
        "nativeSessionId": native_id,
        "turnId": turn_id,
        "status": "no_active_turn",
        "cancelSupported": true,
        "error": {
            "code": "dispatch_cancel_no_active_turn",
            "stage": "turn/cancel",
            "message": "No supervised in-flight turn is bound to this sidecar process."
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
        "cancel" => cancel_turn(params),
        "capabilities" | "caps" => lane_capabilities(params),
        "stream" => Ok(json!({
            "ok": true,
            "agentId": agent_id_param(params).unwrap_or_default(),
            "events": [],
            "streamTransport": "bound_on_send",
            "status": "no_active_stream"
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
        assert_eq!(lane_family(RuntimeAdapter::OpenCode), "acp");
        assert_eq!(lane_family(RuntimeAdapter::Antigravity), "unavailable");
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
    fn open_resume_fails_closed_for_claude_and_cursor() {
        let claude = open_or_resume(&json!({
            "agent": "claude-code",
            "sessionId": "native-1"
        }))
        .unwrap();
        assert_eq!(claude["ok"], false);
        assert_eq!(claude["error"]["code"], "official_native_lane_missing");

        let cursor = open_or_resume(&json!({
            "agent": "cursor",
            "sessionId": "native-2"
        }))
        .unwrap();
        assert_eq!(cursor["ok"], false);
        assert_eq!(cursor["error"]["code"], "exact_session_resume_unavailable");
    }

    #[test]
    fn antigravity_stays_structurally_blocked() {
        let result = open_or_resume(&json!({"agent": "antigravity"})).unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(
            result["error"]["code"],
            "antigravity_public_transport_unavailable"
        );
    }

    #[test]
    fn cancel_reports_structured_disposition_per_family() {
        let acp = cancel_turn(&json!({"agent": "opencode", "sessionId": "s1"})).unwrap();
        assert_eq!(acp["cancelSupported"], true);
        assert_eq!(acp["error"]["code"], "dispatch_cancel_no_active_turn");

        let claude = cancel_turn(&json!({"agent": "claude-code"})).unwrap();
        assert_eq!(claude["error"]["code"], "dispatch_cancel_unsupported");
    }

    #[test]
    fn capabilities_emit_matrix_and_blockers() {
        let caps = lane_capabilities(&json!({"agent": "cursor"})).unwrap();
        assert_eq!(caps["ok"], true);
        assert_eq!(caps["laneFamily"], "acp");
        assert_eq!(caps["capabilities"]["exactResume"], false);
        assert!(
            caps["blockerCodes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|code| code == "exact_session_resume_unavailable")
        );
    }

    #[test]
    fn lane_families_are_official_protocol_labels_only() {
        for family in [
            lane_family(RuntimeAdapter::Codex),
            lane_family(RuntimeAdapter::ClaudeCode),
            lane_family(RuntimeAdapter::OpenCode),
            lane_family(RuntimeAdapter::Antigravity),
        ] {
            assert!(matches!(
                family,
                "acp" | "app-server" | "stream-json" | "unavailable"
            ));
        }
    }
}
