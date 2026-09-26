//! Public backup commands.
//!
//! Two verbs, both routing straight to the native full-data-root owner:
//! `backup export` and `backup import`. The command layer only marshals the data
//! root, the archive path and the writer statement, and reports the owner's typed
//! outcome. It never copies a live database itself and never invents a key.

use super::{AdmittedCommand, CliExecution};
use crate::core::full_data_root_archive::{
    export_data_root, restore_data_root, ExportRequest, RestoreRequest,
};
use anyhow::{anyhow, Result};
use serde_json::json;
use std::path::PathBuf;

pub(super) fn handle_backup_export(command: AdmittedCommand) -> Result<CliExecution> {
    let data_root = data_root(&command)?;
    let archive_path = archive_path(&command)?;
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
    let target_root = command
        .option_text("target-root")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("backup_target_root_required"))?;
    let outcome = restore_data_root(&RestoreRequest {
        archive_path: archive_path(&command)?,
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

fn data_root(command: &AdmittedCommand) -> Result<PathBuf> {
    let raw = command
        .option_text("data-root")
        .ok_or_else(|| anyhow!("backup_data_root_required"))?;
    let root = PathBuf::from(raw);
    let root = if root.is_absolute() {
        root
    } else {
        std::env::current_dir()
            .map_err(|_| anyhow!("backup_data_root_unresolved"))?
            .join(root)
    };
    Ok(root)
}

fn archive_path(command: &AdmittedCommand) -> Result<PathBuf> {
    let path = PathBuf::from(command.required_text("archive"));
    Ok(if path.is_absolute() {
        path
    } else {
        std::env::current_dir()
            .map_err(|_| anyhow!("backup_archive_unresolved"))?
            .join(path)
    })
}
