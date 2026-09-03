//! Desktop-owned authenticated loopback Streamable HTTP Subagent MCP service.

use crate::core::mcp::{
    McpMessage, McpRequestId, McpServerEngine, McpSessionState, decode_http_body, encode_http_body,
};
use crate::domain::subagent_mcp::{
    CallerContext, MAX_MCP_FRAME_BYTES, SubagentMcpApplication, production_application,
    server_definition,
};
use anyhow::{Result, anyhow};
use licoup_agent_runtime::ProviderId;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

const DISCOVERY_SCHEMA: &str = "licoup.subagent-mcp.discovery.v1";
const MAX_HTTP_HEADER_BYTES: usize = 16 * 1024;
const MAX_HTTP_CONNECTIONS: usize = 32;
const MAX_SESSIONS: usize = 64;
const MAX_TOOL_WORKERS: usize = 8;
const HEALTH_INTERVAL: Duration = Duration::from_secs(2);
const RESTART_BACKOFF_MIN: Duration = Duration::from_millis(250);
const RESTART_BACKOFF_MAX: Duration = Duration::from_secs(8);
const PROBE_FAILURE_THRESHOLD: u8 = 2;

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DiscoveryDocument {
    schema_version: String,
    endpoint: String,
    generation: String,
    tokens: HashMap<String, String>,
}

#[derive(Clone)]
pub struct ConnectorDiscovery {
    endpoint: String,
    bearer_token: String,
}

pub struct SubagentMcpSupervisor {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    discovery_path: PathBuf,
    generation: String,
    address: SocketAddr,
    probe_identity: ConnectorDiscovery,
}

impl SubagentMcpSupervisor {
    pub fn start() -> Result<Self> {
        let application =
            production_application().map_err(|_| anyhow!("subagent_mcp_unavailable"))?;
        Self::start_with_application(application)
    }

    fn start_with_application(application: SubagentMcpApplication) -> Result<Self> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let address = listener.local_addr()?;
        if !address.ip().is_loopback() {
            return Err(anyhow!("subagent_mcp_loopback_required"));
        }
        // Complete every fallible in-process construction before publishing
        // discovery. After publication, the only fallible step is thread
        // creation, whose error path performs generation-bound cleanup.
        let engine = McpServerEngine::new(server_definition(), application)?;
        let generation = uuid::Uuid::new_v4().simple().to_string();
        let tokens = ["codex", "cursor", "antigravity"]
            .into_iter()
            .map(|provider| {
                (
                    provider.to_owned(),
                    format!(
                        "{}{}",
                        uuid::Uuid::new_v4().simple(),
                        uuid::Uuid::new_v4().simple()
                    ),
                )
            })
            .collect::<HashMap<_, _>>();
        let discovery_path = discovery_path()?;
        write_discovery(
            &discovery_path,
            &DiscoveryDocument {
                schema_version: DISCOVERY_SCHEMA.to_owned(),
                endpoint: format!("http://{address}/mcp"),
                generation: generation.clone(),
                tokens: tokens.clone(),
            },
        )?;
        let probe_identity = ConnectorDiscovery {
            endpoint: format!("http://{address}/mcp"),
            bearer_token: tokens
                .keys()
                .min()
                .and_then(|provider| tokens.get(provider))
                .cloned()
                .ok_or_else(|| anyhow!("subagent_mcp_unavailable"))?,
        };
        let stop = Arc::new(AtomicBool::new(false));
        let service = Arc::new(ServiceState {
            engine,
            tokens,
            sessions: Mutex::new(HashMap::new()),
            active_connections: AtomicUsize::new(0),
            active_tool_calls: AtomicUsize::new(0),
            address,
        });
        let thread_stop = Arc::clone(&stop);
        let thread = match thread::Builder::new()
            .name("subagent-mcp-http".to_owned())
            .spawn(move || serve(listener, service, thread_stop))
        {
            Ok(thread) => thread,
            Err(error) => {
                cleanup_discovery_generation(&discovery_path, &generation);
                return Err(error.into());
            }
        };
        Ok(Self {
            stop,
            thread: Some(thread),
            discovery_path,
            generation,
            address,
            probe_identity,
        })
    }

    pub fn healthy(&self) -> bool {
        self.thread
            .as_ref()
            .is_some_and(|thread| !thread.is_finished())
            && self.address.ip().is_loopback()
    }

    /// Health is the real contract, not thread liveness: one authenticated
    /// initialize plus the exact ordered nine-tool catalog. The probe identity
    /// never leaves the process and the probe session is closed afterwards.
    fn health_probe(&self) -> bool {
        let initialize = McpMessage::request(
            McpRequestId::from(1_i64),
            "initialize",
            Some(
                serde_json::json!({
                    "protocolVersion": crate::domain::subagent_mcp::PROTOCOL_REVISION,
                    "capabilities": {},
                    "clientInfo": {"name": "licoup-supervisor-health", "version": "1"}
                })
                .as_object()
                .cloned()
                .unwrap_or_default(),
            ),
        );
        let Ok(initialize) = initialize else {
            return false;
        };
        let Ok(body) = encode_http_body(&initialize, MAX_MCP_FRAME_BYTES) else {
            return false;
        };
        let Ok((status, session, response)) = health_exchange(&self.probe_identity, None, &body)
        else {
            return false;
        };
        let session = session.filter(|session| !session.is_empty());
        if status != 200 {
            if let Some(session) = session.as_deref() {
                let _ = connector_close_session(&self.probe_identity, session);
            }
            return false;
        }
        let Some(session) = session else {
            return false;
        };
        let healthy = (|| {
            let negotiated = decode_http_body(&response, MAX_MCP_FRAME_BYTES)
                .ok()
                .map(|message| message.to_value());
            let valid_initialize = negotiated.as_ref().is_some_and(|value| {
                value
                    .pointer("/result/protocolVersion")
                    .and_then(Value::as_str)
                    == Some(crate::domain::subagent_mcp::PROTOCOL_REVISION)
                    && value
                        .pointer("/result/serverInfo/name")
                        .and_then(Value::as_str)
                        == Some(crate::domain::subagent_mcp::SERVER_NAME)
                    && value
                        .pointer("/result/serverInfo/version")
                        .and_then(Value::as_str)
                        == Some(crate::domain::subagent_mcp::SERVER_VERSION)
            });
            if !valid_initialize {
                return false;
            }
            let Ok(list) = McpMessage::request(2_i64, "tools/list", Some(Map::new())) else {
                return false;
            };
            let Ok(body) = encode_http_body(&list, MAX_MCP_FRAME_BYTES) else {
                return false;
            };
            let listed = health_exchange(&self.probe_identity, Some(&session), &body)
                .ok()
                .and_then(|(status, returned, response)| {
                    (status == 200 && returned.as_deref() == Some(session.as_str()))
                        .then(|| decode_http_body(&response, MAX_MCP_FRAME_BYTES).ok())
                        .flatten()
                })
                .map(|message| message.to_value());
            listed.is_some_and(|value| {
                value
                    .pointer("/result/tools")
                    .and_then(Value::as_array)
                    .map(|tools| {
                        tools
                            .iter()
                            .filter_map(|tool| tool.get("name").and_then(Value::as_str))
                            .collect::<Vec<_>>()
                    })
                    .as_deref()
                    == Some(crate::domain::subagent_mcp::TOOL_NAMES)
            })
        })();
        let closed = connector_close_session(&self.probe_identity, &session).is_ok();
        healthy && closed
    }
}

impl Drop for SubagentMcpSupervisor {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect_timeout(&self.address, Duration::from_millis(100));
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        cleanup_discovery_generation(&self.discovery_path, &self.generation);
    }
}

#[cfg(test)]
impl SubagentMcpSupervisor {
    /// Simulate an unexpected serve-thread exit without running Drop: the
    /// discovery file and sessions stay exactly as a crash would leave them.
    fn force_exit_for_test(&self) {
        self.stop.store(true, Ordering::Release);
        let _ = TcpStream::connect_timeout(&self.address, Duration::from_millis(100));
    }
}

/// Desktop-owned supervision for the Subagent MCP service. The first service
/// is constructed before `start` returns, so a provider cannot race its MCP
/// `initialize` against an empty discovery slot. Starting supervision still
/// never fails: an initial construction failure degrades MCP readiness while
/// the monitor retries with bounded backoff. An unexpected exit or a failed
/// initialize + exact-tools/list health probe triggers a bounded restart.
/// Dropping the supervision stops the monitor and removes live discovery state.
pub struct SubagentMcpService {
    stop: Arc<AtomicBool>,
    monitor: Option<JoinHandle<()>>,
    current: Arc<Mutex<Option<Arc<SubagentMcpSupervisor>>>>,
}

impl SubagentMcpService {
    pub fn start() -> Self {
        Self::start_with_factory(SubagentMcpSupervisor::start)
    }

    fn start_with_factory(
        factory: impl Fn() -> Result<SubagentMcpSupervisor> + Send + 'static,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        // Publish the first healthy instance synchronously. Previously the
        // monitor slept for RESTART_BACKOFF_MIN before its first construction;
        // an Agent starting in that window observed discovery EOF even though
        // the service became reachable moments later.
        let initial = factory().ok().map(Arc::new);
        let current: Arc<Mutex<Option<Arc<SubagentMcpSupervisor>>>> = Arc::new(Mutex::new(initial));
        let monitor_stop = Arc::clone(&stop);
        let monitor_current = Arc::clone(&current);
        let monitor = thread::Builder::new()
            .name("subagent-mcp-supervision".to_owned())
            .spawn(move || supervise(factory, monitor_current, monitor_stop))
            .ok();
        Self {
            stop,
            monitor,
            current,
        }
    }

    pub fn healthy(&self) -> bool {
        self.current
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .as_ref()
            .is_some_and(|supervisor| supervisor.healthy())
    }

    #[cfg(test)]
    fn force_exit_for_test(&self) {
        if let Some(supervisor) = self
            .current
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .as_ref()
        {
            supervisor.force_exit_for_test();
        }
    }
}

impl Drop for SubagentMcpService {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(monitor) = self.monitor.take() {
            let _ = monitor.join();
        }
        if let Some(supervisor) = self
            .current
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .take()
        {
            drop(supervisor);
        }
    }
}

fn supervise(
    factory: impl Fn() -> Result<SubagentMcpSupervisor>,
    current: Arc<Mutex<Option<Arc<SubagentMcpSupervisor>>>>,
    stop: Arc<AtomicBool>,
) {
    let mut backoff = RESTART_BACKOFF_MIN;
    let mut probe_failures = 0_u8;
    while !stop.load(Ordering::Acquire) {
        // Never hold the slot lock across the network probe.
        let instance = current
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone();
        let live = instance.map(|supervisor| {
            supervisor.healthy() && {
                probe_failures = if supervisor.health_probe() {
                    0
                } else {
                    probe_failures.saturating_add(1)
                };
                probe_failures < PROBE_FAILURE_THRESHOLD
            }
        });
        match live {
            Some(true) => {
                backoff = RESTART_BACKOFF_MIN;
                if interruptible_sleep(&stop, HEALTH_INTERVAL) {
                    break;
                }
            }
            Some(false) | None => {
                probe_failures = 0;
                // Drop the stale instance first: its generation-bound cleanup
                // cannot remove a successor's discovery file.
                let stale = current
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner())
                    .take();
                drop(stale);
                if interruptible_sleep(&stop, backoff) {
                    break;
                }
                backoff = (backoff * 2).min(RESTART_BACKOFF_MAX);
                if let Ok(supervisor) = factory() {
                    *current.lock().unwrap_or_else(|poison| poison.into_inner()) =
                        Some(Arc::new(supervisor));
                }
            }
        }
    }
}

fn interruptible_sleep(stop: &Arc<AtomicBool>, duration: Duration) -> bool {
    let deadline = std::time::Instant::now() + duration;
    loop {
        if stop.load(Ordering::Acquire) {
            return true;
        }
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return false;
        }
        thread::sleep(remaining.min(Duration::from_millis(50)));
    }
}

struct ServiceState {
    engine: McpServerEngine<SubagentMcpApplication>,
    tokens: HashMap<String, String>,
    sessions: Mutex<HashMap<String, ServerSession>>,
    active_connections: AtomicUsize,
    active_tool_calls: AtomicUsize,
    address: SocketAddr,
}

struct ServerSession {
    provider: String,
    state: Arc<McpSessionState>,
}

fn serve(listener: TcpListener, service: Arc<ServiceState>, stop: Arc<AtomicBool>) {
    while !stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, peer)) => {
                if !peer.ip().is_loopback()
                    || service
                        .active_connections
                        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                            (count < MAX_HTTP_CONNECTIONS).then_some(count + 1)
                        })
                        .is_err()
                {
                    continue;
                }
                let request_service = Arc::clone(&service);
                if thread::Builder::new()
                    .name("subagent-mcp-request".to_owned())
                    .spawn(move || {
                        let _permit = ConnectionPermit(&request_service.active_connections);
                        let _ = handle_connection(stream, &request_service);
                    })
                    .is_err()
                {
                    service.active_connections.fetch_sub(1, Ordering::AcqRel);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => thread::sleep(Duration::from_millis(10)),
        }
    }
}

struct ConnectionPermit<'a>(&'a AtomicUsize);

impl Drop for ConnectionPermit<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

struct HttpRequest {
    method: String,
    path: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

fn handle_connection(mut stream: TcpStream, service: &ServiceState) -> Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    let request = match read_http_request(&mut stream) {
        Ok(request) => request,
        Err(_) => return write_http(&mut stream, 400, &[], b""),
    };
    // Admission happens before any effect: exact numeric loopback Host, no
    // browser Origin, then the bearer client identity. A browser-origin or
    // misdirected request never reaches token comparison or session state.
    let expected_host = service.address.to_string();
    if request.headers.get("host").map(String::as_str) != Some(expected_host.as_str()) {
        return write_http(&mut stream, 400, &[], b"");
    }
    if request.headers.contains_key("origin") {
        return write_http(&mut stream, 400, &[], b"");
    }
    let Some(token) = request
        .headers
        .get("authorization")
        .and_then(|value| value.strip_prefix("Bearer "))
    else {
        return write_http(&mut stream, 401, &[], b"");
    };
    if [
        "x-licoup-conversation-id",
        "x-licoup-membership-id",
        "x-licoup-parent-dispatch-id",
    ]
    .into_iter()
    .any(|name| {
        request
            .headers
            .get(name)
            .is_some_and(|value| !valid_context_header(value))
    }) {
        return write_http(&mut stream, 400, &[], b"");
    }
    let Some(provider) = service
        .tokens
        .iter()
        .find_map(|(provider, expected)| (constant_time_eq(token, expected)).then_some(provider))
    else {
        return write_http(&mut stream, 401, &[], b"");
    };
    if request.method == "GET" && request.path == "/health" {
        return write_http(&mut stream, 204, &[], b"");
    }
    if request.method == "DELETE" && request.path == "/mcp" {
        let Some(session_id) = request.headers.get("mcp-session-id") else {
            return write_http(&mut stream, 400, &[], b"");
        };
        let mut sessions = service
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let removed = sessions
            .get(session_id)
            .is_some_and(|session| session.provider == *provider)
            && sessions.remove(session_id).is_some();
        return write_http(&mut stream, if removed { 204 } else { 404 }, &[], b"");
    }
    if request.method != "POST" || request.path != "/mcp" {
        return write_http(&mut stream, 404, &[], b"");
    }
    if request.headers.get("content-type").map(String::as_str) != Some("application/json") {
        return write_http(&mut stream, 415, &[], b"");
    }
    let message = match decode_http_body(&request.body, MAX_MCP_FRAME_BYTES) {
        Ok(message) => message,
        Err(_) => return write_http(&mut stream, 400, &[], b""),
    };
    let initialize =
        matches!(&message, McpMessage::Request { method, .. } if method == "initialize");
    // The protocol revision is admitted before effects: a present header must
    // be one of the server's explicit revisions, and every post-initialize
    // request must carry the revision negotiated for that session.
    let request_protocol_revision = request
        .headers
        .get("mcp-protocol-version")
        .map(String::as_str);
    match request_protocol_revision {
        Some(revision)
            if service
                .engine
                .definition()
                .supports_protocol_revision(revision) => {}
        Some(_) => return write_http(&mut stream, 400, &[], b""),
        None if initialize => {}
        None => return write_http(&mut stream, 400, &[], b""),
    }
    let requested_session = request.headers.get("mcp-session-id").cloned();
    let (session_id, session) = if initialize && requested_session.is_none() {
        let mut sessions = service
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if sessions.len() >= MAX_SESSIONS {
            return write_http(&mut stream, 503, &[], b"");
        }
        let id = uuid::Uuid::new_v4().simple().to_string();
        let session = Arc::new(McpSessionState::default());
        sessions.insert(
            id.clone(),
            ServerSession {
                provider: provider.clone(),
                state: Arc::clone(&session),
            },
        );
        (id, session)
    } else {
        let Some(id) = requested_session else {
            return write_http(&mut stream, 400, &[], b"");
        };
        let session = service
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get(&id)
            .filter(|session| session.provider == *provider)
            .map(|session| Arc::clone(&session.state));
        let Some(session) = session else {
            return write_http(&mut stream, 404, &[], b"");
        };
        (id, session)
    };
    if !initialize && session.protocol_revision() != request_protocol_revision {
        return write_http(&mut stream, 400, &[], b"");
    }
    // The bounded tool-effect permit is claimed only after the request has
    // proven its identity, revision, and session, so invalid calls can never
    // occupy an effect slot.
    let _tool_permit = if matches!(&message, McpMessage::Request { method, .. } if method == "tools/call")
    {
        match ToolPermit::acquire(&service.active_tool_calls) {
            Some(permit) => Some(permit),
            None => return write_http(&mut stream, 503, &[], b""),
        }
    } else {
        None
    };
    let caller = CallerContext {
        provider_id: ProviderId::parse(provider.clone())
            .map_err(|_| anyhow!("caller_provider_invalid"))?,
        conversation_id: request.headers.get("x-licoup-conversation-id").cloned(),
        membership_id: request.headers.get("x-licoup-membership-id").cloned(),
        parent_dispatch_id: request.headers.get("x-licoup-parent-dispatch-id").cloned(),
        authenticated: true,
    };
    match service.engine.handle(&session, &caller, message) {
        Some(response) => {
            let body = encode_http_body(&response, MAX_MCP_FRAME_BYTES)?;
            let response_protocol_revision = session
                .protocol_revision()
                .unwrap_or(service.engine.definition().protocol_revision);
            write_http(
                &mut stream,
                200,
                &[
                    ("content-type", "application/json"),
                    ("mcp-session-id", session_id.as_str()),
                    ("mcp-protocol-version", response_protocol_revision),
                ],
                &body,
            )
        }
        None => write_http(
            &mut stream,
            202,
            &[("mcp-session-id", session_id.as_str())],
            b"",
        ),
    }
}

struct ToolPermit<'a>(&'a AtomicUsize);

impl<'a> ToolPermit<'a> {
    fn acquire(counter: &'a AtomicUsize) -> Option<Self> {
        counter
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < MAX_TOOL_WORKERS).then_some(count + 1)
            })
            .ok()
            .map(|_| Self(counter))
    }
}

impl Drop for ToolPermit<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn read_http_request(stream: &mut TcpStream) -> Result<HttpRequest> {
    let mut bytes = Vec::with_capacity(1024);
    let header_end = loop {
        if bytes.len() >= MAX_HTTP_HEADER_BYTES {
            return Err(anyhow!("http_headers_too_large"));
        }
        let mut buffer = [0_u8; 1024];
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            return Err(anyhow!("http_request_incomplete"));
        }
        bytes.extend_from_slice(&buffer[..count]);
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            let header_end = index + 4;
            if header_end > MAX_HTTP_HEADER_BYTES {
                return Err(anyhow!("http_headers_too_large"));
            }
            break header_end;
        }
    };
    let head = std::str::from_utf8(&bytes[..header_end - 4])?;
    let mut lines = head.split("\r\n");
    let request_line = lines
        .next()
        .ok_or_else(|| anyhow!("http_request_invalid"))?;
    let mut request_parts = request_line.split(' ');
    let method = request_parts.next().unwrap_or_default().to_owned();
    let path = request_parts.next().unwrap_or_default().to_owned();
    if request_parts.next() != Some("HTTP/1.1") || request_parts.next().is_some() {
        return Err(anyhow!("http_request_invalid"));
    }
    let mut headers = HashMap::new();
    for line in lines {
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| anyhow!("http_header_invalid"))?;
        let name = name.trim().to_ascii_lowercase();
        if name.is_empty() || headers.insert(name, value.trim().to_owned()).is_some() {
            return Err(anyhow!("http_header_invalid"));
        }
    }
    if headers.contains_key("transfer-encoding") {
        return Err(anyhow!("http_chunked_unsupported"));
    }
    let content_length = headers
        .get("content-length")
        .map(|value| value.parse::<usize>())
        .transpose()?
        .unwrap_or(0);
    if content_length > MAX_MCP_FRAME_BYTES {
        return Err(anyhow!("http_body_too_large"));
    }
    let mut body = bytes[header_end..].to_vec();
    while body.len() < content_length {
        let mut buffer = [0_u8; 4096];
        let count = stream.read(&mut buffer)?;
        if count == 0 {
            return Err(anyhow!("http_body_incomplete"));
        }
        body.extend_from_slice(&buffer[..count]);
        if body.len() > content_length {
            return Err(anyhow!("http_body_overrun"));
        }
    }
    if body.len() != content_length {
        return Err(anyhow!("http_body_invalid"));
    }
    Ok(HttpRequest {
        method,
        path,
        headers,
        body,
    })
}

fn write_http(
    stream: &mut TcpStream,
    status: u16,
    headers: &[(&str, &str)],
    body: &[u8],
) -> Result<()> {
    let reason = match status {
        200 => "OK",
        202 => "Accepted",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        415 => "Unsupported Media Type",
        503 => "Service Unavailable",
        _ => "Error",
    };
    write!(stream, "HTTP/1.1 {status} {reason}\r\n")?;
    for (name, value) in headers {
        write!(stream, "{name}: {value}\r\n")?;
    }
    write!(
        stream,
        "content-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    )?;
    stream.write_all(body)?;
    stream.flush()?;
    Ok(())
}

fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

fn discovery_path() -> Result<PathBuf> {
    let root = super::paths::portable_data_dir()?
        .join("client-state")
        .join("subagent-mcp");
    super::file_security::ensure_private_dir(&root)?;
    Ok(root.join("discovery.json"))
}

fn write_discovery(path: &Path, document: &DiscoveryDocument) -> Result<()> {
    let text = serde_json::to_string(document)?;
    super::file_security::atomic_write_private_text_bounded(path, &text, 16 * 1024)
}

fn read_discovery(path: &Path) -> Result<DiscoveryDocument> {
    let text = super::file_security::read_existing_private_text_bounded(path, 16 * 1024)?
        .ok_or_else(|| anyhow!("subagent_mcp_discovery_unavailable"))?;
    let document: DiscoveryDocument = serde_json::from_str(&text)?;
    if !valid_discovery_document(&document) {
        return Err(anyhow!("subagent_mcp_discovery_invalid"));
    }
    Ok(document)
}

fn valid_discovery_document(document: &DiscoveryDocument) -> bool {
    let port = document
        .endpoint
        .strip_prefix("http://127.0.0.1:")
        .and_then(|value| value.strip_suffix("/mcp"));
    let valid_port = port.is_some_and(|value| {
        !value.is_empty()
            && value.bytes().all(|byte| byte.is_ascii_digit())
            && value
                .parse::<u16>()
                .ok()
                .is_some_and(|port| port > 0 && port.to_string() == value)
    });
    document.schema_version == DISCOVERY_SCHEMA
        && valid_port
        && lowercase_hex(&document.generation, 32)
        && document.tokens.len() == 3
        && ["antigravity", "codex", "cursor"]
            .into_iter()
            .all(|provider| {
                document
                    .tokens
                    .get(provider)
                    .is_some_and(|token| lowercase_hex(token, 64))
            })
}

fn lowercase_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
}

fn cleanup_discovery_generation(path: &Path, generation: &str) {
    let owned = super::file_security::read_existing_private_text_bounded(path, 16 * 1024)
        .ok()
        .flatten()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| {
            value
                .get("generation")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .is_some_and(|observed| observed == generation);
    if owned {
        let _ = fs::remove_file(path);
    }
}

pub fn load_connector_discovery(provider: &str) -> Result<ConnectorDiscovery> {
    if !matches!(provider, "codex" | "cursor" | "antigravity") {
        return Err(anyhow!("subagent_mcp_caller_invalid"));
    }
    let document = read_discovery(&discovery_path()?)?;
    let token = document
        .tokens
        .get(provider)
        .cloned()
        .ok_or_else(|| anyhow!("subagent_mcp_discovery_invalid"))?;
    Ok(ConnectorDiscovery {
        endpoint: document.endpoint,
        bearer_token: token,
    })
}

pub fn connector_exchange(
    discovery: &ConnectorDiscovery,
    session_id: Option<&str>,
    protocol_revision: &str,
    body: &[u8],
) -> Result<(u16, Option<String>, Vec<u8>)> {
    if !crate::domain::subagent_mcp::server_definition()
        .supports_protocol_revision(protocol_revision)
    {
        return Err(anyhow!("subagent_mcp_protocol_revision_invalid"));
    }
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(2))
        .timeout_read(Duration::from_secs(30))
        .timeout_write(Duration::from_secs(30))
        .build();
    let mut request = agent
        .post(&discovery.endpoint)
        .set(
            "authorization",
            &format!("Bearer {}", discovery.bearer_token),
        )
        .set("content-type", "application/json")
        .set("accept", "application/json")
        .set("mcp-protocol-version", protocol_revision);
    for (header, variable) in [
        ("x-licoup-conversation-id", "LICOUP_MCP_CONVERSATION_ID"),
        ("x-licoup-membership-id", "LICOUP_MCP_MEMBERSHIP_ID"),
        (
            "x-licoup-parent-dispatch-id",
            "LICOUP_MCP_PARENT_DISPATCH_ID",
        ),
    ] {
        if let Ok(value) = std::env::var(variable)
            && valid_context_header(&value)
        {
            request = request.set(header, &value);
        }
    }
    if let Some(session_id) = session_id {
        request = request.set("mcp-session-id", session_id);
    }
    let response = match request.send_bytes(body) {
        Ok(response) => response,
        Err(ureq::Error::Status(_, response)) => response,
        Err(_) => return Err(anyhow!("subagent_mcp_connector_transport_failed")),
    };
    let status = response.status();
    let session = response.header("mcp-session-id").map(str::to_owned);
    let mut body = Vec::new();
    response
        .into_reader()
        .take((MAX_MCP_FRAME_BYTES + 1) as u64)
        .read_to_end(&mut body)?;
    if body.len() > MAX_MCP_FRAME_BYTES {
        return Err(anyhow!("subagent_mcp_connector_response_too_large"));
    }
    Ok((status, session, body))
}

pub fn connector_close_session(discovery: &ConnectorDiscovery, session_id: &str) -> Result<()> {
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(2))
        .timeout_read(Duration::from_secs(3))
        .timeout_write(Duration::from_secs(3))
        .build();
    let response = agent
        .delete(&discovery.endpoint)
        .set(
            "authorization",
            &format!("Bearer {}", discovery.bearer_token),
        )
        .set("mcp-session-id", session_id)
        .call();
    match response {
        Ok(response) if response.status() == 204 => Ok(()),
        _ => Err(anyhow!("subagent_mcp_connector_close_failed")),
    }
}

/// Bounded health exchange used only by the supervisor's own probe. Tight
/// deadlines keep the monitor responsive and never carry caller context.
fn health_exchange(
    discovery: &ConnectorDiscovery,
    session_id: Option<&str>,
    body: &[u8],
) -> Result<(u16, Option<String>, Vec<u8>)> {
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(Duration::from_secs(1))
        .timeout_read(Duration::from_secs(2))
        .timeout_write(Duration::from_secs(2))
        .build();
    let mut request = agent
        .post(&discovery.endpoint)
        .set(
            "authorization",
            &format!("Bearer {}", discovery.bearer_token),
        )
        .set("content-type", "application/json")
        .set("accept", "application/json")
        .set(
            "mcp-protocol-version",
            crate::domain::subagent_mcp::PROTOCOL_REVISION,
        );
    if let Some(session_id) = session_id {
        request = request.set("mcp-session-id", session_id);
    }
    let response = match request.send_bytes(body) {
        Ok(response) => response,
        Err(ureq::Error::Status(_, response)) => response,
        Err(_) => return Err(anyhow!("subagent_mcp_health_transport_failed")),
    };
    let status = response.status();
    let session = response.header("mcp-session-id").map(str::to_owned);
    let mut body = Vec::new();
    response
        .into_reader()
        .take((MAX_MCP_FRAME_BYTES + 1) as u64)
        .read_to_end(&mut body)?;
    if body.len() > MAX_MCP_FRAME_BYTES {
        return Err(anyhow!("subagent_mcp_health_response_too_large"));
    }
    Ok((status, session, body))
}

fn valid_context_header(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'.' | b'_' | b'-'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::mcp::{McpMessage, McpRequestId};
    use crate::domain::subagent_mcp::{ConversationHostPort, ReadOnlyTargetPort, TargetMembership};
    use licoup_agent_adapters::AdapterRegistry;
    use licoup_agent_runtime::DurableNativeBinding;
    use licoup_conversation::{SubagentDispatchClaim, SubagentDispatchClaimState};
    use serde_json::{Map, Value, json};

    #[test]
    fn tokens_compare_without_prefix_acceptance() {
        assert!(constant_time_eq("abc", "abc"));
        assert!(!constant_time_eq("abc", "abd"));
        assert!(!constant_time_eq("abc", "abc0"));
    }

    #[test]
    fn caller_context_headers_are_closed_identifiers() {
        assert!(valid_context_header("membership:fixture-1"));
        assert!(!valid_context_header("../private"));
        assert!(!valid_context_header("line\nbreak"));
    }

    #[test]
    fn discovery_admission_is_exact_and_lowercase() {
        let valid = || DiscoveryDocument {
            schema_version: DISCOVERY_SCHEMA.to_owned(),
            endpoint: "http://127.0.0.1:34567/mcp".to_owned(),
            generation: "a".repeat(32),
            tokens: HashMap::from([
                ("antigravity".to_owned(), "b".repeat(64)),
                ("codex".to_owned(), "c".repeat(64)),
                ("cursor".to_owned(), "d".repeat(64)),
            ]),
        };
        assert!(valid_discovery_document(&valid()));
        for endpoint in [
            "http://localhost:34567/mcp",
            "http://127.0.0.1:034567/mcp",
            "http://127.0.0.1:34567/mcp?extra=1",
            "http://127.0.0.1:34567/other",
        ] {
            let mut document = valid();
            document.endpoint = endpoint.to_owned();
            assert!(!valid_discovery_document(&document));
        }
        let mut uppercase = valid();
        uppercase.tokens.insert("codex".to_owned(), "A".repeat(64));
        assert!(!valid_discovery_document(&uppercase));
        let mut extra = valid();
        extra.tokens.insert("other".to_owned(), "e".repeat(64));
        assert!(!valid_discovery_document(&extra));
    }

    struct FixtureConversation;

    impl ConversationHostPort for FixtureConversation {
        fn verify_caller(
            &self,
            _: &CallerContext,
            _: &str,
        ) -> std::result::Result<(), crate::core::mcp::McpApplicationError> {
            unreachable!()
        }
        fn assistant_profiles(
            &self,
            _: &CallerContext,
            _: &Map<String, Value>,
        ) -> std::result::Result<Value, crate::core::mcp::McpApplicationError> {
            unreachable!()
        }
        fn assistant_workflow(
            &self,
            _: &CallerContext,
            _: &str,
            _: &Map<String, Value>,
        ) -> std::result::Result<Value, crate::core::mcp::McpApplicationError> {
            unreachable!()
        }
        fn target_membership(
            &self,
            _: &str,
            _: &str,
        ) -> std::result::Result<TargetMembership, crate::core::mcp::McpApplicationError> {
            unreachable!()
        }
        fn claim_dispatch(
            &self,
            _: &str,
            _: &str,
            _: &str,
            _: Option<&str>,
        ) -> std::result::Result<SubagentDispatchClaim, crate::core::mcp::McpApplicationError>
        {
            unreachable!()
        }
        fn update_claim(
            &self,
            _: &str,
            _: SubagentDispatchClaimState,
        ) -> std::result::Result<(), crate::core::mcp::McpApplicationError> {
            unreachable!()
        }
        fn active_claim(
            &self,
            _: &str,
            _: &str,
            _: &str,
        ) -> std::result::Result<Option<SubagentDispatchClaim>, crate::core::mcp::McpApplicationError>
        {
            unreachable!()
        }
        fn latest_resume_binding(
            &self,
            _: &str,
            _: &str,
        ) -> std::result::Result<DurableNativeBinding, crate::core::mcp::McpApplicationError>
        {
            unreachable!()
        }
        fn record_inbound(
            &self,
            _: &str,
            _: Option<&str>,
            _: Option<&str>,
            _: &str,
            _: &str,
        ) -> std::result::Result<(), crate::core::mcp::McpApplicationError> {
            Ok(())
        }
    }

    struct FixtureTargets;

    impl ReadOnlyTargetPort for FixtureTargets {
        fn list(&self) -> std::result::Result<Value, crate::core::mcp::McpApplicationError> {
            Ok(json!({"subagents": []}))
        }
        fn probe(
            &self,
            _: &ProviderId,
        ) -> std::result::Result<Value, crate::core::mcp::McpApplicationError> {
            unreachable!()
        }
    }

    fn assert_connector_initialize_succeeds(provider: &str) {
        let discovery = load_connector_discovery(provider).unwrap();
        let initialize = encode_http_body(
            &McpMessage::request(
                McpRequestId::from(1_i64),
                "initialize",
                Some(
                    json!({
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "clientInfo": {"name": "fixture", "version": "1"}
                    })
                    .as_object()
                    .unwrap()
                    .clone(),
                ),
            )
            .unwrap(),
            MAX_MCP_FRAME_BYTES,
        )
        .unwrap();
        let (status, session, _) = connector_exchange(
            &discovery,
            None,
            crate::domain::subagent_mcp::PROTOCOL_REVISION,
            &initialize,
        )
        .unwrap();
        assert_eq!(status, 200);
        connector_close_session(&discovery, session.as_deref().unwrap()).unwrap();
    }

    #[test]
    fn authenticated_loopback_service_lists_common_catalog_and_cleans_discovery() {
        let root =
            std::env::temp_dir().join(format!("licoup-subagent-http-{}", uuid::Uuid::new_v4()));
        let previous = super::super::paths::set_portable_data_dir_override(Some(root.clone()));
        let application = SubagentMcpApplication::new(
            Arc::new(FixtureConversation),
            AdapterRegistry::empty(),
            Arc::new(FixtureTargets),
        );
        let supervisor = SubagentMcpSupervisor::start_with_application(application).unwrap();
        assert!(supervisor.healthy());
        assert!(supervisor.health_probe());
        let discovery = load_connector_discovery("codex").unwrap();
        let initialize = McpMessage::request(
            McpRequestId::from(1_i64),
            "initialize",
            Some(
                json!({
                    "protocolVersion": "2025-06-18",
                    "capabilities": {},
                    "clientInfo": {"name": "fixture", "version": "1"}
                })
                .as_object()
                .unwrap()
                .clone(),
            ),
        )
        .unwrap();
        let body = encode_http_body(&initialize, MAX_MCP_FRAME_BYTES).unwrap();
        let (status, session, response) = connector_exchange(
            &discovery,
            None,
            crate::domain::subagent_mcp::PROTOCOL_REVISION,
            &body,
        )
        .unwrap();
        assert_eq!(status, 200);
        assert!(decode_http_body(&response, MAX_MCP_FRAME_BYTES).is_ok());
        let list = McpMessage::request(2_i64, "tools/list", Some(Map::new())).unwrap();
        let body = encode_http_body(&list, MAX_MCP_FRAME_BYTES).unwrap();
        let (status, returned, response) = connector_exchange(
            &discovery,
            session.as_deref(),
            crate::domain::subagent_mcp::PROTOCOL_REVISION,
            &body,
        )
        .unwrap();
        assert_eq!(status, 200);
        assert_eq!(returned, session);
        let response = decode_http_body(&response, MAX_MCP_FRAME_BYTES)
            .unwrap()
            .to_value();
        assert_eq!(
            response
                .pointer("/result/tools")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(9)
        );
        connector_close_session(&discovery, session.as_deref().unwrap()).unwrap();
        let body = encode_http_body(&list, MAX_MCP_FRAME_BYTES).unwrap();
        let (status, _, _) = connector_exchange(
            &discovery,
            session.as_deref(),
            crate::domain::subagent_mcp::PROTOCOL_REVISION,
            &body,
        )
        .unwrap();
        assert_eq!(status, 404);

        let compatible_initialize = McpMessage::request(
            McpRequestId::from(3_i64),
            "initialize",
            Some(
                json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "fixture", "version": "1"}
                })
                .as_object()
                .unwrap()
                .clone(),
            ),
        )
        .unwrap();
        let body = encode_http_body(&compatible_initialize, MAX_MCP_FRAME_BYTES).unwrap();
        let (status, compatible_session, response) =
            connector_exchange(&discovery, None, "2025-11-25", &body).unwrap();
        assert_eq!(status, 200);
        let response = decode_http_body(&response, MAX_MCP_FRAME_BYTES)
            .unwrap()
            .to_value();
        assert_eq!(response["result"]["protocolVersion"], "2025-11-25");
        connector_close_session(&discovery, compatible_session.as_deref().unwrap()).unwrap();
        let discovery_file = supervisor.discovery_path.clone();
        drop(supervisor);
        assert!(!discovery_file.exists());
        super::super::paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(root);
    }

    fn raw_request(address: &SocketAddr, head: &str, body: &str) -> u16 {
        use std::io::Read as _;
        let mut stream = TcpStream::connect(address).unwrap();
        stream
            .write_all(format!("{head}\r\ncontent-length: {}\r\n\r\n{body}", body.len()).as_bytes())
            .unwrap();
        let mut response = Vec::new();
        let _ = stream.read_to_end(&mut response);
        let text = String::from_utf8_lossy(&response);
        text.strip_prefix("HTTP/1.1 ")
            .and_then(|rest| rest.get(..3))
            .and_then(|code| code.parse().ok())
            .unwrap()
    }

    #[test]
    fn admission_rejects_foreign_host_origin_and_revision_before_effects() {
        let root =
            std::env::temp_dir().join(format!("licoup-subagent-admit-{}", uuid::Uuid::new_v4()));
        let previous = super::super::paths::set_portable_data_dir_override(Some(root.clone()));
        let application = SubagentMcpApplication::new(
            Arc::new(FixtureConversation),
            AdapterRegistry::empty(),
            Arc::new(FixtureTargets),
        );
        let supervisor = SubagentMcpSupervisor::start_with_application(application).unwrap();
        let discovery = load_connector_discovery("cursor").unwrap();
        let address = supervisor.address;
        let initialize = encode_http_body(
            &McpMessage::request(
                McpRequestId::from(1_i64),
                "initialize",
                Some(
                    json!({
                        "protocolVersion": "2025-06-18",
                        "capabilities": {},
                        "clientInfo": {"name": "fixture", "version": "1"}
                    })
                    .as_object()
                    .unwrap()
                    .clone(),
                ),
            )
            .unwrap(),
            MAX_MCP_FRAME_BYTES,
        )
        .unwrap();
        let initialize = String::from_utf8(initialize).unwrap();
        let auth = format!("Bearer {}", discovery.bearer_token);

        // Exact numeric loopback Host is required before token comparison.
        assert_eq!(
            raw_request(
                &address,
                &format!(
                    "POST /mcp HTTP/1.1\r\nhost: attacker.example\r\nauthorization: {auth}\r\ncontent-type: application/json\r\nmcp-protocol-version: 2025-06-18"
                ),
                &initialize,
            ),
            400
        );
        // Any browser Origin is rejected even with a valid bearer token.
        assert_eq!(
            raw_request(
                &address,
                &format!(
                    "POST /mcp HTTP/1.1\r\nhost: {address}\r\norigin: http://attacker.example\r\nauthorization: {auth}\r\ncontent-type: application/json\r\nmcp-protocol-version: 2025-06-18"
                ),
                &initialize,
            ),
            400
        );
        // A skewed protocol revision never reaches session state.
        assert_eq!(
            raw_request(
                &address,
                &format!(
                    "POST /mcp HTTP/1.1\r\nhost: {address}\r\nauthorization: {auth}\r\ncontent-type: application/json\r\nmcp-protocol-version: 1999-01-01"
                ),
                &initialize,
            ),
            400
        );
        // Authenticated caller context is still a closed bounded identifier.
        assert_eq!(
            raw_request(
                &address,
                &format!(
                    "POST /mcp HTTP/1.1\r\nhost: {address}\r\nauthorization: {auth}\r\ncontent-type: application/json\r\nmcp-protocol-version: 2025-06-18\r\nx-licoup-conversation-id: ../private"
                ),
                &initialize,
            ),
            400
        );
        // A missing revision header is tolerated only for initialize.
        assert_eq!(
            raw_request(
                &address,
                &format!(
                    "POST /mcp HTTP/1.1\r\nhost: {address}\r\nauthorization: {auth}\r\ncontent-type: application/json"
                ),
                &initialize,
            ),
            200
        );
        let list = String::from_utf8(
            encode_http_body(
                &McpMessage::request(2_i64, "tools/list", Some(Map::new())).unwrap(),
                MAX_MCP_FRAME_BYTES,
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            raw_request(
                &address,
                &format!(
                    "POST /mcp HTTP/1.1\r\nhost: {address}\r\nauthorization: {auth}\r\ncontent-type: application/json"
                ),
                &list,
            ),
            400
        );
        drop(supervisor);
        super::super::paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn supervision_restarts_unexpected_exit_with_fresh_generation() {
        let root =
            std::env::temp_dir().join(format!("licoup-subagent-super-{}", uuid::Uuid::new_v4()));
        let previous = super::super::paths::set_portable_data_dir_override(Some(root.clone()));
        // The portable-dir override is thread-local: the monitor thread
        // installs it inside the factory before constructing the service.
        let monitor_root = root.clone();
        let service = SubagentMcpService::start_with_factory(move || {
            super::super::paths::set_portable_data_dir_override(Some(monitor_root.clone()));
            SubagentMcpSupervisor::start_with_application(SubagentMcpApplication::new(
                Arc::new(FixtureConversation),
                AdapterRegistry::empty(),
                Arc::new(FixtureTargets),
            ))
        });
        assert!(
            service.healthy(),
            "the initial service must be ready when start returns"
        );
        let first_generation = read_discovery(&discovery_path().unwrap())
            .expect("initial discovery must be published before start returns")
            .generation;
        assert_connector_initialize_succeeds("antigravity");
        service.force_exit_for_test();
        let deadline = std::time::Instant::now() + Duration::from_secs(15);
        loop {
            let restarted = read_discovery(&discovery_path().unwrap())
                .ok()
                .filter(|_| service.healthy())
                .is_some_and(|document| document.generation != first_generation);
            if restarted {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "restart timed out");
            thread::sleep(Duration::from_millis(25));
        }
        assert_connector_initialize_succeeds("antigravity");
        let discovery_file = discovery_path().unwrap();
        drop(service);
        assert!(!discovery_file.exists());
        super::super::paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(root);
    }
}
