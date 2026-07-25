use std::time::Duration;

use anyhow::{Result, anyhow, ensure};
use serde_json::Value;
use url::Url;

use crate::platform::url_security::is_https_or_loopback_http_url;

use super::contract::{
    HTTP_TIMEOUT_SECONDS, MAX_RETRY_AFTER_SECONDS, SESSION_COOKIE_NAME, SecureClientRelayAuth,
    SecureClientRelayRequest, SecureClientRelayResponseHead,
};
use super::response_codec::{decode_error_code, decode_success_response};
use super::status_projection::project_http_error;

pub(super) struct SecureClientRelayHttpClient {
    base_url: String,
    auth: SecureClientRelayAuth,
}

impl SecureClientRelayHttpClient {
    pub(super) fn new(base_url: impl Into<String>, auth: SecureClientRelayAuth) -> Result<Self> {
        let base_url = validate_base_url(base_url.into())?;
        Ok(Self { base_url, auth })
    }

    pub(super) fn post(&self, request: SecureClientRelayRequest) -> Result<Value> {
        let operation = request.operation;
        let url = format!("{}{}", self.base_url, operation.path());
        let cookie = format!("{SESSION_COOKIE_NAME}={}", self.auth.session_token());
        let response = ureq::post(&url)
            .timeout(Duration::from_secs(HTTP_TIMEOUT_SECONDS))
            .set("accept", "application/json")
            .set("content-type", "application/json")
            .set("cookie", &cookie)
            .set("x-lico-csrf", self.auth.csrf_token())
            .set("x-lico-safety-confirm", "true")
            .send_json(request.body);
        match response {
            Ok(response) => {
                let head = response_head(&response);
                decode_success_response(
                    operation,
                    head.content_type.as_deref(),
                    response.into_reader(),
                )
            }
            Err(ureq::Error::Status(status, response)) => {
                let head = response_head(&response);
                let code = decode_error_code(head.content_type.as_deref(), response.into_reader())
                    .unwrap_or_else(|_| "secure_client_relay_http_error".to_string());
                Err(anyhow::Error::new(project_http_error(
                    operation,
                    status,
                    code,
                    head.retry_after_seconds,
                )))
            }
            Err(ureq::Error::Transport(_)) => Err(anyhow!(
                "secure client relay {} transport failed",
                operation.key()
            )),
        }
    }
}

fn validate_base_url(base_url: String) -> Result<String> {
    ensure!(
        !base_url.trim().is_empty() && base_url == base_url.trim() && !base_url.ends_with('/'),
        "secure client relay base URL is invalid"
    );
    let parsed =
        Url::parse(&base_url).map_err(|_| anyhow!("secure client relay base URL is invalid"))?;
    ensure!(
        !parsed.cannot_be_a_base()
            && parsed.username().is_empty()
            && parsed.password().is_none()
            && parsed.query().is_none()
            && parsed.fragment().is_none()
            && parsed.path() == "/",
        "secure client relay base URL is invalid"
    );
    ensure!(
        is_https_or_loopback_http_url(&base_url),
        "secure client relay requires HTTPS except for loopback endpoints"
    );
    Ok(base_url)
}

fn response_head(response: &ureq::Response) -> SecureClientRelayResponseHead {
    SecureClientRelayResponseHead {
        content_type: response.header("content-type").map(str::to_string),
        retry_after_seconds: response
            .header("retry-after")
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
            .and_then(|value| value.parse::<u64>().ok())
            .filter(|seconds| *seconds <= MAX_RETRY_AFTER_SECONDS),
    }
}
