//! Typed failures.
//!
//! Every failure is a stable code with no local path and no stored value in it, so the
//! tool can be run on a machine whose paths never leave it.
//!
//! The code set is one value shared by every verb, so the crate keeps the whole
//! vocabulary live rather than pruning the constants one consumer happens not to use yet.

#![allow(dead_code)]

use std::fmt;

/// A failure the tool reports without exposing the machine it ran on.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ToolError {
    code: &'static str,
}

impl ToolError {
    pub const fn new(code: &'static str) -> Self {
        Self { code }
    }

    pub const fn code(&self) -> &'static str {
        self.code
    }
}

impl fmt::Display for ToolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code)
    }
}

impl std::error::Error for ToolError {}

pub type ToolResult<T> = Result<T, ToolError>;

/// The data root the caller named is missing.
pub const DATA_ROOT_MISSING: ToolError = ToolError::new("data_root_missing");
/// The data root is not a directory.
pub const DATA_ROOT_NOT_DIRECTORY: ToolError = ToolError::new("data_root_not_directory");
/// The client's own owners could not report the frontier.
pub const FRONTIER_UNAVAILABLE: ToolError = ToolError::new("migration_frontier_unavailable");
/// The client's own owners could not report the observed state.
pub const STATE_UNAVAILABLE: ToolError = ToolError::new("migration_state_unavailable");
/// The stored state is newer than this tool knows how to read.
pub const STATE_NEWER_THAN_TOOL: ToolError = ToolError::new("state_newer_than_binary");
/// The named target is not one the fixed endpoints offer.
pub const TARGET_UNSUPPORTED: ToolError = ToolError::new("migration_target_unsupported");
/// The operator has not stated that every writer is stopped.
pub const WRITERS_RUNNING: ToolError = ToolError::new("maintenance_confirmation_required");
/// A run marker exists but cannot be parsed.
pub const MARKER_INVALID: ToolError = ToolError::new("migration_marker_invalid");
/// A run marker exists but cannot be read.
pub const MARKER_UNREADABLE: ToolError = ToolError::new("migration_marker_unreadable");
/// A run marker could not be written.
pub const MARKER_UNWRITABLE: ToolError = ToolError::new("migration_marker_unwritable");
/// A resume was asked for a journal whose run does not match this binary's frontier.
pub const JOURNAL_MISMATCHED: ToolError = ToolError::new("migration_journal_mismatched");
/// A step the owner reported as committed is not supported by the observed state.
pub const COMMIT_UNSUPPORTED: ToolError = ToolError::new("migration_commit_unsupported");
/// A resume point could not be advanced, so no further step was taken.
pub const STOPPED: ToolError = ToolError::new("migration_stopped");
/// The client's own conversion owner refused the root.
pub const OWNER_REFUSED: ToolError = ToolError::new("migration_owner_refused");
/// A verb was reached without the data root it reads.
pub const DATA_ROOT_REQUIRED: ToolError = ToolError::new("data_root_required");
/// An archive verb was reached without the archive it reads or writes.
pub const ARCHIVE_REQUIRED: ToolError = ToolError::new("archive_required");
/// An import was reached without the empty destination it publishes into.
pub const TARGET_ROOT_REQUIRED: ToolError = ToolError::new("target_root_required");
/// A rehearsal was reached without the disposable working directory it stages in.
pub const WORK_ROOT_REQUIRED: ToolError = ToolError::new("work_root_required");
/// The archive an export was asked to write sits inside the root it would capture.
pub const ARCHIVE_INSIDE_DATA_ROOT: ToolError = ToolError::new("archive_path_inside_data_root");
/// The rehearsal's disposable working root sits inside the source it promised only to read.
pub const WORK_ROOT_INSIDE_DATA_ROOT: ToolError = ToolError::new("work_root_inside_data_root");

/// A failure that names the marker it read, never the path it read it from.
pub fn marker_read_failed(_path: &std::path::Path) -> ToolError {
    MARKER_UNREADABLE
}

/// A marker document that could not be parsed.
pub const fn marker_invalid(_what: &'static str) -> ToolError {
    MARKER_INVALID
}

/// A marker that could not be written.
pub const fn marker_unwritable() -> ToolError {
    MARKER_UNWRITABLE
}
