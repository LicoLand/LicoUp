use super::{AdmittedCommand, CliExecution};
use anyhow::{Result, anyhow};
use serde_json::Value;

use crate::domain::adaptive_flywheel::StrategyService;
use crate::platform::paths::portable_data_dir;

pub(super) fn handle_strategy_execute(mut command: AdmittedCommand) -> Result<CliExecution> {
    let input = match command.take_option_json("stdin-json") {
        Some(Value::Object(input)) => Value::Object(input),
        Some(_) => return Err(anyhow!("strategy_request_invalid")),
        None => return Err(anyhow!("strategy_request_required")),
    };
    let root = portable_data_dir()?;
    let service = StrategyService::open(&root)?;
    Ok(CliExecution::Json(service.execute(input)?))
}
