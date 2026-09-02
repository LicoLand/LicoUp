mod command;
mod composition;
mod control;
mod errors;
mod events;
mod execution;
mod io;
mod model;
mod params;
mod probe;
mod protocol;
mod supervision;
mod support;
mod transport;

#[path = "../../../../tests/fixtures/claude_process_local_test_lock.rs"]
mod claude_process_local_test_lock;

use super::command::{FIXED_STREAM_ARGS, LaunchIdentity, executable_augmented_path};
use super::control::{ControlDisposition, denied_control_response, interrupt_request};
use super::errors::{ProtocolFailure, requires_transport_reset};
use super::events::{partial_text_delta, project_event};
use super::execution::execute;
use super::io::{
    MAX_PROTOCOL_LINE_BYTES, TransportEvent, drain_stderr, read_bounded, read_protocol_messages,
};
use super::model::{
    BoundedTranscript, CapabilityProbe, EffectiveSettings, RUNTIME_PROTOCOL, RunResult,
    TransportLifecycle,
};
use super::params::DriverConfig;
use super::probe::probe;
use super::protocol::TurnState;
use super::supervision::{
    cancel, cleanup_session, clear_all_for_test, has_live_session, lookup_session_transport, steer,
};
use super::transport::PersistentTransport;
use serde_json::{Value, json};
use std::fs;
use std::io::{BufReader, Cursor};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use support::*;
