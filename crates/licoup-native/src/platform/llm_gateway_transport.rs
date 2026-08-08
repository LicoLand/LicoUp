//! Bounded outbound transport for the local LLM gateway.

use crate::domain::llm_api_key_vault::GatewayCredentialLease;
use crate::domain::llm_gateway::{
    CompiledGateway, CredentialStyle, GatewayError, GatewayResponse, MAX_GATEWAY_BODY_BYTES,
    UpstreamProtocol,
};
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

/// Routes, converts, authorizes, and executes one model request. Credential
/// lookup happens only after the closed route and endpoint have been accepted.
pub fn exchange(
    gateway: &CompiledGateway,
    path: &str,
    body: &[u8],
    incoming_user_agent: Option<&str>,
    incoming_anthropic_beta: Option<&str>,
    credentials: &GatewayCredentialLease,
) -> Result<GatewayResponse, GatewayTransportError> {
    let prepared = gateway
        .prepare(path, body)
        .map_err(GatewayTransportError::Gateway)?;
    let credential = credentials
        .resolve(prepared.credential_provider)
        .map_err(|_| GatewayTransportError::CredentialUnavailable)?;
    let credential = credential
        .expose_utf8()
        .map_err(|_| GatewayTransportError::CredentialUnavailable)?;
    let _permit = Permit::acquire()?;
    let agent = ureq::AgentBuilder::new()
        .redirects(0)
        .timeout_connect(CONNECT_TIMEOUT)
        .timeout_read(REQUEST_TIMEOUT)
        .timeout_write(REQUEST_TIMEOUT)
        .build();
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
        CredentialStyle::Bearer => request.set("authorization", &format!("Bearer {credential}")),
        CredentialStyle::XApiKey => request.set("x-api-key", &credential),
    };
    let response = match request.send_bytes(&prepared.body) {
        Ok(response) => response,
        Err(ureq::Error::Status(_, response)) => response,
        Err(ureq::Error::Transport(_)) => return Err(GatewayTransportError::TransportFailed),
    };
    let status = response.status();
    let content_type = response.header("content-type").map(str::to_owned);
    let mut response_body = Vec::new();
    response
        .into_reader()
        .take((MAX_GATEWAY_BODY_BYTES as u64).saturating_add(1))
        .read_to_end(&mut response_body)
        .map_err(|_| GatewayTransportError::TransportFailed)?;
    if response_body.len() > MAX_GATEWAY_BODY_BYTES {
        return Err(GatewayTransportError::ResponseTooLarge);
    }
    gateway
        .finish(&prepared, status, content_type.as_deref(), &response_body)
        .map_err(GatewayTransportError::Gateway)
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

    #[test]
    fn user_agent_forwarding_is_bounded_and_header_safe() {
        assert!(valid_header_value("codex-cli/1.0"));
        assert!(!valid_header_value("codex\r\nx-api-key: secret"));
        assert!(!valid_header_value(&"x".repeat(1025)));
    }
}
