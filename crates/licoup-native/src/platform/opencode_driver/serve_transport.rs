use super::continuity::open_serve_session;
use super::{OPENCODE_DRIVER, serve_capabilities};
use crate::platform::acp_driver_runtime::{
    CapabilityProbe, EffectiveSettings, ProtocolConfig, ProtocolFailure, RunResult,
    extract_assistant_text, project_agent_chunks, timestamp,
};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};
use uuid::Uuid;

const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

struct ServeOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    thread_id: String,
    turn_id: String,
    turn_status: String,
    effective: EffectiveSettings,
    capabilities: CapabilityProbe,
}

pub(in crate::platform) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    let _ = (max_stdout, max_stderr);
    let started_at = timestamp();
    let config = match ProtocolConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => {
            return RunResult::failed(
                OPENCODE_DRIVER,
                failure,
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };

    let endpoint = match super::super::opencode_serve::ensure_attach_endpoint(executable) {
        Ok(endpoint) => endpoint,
        Err(error) => {
            let missing = error.to_string().contains("missing");
            return RunResult::failed(
                OPENCODE_DRIVER,
                ProtocolFailure::new(
                    "acp_process_start_failed",
                    if missing {
                        "The requested ACP agent executable is not available."
                    } else {
                        "The OpenCode serve endpoint is not available for attach."
                    },
                    "serve/ensure",
                ),
                started_at,
                None,
                false,
                false,
                CapabilityProbe::default(),
                Vec::new(),
            );
        }
    };

    // timeoutMs 0 opts out of any turn deadline (see runtime_adapters/dispatch),
    // so only a non-zero window gets a concrete deadline.
    let deadline = (timeout_ms != 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    match execute_via_serve(&endpoint, &config, deadline) {
        Ok(outcome) => RunResult {
            ok: true,
            output: outcome.output,
            events: outcome.events,
            error: None,
            session_id: outcome.session_id,
            thread_id: outcome.thread_id,
            turn_id: outcome.turn_id,
            turn_status: outcome.turn_status,
            effective: outcome.effective,
            capabilities: outcome.capabilities,
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at,
            runtime_protocol: OPENCODE_DRIVER.runtime_protocol,
            driver_id: OPENCODE_DRIVER.agent_id,
        },
        Err(failure) => RunResult::failed(
            OPENCODE_DRIVER,
            failure,
            started_at,
            None,
            false,
            false,
            CapabilityProbe::default(),
            Vec::new(),
        ),
    }
}

fn execute_via_serve(
    endpoint: &super::super::opencode_serve::ServeEndpoint,
    config: &ProtocolConfig,
    deadline: Option<Instant>,
) -> Result<ServeOutcome, ProtocolFailure> {
    let session_id = open_serve_session(endpoint, config, deadline)?;
    let message_body = build_serve_message_body(config);

    let turn_id = Uuid::new_v4().to_string();
    let _active_turn = super::super::local_service::turn_control::register(
        OPENCODE_DRIVER.agent_id,
        &endpoint.attach_url,
        &session_id,
    )
    .map_err(|_| {
        ProtocolFailure::new(
            "acp_control_capacity",
            "The OpenCode active-turn control registry is at capacity.",
            "turn/control",
        )
        .with_session(Some(&session_id))
    })?;
    super::super::turn_event_emit::emit_turn_event(
        "dispatch.turn.bound",
        &session_id,
        &turn_id,
        json!({}),
    );
    let watch_stop = Arc::new(AtomicBool::new(false));
    let watch_flag = Arc::clone(&watch_stop);
    let watch_url = endpoint.attach_url.clone();
    let watch_session = session_id.clone();
    let (chunk_sender, chunk_receiver) = mpsc::sync_channel::<String>(64);
    let watch_handle = thread::spawn(move || {
        super::super::opencode_serve::watch_session_events(
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
                super::super::turn_event_emit::emit_agent_message_chunk(
                    &session_id,
                    &turn_id,
                    &text,
                );
                streamed.push(text);
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
    let response = post_handle.join().map_err(|_| {
        ProtocolFailure::new(
            "acp_protocol_read_failed",
            "The OpenCode serve response worker could not be joined.",
            "serve/http",
        )
    })?;
    watch_stop.store(true, Ordering::Relaxed);
    let _ = watch_handle.join();
    for text in chunk_receiver.try_iter() {
        super::super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
        streamed.push(text);
    }
    let response = response?;
    let output = extract_assistant_text(&response);
    if output.is_empty() {
        return Err(ProtocolFailure::new(
            "acp_final_message_missing",
            "The ACP agent completed the turn without a final agent message.",
            "session/prompt",
        )
        .with_session(Some(&session_id)));
    }
    super::super::turn_event_emit::emit_agent_message_completed(&session_id, &turn_id, &output);
    let mut events = project_agent_chunks(streamed);
    events.extend(super::super::skill_invocation_projection::project_skill_invocations(&response));
    Ok(ServeOutcome {
        output: output.clone(),
        events,
        session_id: session_id.clone(),
        thread_id: session_id,
        turn_id,
        turn_status: "end_turn".to_string(),
        effective: EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            model: config.settings.model.clone(),
            reasoning_effort: config.settings.reasoning_effort.clone(),
            mode: config.settings.mode.clone(),
            runtime_agent: config.settings.runtime_agent.clone(),
            allow_all: config.settings.allow_all,
            sandbox: None,
            approval_policy: None,
        },
        capabilities: serve_capabilities(),
    })
}

pub(super) fn build_serve_message_body(config: &ProtocolConfig) -> Value {
    let mut message_body = json!({
        "parts": [{"type": "text", "text": config.prompt}]
    });
    if let Some(model) = config.settings.model.as_deref() {
        // OpenCode accepts provider/model; when only a bare id is present keep text.
        if let Some((provider, model_id)) = model.split_once('/') {
            message_body["model"] = json!({
                "providerID": provider,
                "modelID": model_id
            });
        }
    }
    if let Some(agent) = config.settings.runtime_agent.as_deref() {
        message_body["agent"] = json!(agent);
    }
    message_body
}

pub(super) fn wait_post_json(
    url: &str,
    body: &Value,
    deadline: Option<Instant>,
) -> Result<Value, ProtocolFailure> {
    let timeout = remaining_turn_timeout(deadline)?;
    super::super::opencode_serve::post_json_with_optional_timeout(url, body, timeout).map_err(
        |_| {
            if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                turn_timeout_failure()
            } else {
                ProtocolFailure::new(
                    "acp_protocol_write_failed",
                    "The ACP agent stopped accepting protocol messages.",
                    "serve/http",
                )
            }
        },
    )
}

pub(super) fn remaining_turn_timeout(
    deadline: Option<Instant>,
) -> Result<Option<Duration>, ProtocolFailure> {
    match deadline {
        None => Ok(None),
        Some(deadline) => deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .map(Some)
            .ok_or_else(turn_timeout_failure),
    }
}

pub(super) fn turn_timeout_failure() -> ProtocolFailure {
    ProtocolFailure::new(
        "acp_protocol_timeout",
        "The ACP agent timed out before the turn completed.",
        "session/prompt",
    )
}
