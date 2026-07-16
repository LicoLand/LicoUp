use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["collaboration", "status"],
        handle_status,
        "Show the disabled-by-default optional collaboration state",
    );
    table.register_rest(
        &["collaboration", "enable"],
        handle_enable,
        "Manually enable optional collaboration before plugin installation",
    );
    table.register_rest(
        &["collaboration", "runner-trust", "import"],
        handle_runner_trust_import,
        "Import one directly approved exact runner trust binding",
    );
    table.register_rest(
        &["collaboration", "runner-trust", "remove"],
        handle_runner_trust_remove,
        "Remove one directly approved exact runner trust binding",
    );
    table.register_rest(
        &["collaboration", "install", "plan"],
        handle_install_plan,
        "Fetch and inspect a declarative collaboration plugin from GitHub",
    );
    table.register_rest(
        &["collaboration", "install", "apply"],
        handle_install_apply,
        "Install an exact digest-bound collaboration plugin plan",
    );
    table.register_rest(
        &["collaboration", "install", "cancel"],
        handle_install_cancel,
        "Cancel an exact digest-bound staged collaboration plugin plan",
    );
    table.register_rest(
        &["collaboration", "workflow", "catalog"],
        handle_workflow_catalog,
        "Explicitly load the installed declarative workflow catalog",
    );
    table.register_rest(
        &["collaboration", "workflow", "local-deployment", "plan"],
        handle_local_deployment_plan,
        "Preview one digest-bound repository-owned local assembly",
    );
    table.register_rest(
        &["collaboration", "workflow", "local-deployment", "apply"],
        handle_local_deployment_apply,
        "Assemble one exact confirmed plan with the repository-owned adapter without running plugin code",
    );
    table.register_rest(
        &["collaboration", "workflow", "mcp-install", "plan"],
        handle_mcp_install_plan,
        "Preview exact per-agent MCP payload and review-artifact files",
    );
    table.register_rest(
        &["collaboration", "workflow", "mcp-install", "apply"],
        handle_mcp_install_apply,
        "Apply one exact confirmed MCP payload plan without modifying vendor configuration",
    );
    table.register_rest(
        &["collaboration", "workflow", "cancel"],
        handle_workflow_cancel,
        "Cancel and consume an exact workflow plan",
    );
    table.register_rest(
        &["collaboration", "local-server", "status"],
        handle_local_server_status,
        "Show local assembly and controlled inspection-runtime state",
    );
    table.register_rest(
        &["collaboration", "local-server", "start"],
        handle_local_server_start,
        "Start one directly approved loopback assembly-inspection runtime",
    );
    table.register_rest(
        &["collaboration", "local-server", "stop"],
        handle_local_server_stop,
        "Stop one directly approved assembly-inspection runtime",
    );
    table.register_rest(
        &["collaboration", "local-server", "uninstall"],
        handle_local_server_uninstall,
        "Uninstall one stopped digest-bound local assembly",
    );
    table.register_rest(
        &["collaboration", "mcp-bridge"],
        handle_mcp_bridge,
        "Reject bridge activation until the authenticated LicoArc approval broker is available",
    );
    table.register_rest(
        &["collaboration", "disable"],
        handle_disable,
        "Disable optional collaboration without loading the plugin",
    );
    table.register_rest(
        &["collaboration", "uninstall"],
        handle_uninstall,
        "Uninstall an exact digest-bound collaboration plugin",
    );
    table.register_rest(
        &["collaboration", "cleanup"],
        handle_cleanup,
        "Explicitly retry bounded post-commit collaboration cleanup",
    );
}

fn handle_status(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::status(&params)?,
    ))
}

fn handle_enable(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::enable(&params)?,
    ))
}

fn handle_runner_trust_import(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::runner_trust_import(&params)?,
    ))
}

fn handle_runner_trust_remove(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::runner_trust_remove(&params)?,
    ))
}

fn handle_install_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::install_plan(&params)?,
    ))
}

fn handle_install_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::install_apply(&params)?,
    ))
}

fn handle_install_cancel(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::install_cancel(&params)?,
    ))
}

fn handle_workflow_catalog(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::workflow_catalog(&params)?,
    ))
}

fn handle_local_deployment_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[4..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::local_deployment_plan(&params)?,
    ))
}

fn handle_local_deployment_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[4..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::local_deployment_apply(&params)?,
    ))
}

fn handle_mcp_install_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[4..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::mcp_install_plan(&params)?,
    ))
}

fn handle_mcp_install_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[4..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::mcp_install_apply(&params)?,
    ))
}

fn handle_workflow_cancel(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::workflow_cancel(&params)?,
    ))
}

fn handle_local_server_status(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::local_server_status(&params)?,
    ))
}

fn handle_local_server_start(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::local_server_start(&params)?,
    ))
}

fn handle_local_server_stop(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::local_server_stop(&params)?,
    ))
}

fn handle_local_server_uninstall(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::local_server_uninstall(&params)?,
    ))
}

fn handle_mcp_bridge(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    let agent_id = params
        .get("agentId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("collaboration_mcp_bridge_agent_required"))?;
    let registration_id = params
        .get("registrationId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("collaboration_mcp_bridge_registration_required"))?;
    let store = crate::platform::client_state::ClientStateStore::portable()?;
    crate::domain::collaboration_plugin::serve_mcp_bridge(&store, agent_id, registration_id)?;
    Ok(CliExecution::Streamed)
}

fn handle_disable(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::disable(&params)?,
    ))
}

fn handle_uninstall(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::uninstall(&params)?,
    ))
}

fn handle_cleanup(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::domain::collaboration_plugin::cleanup(&params)?,
    ))
}

#[cfg(test)]
mod tests {
    use super::super::CommandTable;

    #[test]
    fn collaboration_help_exposes_plan_apply_and_cancel_without_automatic_routes() {
        let help = CommandTable::new().help_text().join("\n");
        for path in [
            "collaboration runner-trust import",
            "collaboration runner-trust remove",
            "collaboration install cancel",
            "collaboration workflow local-deployment plan",
            "collaboration workflow local-deployment apply",
            "collaboration workflow mcp-install plan",
            "collaboration workflow mcp-install apply",
            "collaboration workflow cancel",
            "collaboration local-server status",
            "collaboration local-server start",
            "collaboration local-server stop",
            "collaboration local-server uninstall",
            "collaboration mcp-bridge",
            "collaboration cleanup",
        ] {
            assert!(help.contains(path));
        }
        assert!(!help.contains("collaboration workflow startup"));
        assert!(!help.contains("collaboration workflow schedule"));
    }
}
