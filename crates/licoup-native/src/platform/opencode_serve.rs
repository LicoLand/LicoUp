//! OpenCode headless serve facade.

mod policy;

use anyhow::Result;
use serde_json::Value;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::SyncSender;

use super::local_service;

pub use super::local_service::ServeEndpoint;
pub const DEFAULT_PORT: u16 = policy::DEFAULT_PORT;

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

pub(super) fn get_json(url: &str) -> Result<Value> {
    local_service::serve::get_json(policy::SPEC, url)
}

pub(super) fn post_json(url: &str, body: &Value) -> Result<Value> {
    local_service::serve::post_json(policy::SPEC, url, body)
}

pub(super) fn watch_session_events(
    attach_url: &str,
    session_id: &str,
    stop: &AtomicBool,
    chunks: &SyncSender<String>,
) {
    local_service::serve::watch_session_events(policy::SPEC, attach_url, session_id, stop, chunks)
}

#[cfg(test)]
fn project_event(
    projection: &mut local_service::serve::SessionEventProjection,
    session_id: &str,
    data: &str,
) -> Option<String> {
    projection.observe(session_id, data)
}

#[cfg(test)]
mod tests;
