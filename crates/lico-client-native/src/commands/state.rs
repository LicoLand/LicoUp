// state commands: state get|set <collection>, activity list

use super::{CliExecution, CommandTable, cli_params, parse_json_arg};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["state", "get"],
        handle_state_get,
        "Get state by collection",
    );
    table.register_rest(
        &["state", "set"],
        handle_state_set,
        "Set state collection payload",
    );
    table.register_rest(
        &["activity", "list"],
        handle_activity_list,
        "List recent activity",
    );
}

fn handle_state_get(args: &[String]) -> Result<CliExecution> {
    let collection = &args[2];
    Ok(CliExecution::Json(crate::client_state::state_get(
        collection,
    )?))
}

fn handle_state_set(args: &[String]) -> Result<CliExecution> {
    let collection = &args[2];
    let payload = &args[3];
    Ok(CliExecution::Json(crate::client_state::state_set(
        collection,
        parse_json_arg(payload),
    )?))
}

fn handle_activity_list(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::client_state::activity_list(
        &params,
    )?))
}
