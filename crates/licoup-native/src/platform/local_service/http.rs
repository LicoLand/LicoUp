use serde_json::Value;
use std::io::Read;
use std::sync::OnceLock;
use std::time::Duration;
use url::Url;

use super::bounds::{
    CONCURRENCY_WAIT, MAX_HTTP_HEADER_BYTES, MAX_HTTP_HEADER_COUNT, MAX_HTTP_IN_FLIGHT,
    MAX_HTTP_REQUEST_BODY_BYTES, MAX_HTTP_RESPONSE_BODY_BYTES,
};
use super::concurrency::{BoundedGate, LimitFailure};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum HttpFailure {
    BodyTooLarge,
    Busy,
    HeadersTooLarge,
    InvalidJson,
    InvalidUrl,
    NotFound,
    Request,
    Serialize,
    Status,
    Unavailable,
}

fn request_gate() -> &'static BoundedGate {
    static GATE: OnceLock<BoundedGate> = OnceLock::new();
    GATE.get_or_init(|| BoundedGate::new(MAX_HTTP_IN_FLIGHT))
}

pub(in crate::platform) fn get_json(url: &str, timeout: Duration) -> Result<Value, HttpFailure> {
    let url = validate_url(url)?;
    let _permit = request_gate()
        .acquire(CONCURRENCY_WAIT)
        .map_err(map_limit_failure)?;
    let request = agent(timeout).get(url.as_str());
    let response = map_response(request.call())?;
    decode_json(response)
}

pub(in crate::platform) fn post_json(
    url: &str,
    body: &Value,
    timeout: Duration,
) -> Result<Value, HttpFailure> {
    let url = validate_url(url)?;
    let bytes = serde_json::to_vec(body).map_err(|_| HttpFailure::Serialize)?;
    if bytes.len() > MAX_HTTP_REQUEST_BODY_BYTES {
        return Err(HttpFailure::BodyTooLarge);
    }
    let _permit = request_gate()
        .acquire(CONCURRENCY_WAIT)
        .map_err(map_limit_failure)?;
    let request = agent(timeout)
        .post(url.as_str())
        .set("Content-Type", "application/json");
    let response = map_response(request.send_bytes(&bytes))?;
    decode_json(response)
}

pub(in crate::platform) fn probe_status(url: &str, timeout: Duration) -> Result<u16, HttpFailure> {
    let url = validate_url(url)?;
    let _permit = request_gate()
        .acquire(CONCURRENCY_WAIT)
        .map_err(map_limit_failure)?;
    match agent(timeout).get(url.as_str()).call() {
        Ok(response) => {
            validate_headers(&response)?;
            Ok(response.status())
        }
        Err(ureq::Error::Status(status, response)) => {
            validate_headers(&response)?;
            Ok(status)
        }
        Err(_) => Err(HttpFailure::Request),
    }
}

pub(in crate::platform) fn validate_url(raw: &str) -> Result<Url, HttpFailure> {
    let url = Url::parse(raw).map_err(|_| HttpFailure::InvalidUrl)?;
    if crate::platform::url_security::is_https_or_loopback_http_url(raw) {
        Ok(url)
    } else {
        Err(HttpFailure::InvalidUrl)
    }
}

pub(in crate::platform) fn validate_headers(response: &ureq::Response) -> Result<(), HttpFailure> {
    let names = response.headers_names();
    if names.len() > MAX_HTTP_HEADER_COUNT {
        return Err(HttpFailure::HeadersTooLarge);
    }
    let total = names.iter().try_fold(0usize, |total, name| {
        response
            .all(name)
            .iter()
            .try_fold(total.saturating_add(name.len()), |subtotal, value| {
                let next = subtotal.saturating_add(value.len());
                (next <= MAX_HTTP_HEADER_BYTES).then_some(next)
            })
    });
    if total.is_none() {
        return Err(HttpFailure::HeadersTooLarge);
    }
    Ok(())
}

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        // Native serve adapters are local control planes. Never inherit a
        // process proxy here: loopback abort/prompt traffic must stay local,
        // deterministic, and independent from proxy environment state.
        .try_proxy_from_env(false)
        .timeout_connect(timeout.min(Duration::from_secs(2)))
        .timeout_read(timeout)
        .timeout_write(timeout)
        .build()
}

fn map_response(
    response: Result<ureq::Response, ureq::Error>,
) -> Result<ureq::Response, HttpFailure> {
    match response {
        Ok(response) => {
            validate_headers(&response)?;
            Ok(response)
        }
        Err(ureq::Error::Status(404, response)) => {
            validate_headers(&response)?;
            Err(HttpFailure::NotFound)
        }
        Err(ureq::Error::Status(_, response)) => {
            validate_headers(&response)?;
            Err(HttpFailure::Status)
        }
        Err(_) => Err(HttpFailure::Request),
    }
}

fn decode_json(response: ureq::Response) -> Result<Value, HttpFailure> {
    let mut bytes = Vec::new();
    response
        .into_reader()
        .take((MAX_HTTP_RESPONSE_BODY_BYTES as u64).saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| HttpFailure::Request)?;
    if bytes.len() > MAX_HTTP_RESPONSE_BODY_BYTES {
        return Err(HttpFailure::BodyTooLarge);
    }
    serde_json::from_slice(&bytes).map_err(|_| HttpFailure::InvalidJson)
}

fn map_limit_failure(failure: LimitFailure) -> HttpFailure {
    match failure {
        LimitFailure::Busy => HttpFailure::Busy,
        LimitFailure::Unavailable => HttpFailure::Unavailable,
    }
}
