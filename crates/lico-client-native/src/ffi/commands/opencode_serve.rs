// opencode-serve commands: opencode-serve ensure|start|stop|restart|status

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["opencode-serve"],
        handle_opencode_serve,
        "OpenCode local serve lifecycle",
    );
}

fn handle_opencode_serve(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "ensure" => crate::platform::opencode_serve::ensure(&params)?,
        "start" => crate::platform::opencode_serve::start(&params)?,
        "stop" => crate::platform::opencode_serve::stop(&params)?,
        "restart" => crate::platform::opencode_serve::restart(&params)?,
        "status" => crate::platform::opencode_serve::status(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
