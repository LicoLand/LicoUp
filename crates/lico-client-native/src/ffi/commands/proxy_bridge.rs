// proxy-bridge commands: detect|status|plan|apply|rollback

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["proxy-bridge", "detect"],
        handle_proxy_bridge_detect,
        "Detect local Clash Verge proxy and TUN advisory state",
    );
    table.register_rest(
        &["proxy-bridge", "status"],
        handle_proxy_bridge_status,
        "Show retained Clash proxy bridge status",
    );
    table.register_rest(
        &["proxy-bridge", "plan"],
        handle_proxy_bridge_plan,
        "Plan client and agent proxy wrapper bridge changes",
    );
    table.register_rest(
        &["proxy-bridge", "apply"],
        handle_proxy_bridge_apply,
        "Enable client proxy bridge and create agent wrappers",
    );
    table.register_rest(
        &["proxy-bridge", "rollback"],
        handle_proxy_bridge_rollback,
        "Disable client proxy bridge and remove managed wrappers",
    );
}

fn handle_proxy_bridge_detect(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::proxy_bridge::detect(
        &params,
    )?))
}

fn handle_proxy_bridge_status(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::proxy_bridge::status(
        &params,
    )?))
}

fn handle_proxy_bridge_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::proxy_bridge::plan(
        &params,
    )?))
}

fn handle_proxy_bridge_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::proxy_bridge::apply(
        &params,
    )?))
}

fn handle_proxy_bridge_rollback(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::proxy_bridge::rollback(
        &params,
    )?))
}
