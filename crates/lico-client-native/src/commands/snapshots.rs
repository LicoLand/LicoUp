// snapshots commands: snapshots list|restore|collect, snapshots root|curator|bridge|curation|profiles|archive|collections, conversations

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
        &["snapshots", "curator"],
        handle_snapshots_curator,
        "Curator get|set",
    );
    table.register_rest(
        &["snapshots", "bridge", "ensure"],
        handle_snapshots_bridge,
        "Ensure bridge",
    );
    table.register_rest(
        &["snapshots", "curation", "start"],
        handle_snapshots_curation_start,
        "Start curation",
    );
    table.register_rest(
        &["snapshots", "curation", "submit-result"],
        handle_snapshots_curation_submit,
        "Submit curation result",
    );
    table.register_rest(
        &["snapshots", "curation", "candidates", "list"],
        handle_snapshots_curation_candidates,
        "List curation candidates",
    );
    table.register_rest(
        &["snapshots", "curation", "candidate", "expand"],
        handle_snapshots_curation_candidate_expand,
        "Expand curation candidate",
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
        "Conversation list|append|delete",
    );
}

fn handle_snapshots_list(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::client_state::snapshots_list(
        &params,
    )?))
}

fn handle_snapshots_restore(args: &[String]) -> Result<CliExecution> {
    let snapshot_id = &args[2];
    Ok(CliExecution::Json(crate::client_state::snapshots_restore(
        snapshot_id,
    )?))
}

fn handle_snapshots_collect(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[2..]);
    Ok(CliExecution::Json(crate::conversation_snapshots::collect(
        &params,
    )?))
}

fn handle_snapshots_root(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "get" => crate::conversation_snapshots::root_get(&params)?,
        "set" => crate::conversation_snapshots::root_set(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_snapshots_curator(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "get" => crate::conversation_snapshots::curator_get(&params)?,
        "set" => crate::conversation_snapshots::curator_set(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_snapshots_bridge(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::conversation_snapshots::bridge_ensure(&params)?,
    ))
}

fn handle_snapshots_curation_start(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::conversation_snapshots::curation_start(&params)?,
    ))
}

fn handle_snapshots_curation_submit(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::conversation_snapshots::curation_submit_result(&params)?,
    ))
}

fn handle_snapshots_curation_candidates(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[4..]);
    Ok(CliExecution::Json(
        crate::conversation_snapshots::curation_candidates_list(&params)?,
    ))
}

fn handle_snapshots_curation_candidate_expand(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[4..]);
    Ok(CliExecution::Json(
        crate::conversation_snapshots::curation_candidate_expand(&params)?,
    ))
}

fn handle_snapshots_profiles(args: &[String]) -> Result<CliExecution> {
    let action = &args[2];
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "list" => crate::conversation_snapshots::profiles_list(&params)?,
        "get" => crate::conversation_snapshots::profile_get(&params)?,
        "import" => crate::conversation_snapshots::profile_import(&params)?,
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
            "create" => crate::conversation_archive_jobs::create(&params)?,
            "status" => crate::conversation_archive_jobs::status(&params)?,
            "list" => crate::conversation_archive_jobs::list(&params)?,
            "events" => crate::conversation_archive_jobs::events(&params)?,
            "cancel" => crate::conversation_archive_jobs::cancel(&params)?,
            "drain" => crate::conversation_archive_jobs::drain(&params)?,
            _ => return Ok(CliExecution::Usage),
        };
        return Ok(CliExecution::Json(result));
    }
    let params = cli_params(&args[3..]);
    let result = match action.as_str() {
        "collect" => crate::conversation_snapshots::archive_collect(&params)?,
        "run" => crate::conversation_snapshots::archive_run(&params)?,
        "verify" => crate::conversation_snapshots::archive_verify(&params)?,
        "report" => crate::conversation_snapshots::archive_report(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}

fn handle_snapshots_collections(args: &[String]) -> Result<CliExecution> {
    let params = cli_params(&args[3..]);
    Ok(CliExecution::Json(
        crate::conversation_snapshots::collections_list(&params)?,
    ))
}

fn handle_conversations(args: &[String]) -> Result<CliExecution> {
    let action = &args[1];
    let params = cli_params(&args[2..]);
    let result = match action.as_str() {
        "list" => crate::conversations::conversation_list(&params)?,
        "append" => crate::conversations::conversation_append(&params)?,
        "delete" => crate::conversations::conversation_delete(&params)?,
        _ => return Ok(CliExecution::Usage),
    };
    Ok(CliExecution::Json(result))
}
