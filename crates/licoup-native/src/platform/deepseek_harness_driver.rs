use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::{Arc, LazyLock, Mutex, mpsc};
use std::time::{Duration, Instant};

use super::process_supervisor::SupervisedChild;

pub(super) const DRIVER_ID: &str = "deepseek-harness-sdk-jsonrpc";
pub(super) const RUNTIME_PROTOCOL: &str = "deepseek-harness-sdk-stdio-jsonrpc";
const MAX_TRANSPORTS: usize = 8;

static TRANSPORTS: LazyLock<Mutex<HashMap<String, Arc<ManagedTransport>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Debug, Default)]
pub(super) struct EffectiveSettings {
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) permission_mode: Option<String>,
    pub(super) sandbox: Option<Value>,
    pub(super) approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
pub(super) struct ProtocolFailure {
    code: &'static str,
    message: &'static str,
    stage: &'static str,
}

impl ProtocolFailure {
    fn new(code: &'static str, message: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            message,
            stage,
        }
    }

    pub(super) fn into_payload(self) -> ProtocolFailurePayload {
        ProtocolFailurePayload {
            code: self.code,
            message: self.message,
            stage: self.stage,
            user_interaction_required: false,
            request_method: None,
            session_id: None,
            thread_id: None,
            turn_id: None,
            turn_status: None,
        }
    }
}

pub(super) struct ProtocolFailurePayload {
    pub(super) code: &'static str,
    pub(super) message: &'static str,
    pub(super) stage: &'static str,
    pub(super) user_interaction_required: bool,
    pub(super) request_method: Option<String>,
    pub(super) session_id: Option<String>,
    pub(super) thread_id: Option<String>,
    pub(super) turn_id: Option<String>,
    pub(super) turn_status: Option<String>,
}

#[derive(Debug)]
pub(super) struct RunResult {
    pub(super) ok: bool,
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) error: Option<ProtocolFailure>,
    pub(super) session_id: String,
    pub(super) thread_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: EffectiveSettings,
    pub(super) status_code: Option<i32>,
    pub(super) stdout_truncated: bool,
    pub(super) stderr_truncated: bool,
    pub(super) started_at: String,
}

impl RunResult {
    fn failed(failure: ProtocolFailure, started_at: String) -> Self {
        Self {
            ok: false,
            output: String::new(),
            events: Vec::new(),
            error: Some(failure),
            session_id: String::new(),
            thread_id: String::new(),
            turn_id: String::new(),
            turn_status: "failed".to_string(),
            effective: EffectiveSettings::default(),
            status_code: None,
            stdout_truncated: false,
            stderr_truncated: false,
            started_at,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct TransportConfig {
    executable: String,
    cwd: PathBuf,
    provider: String,
    model: String,
    max_tokens: Option<u64>,
    cordis_config: Option<PathBuf>,
    output_limit: usize,
    stderr_limit: usize,
}

struct ManagedTransport {
    config: TransportConfig,
    state: Mutex<Option<TransportState>>,
}

struct TransportState {
    child: SupervisedChild,
    stdin: ChildStdin,
    receiver: mpsc::Receiver<std::result::Result<ProtocolFrame, FrameFailure>>,
    next_request_id: u64,
}

struct ProtocolFrame {
    value: Value,
    bytes: usize,
}

#[derive(Clone, Copy)]
enum FrameFailure {
    InvalidJson,
    OutputLimit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum CleanupDisposition {
    Accepted,
    SessionUnavailable,
    Unavailable,
}

pub(super) fn execute(
    executable: &str,
    params: &Value,
    prompt: &str,
    session_id: &str,
    cwd: Option<&Path>,
    timeout_ms: u64,
    max_stdout: Option<usize>,
    max_stderr: usize,
) -> RunResult {
    let started_at = timestamp();
    let Some(cwd) = cwd.filter(|path| path.is_absolute()) else {
        return RunResult::failed(
            failure(
                "deepseek_harness_absolute_cwd_required",
                "DeepSeek Harness requires an absolute workspace directory.",
                "params/cwd",
            ),
            started_at,
        );
    };
    let Some(model) = params
        .get("model")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return RunResult::failed(
            failure(
                "deepseek_harness_model_required",
                "DeepSeek Harness requires an explicit official model id.",
                "params/model",
            ),
            started_at,
        );
    };
    let provider = params
        .get("provider")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("deepseek-official");
    let cordis_config = params
        .get("cordisConfigPath")
        .and_then(Value::as_str)
        .map(PathBuf::from);
    if cordis_config
        .as_ref()
        .is_some_and(|path| !path.is_absolute())
    {
        return RunResult::failed(
            failure(
                "deepseek_harness_absolute_config_required",
                "DeepSeek Harness requires an absolute Cordis configuration path.",
                "params/cordisConfigPath",
            ),
            started_at,
        );
    }
    let session_id = if session_id.trim().is_empty() {
        uuid::Uuid::new_v4().to_string()
    } else {
        session_id.trim().to_string()
    };
    let config = TransportConfig {
        executable: executable.to_string(),
        cwd: cwd.to_path_buf(),
        provider: provider.to_string(),
        model: model.to_string(),
        max_tokens: params
            .get("maxTokens")
            .and_then(Value::as_u64)
            .filter(|value| *value > 0),
        cordis_config,
        output_limit: max_stdout.unwrap_or(64 * 1024 * 1024),
        stderr_limit: max_stderr,
    };
    let deadline = (timeout_ms != 0).then(|| Instant::now() + Duration::from_millis(timeout_ms));
    let transport = match transport_for_session(&session_id, &config, deadline) {
        Ok(transport) => transport,
        Err(error) => return RunResult::failed(error, started_at),
    };
    let outcome = {
        let mut state = match transport.state.lock() {
            Ok(state) => state,
            Err(_) => {
                evict_transport(&session_id, &transport);
                return RunResult::failed(transport_unavailable(), started_at);
            }
        };
        match state.as_mut() {
            Some(state) => execute_turn(state, prompt, &session_id, config.output_limit, deadline),
            None => Err(transport_unavailable()),
        }
    };
    let (turn_id, raw_events) = match outcome {
        Ok(outcome) => outcome,
        Err(error) => {
            evict_transport(&session_id, &transport);
            shutdown_transport(&transport);
            return RunResult::failed(error, started_at);
        }
    };
    RunResult {
        ok: true,
        output: final_assistant_response(&raw_events),
        events: project_protocol_frames(&raw_events),
        error: None,
        session_id: session_id.clone(),
        thread_id: session_id,
        turn_id,
        turn_status: "completed".to_string(),
        effective: EffectiveSettings {
            cwd: Some(config.cwd.to_string_lossy().into_owned()),
            model: Some(config.model),
            ..EffectiveSettings::default()
        },
        status_code: None,
        stdout_truncated: false,
        stderr_truncated: false,
        started_at,
    }
}

pub(in crate::platform) fn cleanup_session(session_id: &str) -> CleanupDisposition {
    let transport = {
        let mut transports = match TRANSPORTS.lock() {
            Ok(transports) => transports,
            Err(_) => return CleanupDisposition::Unavailable,
        };
        transports.remove(session_id.trim())
    };
    let Some(transport) = transport else {
        return CleanupDisposition::SessionUnavailable;
    };
    if shutdown_transport(&transport) {
        CleanupDisposition::Accepted
    } else {
        CleanupDisposition::Unavailable
    }
}

fn transport_for_session(
    session_id: &str,
    config: &TransportConfig,
    deadline: Option<Instant>,
) -> std::result::Result<Arc<ManagedTransport>, ProtocolFailure> {
    let mut transports = TRANSPORTS.lock().map_err(|_| transport_unavailable())?;
    if let Some(transport) = transports.get(session_id) {
        if transport.config != *config {
            return Err(failure(
                "deepseek_harness_session_config_changed",
                "DeepSeek Harness cannot resume a session after its executable or initialization settings changed.",
                "session/config",
            ));
        }
        return Ok(Arc::clone(transport));
    }
    if transports.len() >= MAX_TRANSPORTS {
        return Err(failure(
            "deepseek_harness_transport_capacity_exceeded",
            "The bounded DeepSeek Harness transport pool is full.",
            "process/capacity",
        ));
    }
    let transport = Arc::new(spawn_transport(config, deadline)?);
    transports.insert(session_id.to_string(), Arc::clone(&transport));
    Ok(transport)
}

fn spawn_transport(
    config: &TransportConfig,
    deadline: Option<Instant>,
) -> std::result::Result<ManagedTransport, ProtocolFailure> {
    let mut command = Command::new(&config.executable);
    command
        .current_dir(&config.cwd)
        .env("DSH_CWD", &config.cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(path) = config.cordis_config.as_ref() {
        command.env("DSH_CORDIS_CONFIG", path);
    }
    let mut child = SupervisedChild::spawn(&mut command).map_err(|_| {
        failure(
            "deepseek_harness_jsonrpc_carrier_unavailable",
            "The official DeepSeek Harness JSON-RPC carrier is unavailable.",
            "process/start",
        )
    })?;
    let Some(mut stdin) = child.stdin() else {
        let _ = child.terminate_tree();
        return Err(transport_unavailable());
    };
    let Some(stdout) = child.stdout() else {
        let _ = child.terminate_tree();
        return Err(transport_unavailable());
    };
    if let Some(mut stderr) = child.stderr() {
        std::thread::spawn(move || {
            // Drain to EOF without retaining third-party output. Stopping at
            // the retention cap can fill the pipe and deadlock the carrier.
            let _ = std::io::copy(&mut stderr, &mut std::io::sink());
        });
    }
    let (sender, receiver) = mpsc::channel();
    let output_limit = config.output_limit;
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let frame = match read_protocol_frame(&mut reader, output_limit) {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(failure) => {
                    let _ = sender.send(Err(failure));
                    return;
                }
            };
            if sender.send(Ok(frame)).is_err() {
                return;
            }
        }
    });
    let mut initialize_params = json!({"cwd": config.cwd.to_string_lossy(), "provider": config.provider, "model": config.model});
    if let Some(max_tokens) = config.max_tokens {
        initialize_params["maxTokens"] = json!(max_tokens);
    }
    let initialize =
        json!({"jsonrpc":"2.0","id":"initialize","method":"initialize","params":initialize_params});
    if write_frame(&mut stdin, &initialize).is_err() {
        let _ = child.terminate_tree();
        return Err(failure(
            "deepseek_harness_transport_write_failed",
            "DeepSeek Harness stopped accepting protocol requests.",
            "protocol/write",
        ));
    }
    let initialized = loop {
        let Some(Ok(frame)) = next_frame(&receiver, deadline) else {
            break false;
        };
        let frame = frame.value;
        if frame.get("id") == Some(&json!("initialize")) {
            break frame
                .pointer("/result/serverInfo/name")
                .and_then(Value::as_str)
                == Some("deepseek-harness-sdk-runtime");
        }
    };
    if !initialized {
        let _ = child.terminate_tree();
        return Err(failure(
            "deepseek_harness_initialize_failed",
            "DeepSeek Harness rejected the fixed SDK handshake.",
            "protocol/initialize",
        ));
    }
    Ok(ManagedTransport {
        config: config.clone(),
        state: Mutex::new(Some(TransportState {
            child,
            stdin,
            receiver,
            next_request_id: 1,
        })),
    })
}

fn execute_turn(
    state: &mut TransportState,
    prompt: &str,
    session_id: &str,
    output_limit: usize,
    deadline: Option<Instant>,
) -> std::result::Result<(String, Vec<Value>), ProtocolFailure> {
    let request_id = format!("prompt-{}", state.next_request_id);
    state.next_request_id = state.next_request_id.saturating_add(1);
    let request = json!({"jsonrpc":"2.0","id":request_id,"method":"session/prompt","params":{"sessionId":session_id,"contentBlocks":[{"type":"text","text":prompt}]}});
    write_frame(&mut state.stdin, &request).map_err(|_| {
        failure(
            "deepseek_harness_prompt_failed",
            "DeepSeek Harness did not admit the prompt.",
            "protocol/prompt",
        )
    })?;
    let mut message_id = None;
    let mut buffered = Vec::new();
    let mut attributed = Vec::new();
    let mut receipt_seen = false;
    let mut output_bytes = 0usize;
    loop {
        let frame = next_frame(&state.receiver, deadline).ok_or_else(turn_incomplete)??;
        output_bytes = output_bytes.saturating_add(frame.bytes);
        if output_bytes > output_limit {
            return Err(output_limit_exceeded());
        }
        let frame = frame.value;
        if frame.get("id") == Some(&json!(request_id)) {
            message_id = frame
                .pointer("/result/messageId")
                .and_then(Value::as_str)
                .map(str::to_string);
            let Some(id) = message_id.as_deref() else {
                return Err(turn_incomplete());
            };
            if let Some(index) = buffered
                .iter()
                .position(|frame| is_inbox_receipt(frame, id))
            {
                receipt_seen = true;
                attributed.extend(buffered.drain(index..));
                if attributed.iter().skip(1).any(is_idle_status) {
                    break;
                }
            }
            continue;
        }
        if frame.pointer("/params/sessionId").and_then(Value::as_str) != Some(session_id) {
            continue;
        }
        if !matches!(
            frame.get("method").and_then(Value::as_str),
            Some("session.event" | "session.status")
        ) {
            continue;
        }
        if receipt_seen {
            let terminal = is_idle_status(&frame);
            attributed.push(frame);
            if terminal {
                break;
            }
        } else if let Some(id) = message_id.as_deref() {
            if is_inbox_receipt(&frame, id) {
                receipt_seen = true;
                attributed.push(frame);
            }
        } else {
            buffered.push(frame);
        }
    }
    let Some(message_id) = message_id else {
        return Err(turn_incomplete());
    };
    if !receipt_seen {
        return Err(turn_incomplete());
    }
    Ok((message_id, attributed))
}

/// Read one newline-delimited frame without allowing `read_line` to allocate
/// past the protocol cap. An oversized frame terminates its transport.
fn read_protocol_frame(
    reader: &mut impl BufRead,
    limit: usize,
) -> std::result::Result<Option<ProtocolFrame>, FrameFailure> {
    let mut bytes = Vec::with_capacity(limit.min(8192));
    loop {
        let available = reader.fill_buf().map_err(|_| FrameFailure::InvalidJson)?;
        if available.is_empty() {
            if bytes.is_empty() {
                return Ok(None);
            }
            break;
        }
        let take = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        if bytes.len().saturating_add(take) > limit {
            return Err(FrameFailure::OutputLimit);
        }
        bytes.extend_from_slice(&available[..take]);
        reader.consume(take);
        if bytes.last() == Some(&b'\n') {
            break;
        }
    }
    while bytes
        .last()
        .is_some_and(|byte| matches!(*byte, b'\n' | b'\r'))
    {
        bytes.pop();
    }
    let value = serde_json::from_slice(&bytes).map_err(|_| FrameFailure::InvalidJson)?;
    Ok(Some(ProtocolFrame {
        value,
        bytes: bytes.len().saturating_add(1),
    }))
}

fn write_frame(stdin: &mut impl Write, value: &Value) -> std::io::Result<()> {
    serde_json::to_writer(&mut *stdin, value)?;
    stdin.write_all(b"\n")?;
    stdin.flush()
}

fn next_frame(
    receiver: &mpsc::Receiver<std::result::Result<ProtocolFrame, FrameFailure>>,
    deadline: Option<Instant>,
) -> Option<std::result::Result<ProtocolFrame, ProtocolFailure>> {
    let result = match deadline {
        Some(deadline) => receiver
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .ok(),
        None => receiver.recv().ok(),
    }?;
    Some(result.map_err(|kind| match kind {
        FrameFailure::InvalidJson => failure(
            "deepseek_harness_invalid_json",
            "DeepSeek Harness emitted an invalid protocol frame.",
            "protocol/output",
        ),
        FrameFailure::OutputLimit => output_limit_exceeded(),
    }))
}

fn is_inbox_receipt(frame: &Value, message_id: &str) -> bool {
    frame.get("method").and_then(Value::as_str) == Some("session.event")
        && frame.pointer("/params/event/type").and_then(Value::as_str)
            == Some("agent/inbox/spliced")
        && frame
            .pointer("/params/event/data/inserted")
            .and_then(Value::as_array)
            .is_some_and(|messages| {
                messages
                    .iter()
                    .any(|message| message.get("id").and_then(Value::as_str) == Some(message_id))
            })
}

fn is_idle_status(frame: &Value) -> bool {
    frame.get("method").and_then(Value::as_str) == Some("session.status")
        && frame.pointer("/params/status").and_then(Value::as_str) == Some("idle")
}

fn final_assistant_response(frames: &[Value]) -> String {
    let Some(event) = frames.iter().rev().find_map(|frame| {
        let event = frame.pointer("/params/event")?;
        (event.get("type").and_then(Value::as_str) == Some("assistant/message")).then_some(event)
    }) else {
        return String::new();
    };
    event
        .pointer("/data/message/content")
        .or_else(|| event.pointer("/data/content"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|block| block.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect()
}

fn project_protocol_frames(frames: &[Value]) -> Vec<Value> {
    frames
        .iter()
        .filter_map(|frame| {
            let session_id = frame.pointer("/params/sessionId").and_then(Value::as_str)?;
            match frame.get("method").and_then(Value::as_str)? {
                "session.status" => {
                    let status = frame.pointer("/params/status").and_then(Value::as_str)?;
                    matches!(status, "idle" | "busy" | "running").then(|| {
                        json!({"method":"session.status","params":{"sessionId":session_id,"status":status}})
                    })
                }
                "session.event" => {
                    let event = frame.pointer("/params/event")?;
                    let kind = event.get("type").and_then(Value::as_str)?;
                    let projected = if kind == "assistant/message" {
                        json!({
                            "type": kind,
                            "data": {"content": [{"type":"text","text": final_assistant_response(std::slice::from_ref(frame))}]}
                        })
                    } else {
                        json!({"type": kind})
                    };
                    Some(json!({"method":"session.event","params":{"sessionId":session_id,"event":projected}}))
                }
                _ => None,
            }
        })
        .collect()
}

fn evict_transport(session_id: &str, expected: &Arc<ManagedTransport>) {
    if let Ok(mut transports) = TRANSPORTS.lock()
        && transports
            .get(session_id)
            .is_some_and(|current| Arc::ptr_eq(current, expected))
    {
        transports.remove(session_id);
    }
}

fn shutdown_transport(transport: &ManagedTransport) -> bool {
    let Ok(mut state) = transport.state.lock() else {
        return false;
    };
    let Some(mut state) = state.take() else {
        return true;
    };
    let wrote = write_frame(
        &mut state.stdin,
        &json!({"jsonrpc":"2.0","id":"shutdown","method":"shutdown"}),
    )
    .is_ok();
    drop(state.stdin);
    let terminated = state
        .child
        .finish_or_terminate_tree(Duration::from_millis(250))
        .is_ok();
    let _ = wrote;
    terminated
}

fn failure(code: &'static str, message: &'static str, stage: &'static str) -> ProtocolFailure {
    ProtocolFailure::new(code, message, stage)
}
fn transport_unavailable() -> ProtocolFailure {
    failure(
        "deepseek_harness_transport_unavailable",
        "The supervised DeepSeek Harness transport is unavailable.",
        "protocol/transport",
    )
}
fn turn_incomplete() -> ProtocolFailure {
    failure(
        "deepseek_harness_turn_incomplete",
        "DeepSeek Harness closed before the admitted activity reached idle.",
        "protocol/terminal",
    )
}
fn output_limit_exceeded() -> ProtocolFailure {
    failure(
        "deepseek_harness_output_limit_exceeded",
        "DeepSeek Harness exceeded the bounded protocol output limit.",
        "protocol/output",
    )
}
fn timestamp() -> String {
    time::OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn message_receipt_search_is_exact_and_recursive() {
        let frame = json!({"method":"session.event","params":{"event":{"type":"agent/inbox/spliced","data":{"inserted":[{"id":"message-1"}]}}}});
        assert!(is_inbox_receipt(&frame, "message-1"));
        assert!(!is_inbox_receipt(&frame, "message"));
    }

    #[test]
    fn assistant_projection_ignores_user_and_tool_events() {
        let frames = vec![
            json!({"params":{"event":{"type":"tool/result","data":{"text":"private"}}}}),
            json!({"params":{"event":{"type":"assistant/message","data":{"message":{"content":[{"type":"text","text":"ok"}]}}}}}),
        ];
        assert_eq!(final_assistant_response(&frames), "ok");
    }

    #[test]
    fn protocol_reader_rejects_an_oversized_line_without_buffering_past_cap() {
        let input = format!("{{\"value\":\"{}\"}}\n", "x".repeat(128));
        let mut reader = BufReader::new(input.as_bytes());
        assert!(matches!(
            read_protocol_frame(&mut reader, 32),
            Err(FrameFailure::OutputLimit)
        ));
    }

    #[test]
    #[cfg(unix)]
    fn two_turns_reuse_one_initialized_process_and_cleanup_exact_session() {
        let root = std::env::temp_dir().join(format!("lico-dsh-test-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let executable = root.join("fake-dsh");
        let log = root.join("protocol.log");
        let source = format!(
            r#"#!/bin/sh
while IFS= read -r line; do
 case "$line" in
  *'"method":"initialize"'*) printf 'initialize %s\n' "$$" >> '{}'; printf '%s\n' '{{"jsonrpc":"2.0","id":"initialize","result":{{"serverInfo":{{"name":"deepseek-harness-sdk-runtime"}}}}}}' ;;
  *'"method":"session/prompt"'*) count=$(grep -c '^prompt ' '{}' 2>/dev/null || true); count=$((count + 1)); id="message-$count"; request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'); session_id=$(printf '%s' "$line" | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p'); printf 'prompt %s %s\n' "$$" "$count" >> '{}'; printf '{{"jsonrpc":"2.0","id":"%s","result":{{"messageId":"%s"}}}}\n' "$request_id" "$id"; printf '{{"jsonrpc":"2.0","method":"session.event","params":{{"sessionId":"%s","event":{{"type":"agent/inbox/spliced","data":{{"inserted":[{{"id":"%s"}}]}}}}}}}}\n' "$session_id" "$id"; printf '{{"jsonrpc":"2.0","method":"session.event","params":{{"sessionId":"%s","event":{{"type":"assistant/message","data":{{"message":{{"content":[{{"type":"text","text":"process-%s-turn-%s"}}]}}}}}}}}}}\n' "$session_id" "$$" "$count"; printf '{{"jsonrpc":"2.0","method":"session.status","params":{{"sessionId":"%s","status":"idle"}}}}\n' "$session_id" ;;
  *'"method":"shutdown"'*) printf 'shutdown %s\n' "$$" >> '{}'; exit 0 ;;
 esac
done
"#,
            log.display(),
            log.display(),
            log.display(),
            log.display()
        );
        fs::write(&executable, source).unwrap();
        let mut permissions = fs::metadata(&executable).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&executable, permissions).unwrap();
        let params = json!({"model":"deepseek-test"});
        let first = execute(
            executable.to_str().unwrap(),
            &params,
            "one",
            "persistent-session",
            Some(&root),
            2_000,
            None,
            4096,
        );
        let second = execute(
            executable.to_str().unwrap(),
            &params,
            "two",
            "persistent-session",
            Some(&root),
            2_000,
            None,
            4096,
        );
        assert!(first.ok, "first turn failed: {:?}", first.error);
        assert!(second.ok, "second turn failed: {:?}", second.error);
        assert_eq!(
            first.output.split("-turn-").next(),
            second.output.split("-turn-").next()
        );
        assert_eq!(first.output.rsplit('-').next(), Some("1"));
        assert_eq!(second.output.rsplit('-').next(), Some("2"));
        let drifted = execute(
            executable.to_str().unwrap(),
            &json!({"model":"different-model"}),
            "must not run",
            "persistent-session",
            Some(&root),
            2_000,
            None,
            4096,
        );
        assert_eq!(
            drifted.error.unwrap().code,
            "deepseek_harness_session_config_changed"
        );
        assert_eq!(
            cleanup_session("persistent-session"),
            CleanupDisposition::Accepted
        );
        assert_eq!(
            cleanup_session("persistent-session"),
            CleanupDisposition::SessionUnavailable
        );
        let log = fs::read_to_string(&log).unwrap();
        assert_eq!(
            log.lines()
                .filter(|line| line.starts_with("initialize "))
                .count(),
            1
        );
        assert_eq!(
            log.lines()
                .filter(|line| line.starts_with("prompt "))
                .count(),
            2
        );
        assert_eq!(
            log.lines()
                .filter(|line| line.starts_with("shutdown "))
                .count(),
            1
        );
        fs::remove_dir_all(root).unwrap();
    }
}
