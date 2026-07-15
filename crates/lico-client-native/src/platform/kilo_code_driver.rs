use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

use super::opencode_driver::{
    AcpDriverSpec, CapabilityProbe, EffectiveSettings, ProtocolFailure, RunResult,
};

/// Primary native lane: Kilo headless `serve` + HTTP attach (ports 4097–4116).
///
/// Exact continue loads `GET /session/{nativeSessionId}` then posts the follow-up
/// to that same id. Streaming comes from SSE `/event` (with a final chunk fallback).
/// Interactive `--continue` / `-c` (newest-session) and argv session identity are
/// never used. ACP (`kilo acp`) remains a secondary vendor surface and is not the
/// conversation send path.
pub(super) const RUNTIME_PROTOCOL: &str = "kilo-code-serve-http-v1";
const KILO_CODE_DRIVER: AcpDriverSpec = AcpDriverSpec::new(RUNTIME_PROTOCOL, &["serve"])
    .with_identity("kilo-code-serve", "kilo_code_serve");
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);

struct ServeTurnConfig {
    prompt: String,
    requested_session_id: String,
    cwd: String,
    model: Option<String>,
    runtime_agent: Option<String>,
    reasoning_effort: Option<String>,
    mode: Option<String>,
    allow_all: Option<bool>,
}

impl ServeTurnConfig {
    fn from_params(
        params: &Value,
        prompt: &str,
        session_id: &str,
        cwd: Option<&Path>,
    ) -> Result<Self, ProtocolFailure> {
        let cwd = cwd
            .map(Path::to_path_buf)
            .or_else(|| {
                params
                    .get("cwd")
                    .or_else(|| params.get("workingDirectory"))
                    .and_then(Value::as_str)
                    .map(PathBuf::from)
            })
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("/")));
        if !cwd.is_absolute() {
            return Err(ProtocolFailure::new(
                "acp_working_directory_invalid",
                "ACP conversation sessions require an absolute working directory.",
                "initialize",
            ));
        }
        Ok(Self {
            prompt: prompt.to_string(),
            requested_session_id: session_id.trim().to_string(),
            cwd: cwd.to_string_lossy().into_owned(),
            model: text_setting(params, &["model"]),
            runtime_agent: text_setting(params, &["agent", "runtimeAgent"]),
            reasoning_effort: text_setting(params, &["reasoningEffort", "reasoning"]),
            mode: text_setting(params, &["mode"]),
            allow_all: params.get("allowAll").and_then(Value::as_bool),
        })
    }

    fn is_resume(&self) -> bool {
        !self.requested_session_id.is_empty()
    }
}

use std::path::PathBuf;

fn text_setting(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

fn timestamp() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    millis.to_string()
}

pub(super) fn capability_probe(
    executable: &str,
    cwd: &Path,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> Result<CapabilityProbe, ProtocolFailure> {
    let _ = (max_stdout, max_stderr);
    if !cwd.is_absolute() {
        return Err(ProtocolFailure::new(
            "acp_working_directory_invalid",
            "ACP conversation sessions require an absolute working directory.",
            "initialize",
        )
        .namespaced(KILO_CODE_DRIVER));
    }
    if executable.trim().is_empty() {
        return Err(ProtocolFailure::new(
            "acp_process_start_failed",
            "The requested ACP agent executable is not available.",
            "serve/ensure",
        )
        .namespaced(KILO_CODE_DRIVER));
    }
    let endpoint = super::kilo_code_serve::ensure_attach_endpoint(executable).map_err(|error| {
        let missing =
            error.to_string().contains("missing") || error.to_string().contains("not available");
        ProtocolFailure::new(
            "acp_process_start_failed",
            if missing {
                "The requested ACP agent executable is not available."
            } else {
                "The Kilo serve endpoint is not available for attach."
            },
            "serve/ensure",
        )
        .namespaced(KILO_CODE_DRIVER)
    })?;
    let health_timeout = timeout_ms.max(1_000);
    let deadline = Instant::now() + Duration::from_millis(health_timeout);
    loop {
        match super::kilo_code_serve::get_json(&format!("{}/global/health", endpoint.attach_url)) {
            Ok(payload)
                if payload
                    .get("healthy")
                    .and_then(Value::as_bool)
                    .unwrap_or(false) =>
            {
                let _ =
                    super::kilo_code_serve::get_json(&format!("{}/session", endpoint.attach_url))
                        .map_err(|_| {
                        ProtocolFailure::new(
                            "acp_initialize_invalid",
                            "The ACP agent returned an invalid initialization response.",
                            "serve/session",
                        )
                        .namespaced(KILO_CODE_DRIVER)
                    })?;
                return Ok(CapabilityProbe {
                    protocol_version: Some(1),
                    load_session: true,
                    resume_session: true,
                    close_session: true,
                    list_sessions: true,
                    delete_session: false,
                    additional_directories: false,
                    image_prompts: false,
                    audio_prompts: false,
                    embedded_context: false,
                });
            }
            _ if Instant::now() >= deadline => {
                return Err(ProtocolFailure::new(
                    "acp_protocol_timeout",
                    "The ACP agent timed out during capability negotiation.",
                    "serve/health",
                )
                .namespaced(KILO_CODE_DRIVER));
            }
            _ => thread::sleep(PROCESS_POLL_INTERVAL),
        }
    }
}

pub(super) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: usize,
    max_stderr: usize,
) -> RunResult {
    let _ = (max_stdout, max_stderr);
    let started_at = timestamp();
    let config = match ServeTurnConfig::from_params(params, prompt, session_id, cwd) {
        Ok(config) => config,
        Err(failure) => {
            return RunResult::failed(
                KILO_CODE_DRIVER,
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
    if executable.trim().is_empty() {
        return RunResult::failed(
            KILO_CODE_DRIVER,
            ProtocolFailure::new(
                "acp_process_start_failed",
                "The requested ACP agent executable is not available.",
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

    let endpoint = match super::kilo_code_serve::ensure_attach_endpoint(executable) {
        Ok(endpoint) => endpoint,
        Err(error) => {
            let missing = error.to_string().contains("missing")
                || error.to_string().contains("not available");
            return RunResult::failed(
                KILO_CODE_DRIVER,
                ProtocolFailure::new(
                    "acp_process_start_failed",
                    if missing {
                        "The requested ACP agent executable is not available."
                    } else {
                        "The Kilo serve endpoint is not available for attach."
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

    let deadline = Instant::now() + Duration::from_millis(timeout_ms.max(1_000));
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
            runtime_protocol: KILO_CODE_DRIVER.runtime_protocol,
            driver_id: KILO_CODE_DRIVER.agent_id,
        },
        Err(failure) => RunResult::failed(
            KILO_CODE_DRIVER,
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

struct ProtocolOutcome {
    output: String,
    events: Vec<Value>,
    session_id: String,
    thread_id: String,
    turn_id: String,
    turn_status: String,
    effective: EffectiveSettings,
    capabilities: CapabilityProbe,
}

fn execute_via_serve(
    endpoint: &super::kilo_code_serve::ServeEndpoint,
    config: &ServeTurnConfig,
    deadline: Instant,
) -> Result<ProtocolOutcome, ProtocolFailure> {
    let session_id = if config.is_resume() {
        let url = format!(
            "{}/session/{}",
            endpoint.attach_url, config.requested_session_id
        );
        match super::kilo_code_serve::get_json(&url) {
            Ok(payload) if payload.get("id").and_then(Value::as_str).is_some() => {
                config.requested_session_id.clone()
            }
            Err(error) if error.to_string().contains("kilo_code_serve_not_found") => {
                return Err(ProtocolFailure::new(
                    "acp_native_session_not_found",
                    "The requested native conversation does not exist in the ACP agent.",
                    "session/load",
                )
                .with_session(Some(&config.requested_session_id)));
            }
            Ok(_) | Err(_) => {
                return Err(ProtocolFailure::new(
                    "acp_native_session_not_found",
                    "The requested native conversation does not exist in the ACP agent.",
                    "session/load",
                )
                .with_session(Some(&config.requested_session_id)));
            }
        }
    } else {
        let mut body = json!({});
        if !config.cwd.is_empty() {
            body["directory"] = json!(config.cwd);
        }
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
            })?
    };

    let mut message_body = json!({
        "parts": [{"type": "text", "text": config.prompt}]
    });
    if let Some(model) = config.model.as_deref()
        && let Some((provider, model_id)) = model.split_once('/')
    {
        message_body["model"] = json!({
            "providerID": provider,
            "modelID": model_id
        });
    }
    if let Some(agent) = config.runtime_agent.as_deref() {
        message_body["agent"] = json!(agent);
    }

    let turn_id = Uuid::new_v4().to_string();
    let watch_stop = Arc::new(AtomicBool::new(false));
    let watch_flag = Arc::clone(&watch_stop);
    let watch_url = endpoint.attach_url.clone();
    let watch_session = session_id.clone();
    let (chunk_sender, chunk_receiver) = mpsc::sync_channel::<String>(64);
    let watch_handle = thread::spawn(move || {
        super::kilo_code_serve::watch_session_events(
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
                super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
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
        super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &text);
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
    if streamed.is_empty() {
        super::turn_event_emit::emit_agent_message_chunk(&session_id, &turn_id, &output);
        streamed.push(output.clone());
    }
    super::turn_event_emit::emit_agent_message_completed(&session_id, &turn_id, &output);
    Ok(ProtocolOutcome {
        output: output.clone(),
        events: streamed
            .into_iter()
            .map(|text| {
                json!({
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": text}
                })
            })
            .collect(),
        session_id: session_id.clone(),
        thread_id: session_id,
        turn_id,
        turn_status: "end_turn".to_string(),
        effective: EffectiveSettings {
            cwd: Some(config.cwd.clone()),
            model: config.model.clone(),
            reasoning_effort: config.reasoning_effort.clone(),
            mode: config.mode.clone(),
            runtime_agent: config.runtime_agent.clone(),
            allow_all: config.allow_all,
            sandbox: None,
            approval_policy: None,
        },
        capabilities: CapabilityProbe {
            protocol_version: Some(1),
            load_session: true,
            resume_session: true,
            close_session: true,
            list_sessions: true,
            delete_session: false,
            additional_directories: false,
            image_prompts: false,
            audio_prompts: false,
            embedded_context: false,
        },
    })
}

fn wait_post_json(url: &str, body: &Value, deadline: Instant) -> Result<Value, ProtocolFailure> {
    if Instant::now() >= deadline {
        return Err(ProtocolFailure::new(
            "acp_protocol_timeout",
            "The ACP agent timed out before the turn completed.",
            "session/prompt",
        ));
    }
    super::kilo_code_serve::post_json(url, body).map_err(|_| {
        ProtocolFailure::new(
            "acp_protocol_write_failed",
            "The ACP agent stopped accepting protocol messages.",
            "serve/http",
        )
    })
}

fn extract_assistant_text(response: &Value) -> String {
    let mut chunks = Vec::new();
    if let Some(parts) = response.get("parts").and_then(Value::as_array) {
        for part in parts {
            if part.get("type").and_then(Value::as_str) == Some("text")
                && let Some(text) = part.get("text").and_then(Value::as_str)
            {
                chunks.push(text.to_string());
            }
        }
    }
    if chunks.is_empty()
        && let Some(items) = response.as_array()
    {
        for item in items {
            if let Some(parts) = item.get("parts").and_then(Value::as_array) {
                for part in parts {
                    if part.get("type").and_then(Value::as_str) == Some("text")
                        && let Some(text) = part.get("text").and_then(Value::as_str)
                    {
                        chunks.push(text.to_string());
                    }
                }
            }
        }
    }
    chunks.join("")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    #[test]
    fn kilo_primary_lane_is_serve_not_acp_or_newest_continue() {
        assert_eq!(KILO_CODE_DRIVER.launch_args, &["serve"]);
        assert_eq!(KILO_CODE_DRIVER.runtime_protocol, RUNTIME_PROTOCOL);
        assert_eq!(KILO_CODE_DRIVER.agent_id, "kilo-code-serve");
        assert_eq!(KILO_CODE_DRIVER.error_prefix, "kilo_code_serve");
        assert_ne!(
            RUNTIME_PROTOCOL,
            super::super::opencode_driver::RUNTIME_PROTOCOL
        );
        assert!(
            !KILO_CODE_DRIVER
                .launch_args
                .iter()
                .any(|argument| *argument == "acp"
                    || argument.contains("continue")
                    || *argument == "-c"
                    || argument.contains("session")
                    || argument.contains("prompt"))
        );
        assert_eq!(super::super::kilo_code_serve::DEFAULT_PORT, 4097);
    }

    #[test]
    fn empty_executable_fails_closed_without_newest_session_fallback() {
        let result = execute(
            "",
            &json!({}),
            "private-kilo-prompt",
            "existing-kilo-native",
            Some(Path::new("/tmp")),
            1_000,
            1024,
            1024,
        );
        assert!(!result.ok);
        assert_eq!(result.driver_id, "kilo-code-serve");
        assert_eq!(result.runtime_protocol, RUNTIME_PROTOCOL);
        let code = result.error.as_ref().map(|error| error.code.as_str());
        assert_eq!(code, Some("kilo_code_serve_process_start_failed"));
    }

    #[test]
    fn fake_http_exact_resume_and_stream_chunk_use_exact_session_id() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let attach = format!("http://127.0.0.1:{port}");
        let server = thread::spawn(move || {
            // GET /session/{id}
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 2048];
            let _ = stream.read(&mut buf);
            let body = br#"{"id":"existing-kilo-native","title":"t"}"#;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                std::str::from_utf8(body).unwrap()
            );
            stream.write_all(response.as_bytes()).unwrap();

            // GET /event (watch) — may arrive before or after POST; accept optionally
            listener.set_nonblocking(true).unwrap();
            // POST /session/{id}/message
            loop {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let mut req = Vec::new();
                        let mut tmp = [0u8; 4096];
                        loop {
                            match stream.read(&mut tmp) {
                                Ok(0) => break,
                                Ok(n) => {
                                    req.extend_from_slice(&tmp[..n]);
                                    if req.windows(4).any(|w| w == b"\r\n\r\n") {
                                        break;
                                    }
                                }
                                Err(_) => break,
                            }
                        }
                        let req_text = String::from_utf8_lossy(&req);
                        if req_text.contains("GET /event") {
                            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
                            let _ = stream.write_all(response.as_bytes());
                            continue;
                        }
                        if req_text.contains("POST /session/existing-kilo-native/message") {
                            assert!(req_text.contains("private-kilo-resume-prompt"));
                            let body = br#"{"parts":[{"type":"text","text":"kilo resumed"}]}"#;
                            let response = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                body.len(),
                                std::str::from_utf8(body).unwrap()
                            );
                            stream.write_all(response.as_bytes()).unwrap();
                            break;
                        }
                    }
                    Err(_) => thread::sleep(Duration::from_millis(10)),
                }
            }
        });

        let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
        let sink_target = Arc::clone(&captured);
        super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
            sink_target.lock().unwrap().push(event);
        }));
        let _guard = super::super::turn_event_emit::StreamSinkGuard;

        let endpoint = super::super::kilo_code_serve::ServeEndpoint::new("127.0.0.1", port);
        assert_eq!(endpoint.attach_url, attach);
        let config = ServeTurnConfig {
            prompt: "private-kilo-resume-prompt".into(),
            requested_session_id: "existing-kilo-native".into(),
            cwd: "/tmp".into(),
            model: None,
            runtime_agent: None,
            reasoning_effort: None,
            mode: None,
            allow_all: None,
        };
        let outcome =
            execute_via_serve(&endpoint, &config, Instant::now() + Duration::from_secs(5))
                .expect("exact resume serve turn");
        assert_eq!(outcome.session_id, "existing-kilo-native");
        assert_eq!(outcome.output, "kilo resumed");
        assert_eq!(outcome.turn_status, "end_turn");

        let events = captured.lock().unwrap().clone();
        assert!(
            events.iter().any(|event| {
                event.get("event").and_then(Value::as_str) == Some("agent.message.chunk")
                    && event.get("sessionId").and_then(Value::as_str)
                        == Some("existing-kilo-native")
                    && event
                        .get("payload")
                        .and_then(|payload| payload.get("text"))
                        .and_then(Value::as_str)
                        == Some("kilo resumed")
            }),
            "expected progressive chunk for exact native session, got {events:?}"
        );
        let _ = server.join();
    }
}
