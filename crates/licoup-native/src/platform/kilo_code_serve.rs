//! Kilo Code headless serve facade.

mod policy;

use anyhow::Result;
use serde_json::Value;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::SyncSender;

use super::local_service;

pub use super::local_service::ServeEndpoint;

pub fn ensure_attach_endpoint(executable: &str) -> Result<ServeEndpoint> {
    local_service::serve::ensure_attach_endpoint(policy::SPEC, executable)
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
