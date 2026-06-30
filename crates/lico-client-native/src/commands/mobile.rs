// mobile commands: mobile relay config|pairing|pc|commands, process-identity

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["mobile", "relay"],
        handle_mobile_relay,
        "Mobile relay config|pairing|pc|commands",
    );
    table.register_rest(
        &["process-identity", "bootstrap", "claim"],
        handle_process_identity_claim,
        "Bootstrap process identity claim",
    );
    table.register_rest(
        &["process-identity", "request", "sign"],
        handle_process_identity_sign,
        "Sign process identity request",
    );
    table.register_rest(
        &["process-identity", "status"],
        handle_process_identity_status,
        "Process identity status",
    );
}

fn handle_mobile_relay(args: &[String]) -> Result<CliExecution> {
    let noun = &args[2];
    let action = &args[3];
    let params = cli_params(&args[4..]);
    let result = match (noun.as_str(), action.as_str()) {
        ("config", "get") => crate::mobile_relay::config_get()?,
        ("config", "set") => crate::mobile_relay::config_set(&params)?,
        ("pairing", "create") => crate::mobile_relay::pairing_create(&params)?,
        ("pairing", "claim") => crate::mobile_relay::pairing_claim(&params)?,
        ("pairing", "status") => crate::mobile_relay::pairing_status(&params)?,
        ("pairing", "revoke") => crate::mobile_relay::pairing_revoke(&params)?,
        ("pc", "check-in") => crate::mobile_relay::pc_check_in(&params)?,
        ("commands", "poll") => crate::mobile_relay::commands_poll(&params)?,
        ("commands", "sync") => crate::mobile_relay::commands_sync(&params)?,
        ("commands", "complete") => crate::mobile_relay::command_complete(&params)?,
        ("commands", "create") => crate::mobile_relay::command_create(&params)?,
        ("commands", "result") => crate::mobile_relay::command_result(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_process_identity_claim(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::process_identity::bootstrap_claim(&params)?,
    ))
}

fn handle_process_identity_sign(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(crate::process_identity::sign_request(
        &params,
    )?))
}

fn handle_process_identity_status(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::process_identity::status(
        &params,
    )?))
}
