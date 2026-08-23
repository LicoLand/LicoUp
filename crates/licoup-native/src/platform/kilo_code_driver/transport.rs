use super::super::acp_driver_runtime::ProtocolFailure;
use super::super::{kilo_code_serve, turn_event_emit};
use super::config::ServeTurnConfig;
use super::projection::{ProtocolOutcome, project_turn};
use crate::platform::native_agent_parser::adapters::kilo_code as serve_parser;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex};
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
        None,
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
    let first_failure = Arc::new(Mutex::new(None::<ProtocolFailure>));
    let turn_completed = Arc::new(AtomicBool::new(false));
    let watch_failure = Arc::clone(&first_failure);
    let watch_completed = Arc::clone(&turn_completed);
    let watch_handle = thread::spawn(move || {
        match kilo_code_serve::watch_session_events(
            &watch_url,
            &watch_session,
            &watch_flag,
            &chunk_sender,
        ) {
            Ok(()) => None,
            Err(kilo_code_serve::EventStreamFailure::Closed) => Some(sse_failure(
                kilo_code_serve::EventStreamFailure::Closed,
                &watch_session,
            )),
            Err(failure) => {
                if !watch_completed.load(Ordering::Acquire) {
                    record_first_failure(&watch_failure, sse_failure(failure, &watch_session));
                }
                None
            }
        }
    });
    let post_url = format!("{}/session/{}/message", endpoint.attach_url, session_id);
    let post_failure = Arc::clone(&first_failure);
    let post_completed = Arc::clone(&turn_completed);
    let post_handle = thread::spawn(move || {
        let response = wait_post_json(&post_url, &message_body, deadline);
        match &response {
            Ok(_) => post_completed.store(true, Ordering::Release),
            Err(failure) => record_first_failure(&post_failure, failure.clone()),
        }
        response
    });
    while !post_handle.is_finished() {
        match chunk_receiver.recv_timeout(PROCESS_POLL_INTERVAL) {
            Ok(text) => {
                turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let response = match post_handle.join() {
        Ok(response) => Some(response),
        Err(_) => {
            record_first_failure(
                &first_failure,
                ProtocolFailure::new(
                    "kilo_code_serve_cleanup_failed",
                    "The Kilo message response worker could not be joined.",
                    "serve/cleanup",
                )
                .with_session(Some(&session_id)),
            );
            None
        }
    };
    watch_stop.store(true, Ordering::Relaxed);
    let provisional_observer_failure = match watch_handle.join() {
        Ok(failure) => failure,
        Err(_) => {
            record_first_failure(
                &first_failure,
                ProtocolFailure::new(
                    "kilo_code_serve_cleanup_failed",
                    "The Kilo event-stream worker could not be joined.",
                    "serve/cleanup",
                )
                .with_session(Some(&session_id)),
            );
            None
        }
    };
    for text in chunk_receiver.try_iter() {
        turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
    }
    if let Some(failure) = select_canonical_failure(
        &first_failure,
        response.as_ref(),
        provisional_observer_failure,
    ) {
        return Err(failure);
    }
    let response = response.ok_or_else(|| {
        ProtocolFailure::new(
            "kilo_code_serve_cleanup_failed",
            "The Kilo message response worker did not return an outcome.",
            "serve/cleanup",
        )
    })??;
    let response = serve_parser::message(&response).ok_or_else(|| {
        ProtocolFailure::new(
            "kilo_code_serve_final_message_missing",
            "The Kilo turn completed without a final assistant message.",
            "session/prompt",
        )
        .with_session(Some(&session_id))
    })?;
    let outcome = project_turn(response, session_id, turn_id, config)?;
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
            Ok(payload) if serve_parser::session_id(&payload).is_some() => {
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
    serve_parser::session_id(&created)
        .map(str::to_string)
        .ok_or_else(|| {
            ProtocolFailure::new(
                "acp_session_id_missing",
                "The ACP agent did not return a native conversation identifier.",
                "session/new",
            )
        })
}

fn record_first_failure(slot: &Mutex<Option<ProtocolFailure>>, failure: ProtocolFailure) {
    if let Ok(mut slot) = slot.lock()
        && slot.is_none()
    {
        *slot = Some(failure);
    }
}

fn select_canonical_failure(
    first_failure: &Mutex<Option<ProtocolFailure>>,
    response: Option<&Result<Value, ProtocolFailure>>,
    provisional_observer_failure: Option<ProtocolFailure>,
) -> Option<ProtocolFailure> {
    let exact_failure = first_failure.lock().ok().and_then(|slot| slot.clone());
    if exact_failure.is_some() {
        return exact_failure;
    }
    if matches!(response, Some(Ok(_))) {
        // The message endpoint owns terminal settlement. A plain SSE EOF is
        // observer loss and cannot relabel an already returned HTTP terminal.
        return None;
    }
    provisional_observer_failure
}

fn sse_failure(failure: kilo_code_serve::EventStreamFailure, session_id: &str) -> ProtocolFailure {
    use super::super::local_service::sse::SseFailure;
    use kilo_code_serve::EventStreamFailure;
    let code = match failure {
        EventStreamFailure::Closed => "kilo_code_serve_sse_closed",
        EventStreamFailure::Decode(_) => "kilo_code_serve_sse_invalid_json",
        EventStreamFailure::Framing(SseFailure::Busy) => "kilo_code_serve_sse_busy",
        EventStreamFailure::Framing(SseFailure::EventLimit) => "kilo_code_serve_sse_event_limit",
        EventStreamFailure::Framing(SseFailure::FrameTooLarge) => {
            "kilo_code_serve_sse_frame_too_large"
        }
        EventStreamFailure::Framing(SseFailure::HeadersTooLarge) => {
            "kilo_code_serve_sse_headers_too_large"
        }
        EventStreamFailure::Framing(SseFailure::InvalidUtf8) => "kilo_code_serve_sse_invalid_utf8",
        EventStreamFailure::Framing(SseFailure::InvalidUrl) => "kilo_code_serve_sse_url_invalid",
        EventStreamFailure::Framing(SseFailure::LineTooLarge) => {
            "kilo_code_serve_sse_line_too_large"
        }
        EventStreamFailure::Framing(SseFailure::Request) => "kilo_code_serve_sse_request_failed",
        EventStreamFailure::Framing(SseFailure::Unavailable) => "kilo_code_serve_sse_unavailable",
    };
    ProtocolFailure::new(
        code,
        "The Kilo event stream failed before the turn completed.",
        "serve/sse",
    )
    .with_session(Some(session_id))
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
    if let Some(instructions) = config.private_instructions.as_deref() {
        // Kilo's OpenCode-compatible message contract accepts native system
        // guidance independently from the user's text part.
        body["system"] = json!(instructions);
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
