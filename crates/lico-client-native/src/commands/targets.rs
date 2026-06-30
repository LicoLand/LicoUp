// targets commands: targets scan|add|inspect

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;
use serde_json::json;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(&["targets", "scan"], handle_targets_scan, "Scan targets");
    table.register_rest(&["targets", "add"], handle_targets_add, "Add a target");
    table.register_rest(
        &["targets", "inspect"],
        handle_targets_inspect,
        "Inspect a target",
    );
}

fn handle_targets_scan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::targets::scan_targets_with_params(&params)?,
    ))
}

fn handle_targets_add(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::targets::add_target(&params)?))
}

fn handle_targets_inspect(args: &[String]) -> Result<CliExecution> {
    let target = &args[2];
    let mut params = cli_params(&args[3..]);
    if let Some(object) = params.as_object_mut() {
        object.insert("target".to_string(), json!(target));
    }
    Ok(CliExecution::Json(
        crate::targets::inspect_target_with_params(&params)?,
    ))
}
