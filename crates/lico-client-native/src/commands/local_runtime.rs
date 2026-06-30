// local-runtime commands: local-runtime ensure|build|start|stop|restart|status|logs

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["local-runtime"],
        handle_local_runtime,
        "Local runtime management",
    );
}

fn handle_local_runtime(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "ensure" => crate::local_runtime::ensure(&params)?,
        "build" => crate::local_runtime::build(&params)?,
        "start" => crate::local_runtime::start(&params)?,
        "stop" => crate::local_runtime::stop(&params)?,
        "restart" => crate::local_runtime::restart(&params)?,
        "status" => crate::local_runtime::status(&params)?,
        "logs" => crate::local_runtime::logs(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
