//! Process-local, loopback-only HTTP front end for the LLM gateway.

use crate::core::secure_mesh_secret_store::SecretBytes;
use crate::domain::llm_api_key_vault::GatewayCredentialSlot;
use crate::domain::llm_gateway::{CompiledGateway, GatewayResponse, MAX_GATEWAY_BODY_BYTES};
use crate::platform::llm_gateway_transport::{
    GatewayExchange, GatewayStreamSink, GatewayTransportError, exchange_to_sink,
};
use crate::platform::llm_gateway_usage::GatewayUsageRecorder;
use std::collections::BTreeMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

const MAX_HEADER_BYTES: usize = 64 * 1024;
const MAX_HEADERS: usize = 128;
const WORKERS: usize = 8;
const QUEUE_DEPTH: usize = 32;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GatewayServerError {
    NonLoopbackListener,
    ListenerConfiguration,
    WorkerFailure,
}

#[derive(Debug)]
struct HttpRequest {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

/// Serves until `stop` is set. The caller owns configuration loading and the
/// listener lifetime; this function never edits host application files.
pub fn serve_loopback(
    listener: TcpListener,
    gateway: Arc<CompiledGateway>,
    stop: Arc<AtomicBool>,
    credentials: Arc<GatewayCredentialSlot>,
    client_token: Arc<SecretBytes>,
    usage: Arc<GatewayUsageRecorder>,
) -> Result<(), GatewayServerError> {
    let address = listener
        .local_addr()
        .map_err(|_| GatewayServerError::ListenerConfiguration)?;
    if !address.ip().is_loopback() {
        return Err(GatewayServerError::NonLoopbackListener);
    }
    listener
        .set_nonblocking(true)
        .map_err(|_| GatewayServerError::ListenerConfiguration)?;
    let (sender, receiver) = mpsc::sync_channel::<TcpStream>(QUEUE_DEPTH);
    let receiver = Arc::new(Mutex::new(receiver));
    let mut workers = Vec::with_capacity(WORKERS);
    for _ in 0..WORKERS {
        let receiver = Arc::clone(&receiver);
        let gateway = Arc::clone(&gateway);
        let credentials = Arc::clone(&credentials);
        let client_token = Arc::clone(&client_token);
        let usage = Arc::clone(&usage);
        workers.push(thread::spawn(move || {
            worker(receiver, gateway, credentials, client_token, usage)
        }));
    }
    while !stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((mut stream, peer)) => {
                if !peer.ip().is_loopback() {
                    let _ = write_error(&mut stream, 403, "loopback_client_required");
                    continue;
                }
                match sender.try_send(stream) {
                    Ok(()) => {}
                    Err(mpsc::TrySendError::Full(mut stream)) => {
                        let _ = write_error(&mut stream, 503, "gateway_busy");
                    }
                    Err(mpsc::TrySendError::Disconnected(_)) => {
                        return Err(GatewayServerError::WorkerFailure);
                    }
                }
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return Err(GatewayServerError::ListenerConfiguration),
        }
    }
    drop(sender);
    for worker in workers {
        worker
            .join()
            .map_err(|_| GatewayServerError::WorkerFailure)?;
    }
    Ok(())
}

fn worker(
    receiver: Arc<Mutex<mpsc::Receiver<TcpStream>>>,
    gateway: Arc<CompiledGateway>,
    credentials: Arc<GatewayCredentialSlot>,
    client_token: Arc<SecretBytes>,
    usage: Arc<GatewayUsageRecorder>,
) {
    loop {
        let stream = match receiver.lock() {
            Ok(receiver) => receiver.recv(),
            Err(_) => return,
        };
        let Ok(mut stream) = stream else { return };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
        handle_connection(&mut stream, &gateway, &credentials, &client_token, &usage);
    }
}

fn handle_connection(
    stream: &mut TcpStream,
    gateway: &CompiledGateway,
    credentials: &GatewayCredentialSlot,
    client_token: &SecretBytes,
    usage: &GatewayUsageRecorder,
) {
    let request = match read_request(stream) {
        Ok(request) => request,
        Err(code) => {
            let _ = write_error(stream, code, "invalid_gateway_request");
            return;
        }
    };
    if !valid_loopback_host(request.headers.get("host"), stream.local_addr().ok()) {
        let _ = write_error(stream, 403, "gateway_host_forbidden");
        return;
    }
    if request.method == "GET" && request.path == "/health" {
        let _ = write_response(
            stream,
            &GatewayResponse {
                status: 200,
                content_type: "application/json",
                body: br#"{"ok":true,"service":"licoup-llm-gateway","protocols":["openai-responses","openai-chat-completions","anthropic-messages"],"clientAuth":"bearer-or-x-api-key"}"#.to_vec(),
            },
        );
        return;
    }
    if request.method != "POST" {
        let _ = write_error(stream, 405, "method_not_allowed");
        return;
    }
    if !request_is_authorized(&request.headers, client_token) {
        let _ = write_error(stream, 401, "gateway_client_unauthorized");
        return;
    }
    let user_agent = request.headers.get("user-agent").map(String::as_str);
    let anthropic_beta = request.headers.get("anthropic-beta").map(String::as_str);
    let mut sink = HttpGatewayStreamSink {
        stream,
        started: false,
    };
    let result = exchange_to_sink(
        gateway,
        &request.path,
        &request.body,
        user_agent,
        anthropic_beta,
        credentials,
        &mut sink,
    );
    if !matches!(&result, Err(GatewayTransportError::Gateway(_))) {
        usage.record(&request.path, user_agent, &request.body);
    }
    match result {
        Ok(GatewayExchange::Buffered(response)) => {
            let _ = write_response(sink.stream, &response);
        }
        Ok(GatewayExchange::Streamed) => {}
        Err(error) => {
            if !sink.started {
                let (status, code) = transport_error(error);
                let _ = write_error(sink.stream, status, code);
            }
        }
    }
}

struct HttpGatewayStreamSink<'a> {
    stream: &'a mut TcpStream,
    started: bool,
}

impl GatewayStreamSink for HttpGatewayStreamSink<'_> {
    fn begin(&mut self, status: u16, content_type: &str) -> std::io::Result<()> {
        write!(
            self.stream,
            "HTTP/1.1 {} {}\r\ncontent-type: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n",
            status,
            reason_phrase(status),
            content_type
        )?;
        self.stream.flush()?;
        self.started = true;
        Ok(())
    }

    fn write(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        self.stream.write_all(bytes)?;
        self.stream.flush()
    }
}

fn valid_loopback_host(host: Option<&String>, local: Option<SocketAddr>) -> bool {
    let (Some(host), Some(local)) = (host, local) else {
        return false;
    };
    let expected = format!("127.0.0.1:{}", local.port());
    host == "127.0.0.1" || host == &expected
}

fn request_is_authorized(headers: &BTreeMap<String, String>, client_token: &SecretBytes) -> bool {
    let authorization = headers
        .get("authorization")
        .and_then(|value| value.strip_prefix("Bearer "));
    let api_key = headers.get("x-api-key").map(String::as_str);
    match (authorization, api_key) {
        (Some(_), Some(_)) | (None, None) => false,
        (Some(token), None) | (None, Some(token)) => {
            crate::platform::llm_gateway_client_auth::token_matches(client_token, token)
        }
    }
}

fn read_request(stream: &mut TcpStream) -> Result<HttpRequest, u16> {
    let mut received = Vec::with_capacity(4096);
    let header_end = loop {
        if received.len() >= MAX_HEADER_BYTES {
            return Err(431);
        }
        let mut chunk = [0u8; 4096];
        let read = stream.read(&mut chunk).map_err(|_| 400u16)?;
        if read == 0 {
            return Err(400);
        }
        received.extend_from_slice(&chunk[..read]);
        if let Some(position) = find_header_end(&received) {
            break position;
        }
    };
    let head = std::str::from_utf8(&received[..header_end]).map_err(|_| 400u16)?;
    let (method, path, headers) = parse_head(head)?;
    if headers.contains_key("transfer-encoding") {
        return Err(400);
    }
    let content_length = headers
        .get("content-length")
        .map(|value| value.parse::<usize>().map_err(|_| 400u16))
        .transpose()?
        .unwrap_or(0);
    if content_length > MAX_GATEWAY_BODY_BYTES {
        return Err(413);
    }
    let body_start = header_end + 4;
    let already = received.len().saturating_sub(body_start);
    if already > content_length {
        received.truncate(body_start + content_length);
    }
    while received.len().saturating_sub(body_start) < content_length {
        let remaining = content_length - received.len().saturating_sub(body_start);
        let mut chunk = vec![0u8; remaining.min(8192)];
        let read = stream.read(&mut chunk).map_err(|_| 400u16)?;
        if read == 0 {
            return Err(400);
        }
        received.extend_from_slice(&chunk[..read]);
    }
    Ok(HttpRequest {
        method,
        path,
        headers,
        body: received[body_start..body_start + content_length].to_vec(),
    })
}

fn parse_head(head: &str) -> Result<(String, String, BTreeMap<String, String>), u16> {
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next().ok_or(400u16)?.split_whitespace();
    let method = request_line.next().ok_or(400u16)?.to_owned();
    let path = request_line.next().ok_or(400u16)?.to_owned();
    let version = request_line.next().ok_or(400u16)?;
    if request_line.next().is_some()
        || version != "HTTP/1.1"
        || !path.starts_with('/')
        || path.contains('?')
        || path.contains('#')
    {
        return Err(400);
    }
    let mut headers = BTreeMap::new();
    for (count, line) in lines.enumerate() {
        if count >= MAX_HEADERS || line.starts_with(' ') || line.starts_with('\t') {
            return Err(431);
        }
        let (name, value) = line.split_once(':').ok_or(400u16)?;
        let name = name.to_ascii_lowercase();
        if name.is_empty()
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            || value.bytes().any(|byte| byte < 0x20 && byte != b'\t')
            || headers.insert(name, value.trim().to_owned()).is_some()
        {
            return Err(400);
        }
    }
    Ok((method, path, headers))
}

fn find_header_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

fn write_response(stream: &mut TcpStream, response: &GatewayResponse) -> std::io::Result<()> {
    let reason = reason_phrase(response.status);
    write!(
        stream,
        "HTTP/1.1 {} {}\r\ncontent-type: {}\r\ncontent-length: {}\r\ncache-control: no-store\r\nconnection: close\r\n\r\n",
        response.status,
        reason,
        response.content_type,
        response.body.len()
    )?;
    stream.write_all(&response.body)
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        500..=599 => "Upstream Failure",
        _ => "Response",
    }
}

fn write_error(stream: &mut TcpStream, status: u16, code: &str) -> std::io::Result<()> {
    let body = serde_json::to_vec(&serde_json::json!({
        "error":{"message":code,"type":"gateway_error","code":code,"param":null}
    }))
    .unwrap_or_default();
    write_response(
        stream,
        &GatewayResponse {
            status,
            content_type: "application/json",
            body,
        },
    )
}

fn transport_error(error: GatewayTransportError) -> (u16, &'static str) {
    use crate::domain::llm_gateway::GatewayError;
    match error {
        GatewayTransportError::Gateway(GatewayError::UnsupportedPath) => {
            (404, "gateway_path_not_found")
        }
        GatewayTransportError::Gateway(GatewayError::RouteNotFound) => {
            (404, "gateway_route_not_found")
        }
        GatewayTransportError::Gateway(GatewayError::RequestTooLarge)
        | GatewayTransportError::ResponseTooLarge => (413, "gateway_payload_too_large"),
        GatewayTransportError::Gateway(_) => (400, "gateway_request_invalid"),
        GatewayTransportError::CredentialUnavailable => (503, "gateway_credential_unavailable"),
        GatewayTransportError::Busy => (503, "gateway_busy"),
        GatewayTransportError::TransportFailed => (502, "gateway_upstream_unavailable"),
    }
}

pub fn bind_address(port: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parser_accepts_bounded_http_and_rejects_smuggling_shapes() {
        let (_, path, headers) =
            parse_head("POST /v1/responses HTTP/1.1\r\nhost: 127.0.0.1\r\ncontent-length: 2")
                .unwrap();
        assert_eq!(path, "/v1/responses");
        assert_eq!(headers["content-length"], "2");
        assert!(parse_head("POST /v1/responses?x=1 HTTP/1.1\r\nhost: x").is_err());
        assert!(parse_head("POST /v1/responses HTTP/1.1\r\nx: 1\r\nx: 2").is_err());
        assert!(parse_head("POST /v1/responses HTTP/1.1\r\n folded: x").is_err());
    }

    #[test]
    fn public_bind_address_is_always_loopback() {
        assert!(bind_address(0).ip().is_loopback());
    }

    #[test]
    fn post_authentication_requires_one_exact_token() {
        let token = SecretBytes::try_from_string("a".repeat(43)).unwrap();
        let mut headers = BTreeMap::new();
        assert!(!request_is_authorized(&headers, &token));
        headers.insert("authorization".into(), format!("Bearer {}", "a".repeat(43)));
        assert!(request_is_authorized(&headers, &token));
        headers.insert("x-api-key".into(), "a".repeat(43));
        assert!(!request_is_authorized(&headers, &token));
        headers.remove("authorization");
        assert!(request_is_authorized(&headers, &token));
        headers.insert("x-api-key".into(), "wrong".into());
        assert!(!request_is_authorized(&headers, &token));
    }

    #[test]
    fn host_is_bound_to_the_listener_port() {
        let local = Some(SocketAddr::from(([127, 0, 0, 1], 15_722)));
        assert!(valid_loopback_host(Some(&"127.0.0.1".into()), local));
        assert!(valid_loopback_host(Some(&"127.0.0.1:15722".into()), local));
        assert!(!valid_loopback_host(Some(&"example.test".into()), local));
        assert!(!valid_loopback_host(Some(&"127.0.0.1:15723".into()), local));
    }
}
