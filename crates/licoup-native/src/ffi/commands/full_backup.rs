//! Public backup commands.
//!
//! Two verbs, both routing straight to the native full-data-root owner:
//! `backup export` and `backup import`. The command layer only marshals the data
//! root, the archive path and the writer statement, and reports the owner's typed
//! outcome. It never copies a live database itself and never invents a key.
//! The caller always names the archive destination; there is no default, and a
//! destination inside the captured root is refused before the owner runs.

use super::{AdmittedCommand, CliExecution};
use anyhow::{Result, anyhow, ensure};
use licoup_foundation::core::full_data_root_archive::{
    ExportRequest, RestoreRequest, archive_path_inside_data_root, export_data_root,
    restore_data_root,
};
use serde_json::json;
use std::path::PathBuf;

pub(super) fn handle_backup_export(command: AdmittedCommand) -> Result<CliExecution> {
    let data_root = absolute_path(
        command
            .option_text("data-root")
            .ok_or_else(|| anyhow!("backup_data_root_required"))?,
        "backup_data_root_unresolved",
    )?;
    let archive_path = absolute_path(
        command.required_text("archive"),
        "backup_archive_unresolved",
    )?;
    // The caller names the destination; the verb never defaults one. The archive must not
    // be part of the data the capture reads, so an inadmissible destination is refused
    // here, before the owner is asked to create anything. The owner holds the same rule
    // for every caller.
    ensure!(
        !archive_path_inside_data_root(&data_root, &archive_path),
        "archive_path_inside_data_root"
    );
    let outcome = export_data_root(&ExportRequest {
        data_root,
        archive_path,
        writers_stopped: command.option_flag("writers-stopped"),
    })?;
    Ok(CliExecution::Json(json!({
        "status": "exported",
        "container": outcome.container.extension(),
        "coverage": outcome.coverage,
        "limitations": outcome.limitations,
        "fileCount": outcome.file_count,
        "totalBytes": outcome.total_bytes,
    })))
}

pub(super) fn handle_backup_import(command: AdmittedCommand) -> Result<CliExecution> {
    let target_root = PathBuf::from(
        command
            .option_text("target-root")
            .ok_or_else(|| anyhow!("backup_target_root_required"))?,
    );
    let outcome = restore_data_root(&RestoreRequest {
        archive_path: absolute_path(
            command.required_text("archive"),
            "backup_archive_unresolved",
        )?,
        target_root,
    })?;
    Ok(CliExecution::Json(json!({
        "status": "imported",
        "container": outcome.container.extension(),
        "coverage": outcome.coverage,
        "limitations": outcome.limitations,
        "fileCount": outcome.file_count,
        "totalBytes": outcome.total_bytes,
    })))
}

/// The absolute form of one admitted path: a relative name the caller supplied is read
/// against the process working directory, exactly as the owner will read it.
fn absolute_path(raw: &str, unresolved: &'static str) -> Result<PathBuf> {
    let path = PathBuf::from(raw);
    Ok(if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .map_err(|_| anyhow!(unresolved))?
            .join(path)
    })
}
