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
    // Run actions drive Agent work on background threads. A one-shot process
    // would orphan the run, so it fails closed with the typed transport
    // rejection before any run state is touched.
    if input
        .get("action")
        .and_then(Value::as_str)
        .is_some_and(strategy_action_requires_persistent_runtime)
    {
        return Err(anyhow!(
            crate::domain::client_conversation::PERSISTENT_TRANSPORT_REQUIRED
        ));
    }
    let root = portable_data_dir()?;
    let service = StrategyService::open(&root)?;
    Ok(CliExecution::Json(service.execute(input)?))
}

fn strategy_action_requires_persistent_runtime(action: &str) -> bool {
    matches!(
        action,
        "strategy.run.start" | "strategy.run.resume" | "strategy.run.retry"
    )
}

#[cfg(test)]
mod tests {
    use super::strategy_action_requires_persistent_runtime;

    #[test]
    fn only_run_driving_actions_require_the_persistent_runtime() {
        for action in [
            "strategy.run.start",
            "strategy.run.resume",
            "strategy.run.retry",
        ] {
            assert!(strategy_action_requires_persistent_runtime(action));
        }
        for action in [
            "strategy.run.active",
            "strategy.run.inspect",
            "strategy.run.cancel",
            "strategy.definition.list",
        ] {
            assert!(!strategy_action_requires_persistent_runtime(action));
        }
    }
}
