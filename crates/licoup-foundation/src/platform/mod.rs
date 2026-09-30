//! Process, IO, path, network-boundary and user-presence primitives.
//!
//! Ordering inside this module is the measured dependency order: `file_security`
//! is the leaf, `paths` sits directly above it, and everything else sits above
//! both. One adapter is the measured exception to the rule that a module here
//! does not reach into `core`: `authorized_secure_record` implements the
//! authority that `core::authorized_secure_record` defines. Nothing in `core`
//! reaches back into `platform`.

pub mod agent_workspace;
pub mod ansi_stripper;
// Linux keeps the fail-closed adapter surface without a native record backend.
#[cfg_attr(target_os = "linux", allow(dead_code))]
pub mod authorized_secure_record;
pub mod diagnostics;
pub mod file_security;
pub mod native_agent_interaction;
pub mod paths;
pub mod process_sandbox;
pub mod process_supervisor;
// The PTY foundation itself is Unix-only; agent output parsing is portable and
// lives in `ansi_stripper` above.
#[cfg(unix)]
pub mod pty_transport;
pub mod raw_execution;
pub mod turn_event_emit;
pub mod url_security;
pub mod user_presence;
pub mod user_shell_environment;
