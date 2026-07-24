//! Canonical request builders shared by shipped desktop, CLI, and MCP clients.

use super::orchestrator_ipc::{OrchestratorIpcRequest, PROTOCOL_VERSION};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

const MAX_ID_BYTES: usize = 128;

pub enum DesktopOrchestratorCommand {
    ServiceStatus,
    StopService {
        idempotency_key: String,
    },
    RegisterPolicy {
        policy: Value,
        idempotency_key: String,
    },
    ActivatePolicy {
        policy_revision_id: String,
        idempotency_key: String,
    },
    SubmitWorkflow {
        policy_revision_id: String,
        input_artifact_handle: String,
        input_digest: String,
        idempotency_key: String,
    },
    WorkflowStatus {
        workflow_id: String,
    },
    WorkflowEvents {
        workflow_id: String,
        after_cursor: u64,
        limit: usize,
    },
    WorkflowWait {
        workflow_id: String,
        after_cursor: u64,
        limit: usize,
        timeout_ms: u64,
    },
    WorkflowMessage {
        workflow_id: String,
        message_artifact_handle: String,
        message_digest: String,
        idempotency_key: String,
    },
    CancelWorkflow {
        workflow_id: String,
        idempotency_key: String,
    },
    ApproveWorkflow {
        workflow_id: String,
        approval_id: String,
        decision: String,
        idempotency_key: String,
    },
}

pub fn build_desktop_orchestrator_request(
    command: DesktopOrchestratorCommand,
) -> Result<OrchestratorIpcRequest> {
    let (method, params, key) = match command {
        DesktopOrchestratorCommand::ServiceStatus => ("service.status", json!({}), None),
        DesktopOrchestratorCommand::StopService { idempotency_key } => {
            ("service.stop", json!({}), Some(idempotency_key))
        }
        DesktopOrchestratorCommand::RegisterPolicy {
            policy,
            idempotency_key,
        } => (
            "policy.register",
            json!({"policy": policy}),
            Some(idempotency_key),
        ),
        DesktopOrchestratorCommand::ActivatePolicy {
            policy_revision_id,
            idempotency_key,
        } => (
            "policy.activate",
            json!({"policyRevisionId": policy_revision_id}),
            Some(idempotency_key),
        ),
        DesktopOrchestratorCommand::SubmitWorkflow {
            policy_revision_id,
            input_artifact_handle,
            input_digest,
            idempotency_key,
        } => (
            "workflow.submit",
            json!({"policyRevisionId": policy_revision_id, "inputArtifactHandle": input_artifact_handle, "inputDigest": input_digest}),
            Some(idempotency_key),
        ),
        DesktopOrchestratorCommand::WorkflowStatus { workflow_id } => {
            ("workflow.status", json!({"workflowId": workflow_id}), None)
        }
        DesktopOrchestratorCommand::WorkflowEvents {
            workflow_id,
            after_cursor,
            limit,
        } => (
            "workflow.events",
            json!({"workflowId": workflow_id, "afterCursor": after_cursor, "limit": limit}),
            None,
        ),
        DesktopOrchestratorCommand::WorkflowWait {
            workflow_id,
            after_cursor,
            limit,
            timeout_ms,
        } => (
            "workflow.wait",
            json!({"workflowId": workflow_id, "afterCursor": after_cursor, "limit": limit, "timeoutMs": timeout_ms}),
            None,
        ),
        DesktopOrchestratorCommand::WorkflowMessage {
            workflow_id,
            message_artifact_handle,
            message_digest,
            idempotency_key,
        } => (
            "workflow.message",
            json!({"workflowId": workflow_id, "messageArtifactHandle": message_artifact_handle, "messageDigest": message_digest}),
            Some(idempotency_key),
        ),
        DesktopOrchestratorCommand::CancelWorkflow {
            workflow_id,
            idempotency_key,
        } => (
            "workflow.cancel",
            json!({"workflowId": workflow_id}),
            Some(idempotency_key),
        ),
        DesktopOrchestratorCommand::ApproveWorkflow {
            workflow_id,
            approval_id,
            decision,
            idempotency_key,
        } => (
            "workflow.approve",
            json!({"workflowId": workflow_id, "approvalId": approval_id, "decision": decision}),
            Some(idempotency_key),
        ),
    };
    request("desktop", method, params, key)
}

pub fn build_cli_orchestrator_request(args: &[String]) -> Result<OrchestratorIpcRequest> {
    let command = args
        .first()
        .map(String::as_str)
        .ok_or_else(|| anyhow!("invalid command"))?;
    let value = |name: &str| option(args, name).ok_or_else(|| anyhow!("missing option"));
    let (method, params, key) = match command {
        "status" => ("service.status", json!({}), None),
        "stop" => ("service.stop", json!({}), Some(value("--idempotency-key")?)),
        "register-policy" => {
            let policy: Value = serde_json::from_str(&value("--policy-json")?)?;
            (
                "policy.register",
                json!({"policy": policy}),
                Some(value("--idempotency-key")?),
            )
        }
        "activate-policy" => (
            "policy.activate",
            json!({"policyRevisionId": value("--policy-revision-id")?}),
            Some(value("--idempotency-key")?),
        ),
        "submit" => (
            "workflow.submit",
            json!({"policyRevisionId": value("--policy-revision-id")?, "inputArtifactHandle": value("--input-artifact-handle")?, "inputDigest": value("--input-digest")?}),
            Some(value("--idempotency-key")?),
        ),
        "workflow-status" => (
            "workflow.status",
            json!({"workflowId": value("--workflow-id")?}),
            None,
        ),
        "events" => (
            "workflow.events",
            json!({"workflowId": value("--workflow-id")?, "afterCursor": value("--after-cursor")?.parse::<u64>()?, "limit": value("--limit")?.parse::<usize>()?}),
            None,
        ),
        "wait" => (
            "workflow.wait",
            json!({"workflowId": value("--workflow-id")?, "afterCursor": value("--after-cursor")?.parse::<u64>()?, "limit": value("--limit")?.parse::<usize>()?, "timeoutMs": value("--timeout-ms")?.parse::<u64>()?}),
            None,
        ),
        "message" => (
            "workflow.message",
            json!({"workflowId": value("--workflow-id")?, "messageArtifactHandle": value("--message-artifact-handle")?, "messageDigest": value("--message-digest")?}),
            Some(value("--idempotency-key")?),
        ),
        "cancel" => (
            "workflow.cancel",
            json!({"workflowId": value("--workflow-id")?}),
            Some(value("--idempotency-key")?),
        ),
        "approve" => (
            "workflow.approve",
            json!({"workflowId": value("--workflow-id")?, "approvalId": value("--approval-id")?, "decision": value("--decision")?}),
            Some(value("--idempotency-key")?),
        ),
        _ => return Err(anyhow!("invalid command")),
    };
    request("cli", method, params, key)
}

pub fn build_codex_mcp_orchestrator_request(
    name: &str,
    arguments: &Value,
) -> Result<OrchestratorIpcRequest> {
    let (method, params, key) = match name {
        "lico_agent_capabilities" => ("service.status", json!({}), None),
        "lico_strategy_preview" => (
            "workflow.preview",
            json!({"policyRevisionId": required(arguments, "policyRevisionId")?, "inputDigest": required(arguments, "inputDigest")?}),
            None,
        ),
        "lico_workflow_submit" => (
            "workflow.submit",
            json!({"policyRevisionId": required(arguments, "policyRevisionId")?, "inputArtifactHandle": required(&arguments["inputArtifact"], "handle")?, "inputDigest": required(&arguments["inputArtifact"], "digest")?}),
            Some(required(arguments, "idempotencyKey")?),
        ),
        "lico_workflow_status" => (
            "workflow.status",
            json!({"workflowId": required(arguments, "workflowId")?}),
            None,
        ),
        "lico_workflow_wait" => (
            "workflow.wait",
            json!({
                "workflowId": required(arguments, "workflowId")?,
                "afterCursor": arguments.get("afterCursor").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing field"))?,
                "limit": arguments.get("limit").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing field"))?,
                "timeoutMs": arguments.get("timeoutMs").and_then(Value::as_u64).ok_or_else(|| anyhow!("missing field"))?,
            }),
            None,
        ),
        "lico_workflow_message" => (
            "workflow.message",
            json!({
                "workflowId": required(arguments, "workflowId")?,
                "messageArtifactHandle": required(&arguments["messageArtifact"], "handle")?,
                "messageDigest": required(&arguments["messageArtifact"], "digest")?,
            }),
            Some(required(arguments, "idempotencyKey")?),
        ),
        "lico_workflow_cancel" => (
            "workflow.cancel",
            json!({"workflowId": required(arguments, "workflowId")?}),
            Some(required(arguments, "idempotencyKey")?),
        ),
        "lico_workflow_approve" => (
            "workflow.approve",
            json!({"workflowId": required(arguments, "workflowId")?, "approvalId": required(arguments, "approvalId")?, "decision": required(arguments, "decision")?}),
            Some(required(arguments, "idempotencyKey")?),
        ),
        _ => return Err(anyhow!("unknown tool")),
    };
    request("codex-mcp", method, params, key)
}

pub fn build_codex_mcp_status_event_request(
    status: &OrchestratorIpcRequest,
    arguments: &Value,
) -> Result<OrchestratorIpcRequest> {
    if status.client_kind != "codex-mcp" || status.method != "workflow.status" {
        return Err(anyhow!("invalid status request"));
    }
    request(
        "codex-mcp",
        "workflow.events",
        json!({
            "workflowId": required(arguments, "workflowId")?,
            "afterCursor": arguments.get("afterCursor").and_then(Value::as_u64).unwrap_or(0),
            "limit": arguments.get("limit").and_then(Value::as_u64).unwrap_or(64).min(256),
        }),
        None,
    )
}

fn request(
    client_kind: &str,
    method: &str,
    params: Value,
    idempotency_key: Option<String>,
) -> Result<OrchestratorIpcRequest> {
    if let Some(key) = idempotency_key.as_deref() {
        validate_id(key)?;
    }
    Ok(OrchestratorIpcRequest {
        protocol_version: PROTOCOL_VERSION.into(),
        request_id: uuid::Uuid::new_v4().simple().to_string(),
        client_kind: client_kind.into(),
        method: method.into(),
        params,
        idempotency_key,
    })
}

fn required(value: &Value, key: &str) -> Result<String> {
    let value = value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("missing field"))?;
    validate_id(value)?;
    Ok(value.to_owned())
}

fn validate_id(value: &str) -> Result<()> {
    if value.is_empty()
        || value.len() > MAX_ID_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(anyhow!("invalid identifier"));
    }
    Ok(())
}

fn option(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|value| value == name)
        .and_then(|index| args.get(index + 1))
        .filter(|value| !value.starts_with("--"))
        .cloned()
}
