// openclaw-gateway commands: openclaw-gateway ensure|start|stop|restart|status

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["openclaw-gateway"],
        handle_openclaw_gateway,
        "OpenClaw local Gateway lifecycle",
    );
}

fn handle_openclaw_gateway(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "ensure" => crate::platform::openclaw_gateway::ensure(&params)?,
        "start" => crate::platform::openclaw_gateway::start(&params)?,
        "stop" => crate::platform::openclaw_gateway::stop(&params)?,
        "restart" => crate::platform::openclaw_gateway::restart(&params)?,
        "status" => crate::platform::openclaw_gateway::status(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
