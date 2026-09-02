use super::super::acp_driver_runtime::ProtocolFailure;
use super::super::{kilo_code_serve, turn_event_emit};
use super::config::ServeTurnConfig;
use super::projection::{ProtocolOutcome, project_turn};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
const SESSION_EVENT_QUEUE_CAPACITY: usize = 64;

pub(super) fn execute_via_serve(
    endpoint: &kilo_code_serve::ServeEndpoint,
    config: &ServeTurnConfig,
    deadline: Option<Instant>,
) -> Result<ProtocolOutcome, ProtocolFailure> {
    let session_id = open_session(endpoint, config, deadline)?;
    let message_body = build_message_body(config);
    let turn_id = Uuid::new_v4().to_string();
    let _active_turn = super::super::local_service::turn_control::register(
        super::KILO_CODE_DRIVER.agent_id,
        &endpoint.attach_url,
        &session_id,
    )
    .map_err(|_| {
        ProtocolFailure::new(
            "acp_control_capacity",
            "The Kilo active-turn control registry is at capacity.",
            "turn/control",
        )
        .with_session(Some(&session_id))
    })?;
    turn_event_emit::emit_turn_event("dispatch.turn.bound", &session_id, &turn_id, json!({}));
    let watch_stop = Arc::new(AtomicBool::new(false));
    let watch_flag = Arc::clone(&watch_stop);
    let watch_url = endpoint.attach_url.clone();
    let watch_session = session_id.clone();
    let (chunk_sender, chunk_receiver) = mpsc::sync_channel::<String>(SESSION_EVENT_QUEUE_CAPACITY);
    let watch_handle = thread::spawn(move || {
        kilo_code_serve::watch_session_events(
            &watch_url,
            &watch_session,
            &watch_flag,
            &chunk_sender,
        );
    });
    let post_url = format!("{}/session/{}/message", endpoint.attach_url, session_id);
    let post_handle = thread::spawn(move || wait_post_json(&post_url, &message_body, deadline));
    let mut streamed = Vec::new();
    while !post_handle.is_finished() {
        match chunk_receiver.recv_timeout(PROCESS_POLL_INTERVAL) {
            Ok(text) => {
                turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
                streamed.push(text);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let response = post_handle.join().map_err(|_| {
        ProtocolFailure::new(
            "acp_protocol_read_failed",
            "The Kilo serve response worker could not be joined.",
            "serve/http",
        )
    })?;
    watch_stop.store(true, Ordering::Relaxed);
    let _ = watch_handle.join();
    for text in chunk_receiver.try_iter() {
        turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
        streamed.push(text);
    }
    let response = response?;
    let outcome = project_turn(&response, streamed, session_id, turn_id, config)?;
    turn_event_emit::emit_agent_message_completed(
        &outcome.session_id,
        &outcome.turn_id,
        &outcome.output,
    );
    Ok(outcome)
}

fn open_session(
    endpoint: &kilo_code_serve::ServeEndpoint,
    config: &ServeTurnConfig,
    deadline: Option<Instant>,
) -> Result<String, ProtocolFailure> {
    if config.is_resume() {
        let url = format!(
            "{}/session/{}",
            endpoint.attach_url, config.requested_session_id
        );
        return match kilo_code_serve::get_json(&url) {
            Ok(payload) if payload.get("id").and_then(Value::as_str).is_some() => {
                Ok(config.requested_session_id.clone())
            }
            Ok(_) | Err(_) => Err(ProtocolFailure::new(
                "acp_native_session_not_found",
                "The requested native conversation does not exist in the ACP agent.",
                "session/load",
            )
            .with_session(Some(&config.requested_session_id))),
        };
    }

    let body = if config.cwd.is_empty() {
        json!({})
    } else {
        json!({"directory": config.cwd})
    };
    let created = wait_post_json(&format!("{}/session", endpoint.attach_url), &body, deadline)?;
    created
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            ProtocolFailure::new(
                "acp_session_id_missing",
                "The ACP agent did not return a native conversation identifier.",
                "session/new",
            )
        })
}

pub(super) fn build_message_body(config: &ServeTurnConfig) -> Value {
    let mut body = json!({
        "parts": [{"type": "text", "text": config.prompt}]
    });
    if let Some(model) = config.model.as_deref() {
        if model == "kilo-auto/free" || model.ends_with(":free") {
            // Kilo presents gateway routes without the outer provider prefix
            // in local history. Its serve API still requires the canonical
            // `kilo` provider and keeps the complete nested route as modelID.
            body["model"] = json!({
                "providerID": "kilo",
                "modelID": model
            });
        } else if let Some((provider, model_id)) = model.split_once('/') {
            body["model"] = json!({
                "providerID": provider,
                "modelID": model_id
            });
        }
    }
    if let Some(agent) = config.runtime_agent.as_deref() {
        body["agent"] = json!(agent);
    }
    if let Some(reasoning_effort) = config.reasoning_effort.as_deref() {
        body["variant"] = json!(reasoning_effort);
    }
    body
}

pub(super) fn wait_post_json(
    url: &str,
    body: &Value,
    deadline: Option<Instant>,
) -> Result<Value, ProtocolFailure> {
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Err(ProtocolFailure::new(
            "acp_protocol_timeout",
            "The ACP agent timed out before the turn completed.",
            "session/prompt",
        ));
    }
    kilo_code_serve::post_json(url, body).map_err(|_| {
        ProtocolFailure::new(
            "acp_protocol_write_failed",
            "The ACP agent stopped accepting protocol messages.",
            "serve/http",
        )
    })
}
