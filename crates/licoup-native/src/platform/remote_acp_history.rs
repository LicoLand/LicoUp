use super::acp_session_transport::{
    TransportEvent, read_protocol_messages, request_id_matches, write_message,
};
use super::process_supervisor::{
    BoundedStdinWriter, SupervisedChild, TransportFinishFailure, finish_protocol_transport,
};
use super::virtual_machine::SshRuntimeConnection;
use crate::core::acp::{
    self, AcpClientCapabilities, AcpImplementation, AcpSessionInfo, AcpSessionMethod,
    AcpSessionOptions, AcpSessionUpdateKind,
};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::io::BufReader;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

const INITIALIZE_REQUEST_ID: i64 = 1;
const FIRST_SESSION_REQUEST_ID: i64 = 2;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(50);
const LOAD_DRAIN_QUIET: Duration = Duration::from_millis(100);
const MAX_STDOUT_BYTES: usize = 20 * 1024 * 1024;
const MAX_STDERR_BYTES: usize = 512 * 1024;
const MAX_LIST_PAGES: usize = 64;
const MAX_PAGE_LIMIT: usize = 500;
const MAX_REPLAY_MESSAGES: usize = 2_000;
const MAX_REPLAY_TEXT_BYTES: usize = 2 * 1024 * 1024;

pub(crate) fn conversation_list(params: &Value) -> Result<Value> {
    let target = params
        .get("agent")
        .or_else(|| params.get("agentId"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("remote_acp_agent_required"))?;
    let connection = SshRuntimeConnection::from_params(params, target)
        .map_err(|error| anyhow!(error.code()))?
        .ok_or_else(|| anyhow!("virtual_machine_connection_required"))?;
    if target == "hermes" && connection.is_hermes_tui_gateway() {
        return super::remote_hermes_gateway_history::conversation_list_with_connection(
            params,
            &connection,
        );
    }
    let session_id = params
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let offset = unsigned_param(params, "offset").unwrap_or(0);
    let limit = unsigned_param(params, "limit")
        .unwrap_or(MAX_PAGE_LIMIT)
        .clamp(1, MAX_PAGE_LIMIT);

    let mut client = RemoteAcpClient::connect(target, &connection)?;
    let capabilities = client.initialize()?;
    let mut sessions = if let Some(session_id) = session_id {
        if !capabilities.load_session {
            return Err(anyhow!("remote_acp_session_load_unsupported"));
        }
        vec![client.load_session(target, session_id, connection.working_directory(), None)?]
    } else {
        if !capabilities.list_sessions {
            return Err(anyhow!("remote_acp_session_list_unsupported"));
        }
        client.list_sessions(target, offset, limit, capabilities.load_session)?
    };
    client.finish()?;
    sessions.sort_by(|left, right| {
        right
            .get("updatedAt")
            .and_then(Value::as_str)
            .cmp(&left.get("updatedAt").and_then(Value::as_str))
            .then_with(|| {
                left.get("nativeSessionId")
                    .and_then(Value::as_str)
                    .cmp(&right.get("nativeSessionId").and_then(Value::as_str))
            })
    });
    let returned = sessions.len();
    let has_more = session_id.is_none() && returned > limit;
    if has_more {
        sessions.truncate(limit);
    }
    let returned = sessions.len();
    let total_sessions = offset
        .saturating_add(returned)
        .saturating_add(usize::from(has_more));
    Ok(json!({
        "ok": true,
        "schemaVersion": 2,
        "mode": "native-history",
        "scanMode": "browse",
        "importMode": "precise-adapter",
        "readOnly": true,
        "agentId": target,
        "adapterId": target,
        "adapterLabel": adapter_label(target),
        "sessions": sessions,
        "page": {
            "offset": offset,
            "limit": limit,
            "returned": returned,
            "totalSessions": total_sessions,
            "hasMore": has_more
        },
        "sources": {
            "transport": "ssh-stdio",
            "protocol": "acp",
            "filesSeen": 0,
            "directoryEntriesSeen": 0,
            "skipped": []
        }
    }))
}

pub(crate) fn has_runtime_connection(params: &Value) -> bool {
    params
        .get("runtimeConnection")
        .is_some_and(|value| !value.is_null())
}

struct RemoteAcpClient {
    child: SupervisedChild,
    stdin: BoundedStdinWriter,
    receiver: Receiver<TransportEvent>,
    stdout_handle: Option<thread::JoinHandle<()>>,
    stderr_handle: Option<thread::JoinHandle<()>>,
    stderr_truncated: Arc<AtomicBool>,
    observed_stdout_bytes: usize,
    next_request_id: i64,
    finished: bool,
}

impl RemoteAcpClient {
    fn connect(target: &str, connection: &SshRuntimeConnection) -> Result<Self> {
        let mut command = connection
            .launch_acp_command(target)
            .map_err(|error| anyhow!(error.code()))?;
        command
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let mut child = SupervisedChild::spawn(&mut command)
            .map_err(|_| anyhow!("remote_acp_process_start_failed"))?;
        let stdout = child
            .stdout()
            .ok_or_else(|| anyhow!("remote_acp_process_pipe_failed"))?;
        let stderr = child
            .stderr()
            .ok_or_else(|| anyhow!("remote_acp_process_pipe_failed"))?;
        let stdin = child
            .stdin()
            .ok_or_else(|| anyhow!("remote_acp_process_pipe_failed"))?;
        let stdin = BoundedStdinWriter::new(stdin);
        let (sender, receiver) = mpsc::channel();
        let stdout_handle =
            thread::spawn(move || read_protocol_messages(BufReader::new(stdout), sender));
        let stderr_truncated = Arc::new(AtomicBool::new(false));
        let stderr_flag = Arc::clone(&stderr_truncated);
        let stderr_handle = thread::spawn(move || {
            super::acp_session_transport::drain_stderr(stderr, MAX_STDERR_BYTES, &stderr_flag)
        });
        Ok(Self {
            child,
            stdin,
            receiver,
            stdout_handle: Some(stdout_handle),
            stderr_handle: Some(stderr_handle),
            stderr_truncated,
            observed_stdout_bytes: 0,
            next_request_id: FIRST_SESSION_REQUEST_ID,
            finished: false,
        })
    }

    fn initialize(&mut self) -> Result<acp::AcpAgentCapabilities> {
        let request = acp::initialize_request(
            INITIALIZE_REQUEST_ID,
            &AcpImplementation::new("lico-up", env!("CARGO_PKG_VERSION")).title("LicoUp"),
            AcpClientCapabilities::default(),
        )
        .map_err(|_| anyhow!("remote_acp_initialize_request_invalid"))?;
        self.send(&request)?;
        let response = self.receive_response(INITIALIZE_REQUEST_ID, |_| Ok(()))?;
        acp::validate_initialize_response(&response, INITIALIZE_REQUEST_ID)
            .map(|response| response.capabilities)
            .map_err(|_| anyhow!("remote_acp_initialize_failed"))
    }

    fn list_sessions(
        &mut self,
        target: &str,
        offset: usize,
        limit: usize,
        can_load: bool,
    ) -> Result<Vec<Value>> {
        let wanted = offset.saturating_add(limit).saturating_add(1);
        let mut cursor = None::<String>;
        let mut seen_cursors = HashSet::new();
        let mut listed = Vec::new();
        for _ in 0..MAX_LIST_PAGES {
            let request_id = self.next_id();
            let request = acp::session_list_request(request_id, None, cursor.as_deref())
                .map_err(|_| anyhow!("remote_acp_session_list_request_invalid"))?;
            self.send(&request)?;
            let response = self.receive_response(request_id, |_| Ok(()))?;
            let page = acp::validate_session_list_response(&response, request_id)
                .map_err(|_| anyhow!("remote_acp_session_list_failed"))?;
            listed.extend(page.sessions);
            if listed.len() >= wanted {
                break;
            }
            let Some(next_cursor) = page.next_cursor else {
                break;
            };
            if !seen_cursors.insert(next_cursor.clone()) {
                return Err(anyhow!("remote_acp_session_cursor_repeated"));
            }
            cursor = Some(next_cursor);
        }
        Ok(listed
            .into_iter()
            .skip(offset)
            .take(limit.saturating_add(1))
            .map(|info| session_projection(target, &info, Vec::new(), can_load))
            .collect())
    }

    fn load_session(
        &mut self,
        target: &str,
        session_id: &str,
        fallback_cwd: &str,
        known_info: Option<&AcpSessionInfo>,
    ) -> Result<Value> {
        let cwd = known_info
            .map(|info| info.cwd.as_str())
            .unwrap_or(fallback_cwd);
        let request_id = self.next_id();
        let request = acp::session_request(
            request_id,
            AcpSessionMethod::Load(session_id),
            AcpSessionOptions::new(std::path::Path::new(cwd)),
        )
        .map_err(|_| anyhow!("remote_acp_session_load_request_invalid"))?;
        self.send(&request)?;
        let mut replay = ReplayCollector::default();
        let response =
            self.receive_response(request_id, |message| replay.observe(message, session_id))?;
        acp::validate_session_response(&response, request_id, AcpSessionMethod::Load(session_id))
            .map_err(|_| anyhow!("remote_acp_session_load_failed"))?;
        self.drain_load_notifications(&mut replay, session_id)?;
        let info = known_info.cloned().unwrap_or_else(|| AcpSessionInfo {
            session_id: session_id.to_string(),
            cwd: cwd.to_string(),
            additional_directories: Vec::new(),
            title: replay.title.clone(),
            updated_at: replay.updated_at.clone(),
            meta: None,
        });
        Ok(session_projection(
            target,
            &info,
            replay.into_messages(),
            true,
        ))
    }

    fn send(&mut self, message: &Value) -> Result<()> {
        write_message(&mut self.stdin, message)
            .map_err(|_| anyhow!("remote_acp_protocol_write_failed"))
    }

    fn receive_response<F>(&mut self, request_id: i64, mut observe: F) -> Result<Value>
    where
        F: FnMut(&Value) -> Result<()>,
    {
        let deadline = Instant::now() + REQUEST_TIMEOUT;
        loop {
            self.stdin
                .check_health()
                .map_err(|_| anyhow!("remote_acp_protocol_write_failed"))?;
            let now = Instant::now();
            if now >= deadline {
                return Err(anyhow!("remote_acp_protocol_timeout"));
            }
            match self
                .receiver
                .recv_timeout((deadline - now).min(PROCESS_POLL_INTERVAL))
            {
                Ok(TransportEvent::Message { message, bytes }) => {
                    self.observe_stdout(bytes)?;
                    if request_id_matches(&message, request_id) {
                        return Ok(message);
                    }
                    if is_server_request(&message) {
                        self.reject_server_request(&message)?;
                    } else {
                        observe(&message)?;
                    }
                }
                Ok(TransportEvent::InvalidJson) => {
                    return Err(anyhow!("remote_acp_protocol_invalid_json"));
                }
                Ok(TransportEvent::LineLimitExceeded) => {
                    return Err(anyhow!("remote_acp_protocol_output_limit"));
                }
                Ok(TransportEvent::StdoutReadFailed) => {
                    return Err(anyhow!("remote_acp_protocol_read_failed"));
                }
                Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(anyhow!("remote_acp_process_exited"));
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
        }
    }

    fn drain_load_notifications(
        &mut self,
        replay: &mut ReplayCollector,
        session_id: &str,
    ) -> Result<()> {
        let deadline = Instant::now() + LOAD_DRAIN_QUIET;
        loop {
            let now = Instant::now();
            if now >= deadline {
                return Ok(());
            }
            match self.receiver.recv_timeout(deadline - now) {
                Ok(TransportEvent::Message { message, bytes }) => {
                    self.observe_stdout(bytes)?;
                    if is_server_request(&message) {
                        self.reject_server_request(&message)?;
                    } else {
                        replay.observe(&message, session_id)?;
                    }
                }
                Err(RecvTimeoutError::Timeout) => return Ok(()),
                Ok(TransportEvent::InvalidJson) => {
                    return Err(anyhow!("remote_acp_protocol_invalid_json"));
                }
                Ok(TransportEvent::LineLimitExceeded) => {
                    return Err(anyhow!("remote_acp_protocol_output_limit"));
                }
                Ok(TransportEvent::StdoutReadFailed) => {
                    return Err(anyhow!("remote_acp_protocol_read_failed"));
                }
                Ok(TransportEvent::StdoutClosed) | Err(RecvTimeoutError::Disconnected) => {
                    return Ok(());
                }
            }
        }
    }

    fn reject_server_request(&mut self, request: &Value) -> Result<()> {
        let Some(id) = request.get("id") else {
            return Ok(());
        };
        self.send(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {
                "code": -32601,
                "message": "Client method is not available during history access."
            }
        }))
    }

    fn observe_stdout(&mut self, bytes: usize) -> Result<()> {
        self.observed_stdout_bytes = self.observed_stdout_bytes.saturating_add(bytes);
        if self.observed_stdout_bytes > MAX_STDOUT_BYTES {
            Err(anyhow!("remote_acp_protocol_output_limit"))
        } else {
            Ok(())
        }
    }

    fn next_id(&mut self) -> i64 {
        let current = self.next_request_id;
        self.next_request_id = self.next_request_id.saturating_add(1);
        current
    }

    fn finish(&mut self) -> Result<()> {
        if self.finished {
            return Ok(());
        }
        self.finished = true;
        let stdout_handle = self
            .stdout_handle
            .take()
            .ok_or_else(|| anyhow!("remote_acp_process_cleanup_failed"))?;
        let stderr_handle = self
            .stderr_handle
            .take()
            .ok_or_else(|| anyhow!("remote_acp_process_cleanup_failed"))?;
        let cleanup = finish_protocol_transport(
            &mut self.child,
            &mut self.stdin,
            stdout_handle,
            stderr_handle,
        );
        if cleanup == Err(TransportFinishFailure::Lifecycle) {
            return Err(anyhow!("remote_acp_process_cleanup_failed"));
        }
        if self.stderr_truncated.load(Ordering::Relaxed) {
            return Err(anyhow!("remote_acp_protocol_output_limit"));
        }
        Ok(())
    }
}

impl Drop for RemoteAcpClient {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

#[derive(Default)]
struct ReplayCollector {
    messages: Vec<ReplayMessage>,
    text_bytes: usize,
    title: Option<String>,
    updated_at: Option<String>,
}

impl ReplayCollector {
    fn observe(&mut self, message: &Value, session_id: &str) -> Result<()> {
        if message.get("method").and_then(Value::as_str) != Some(acp::SESSION_UPDATE_METHOD) {
            return Ok(());
        }
        let update = acp::validate_session_update(message, Some(session_id))
            .map_err(|_| anyhow!("remote_acp_session_replay_invalid"))?;
        match update.kind {
            AcpSessionUpdateKind::UserMessageChunk => {
                if let Some(text) = update.user_message_text() {
                    self.push("user", text)?;
                }
            }
            AcpSessionUpdateKind::AgentMessageChunk => {
                if let Some(text) = update.agent_message_text() {
                    self.push("agent", text)?;
                }
            }
            AcpSessionUpdateKind::SessionInfoUpdate => {
                if let Some(title) = update.payload().get("title").and_then(Value::as_str) {
                    self.title = Some(truncated_text(title, 240));
                }
                if let Some(updated_at) = update.payload().get("updatedAt").and_then(Value::as_str)
                {
                    self.updated_at = Some(truncated_text(updated_at, 128));
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn push(&mut self, role: &'static str, text: &str) -> Result<()> {
        self.text_bytes = self.text_bytes.saturating_add(text.len());
        if self.text_bytes > MAX_REPLAY_TEXT_BYTES {
            return Err(anyhow!("remote_acp_session_replay_limit"));
        }
        if let Some(last) = self.messages.last_mut()
            && last.role == role
        {
            last.text.push_str(text);
            return Ok(());
        }
        if self.messages.len() >= MAX_REPLAY_MESSAGES {
            return Err(anyhow!("remote_acp_session_replay_limit"));
        }
        self.messages.push(ReplayMessage {
            role,
            text: text.to_string(),
        });
        Ok(())
    }

    fn into_messages(self) -> Vec<Value> {
        self.messages
            .into_iter()
            .enumerate()
            .map(|(index, message)| {
                json!({
                    "id": format!("remote-acp-message-{index}"),
                    "role": message.role,
                    "text": message.text,
                    "createdAt": "",
                    "layer": "thread"
                })
            })
            .collect()
    }
}

struct ReplayMessage {
    role: &'static str,
    text: String,
}

fn session_projection(
    target: &str,
    info: &AcpSessionInfo,
    messages: Vec<Value>,
    exact_resume: bool,
) -> Value {
    let title = info
        .title
        .as_deref()
        .map(|value| truncated_text(value, 240))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| format!("{} conversation", adapter_short_label(target)));
    let updated_at = info.updated_at.clone().unwrap_or_default();
    json!({
        "id": info.session_id,
        "agentId": target,
        "adapterId": target,
        "adapterLabel": adapter_label(target),
        "sourceTool": target,
        "sourceClient": target,
        "sourceClientLabel": adapter_label(target),
        "sourceLabel": "Virtual machine ACP",
        "sourceKind": "remote-acp",
        "sourcePath": "",
        "nativeSessionId": info.session_id,
        "importMode": "precise-adapter",
        "title": title,
        "createdAt": updated_at,
        "updatedAt": updated_at,
        "workingDirectory": info.cwd,
        "native": true,
        "readOnly": true,
        "exactResume": exact_resume,
        "messageCount": messages.len(),
        "messages": messages
    })
}

fn is_server_request(message: &Value) -> bool {
    message.get("id").is_some()
        && message.get("method").is_some()
        && message.get("result").is_none()
        && message.get("error").is_none()
}

fn unsigned_param(params: &Value, key: &str) -> Option<usize> {
    params.get(key).and_then(|value| {
        value
            .as_u64()
            .or_else(|| value.as_str()?.trim().parse().ok())
            .and_then(|value| usize::try_from(value).ok())
    })
}

fn adapter_label(target: &str) -> &'static str {
    match target {
        "openclaw" => "OpenClaw - CLI",
        "hermes" => "Hermes Agent - CLI",
        _ => "Native agent",
    }
}

fn adapter_short_label(target: &str) -> &'static str {
    match target {
        "openclaw" => "OpenClaw",
        "hermes" => "Hermes",
        _ => "Native agent",
    }
}

fn truncated_text(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_merges_adjacent_chunks_without_exposing_transport_metadata() {
        let mut replay = ReplayCollector::default();
        for text in ["hello", " world"] {
            replay
                .observe(
                    &json!({
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": "session-1",
                            "update": {
                                "sessionUpdate": "user_message_chunk",
                                "content": {"type": "text", "text": text}
                            }
                        }
                    }),
                    "session-1",
                )
                .unwrap();
        }
        let messages = replay.into_messages();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["text"], "hello world");
        assert!(messages[0].get("host").is_none());
    }
}
