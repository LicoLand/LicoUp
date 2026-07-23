// update commands: update status|check|download|verify|apply|rollback

use super::{AdmittedCommand, CliExecution, admitted_params};
use anyhow::Result;

pub(super) fn handle_update(command: AdmittedCommand) -> Result<CliExecution> {
    let action = match command.path() {
        ["update", action] => *action,
        _ => unreachable!("admission only registers concrete update routes"),
    };
    let params = admitted_params(
        &[
            ("channel", command.option_text("channel")),
            ("manifestPath", command.option_text("manifest-path")),
            ("publicKeysPath", command.option_text("public-keys-path")),
            ("sourcePath", command.option_text("source-path")),
        ],
        &[],
        &[],
    );
    let route = ["update".to_string(), action.to_string()];
    Ok(CliExecution::Json(crate::domain::client_update::dispatch(
        &route, &params,
    )?))
}
