use super::{CliExecution, CommandTable, cli_params};
use crate::domain::mcp_adapter::McpHttpTransportResponse;
use anyhow::{Result, anyhow, ensure};
use serde_json::Value;
use std::io::Read;

const MAX_PRIVATE_MCP_REQUEST_BYTES: usize = 1024 * 1024;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["mcp", "http", "preview"],
        handle_preview,
        "Preview and digest-bind one exact MCP Streamable HTTP transfer",
    );
    table.register_rest(
        &["mcp", "http", "execute"],
        handle_execute,
        "Execute one exact directly confirmed MCP Streamable HTTP transfer",
    );
}

fn handle_preview(args: &[String]) -> Result<CliExecution> {
    let result = (|| -> Result<_> {
        let params = private_stdin_params(&args[3..])?;
        let plans =
            crate::platform::mcp_approval_plan_store::PrivateMcpApprovalPlanStore::open_default()?;
        crate::domain::mcp_adapter::preview_http_transfer(&params, &plans)
    })()
    .map_err(|_| anyhow!("mcp_transfer_preview_failed"))?;
    Ok(CliExecution::Json(result))
}

fn handle_execute(args: &[String]) -> Result<CliExecution> {
    let result = (|| -> Result<_> {
        let params = private_stdin_params(&args[3..])?;
        let _presence = authorize_exact_transfer(&params)?;
        let plans =
            crate::platform::mcp_approval_plan_store::PrivateMcpApprovalPlanStore::open_default()?;
        crate::domain::mcp_adapter::execute_http_transfer(&params, &plans, |packet, session_id| {
            let response = crate::platform::mcp_streamable_http::exchange(packet, session_id)?;
            Ok(McpHttpTransportResponse {
                status: response.status,
                content_type: response.content_type,
                session_id: response.session_id,
                body: response.body,
            })
        })
    })()
    .map_err(|_| anyhow!("mcp_transfer_execute_failed"))?;
    Ok(CliExecution::Json(result))
}

fn private_stdin_params(args: &[String]) -> Result<Value> {
    let control = cli_params(args);
    ensure!(
        control.get("stdinJson").and_then(bool_param) == Some(true),
        "mcp_transfer_private_stdin_required"
    );
    let mut bytes = Vec::new();
    std::io::stdin()
        .take((MAX_PRIVATE_MCP_REQUEST_BYTES as u64).saturating_add(1))
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= MAX_PRIVATE_MCP_REQUEST_BYTES,
        "mcp_transfer_private_input_too_large"
    );
    let params: Value = serde_json::from_slice(&bytes)
        .map_err(|_| anyhow!("mcp_transfer_private_input_invalid"))?;
    ensure!(params.is_object(), "mcp_transfer_private_input_invalid");
    Ok(params)
}

fn authorize_exact_transfer(
    params: &Value,
) -> Result<crate::platform::user_presence::UserPresenceSession> {
    let scope = exact_approval_scope(params)?;
    ensure!(
        crate::platform::user_presence::available(),
        "mcp_transfer_user_presence_unavailable"
    );
    crate::platform::user_presence::authorize("Approve this exact MCP transfer in LicoArc", scope)
}

fn exact_approval_scope(params: &Value) -> Result<&str> {
    let digest = params
        .get("approvalDigest")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("mcp_transfer_approval_scope_invalid"))?;
    ensure!(
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')),
        "mcp_transfer_approval_scope_invalid"
    );
    Ok(digest)
}

fn bool_param(value: &Value) -> Option<bool> {
    value.as_bool().or_else(|| match value.as_str() {
        Some("true") => Some(true),
        Some("false") => Some(false),
        _ => None,
    })
}

#[cfg(test)]
mod tests {
    use super::super::CommandTable;

    #[test]
    fn command_help_exposes_preview_and_direct_execution_only() {
        let help = CommandTable::new().help_text().join("\n");
        assert!(help.contains("mcp http preview"));
        assert!(help.contains("mcp http execute"));
        assert!(!help.contains("mcp http authorize"));
        assert!(!help.contains("mcp http automatic"));
    }

    #[test]
    fn exact_user_presence_scope_rejects_missing_or_noncanonical_digests() {
        assert!(super::exact_approval_scope(&serde_json::json!({})).is_err());
        assert!(
            super::exact_approval_scope(&serde_json::json!({
                "approvalDigest": "A".repeat(64)
            }))
            .is_err()
        );
        assert_eq!(
            super::exact_approval_scope(&serde_json::json!({
                "approvalDigest": "a".repeat(64)
            }))
            .unwrap(),
            "a".repeat(64)
        );
    }
}
