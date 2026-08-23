mod composition;
mod probe;
mod serve_transport;
mod support;

use super::continuity::build_session_create_body;
use super::serve_transport::{
    build_serve_message_body, execute, remaining_turn_timeout, request_failure, wait_post_json,
    workspace_request_url,
};
use super::{OPENCODE_DRIVER, RUNTIME_PROTOCOL, capability_probe, serve_capabilities};
use crate::platform::acp_driver_runtime::ProtocolConfig;
use crate::platform::local_service::http::HttpFailure;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use support::*;
