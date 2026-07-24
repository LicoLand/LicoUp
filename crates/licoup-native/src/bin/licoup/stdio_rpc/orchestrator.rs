use super::*;
use licoup_native::platform::orchestrator_control_plane::DesktopOrchestratorCommand;
use licoup_native::platform::orchestrator_service::PrivateArtifactStore;
use sha2::Digest as _;
use std::path::Path;

pub(super) fn desktop_orchestrator_command(
    params: &Value,
    state_root: &Path,
) -> Result<DesktopOrchestratorCommand> {
    let method = params
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("invalid request"))?;
    let body = params
        .get("params")
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| json!({}));
    let key = || {
        params
            .get("idempotencyKey")
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("invalid request"))
    };
    let text = |name: &str| {
        body.get(name)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| anyhow::anyhow!("invalid request"))
    };
    Ok(match method {
        "policy.register" => DesktopOrchestratorCommand::RegisterPolicy {
            policy: body
                .get("policy")
                .cloned()
                .ok_or_else(|| anyhow::anyhow!("invalid request"))?,
            idempotency_key: key()?,
        },
        "policy.activate" => DesktopOrchestratorCommand::ActivatePolicy {
            policy_revision_id: text("policyRevision").or_else(|_| text("policyRevisionId"))?,
            idempotency_key: key()?,
        },
        "workflow.submit" => {
            let revision = text("policyRevision").or_else(|_| text("policyRevisionId"))?;
            let intent = body.get("intent").cloned().unwrap_or_else(|| json!({}));
            let encoded = serde_json::to_vec(&intent)?;
            let digest = format!("{:x}", sha2::Sha256::digest(&encoded));
            let handle = format!("intent-{}", &digest[..32]);
            let store = PrivateArtifactStore::open(state_root)
                .map_err(|_| anyhow::anyhow!("invalid request"))?;
            let staged = store
                .put(&handle, &encoded)
                .map_err(|_| anyhow::anyhow!("invalid request"))?;
            if staged != digest {
                return Err(anyhow::anyhow!("invalid request"));
            }
            DesktopOrchestratorCommand::SubmitWorkflow {
                policy_revision_id: revision,
                input_artifact_handle: handle,
                input_digest: digest,
                idempotency_key: key()?,
            }
        }
        "workflow.status" => DesktopOrchestratorCommand::WorkflowStatus {
            workflow_id: text("workflowId")?,
        },
        "workflow.events" => DesktopOrchestratorCommand::WorkflowEvents {
            workflow_id: text("workflowId")?,
            after_cursor: body
                .get("afterSequence")
                .or_else(|| body.get("afterCursor"))
                .and_then(Value::as_u64)
                .unwrap_or(0),
            limit: body
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(128)
                .min(256) as usize,
        },
        "workflow.wait" => DesktopOrchestratorCommand::WorkflowWait {
            workflow_id: text("workflowId")?,
            after_cursor: body.get("afterCursor").and_then(Value::as_u64).unwrap_or(0),
            limit: body
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(64)
                .min(128) as usize,
            timeout_ms: body
                .get("timeoutMs")
                .and_then(Value::as_u64)
                .unwrap_or(30_000)
                .min(30_000),
        },
        "workflow.message" => {
            let workflow_id = text("workflowId")?;
            let message = text("message")?;
            if message.trim().is_empty() {
                return Err(anyhow::anyhow!("invalid request"));
            }
            let digest = format!("{:x}", sha2::Sha256::digest(message.as_bytes()));
            let handle = format!("message-{}", &digest[..32]);
            let store = PrivateArtifactStore::open(state_root)
                .map_err(|_| anyhow::anyhow!("invalid request"))?;
            let staged = store
                .put_text(&handle, &message)
                .map_err(|_| anyhow::anyhow!("invalid request"))?;
            if staged != digest {
                return Err(anyhow::anyhow!("invalid request"));
            }
            DesktopOrchestratorCommand::WorkflowMessage {
                workflow_id,
                message_artifact_handle: handle,
                message_digest: digest,
                idempotency_key: key()?,
            }
        }
        "workflow.cancel" => DesktopOrchestratorCommand::CancelWorkflow {
            workflow_id: text("workflowId")?,
            idempotency_key: key()?,
        },
        "workflow.approve" => DesktopOrchestratorCommand::ApproveWorkflow {
            workflow_id: text("workflowId")?,
            approval_id: text("approvalId")?,
            decision: text("decision")?,
            idempotency_key: key()?,
        },
        _ => return Err(anyhow::anyhow!("invalid request")),
    })
}
