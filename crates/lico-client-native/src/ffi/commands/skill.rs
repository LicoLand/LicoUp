use super::{AdmittedCommand, CliExecution, admitted_params};
use anyhow::Result;
use serde_json::Value;

fn with_target(mut params: Value, target: &str) -> Value {
    if let Some(object) = params.as_object_mut() {
        object.insert("target".to_string(), Value::String(target.to_string()));
        object.insert(
            "positionals".to_string(),
            Value::Array(vec![Value::String(target.to_string())]),
        );
    }
    params
}

pub(super) fn handle_skill_list(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("refreshLocal", command.option_text("refresh-local")),
            ("installRoot", command.option_text("install-root")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(crate::domain::skill_hub::skill_list(
        &params,
    )?))
}

pub(super) fn handle_skill_get(command: AdmittedCommand) -> Result<CliExecution> {
    let skill_id = command.required_text("skill-id");
    let params = with_target(
        admitted_params(
            &[
                ("agent", command.option_text("agent")),
                ("discoverLocal", command.option_text("discover-local")),
                ("installRoot", command.option_text("install-root")),
            ],
            &[],
            &[],
        ),
        skill_id,
    );
    Ok(CliExecution::Json(crate::domain::skill_hub::skill_get(
        &params,
    )?))
}

pub(super) fn handle_skill_install_plan(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("url", command.option_text("url")),
            ("installRoot", command.option_text("install-root")),
            ("name", command.option_text("name")),
            ("overwrite", command.option_text("overwrite")),
            ("pin", command.option_text("pin")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_install_plan(&params)?,
    ))
}

pub(super) fn handle_skill_install_apply(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("url", command.option_text("url")),
            ("installRoot", command.option_text("install-root")),
            ("name", command.option_text("name")),
            ("overwrite", command.option_text("overwrite")),
            ("pin", command.option_text("pin")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_install_apply(&params)?,
    ))
}

pub(super) fn handle_skill_install_rollback(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("snapshotId", command.option_text("snapshot-id")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_install_rollback(&params)?,
    ))
}

pub(super) fn handle_skill_update_plan(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("skill", command.option_text("skill")),
            ("sourcePath", command.option_text("source-path")),
            ("url", command.option_text("url")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_update_plan(&params)?,
    ))
}

pub(super) fn handle_skill_update_apply(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("skill", command.option_text("skill")),
            ("confirmation", command.option_text("confirmation")),
            ("sourcePath", command.option_text("source-path")),
            ("url", command.option_text("url")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_update_apply(&params)?,
    ))
}

pub(super) fn handle_skill_delete_plan(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("skill", command.option_text("skill")),
            ("agent", command.option_text("agent")),
            ("agents", command.option_text("agents")),
            ("confirmation", command.option_text("confirmation")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_delete_plan(&params)?,
    ))
}

pub(super) fn handle_skill_delete_apply(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("skill", command.option_text("skill")),
            ("agent", command.option_text("agent")),
            ("agents", command.option_text("agents")),
            ("confirmation", command.option_text("confirmation")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_delete_apply(&params)?,
    ))
}

pub(super) fn handle_skill_auto_update_set(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("skill", command.option_text("skill")),
            ("enabled", command.option_text("enabled")),
            (
                "directUserAction",
                command.option_text("direct-user-action"),
            ),
            ("sourcePath", command.option_text("source-path")),
            ("url", command.option_text("url")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_auto_update_set(&params)?,
    ))
}

pub(super) fn handle_skill_auto_update_run(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            (
                "directUserAction",
                command.option_text("direct-user-action"),
            ),
            ("skill", command.option_text("skill")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_auto_update_run(&params)?,
    ))
}

pub(super) fn handle_skill_auto_update_tick(_command: AdmittedCommand) -> Result<CliExecution> {
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_auto_update_tick()?,
    ))
}

pub(super) fn handle_skill_visibility(command: AdmittedCommand) -> Result<CliExecution> {
    let skill_id = command.required_text("skill-id");
    let params = with_target(
        admitted_params(
            &[
                ("agent", command.option_text("agent")),
                ("hidden", command.option_text("hidden")),
            ],
            &[],
            &[],
        ),
        skill_id,
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_visibility(&params)?,
    ))
}

pub(super) fn handle_skill_pin(command: AdmittedCommand) -> Result<CliExecution> {
    let skill_id = command.required_text("skill-id");
    let params = with_target(
        admitted_params(
            &[
                ("agent", command.option_text("agent")),
                ("version", command.option_text("version")),
            ],
            &[],
            &[],
        ),
        skill_id,
    );
    Ok(CliExecution::Json(crate::domain::skill_hub::skill_pin(
        &params,
    )?))
}

pub(super) fn handle_skill_usage_report(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("skill", command.option_text("skill")),
            ("days", command.option_text("days")),
            ("from", command.option_text("from")),
            ("to", command.option_text("to")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::skill_hub::skill_usage_report(&params)?,
    ))
}
