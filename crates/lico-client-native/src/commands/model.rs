// model commands: model profiles list|set, forward

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register(&["model", "profiles", "list"], handle_model_profiles_list);
    table.register_rest(
        &["model", "profiles", "set"],
        handle_model_profiles_set,
        "Set a model profile",
    );
    table.register_rest(&["forward"], handle_forward, "Forward a model request");
}

fn handle_model_profiles_list(_args: &[String]) -> Result<CliExecution> {
    Ok(CliExecution::Json(crate::forwarding::list_model_profiles()?))
}

fn handle_model_profiles_set(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(crate::forwarding::save_model_profile(
        &params,
    )?))
}

fn handle_forward(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[1..]);
    Ok(CliExecution::Json(crate::forwarding::forward(&params)?))
}
