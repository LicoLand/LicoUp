// update commands: update status|check|download|verify|apply|rollback

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["update"],
        handle_update,
        "Client update status|check|download|verify|apply|rollback (signed channel, public metadata only; productionReady stays false)",
    );
}

fn handle_update(args: &[String]) -> Result<CliExecution> {
    let params = if args.len() > 2 {
        cli_params(&args[2..])
    } else {
        cli_params(&[])
    };
    Ok(CliExecution::Json(crate::domain::client_update::dispatch(
        args, &params,
    )?))
}
