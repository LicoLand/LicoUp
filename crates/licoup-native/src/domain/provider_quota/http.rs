//! Bounded HTTP fetches for provider quota endpoints.
//!
//! Credentials travel only in request headers built in memory; responses are
//! bounded in size and only the parsed JSON body leaves these helpers. URLs
//! are restricted to HTTPS or loopback HTTP, matching the platform URL
//! security policy.

use super::contract::QuotaFetchError;
use serde_json::Value;
use std::io::Read;
use std::sync::OnceLock;
use std::time::Duration;

pub(super) const HOSTED_FETCH_TIMEOUT: Duration = Duration::from_secs(10);
pub(super) const LOOPBACK_FETCH_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_RESPONSE_BYTES: u64 = 512 * 1024;

fn hosted_agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(2))
            .build()
    })
}

fn loopback_agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            // Loopback quota traffic must stay local and deterministic; never
            // inherit a process proxy for it.
            .try_proxy_from_env(false)
            .timeout_connect(Duration::from_secs(2))
            .build()
    })
}

fn validate_url(url: &str, code: &'static str) -> Result<(), QuotaFetchError> {
    if crate::platform::url_security::is_https_or_loopback_http_url(url) {
        Ok(())
    } else {
        Err(QuotaFetchError::new(code))
    }
}

pub(super) fn get_json_with_bearer(
    url: &str,
    bearer: &str,
    timeout: Duration,
) -> Result<Value, QuotaFetchError> {
    get_json_with_header(url, "Authorization", &format!("Bearer {bearer}"), timeout)
}

pub(super) fn get_json_with_cookie(
    url: &str,
    cookie: &str,
    timeout: Duration,
) -> Result<Value, QuotaFetchError> {
    get_json_with_header(url, "Cookie", cookie, timeout)
}

fn get_json_with_header(
    url: &str,
    header: &str,
    value: &str,
    timeout: Duration,
) -> Result<Value, QuotaFetchError> {
    validate_url(url, "quota_endpoint_url_rejected")?;
    let response = hosted_agent()
        .get(url)
        .timeout(timeout)
        .set(header, value)
        .call()
        .map_err(|_| QuotaFetchError::new("quota_endpoint_request_failed"))?;
    decode_bounded_json(response)
}

pub(super) fn post_json_loopback(
    url: &str,
    headers: &[(&str, &str)],
    timeout: Duration,
) -> Result<Value, QuotaFetchError> {
    validate_url(url, "quota_loopback_url_rejected")?;
    let mut request = loopback_agent()
        .post(url)
        .timeout(timeout)
        .set("Content-Type", "application/json");
    for (name, value) in headers {
        request = request.set(name, value);
    }
    let response = request
        .send_bytes(b"{}")
        .map_err(|_| QuotaFetchError::new("quota_loopback_request_failed"))?;
    decode_bounded_json(response)
}

fn decode_bounded_json(response: ureq::Response) -> Result<Value, QuotaFetchError> {
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take(MAX_RESPONSE_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| QuotaFetchError::new("quota_response_read_failed"))?;
    if bytes.len() as u64 > MAX_RESPONSE_BYTES {
        return Err(QuotaFetchError::new("quota_response_too_large"));
    }
    serde_json::from_slice(&bytes).map_err(|_| QuotaFetchError::new("quota_response_invalid_json"))
}
