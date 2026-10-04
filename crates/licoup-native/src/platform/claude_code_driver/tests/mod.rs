mod command;
mod composition;
mod control;
mod failure;
mod events;
mod execution;
mod io;
mod model;
mod launch;
mod probe;
mod protocol;
mod supervision;
mod support;
mod transport;

#[path = "../../../../tests/fixtures/claude_process_local_test_lock.rs"]
mod claude_process_local_test_lock;

use super::launch::{FIXED_STREAM_ARGS, executable_augmented_path};
use licoup_agent_claude_code::protocol::LaunchIdentity;
use super::control::ControlDisposition;
use super::failure::ProtocolFailure;
use super::launch::DriverConfig;
use super::reset::requires_transport_reset;
use super::execution::execute;
use super::io::{
    MAX_PROTOCOL_LINE_BYTES, TransportEvent, drain_stderr, read_bounded, read_protocol_messages,
};
use super::model::{CompleteTranscript, RUNTIME_PROTOCOL, RunResult, TransportLifecycle};
use licoup_agent_claude_code::protocol::{CapabilityProbe, EffectiveSettings};
use super::probe::probe;
use super::supervision::{
    cancel, cleanup_session, clear_all_for_test, has_live_session, lookup_session_transport, steer,
};
use super::transport::PersistentTransport;
use crate::platform::native_agent_parser::adapters::NativeLineParser;
use licoup_agent_claude_code::protocol::parser::events::partial_text_delta;
use licoup_agent_claude_code::protocol::parser::{
    ClaudeCodeParser, ClaudeEffect, interrupt_request,
};
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
