mod codec;
mod composition;
mod continuity;
mod errors;
mod events;
mod execution;
mod interaction;
mod io;
mod model;
mod params;
mod probe;
mod protocol;
mod supervision;
mod support;

use super::codec::{
    INITIALIZE_REQUEST_ID, SESSION_REQUEST_ID, decode_message, encode_message, request_id_matches,
};
use super::continuity::{SessionBinding, session_request};
use super::errors::ProtocolFailure;
use super::events::projected_event;
use super::execution::execute;
use super::io::{TransportEvent, drain_stderr, read_protocol_messages};
use super::model::{EffectiveSettings, RUNTIME_PROTOCOL, RunResult};
use super::params::{ProtocolConfig, normalize_agent_id};
use super::probe::{first_nonempty_line, probe};
use super::protocol::{OpenClawProtocol, ProtocolEffect, ProtocolPhase};
use super::supervision::{ATTACH_ARGS_PREFIX, LaunchSpec, attach_mode, resolve_gateway_endpoint};
use crate::core::acp;
use serde_json::{Value, json};
use std::fs;
use std::io::Cursor;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc;
use support::*;
