use super::{AdmittedCommand, CliExecution, admitted_params};
use anyhow::Result;

pub(super) fn handle_snapshots_list(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(&[("target", command.option_text("target"))], &[], &[]);
    Ok(CliExecution::Json(
        crate::platform::client_state::snapshots_list(&params)?,
    ))
}

pub(super) fn handle_snapshots_restore(command: AdmittedCommand) -> Result<CliExecution> {
    let snapshot_id = command.required_text("snapshot-id");
    Ok(CliExecution::Json(
        crate::platform::client_state::snapshots_restore(snapshot_id)?,
    ))
}

pub(super) fn handle_snapshots_collect(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[
            ("topic", command.option_text("topic")),
            ("agent", command.option_text("agent")),
        ],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::conversation_snapshots::collect(&params)?,
    ))
}

pub(super) fn handle_snapshots_root(command: AdmittedCommand) -> Result<CliExecution> {
    let action = match command.path() {
        ["snapshots", "root", action] => *action,
        _ => unreachable!("admission only registers concrete snapshot root routes"),
    };
    let params = admitted_params(&[("path", command.option_text("path"))], &[], &[]);
    let result = match action {
        "get" => crate::domain::conversation_snapshots::root_get(&params)?,
        "set" => crate::domain::conversation_snapshots::root_set(&params)?,
        _ => unreachable!("admission only registers supported snapshot root actions"),
    };
    Ok(CliExecution::Json(result))
}

pub(super) fn handle_snapshots_profiles(command: AdmittedCommand) -> Result<CliExecution> {
    let action = match command.path() {
        ["snapshots", "profiles", action] => *action,
        _ => unreachable!("admission only registers concrete snapshot profile routes"),
    };
    let params = admitted_params(
        &[
            ("profile", command.option_text("profile")),
            ("profileFile", command.option_text("profile-file")),
        ],
        &[("profileJson", command.option_json("profile-json"))],
        &[],
    );
    let result = match action {
        "list" => crate::domain::conversation_snapshots::profiles_list(&params)?,
        "get" => crate::domain::conversation_snapshots::profile_get(&params)?,
        "import" => crate::domain::conversation_snapshots::profile_import(&params)?,
        _ => unreachable!("admission only registers supported snapshot profile actions"),
    };
    Ok(CliExecution::Json(result))
}

pub(super) fn handle_snapshots_archive(command: AdmittedCommand) -> Result<CliExecution> {
    let route = command.path();
    let params = admitted_params(
        &[
            ("selectionMode", command.option_text("selection-mode")),
            ("query", command.option_text("query")),
            ("path", command.option_text("path")),
            ("agent", command.option_text("agent")),
            ("planBinding", command.option_text("plan-binding")),
            ("jobId", command.option_text("job-id")),
            ("once", command.option_text("once")),
            ("keywords", command.option_text("keywords")),
            ("trigger", command.option_text("trigger")),
            ("profile", command.option_text("profile")),
            ("collectionPath", command.option_text("collection-path")),
        ],
        &[],
        &[],
    );
    let result = match route {
        ["snapshots", "archive", "collect"] => {
            crate::domain::conversation_snapshots::archive_collect(&params)?
        }
        ["snapshots", "archive", "run"] => {
            crate::domain::conversation_snapshots::archive_run(&params)?
        }
        ["snapshots", "archive", "verify"] => {
            crate::domain::conversation_snapshots::archive_verify(&params)?
        }
        ["snapshots", "archive", "report"] => {
            crate::domain::conversation_snapshots::archive_report(&params)?
        }
        ["snapshots", "archive", "jobs", "preview"] => {
            crate::domain::conversation_archive_jobs::preview(&params)?
        }
        ["snapshots", "archive", "jobs", "create"] => {
            crate::domain::conversation_archive_jobs::create(&params)?
        }
        ["snapshots", "archive", "jobs", "status"] => {
            crate::domain::conversation_archive_jobs::status(&params)?
        }
        ["snapshots", "archive", "jobs", "list"] => {
            crate::domain::conversation_archive_jobs::list(&params)?
        }
        ["snapshots", "archive", "jobs", "events"] => {
            crate::domain::conversation_archive_jobs::events(&params)?
        }
        ["snapshots", "archive", "jobs", "cancel"] => {
            crate::domain::conversation_archive_jobs::cancel(&params)?
        }
        ["snapshots", "archive", "jobs", "drain"] => {
            crate::domain::conversation_archive_jobs::drain(&params)?
        }
        _ => unreachable!("admission only registers supported snapshot archive actions"),
    };
    Ok(CliExecution::Json(result))
}

pub(super) fn handle_snapshots_collections(command: AdmittedCommand) -> Result<CliExecution> {
    let params = admitted_params(
        &[("snapshotRoot", command.option_text("snapshot-root"))],
        &[],
        &[],
    );
    Ok(CliExecution::Json(
        crate::domain::conversation_snapshots::collections_list(&params)?,
    ))
}

pub(super) fn handle_conversations(command: AdmittedCommand) -> Result<CliExecution> {
    let action = match command.path() {
        ["conversations", action] => *action,
        _ => unreachable!("admission only registers concrete conversation routes"),
    };
    let params = admitted_params(
        &[
            ("agent", command.option_text("agent")),
            ("limit", command.option_text("limit")),
            ("offset", command.option_text("offset")),
            ("sessionId", command.option_text("session-id")),
            ("text", command.option_text("text")),
        ],
        &[],
        &[],
    );
    let result = match action {
        "list" => crate::domain::conversations::conversation_list(&params)?,
        "stream" => {
            crate::domain::conversations::conversation_stream(&params)?;
            return Ok(CliExecution::Streamed);
        }
        "append" => crate::domain::conversations::conversation_append(&params)?,
        "delete" => crate::domain::conversations::conversation_delete(&params)?,
        _ => unreachable!("admission only registers supported conversation actions"),
    };
    Ok(CliExecution::Json(result))
}
