mod composition;
mod config;
mod execution;
mod probe;
mod projection;
mod transport;

use super::super::kilo_code_serve;
use super::config::ServeTurnConfig;
use super::execution::execute;
use super::probe::capability_probe;
use super::projection::{extract_assistant_text, project_turn, serve_capabilities};
use super::transport::{build_message_body, execute_via_serve, wait_post_json};
use super::{KILO_CODE_DRIVER, RUNTIME_PROTOCOL};
use serde_json::{Value, json};
use std::path::Path;
use std::thread;
use std::time::{Duration, Instant};

fn test_config(prompt: &str, session_id: &str) -> ServeTurnConfig {
    ServeTurnConfig {
        prompt: prompt.to_string(),
        requested_session_id: session_id.to_string(),
        cwd: std::env::current_dir()
            .unwrap()
            .to_string_lossy()
            .into_owned(),
        model: None,
        runtime_agent: None,
        reasoning_effort: None,
        mode: None,
        allow_all: None,
    }
}
