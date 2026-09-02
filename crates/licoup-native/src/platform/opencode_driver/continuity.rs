use super::super::acp_driver_runtime::{ProtocolConfig, ProtocolFailure};
use super::super::opencode_serve::ServeEndpoint;
use serde_json::{Value, json};
use std::time::Instant;

pub(super) fn open_serve_session(
    endpoint: &ServeEndpoint,
    config: &ProtocolConfig,
    deadline: Option<Instant>,
) -> Result<String, ProtocolFailure> {
    if config.is_resume() {
        let url = format!(
            "{}/session/{}",
            endpoint.attach_url, config.requested_session_id
        );
        return match super::super::opencode_serve::get_json(&url) {
            Ok(payload) if payload.get("id").and_then(Value::as_str).is_some() => {
                Ok(config.requested_session_id.clone())
            }
            Ok(_) | Err(_) => Err(ProtocolFailure::new(
                "acp_native_session_not_found",
                "The requested native conversation does not exist in the ACP agent.",
                "session/load",
            )
            .with_session(Some(&config.requested_session_id))),
        };
    }

    let timeout = super::serve_transport::remaining_turn_timeout(deadline)?;
    let body = if config.cwd.is_empty() {
        json!({})
    } else {
        json!({"directory": config.cwd})
    };
    let created = super::super::opencode_serve::post_json_with_optional_timeout(
        &format!("{}/session", endpoint.attach_url),
        &body,
        timeout,
    )
    .map_err(|_| {
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            super::serve_transport::turn_timeout_failure()
        } else {
            ProtocolFailure::new(
                "acp_protocol_write_failed",
                "The ACP agent stopped accepting protocol messages.",
                "serve/http",
            )
        }
    })?;
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
        })
}
