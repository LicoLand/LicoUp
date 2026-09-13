//! Kilo Code headless serve facade.

mod policy;

use anyhow::Result;
use serde_json::Value;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::SyncSender;

use super::local_service;
use super::native_agent_parser::adapters::kilo_code::{ServeEventFailure, ServeEventParser};

pub use super::local_service::ServeEndpoint;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum EventStreamFailure {
    Closed,
    Decode(ServeEventFailure),
    Framing(super::local_service::sse::SseFailure),
}

pub(super) fn ensure_attachment(executable: &str) -> Result<local_service::ServeAttachment> {
    local_service::serve::ensure_attachment(policy::SPEC, executable)
}

pub(super) fn get_json(url: &str) -> Result<Value> {
    local_service::serve::get_json(policy::SPEC, url, None)
}

pub(super) fn get_session_json(url: &str) -> Result<Value> {
    local_service::serve::get_json(policy::SPEC, url, Some("kilo-code.http"))
}

pub(super) fn post_json(url: &str, body: &Value) -> Result<Value> {
    local_service::serve::post_json(policy::SPEC, url, body, "kilo-code.http")
}

pub(super) fn watch_session_events(
    attach_url: &str,
    session_id: &str,
    stop: &AtomicBool,
    chunks: &SyncSender<String>,
) -> std::result::Result<(), EventStreamFailure> {
    let url = format!("{}/event", attach_url.trim_end_matches('/'));
    let mut parser = ServeEventParser::new(session_id);
    let mut decode_failure = None;
    let raw_observer = super::raw_execution::RawExecutionObserver::current();
    let result = local_service::sse::watch_frames(&url, stop, |data, frame| {
        if let Some(observer) = raw_observer.as_ref()
            && local_service::sse::frame_belongs_to_session(data, session_id)
        {
            observer.record_bytes(
                "kilo-code.sse",
                super::raw_execution::RawExecutionDirection::Received,
                frame,
            );
        }
        match parser.observe(data) {
            Ok(Some(text)) => {
                let _ = chunks.try_send(text);
                true
            }
            Ok(None) => true,
            Err(failure) => {
                decode_failure = Some(failure);
                false
            }
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
