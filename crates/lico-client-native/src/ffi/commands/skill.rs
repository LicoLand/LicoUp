// skill commands: skill list|get|visibility set|pin set

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(&["skill", "list"], handle_skill_list, "List skills");
    table.register_rest(&["skill", "get"], handle_skill_get, "Get skill details");
    table.register_rest(
        &["skill", "install", "plan"],
        handle_skill_install_plan,
        "Plan installing a GitHub skill into a target agent",
    );
    table.register_rest(
        &["skill", "install", "apply"],
        handle_skill_install_apply,
        "Install a GitHub skill into a target agent",
    );
    table.register_rest(
        &["skill", "install", "rollback"],
        handle_skill_install_rollback,
        "Rollback a skill install snapshot",
    );
    table.register_rest(
        &["skill", "visibility", "set"],
        handle_skill_visibility,
        "Set skill visibility",
    );
    table.register_rest(&["skill", "pin", "set"], handle_skill_pin, "Pin a skill");
}

fn handle_skill_list(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::skill_hub::skill_list(
        &params,
    )?))
}

fn handle_skill_get(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::domain::skill_hub::skill_get(
        &params,
    )?))
}

fn handle_skill_install_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_install_plan(&params)?,
    ))
}

fn handle_skill_install_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_install_apply(&params)?,
    ))
}

fn handle_skill_install_rollback(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_install_rollback(&params)?,
    ))
}

fn handle_skill_visibility(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_visibility(&params)?,
    ))
}

fn handle_skill_pin(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(crate::domain::skill_hub::skill_pin(
        &params,
    )?))
}
