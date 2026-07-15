// mcp commands: mcp plugin status|update|rollback, mcp config plan|apply|rollback

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["mcp", "plugin"],
        handle_mcp_plugin,
        "MCP plugin status|update|rollback",
    );
    table.register_rest(
        &["mcp", "config"],
        handle_mcp_config,
        "MCP config plan|apply|rollback",
    );
}

fn handle_mcp_plugin(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "status" => crate::domain::mcp_plugins::plugin_status(&params)?,
        "update" => crate::domain::mcp_plugins::plugin_update(&params)?,
        "rollback" => crate::domain::mcp_plugins::plugin_rollback(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_mcp_config(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "plan" => crate::domain::targets::mcp_config_plan(&params)?,
        "apply" => crate::domain::targets::mcp_config_apply(&params)?,
        "rollback" => crate::domain::targets::mcp_config_rollback(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
