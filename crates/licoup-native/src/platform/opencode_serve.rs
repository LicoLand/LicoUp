//! OpenCode headless serve facade.

mod policy;

use anyhow::Result;
use serde_json::Value;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::SyncSender;

use super::local_service::{self, http::HttpFailure};
use super::native_agent_parser::adapters::opencode::{ServeEventFailure, ServeEventParser};

pub use super::local_service::ServeEndpoint;
pub const DEFAULT_PORT: u16 = policy::DEFAULT_PORT;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum EventStreamFailure {
    Closed,
    Decode(ServeEventFailure),
    Framing(super::local_service::sse::SseFailure),
}

pub fn ensure(params: &Value) -> Result<Value> {
    local_service::serve::ensure(policy::SPEC, params)
}

pub fn start(params: &Value) -> Result<Value> {
    local_service::serve::start(policy::SPEC, params)
}

pub fn restart(params: &Value) -> Result<Value> {
    local_service::serve::restart(policy::SPEC, params)
}

pub fn stop(_params: &Value) -> Result<Value> {
    local_service::serve::stop(policy::SPEC)
}

pub fn status(_params: &Value) -> Result<Value> {
    local_service::serve::status(policy::SPEC)
}

pub fn ensure_attach_endpoint(executable: &str) -> Result<ServeEndpoint> {
    local_service::serve::ensure_attach_endpoint(policy::SPEC, executable)
}

pub(super) fn ensure_attachment(executable: &str) -> Result<local_service::ServeAttachment> {
    local_service::serve::ensure_attachment(policy::SPEC, executable)
}

pub fn select_available_port(preferred: u16) -> Result<u16> {
    local_service::serve::select_available_port(policy::SPEC, preferred)
}

pub fn select_available_port_with<F>(preferred: u16, is_bindable: F) -> Result<u16>
where
    F: Fn(u16) -> bool,
{
    local_service::serve::select_available_port_with(policy::SPEC, preferred, is_bindable)
}

pub fn is_reserved_conflict_port(port: u16) -> bool {
    local_service::serve::is_reserved_port(policy::SPEC, port)
}

pub(super) fn get_json(url: &str) -> std::result::Result<Value, HttpFailure> {
    local_service::http::get_json(url, std::time::Duration::from_secs(5))
}

pub(super) fn post_json_with_optional_timeout(
    url: &str,
    body: &Value,
    timeout: Option<std::time::Duration>,
) -> std::result::Result<Value, HttpFailure> {
    local_service::http::post_json_with_optional_timeout(url, body, timeout)
}

pub(super) fn watch_session_events_url(
    url: &str,
    session_id: &str,
    stop: &AtomicBool,
    chunks: &SyncSender<String>,
) -> std::result::Result<(), EventStreamFailure> {
    let mut parser = ServeEventParser::new(session_id);
    let mut decode_failure = None;
    let result = local_service::sse::watch_data(url, stop, |data| match parser.observe(data) {
        Ok(Some(text)) => {
            let _ = chunks.try_send(text);
            true
        }
        Ok(None) => true,
        Err(failure) => {
            decode_failure = Some(failure);
            false
        }
    });
    if let Some(failure) = decode_failure {
        return Err(EventStreamFailure::Decode(failure));
    }
    match result {
        Ok(()) if !stop.load(std::sync::atomic::Ordering::Relaxed) => {
            Err(EventStreamFailure::Closed)
        }
        Ok(()) => Ok(()),
        Err(failure) => Err(EventStreamFailure::Framing(failure)),
    }
}

#[cfg(test)]
mod tests;
