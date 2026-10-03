//! Starting the supervised Claude Code process.
//!
//! The launch identity, the fixed streaming-input argv and its compatibility
//! rule are this Agent's protocol and live in the package. What is added here is
//! the part the package cannot own: creating the child process, giving it the
//! user's own shell environment, and augmenting `PATH` so sibling vendor tools
//! keep resolving.

use super::super::process_supervisor::SupervisedChild;
use licoup_agent_claude_code::protocol::LaunchIdentity;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub(in crate::platform) use licoup_agent_claude_code::protocol::FIXED_STREAM_ARGS;

/// Start this Agent's CLI for one turn.
///
/// The prompt never reaches argv: it is written to the child's standard input
/// by the process half. A resumed conversation passes only the native session
/// identifier.
pub(in crate::platform) fn spawn(
    identity: &LaunchIdentity,
) -> io::Result<SupervisedChild> {
    let mut command = Command::new(&identity.executable);
    super::super::user_shell_environment::apply_to_command(&mut command);
    command
        .args(identity.args())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // The executable's own directory stays the PATH head on top of the
    // user shell snapshot PATH, so sibling vendor tools keep resolving.
    if let Some(path) = executable_augmented_path(
        &identity.executable,
        super::super::user_shell_environment::get("PATH").map(OsStr::new),
    ) {
        command.env("PATH", path);
    }
    if let Some(cwd) = identity.cwd.as_ref() {
        command.current_dir(cwd);
    }
    SupervisedChild::spawn(&mut command)
}

pub(in crate::platform) fn executable_augmented_path(
    executable: &str,
    inherited: Option<&OsStr>,
) -> Option<OsString> {
    let parent = Path::new(executable).parent()?.as_os_str();
    if parent.is_empty() {
        return None;
    }
    let mut paths = vec![PathBuf::from(parent)];
    if let Some(inherited) = inherited {
        paths.extend(std::env::split_paths(inherited));
    }
    std::env::join_paths(paths).ok()
}
