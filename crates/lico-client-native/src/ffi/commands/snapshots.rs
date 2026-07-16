// snapshots commands: snapshots list|restore|collect, snapshots root|profiles|archive|collections, conversations

use super::{CliExecution, CommandTable, cli_params};
use anyhow::Result;

pub fn register_commands(table: &mut CommandTable) {
    table.register_rest(
        &["snapshots", "list"],
        handle_snapshots_list,
        "List snapshots",
    );
    table.register_rest(
        &["snapshots", "restore"],
        handle_snapshots_restore,
        "Restore snapshot by ID",
    );
    table.register_rest(
        &["snapshots", "collect"],
        handle_snapshots_collect,
        "Collect snapshots",
    );
    table.register_rest(
        &["snapshots", "root"],
        handle_snapshots_root,
        "Root snapshot get|set",
    );
    table.register_rest(
        &["snapshots", "profiles"],
        handle_snapshots_profiles,
        "Profile list|get|import",
    );
    table.register_rest(
        &["snapshots", "archive"],
        handle_snapshots_archive,
        "Archive jobs|collect|run|verify|report",
    );
    table.register_rest(
        &["snapshots", "collections", "list"],
        handle_snapshots_collections,
        "List collections",
    );
    table.register_rest(
        &["conversations"],
        handle_conversations,
        "Conversation list|stream|append|delete",
    );
}

fn handle_snapshots_list(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::platform::client_state::snapshots_list(&params)?,
    ))
}

fn handle_snapshots_restore(args: &[String]) -> Result<CliExecution> {
    let snapshot_id = &args[2];
    Ok(CliExecution::Json(
        crate::platform::client_state::snapshots_restore(snapshot_id)?,
    ))
}

fn handle_snapshots_collect(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(
        crate::domain::conversation_snapshots::collect(&params)?,
    ))
}

fn handle_snapshots_root(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "get" => crate::domain::conversation_snapshots::root_get(&params)?,
        "set" => crate::domain::conversation_snapshots::root_set(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_snapshots_profiles(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "list" => crate::domain::conversation_snapshots::profiles_list(&params)?,
        "get" => crate::domain::conversation_snapshots::profile_get(&params)?,
        "import" => crate::domain::conversation_snapshots::profile_import(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_snapshots_archive(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    if action == "jobs" {
        if args.len() < 4 {
            return Ok(CliExecution::Usage);
        }
        let job_action = &args[3];
        let params = cli_params(&args[4..]);
        let result = match job_action.as_str() {
            "preview" => crate::domain::conversation_archive_jobs::preview(&params)?,
            "create" => crate::domain::conversation_archive_jobs::create(&params)?,
            "status" => crate::domain::conversation_archive_jobs::status(&params)?,
            "list" => crate::domain::conversation_archive_jobs::list(&params)?,
            "events" => crate::domain::conversation_archive_jobs::events(&params)?,
            "cancel" => crate::domain::conversation_archive_jobs::cancel(&params)?,
            "drain" => crate::domain::conversation_archive_jobs::drain(&params)?,
            _ => return Ok(CliExecution::Usage),
        };
        return Ok(CliExecution::Json(result));
    }
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "collect" => crate::domain::conversation_snapshots::archive_collect(&params)?,
        "run" => crate::domain::conversation_snapshots::archive_run(&params)?,
        "verify" => crate::domain::conversation_snapshots::archive_verify(&params)?,
        "report" => crate::domain::conversation_snapshots::archive_report(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_snapshots_collections(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::domain::conversation_snapshots::collections_list(&params)?,
    ))
}

fn handle_conversations(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "list" => crate::domain::conversations::conversation_list(&params)?,
        "stream" => {
            crate::domain::conversations::conversation_stream(&params)?;
            return Ok(CliExecution::Streamed);
        }
        "append" => crate::domain::conversations::conversation_append(&params)?,
        "delete" => crate::domain::conversations::conversation_delete(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
