// skill commands: local discovery, installation policy, and aggregate usage.

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
        &["skill", "update", "plan"],
        handle_skill_update_plan,
        "Plan updating a skill from its configured local mirror or GitHub source",
    );
    table.register_rest(
        &["skill", "update", "apply"],
        handle_skill_update_apply,
        "Apply a confirmed skill update",
    );
    table.register_rest(
        &["skill", "delete", "plan"],
        handle_skill_delete_plan,
        "Plan deleting a skill from one or more agents",
    );
    table.register_rest(
        &["skill", "delete", "apply"],
        handle_skill_delete_apply,
        "Apply a confirmed multi-agent skill deletion",
    );
    table.register_rest(
        &["skill", "auto-update", "set"],
        handle_skill_auto_update_set,
        "Enable or disable scheduled updates from an explicit local mirror or GitHub source",
    );
    table.register_rest(
        &["skill", "auto-update", "run"],
        handle_skill_auto_update_run,
        "Run an enabled configured-update batch immediately from a direct user action",
    );
    table.register_rest(
        &["skill", "auto-update", "tick"],
        handle_skill_auto_update_tick,
        "Run the bounded due-policy scheduler tick",
    );
    table.register_rest(
        &["skill", "visibility", "set"],
        handle_skill_visibility,
        "Set skill visibility",
    );
    table.register_rest(&["skill", "pin", "set"], handle_skill_pin, "Pin a skill");
    table.register_rest(
        &["skill", "usage", "report"],
        handle_skill_usage_report,
        "Report local skill invocation frequency",
    );
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

fn handle_skill_update_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_update_plan(&params)?,
    ))
}

fn handle_skill_update_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_update_apply(&params)?,
    ))
}

fn handle_skill_delete_plan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_delete_plan(&params)?,
    ))
}

fn handle_skill_delete_apply(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_delete_apply(&params)?,
    ))
}

fn handle_skill_auto_update_set(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_auto_update_set(&params)?,
    ))
}

fn handle_skill_auto_update_run(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_auto_update_run(&params)?,
    ))
}

fn handle_skill_auto_update_tick(_args: &[String]) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_auto_update_tick()?,
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

fn handle_skill_usage_report(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_usage_report(&params)?,
    ))
}
