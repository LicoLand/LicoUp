// model commands: model profiles list|set|delete, forward, provider-chat

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register(&["model", "profiles", "list"], handle_model_profiles_list);
    table.register_rest(
        &["model", "profiles", "set"],
        handle_model_profiles_set,
        "Set a model profile",
    );
    table.register_rest(
        &["model", "profiles", "delete"],
        handle_model_profiles_delete,
        "Delete an account-scoped model profile credential",
    );
    table.register_rest(&["forward"], handle_forward, "Forward a model request");
    table.register_rest(
        &["provider-chat"],
        handle_provider_chat,
        "Send a model-forwarding provider chat request",
    );
}

fn handle_model_profiles_list(_args: &[String]) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::domain::forwarding::list_model_profiles()?,
    ))
}

fn handle_model_profiles_set(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::forwarding::save_model_profile(&params)?,
    ))
}

fn handle_model_profiles_delete(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::forwarding::delete_model_profile_credential(&params)?,
    ))
}

fn handle_forward(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[1..]);
    Ok(CliExecution::Json(crate::domain::forwarding::forward(
        &params,
    )?))
}

fn handle_provider_chat(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[1..]);
    Ok(CliExecution::Json(
        crate::domain::forwarding::provider_chat(&params)?,
    ))
}
