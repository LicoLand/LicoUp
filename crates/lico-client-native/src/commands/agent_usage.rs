// agent-usage commands: agent-usage scan|report

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["agent-usage", "scan"],
        handle_agent_usage_scan,
        "Scan local agent token usage and process traffic attribution",
    );
    table.register_rest(
        &["agent-usage", "report"],
        handle_agent_usage_report,
        "List retained agent usage reports",
    );
}

fn handle_agent_usage_scan(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::agent_usage::scan(&params)?))
}

fn handle_agent_usage_report(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::agent_usage::report(&params)?))
}
