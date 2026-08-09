//! Bounded outbound transport for the local LLM gateway.

use crate::domain::llm_api_key_vault::GatewayCredentialSlot;
use crate::domain::llm_gateway::{
    CompiledGateway, CredentialStyle, GatewayError, GatewayResponse, MAX_GATEWAY_BODY_BYTES,
    UpstreamProtocol,
};
use crate::domain::llm_gateway_stream::GatewayStreamTransformer;
use std::io::Read;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

const MAX_IN_FLIGHT: usize = 16;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(180);
static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GatewayTransportError {
    Gateway(GatewayError),
    CredentialUnavailable,
    Busy,
    TransportFailed,
    ResponseTooLarge,
}

pub trait GatewayStreamSink {
    fn begin(&mut self, status: u16, content_type: &str) -> std::io::Result<()>;
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<()>;
}

pub enum GatewayExchange {
    Buffered(GatewayResponse),
    Streamed,
}

/// Routes, converts, authorizes, and executes one model request. Credential
/// lookup happens only after the closed route and endpoint have been accepted.
pub fn exchange(
    gateway: &CompiledGateway,
    path: &str,
    body: &[u8],
    incoming_user_agent: Option<&str>,
    incoming_anthropic_beta: Option<&str>,
    credentials: &GatewayCredentialSlot,
) -> Result<GatewayResponse, GatewayTransportError> {
    match exchange_inner(
        gateway,
        path,
        body,
        incoming_user_agent,
        incoming_anthropic_beta,
        credentials,
        None,
    )? {
        GatewayExchange::Buffered(response) => Ok(response),
        GatewayExchange::Streamed => Err(GatewayTransportError::TransportFailed),
    }
}

pub fn exchange_to_sink(
    gateway: &CompiledGateway,
    path: &str,
    body: &[u8],
    incoming_user_agent: Option<&str>,
    incoming_anthropic_beta: Option<&str>,
    credentials: &GatewayCredentialSlot,
    sink: &mut dyn GatewayStreamSink,
) -> Result<GatewayExchange, GatewayTransportError> {
    exchange_inner(
        gateway,
        path,
        body,
        incoming_user_agent,
        incoming_anthropic_beta,
        credentials,
        Some(sink),
    )
}

fn exchange_inner(
    gateway: &CompiledGateway,
    path: &str,
    body: &[u8],
    incoming_user_agent: Option<&str>,
    incoming_anthropic_beta: Option<&str>,
    credentials: &GatewayCredentialSlot,
    mut sink: Option<&mut dyn GatewayStreamSink>,
) -> Result<GatewayExchange, GatewayTransportError> {
    let prepared = gateway
        .prepare(path, body)
        .map_err(GatewayTransportError::Gateway)?;
    let credential_candidates = credentials
        .resolve_candidates(prepared.credential_provider)
        .map_err(|_| GatewayTransportError::CredentialUnavailable)?;
    let _permit = Permit::acquire()?;
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(CONNECT_TIMEOUT)
        .timeout_read(REQUEST_TIMEOUT)
        .timeout_write(REQUEST_TIMEOUT)
        .build();
    let candidate_count = credential_candidates.len();
    for (candidate_index, credential) in credential_candidates.into_iter().enumerate() {
        let credential = credential
            .expose_utf8()
            .map_err(|_| GatewayTransportError::CredentialUnavailable)?;
        let mut request = agent
            .post(&prepared.endpoint)
            .set(
                "accept",
                if prepared.stream {
                    "text/event-stream"
                } else {
                    "application/json"
                },
            )
            .set("content-type", "application/json");
        if let Some(user_agent) = incoming_user_agent.filter(|value| valid_header_value(value)) {
            request = request.set("user-agent", user_agent);
        }
        if prepared.upstream_protocol == UpstreamProtocol::AnthropicMessages {
            request = request.set("anthropic-version", "2023-06-01");
            if let Some(beta) = incoming_anthropic_beta.filter(|value| valid_header_value(value)) {
                request = request.set("anthropic-beta", beta);
            }
        }
        request = match prepared.credential_style {
            CredentialStyle::Bearer => {
                request.set("authorization", &format!("Bearer {credential}"))
            }
            CredentialStyle::XApiKey => request.set("x-api-key", &credential),
        };
        let has_fallback = candidate_index + 1 < candidate_count;
        let response = match request.send_bytes(&prepared.body) {
            Ok(response) => response,
            Err(ureq::Error::Status(status, response)) => {
                if has_fallback && retryable_status(status) {
                    continue;
                }
                response
            }
            Err(ureq::Error::Transport(_)) if has_fallback => continue,
            Err(ureq::Error::Transport(_)) => {
                return Err(GatewayTransportError::TransportFailed);
            }
        };
        let status = response.status();
        let content_type = response.header("content-type").map(str::to_owned);
        let is_sse = content_type
            .as_deref()
            .is_some_and(|value| value.to_ascii_lowercase().contains("text/event-stream"));
        if prepared.stream && (200..300).contains(&status) && is_sse {
            if let Some(sink) = sink.as_deref_mut() {
                let mut transformer = GatewayStreamTransformer::new(&prepared)
                    .map_err(GatewayTransportError::Gateway)?;
                let remember_history = prepared.client_protocol
                    == crate::domain::llm_gateway::ClientProtocol::OpenAiResponses
                    && prepared.upstream_protocol == UpstreamProtocol::OpenAiChatCompletions;
                let mut history_body = Vec::new();
                sink.begin(status, "text/event-stream")
                    .map_err(|_| GatewayTransportError::TransportFailed)?;
                let mut reader = response.into_reader();
                let mut chunk = [0u8; 8192];
                loop {
                    let read = reader
                        .read(&mut chunk)
                        .map_err(|_| GatewayTransportError::TransportFailed)?;
                    if read == 0 {
                        break;
                    }
                    let converted = transformer
                        .push(&chunk[..read])
                        .map_err(GatewayTransportError::Gateway)?;
                    if remember_history {
                        history_body.extend_from_slice(&chunk[..read]);
                    }
                    if !converted.is_empty() {
                        sink.write(&converted)
                            .map_err(|_| GatewayTransportError::TransportFailed)?;
                    }
                }
                let final_bytes = transformer
                    .finish()
                    .map_err(GatewayTransportError::Gateway)?;
                if !final_bytes.is_empty() {
                    sink.write(&final_bytes)
                        .map_err(|_| GatewayTransportError::TransportFailed)?;
                }
                if remember_history {
                    gateway
                        .remember_stream_response(&prepared, &history_body)
                        .map_err(GatewayTransportError::Gateway)?;
                }
                return Ok(GatewayExchange::Streamed);
            }
        }
        let mut response_body = Vec::new();
        response
            .into_reader()
            .take((MAX_GATEWAY_BODY_BYTES as u64).saturating_add(1))
            .read_to_end(&mut response_body)
            .map_err(|_| GatewayTransportError::TransportFailed)?;
        if response_body.len() > MAX_GATEWAY_BODY_BYTES {
            return Err(GatewayTransportError::ResponseTooLarge);
        }
        return gateway
            .finish(&prepared, status, content_type.as_deref(), &response_body)
            .map(GatewayExchange::Buffered)
            .map_err(GatewayTransportError::Gateway);
    }
    Err(GatewayTransportError::CredentialUnavailable)
}

fn retryable_status(status: u16) -> bool {
    matches!(status, 401 | 403 | 429) || (500..=599).contains(&status)
}

fn valid_header_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 1024
        && value
            .bytes()
            .all(|byte| byte == b'\t' || (0x20..=0x7e).contains(&byte))
}

struct Permit;

impl Permit {
    fn acquire() -> Result<Self, GatewayTransportError> {
        IN_FLIGHT
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < MAX_IN_FLIGHT).then_some(active + 1)
            })
            .map(|_| Self)
            .map_err(|_| GatewayTransportError::Busy)
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_secret_store::SecretBytes;
    use crate::domain::llm_api_key_vault::{
        GatewayCredential, GatewayCredentialEpochSource, GatewayCredentialLease,
        GatewayCredentialLeaseDays, LlmApiKeyProvider,
    };
    use crate::domain::llm_gateway::{
        ClientProtocol, CredentialStyle, GatewayConfig, GatewayProvider, ModelRoute,
    };
    use anyhow::Result;
    use std::collections::BTreeMap;
    use std::io::Write as _;
    use std::net::TcpListener;
    use std::sync::Arc;

    struct StaticEpochSource(String);

    impl GatewayCredentialEpochSource for StaticEpochSource {
        fn active_epoch(&self) -> Result<Option<String>> {
            Ok(Some(self.0.clone()))
        }
    }

    struct ChannelSink(std::sync::mpsc::Sender<Vec<u8>>);

    impl GatewayStreamSink for ChannelSink {
        fn begin(&mut self, _status: u16, _content_type: &str) -> std::io::Result<()> {
            Ok(())
        }

        fn write(&mut self, bytes: &[u8]) -> std::io::Result<()> {
            self.0.send(bytes.to_vec()).unwrap();
            Ok(())
        }
    }

    #[test]
    fn user_agent_forwarding_is_bounded_and_header_safe() {
        assert!(valid_header_value("codex-cli/1.0"));
        assert!(!valid_header_value("codex\r\nx-api-key: secret"));
        assert!(!valid_header_value(&"x".repeat(1025)));
    }

    #[test]
    fn transport_fails_over_to_the_next_authorized_key() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let mut authorization_headers = Vec::new();
            for status in [401, 200] {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buffer = [0u8; 4096];
                loop {
                    let read = stream.read(&mut buffer).unwrap();
                    request.extend_from_slice(&buffer[..read]);
                    if request.windows(4).any(|window| window == b"\r\n\r\n") {
                        break;
                    }
                }
                let request_text = String::from_utf8_lossy(&request);
                authorization_headers.push(
                    request_text
                        .lines()
                        .find(|line| line.to_ascii_lowercase().starts_with("authorization:"))
                        .map(str::to_owned)
                        .unwrap(),
                );
                let body = if status == 200 {
                    r#"{"id":"chat-1","object":"chat.completion","created":1,"model":"upstream","choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
                } else {
                    r#"{"error":{"message":"rejected"}}"#
                };
                write!(
                    stream,
                    "HTTP/1.1 {status} Test\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .unwrap();
            }
            assert_ne!(authorization_headers[0], authorization_headers[1]);
        });

        let gateway = CompiledGateway::compile(GatewayConfig {
            schema_version: 1,
            providers: vec![GatewayProvider {
                id: "fixture".to_owned(),
                base_url: format!("http://{address}/v1"),
                protocol: UpstreamProtocol::OpenAiChatCompletions,
                credential_provider: LlmApiKeyProvider::Kimi,
                credential_style: CredentialStyle::Bearer,
            }],
            routes: vec![ModelRoute {
                client_protocol: ClientProtocol::OpenAiChatCompletions,
                requested_model: "requested".to_owned(),
                provider_id: "fixture".to_owned(),
                upstream_model: "upstream".to_owned(),
            }],
        })
        .unwrap();
        let epoch = uuid::Uuid::new_v4().to_string();
        let credentials = BTreeMap::from([(
            LlmApiKeyProvider::Kimi,
            ["fixture-first-key", "fixture-second-key"]
                .into_iter()
                .map(|secret| {
                    GatewayCredential::new(
                        uuid::Uuid::new_v4().to_string(),
                        SecretBytes::try_from_string(secret.to_owned()).unwrap(),
                        None,
                    )
                    .unwrap()
                })
                .collect(),
        )]);
        let slot = GatewayCredentialSlot::new(
            GatewayCredentialLease::new(
                credentials,
                GatewayCredentialLeaseDays::Seven,
                epoch.clone(),
                Arc::new(StaticEpochSource(epoch)),
            )
            .unwrap(),
        );

        let response = exchange(
            &gateway,
            "/v1/chat/completions",
            br#"{"model":"requested","messages":[{"role":"user","content":"hello"}]}"#,
            None,
            None,
            &slot,
        )
        .unwrap();

        assert_eq!(response.status, 200);
        server.join().unwrap();
    }

    #[test]
    fn streaming_transport_delivers_first_event_before_upstream_finishes() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (release_sender, release_receiver) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 4096];
            let _ = stream.read(&mut request).unwrap();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: {{\"id\":\"one\",\"choices\":[{{\"delta\":{{\"content\":\"first\"}}}}]}}\n\n"
            )
            .unwrap();
            stream.flush().unwrap();
            release_receiver
                .recv_timeout(Duration::from_secs(2))
                .unwrap();
            stream.write_all(b"data: [DONE]\n\n").unwrap();
        });

        let gateway = CompiledGateway::compile(GatewayConfig {
            schema_version: 1,
            providers: vec![GatewayProvider {
                id: "fixture".to_owned(),
                base_url: format!("http://{address}/v1"),
                protocol: UpstreamProtocol::OpenAiChatCompletions,
                credential_provider: LlmApiKeyProvider::Kimi,
                credential_style: CredentialStyle::Bearer,
            }],
            routes: vec![ModelRoute {
                client_protocol: ClientProtocol::OpenAiChatCompletions,
                requested_model: "requested".to_owned(),
                provider_id: "fixture".to_owned(),
                upstream_model: "upstream".to_owned(),
            }],
        })
        .unwrap();
        let epoch = uuid::Uuid::new_v4().to_string();
        let credentials = BTreeMap::from([(
            LlmApiKeyProvider::Kimi,
            vec![
                GatewayCredential::new(
                    uuid::Uuid::new_v4().to_string(),
                    SecretBytes::try_from_string("fixture-stream-key".to_owned()).unwrap(),
                    None,
                )
                .unwrap(),
            ],
        )]);
        let slot = GatewayCredentialSlot::new(
            GatewayCredentialLease::new(
                credentials,
                GatewayCredentialLeaseDays::Seven,
                epoch.clone(),
                Arc::new(StaticEpochSource(epoch)),
            )
            .unwrap(),
        );
        let (event_sender, event_receiver) = std::sync::mpsc::channel();
        let exchange = std::thread::spawn(move || {
            let mut sink = ChannelSink(event_sender);
            exchange_to_sink(
                &gateway,
                "/v1/chat/completions",
                br#"{"model":"requested","stream":true,"messages":[]}"#,
                None,
                None,
                &slot,
                &mut sink,
            )
        });

        let first = event_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("first SSE event before upstream completion");
        assert!(String::from_utf8_lossy(&first).contains("first"));
        release_sender.send(()).unwrap();
        match exchange.join().unwrap() {
            Ok(GatewayExchange::Streamed) => {}
            Ok(GatewayExchange::Buffered(_)) => panic!("stream was buffered"),
            Err(error) => panic!("stream failed: {error:?}"),
        }
        server.join().unwrap();
    }
}
