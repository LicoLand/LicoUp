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
        let url = super::serve_transport::workspace_request_url(
            &endpoint.attach_url,
            &["session", &config.requested_session_id],
            &config.cwd,
        )?;
        return match super::super::opencode_serve::get_json(&url) {
            Ok(payload) if payload.get("id").and_then(Value::as_str).is_some() => {
                Ok(config.requested_session_id.clone())
            }
            Ok(_) => Err(ProtocolFailure::new(
                "acp_native_session_not_found",
                "The requested native conversation does not exist in the ACP agent.",
                "session/load",
            )
            .with_session(Some(&config.requested_session_id))),
            Err(failure) => Err(super::serve_transport::request_failure(
                failure,
                "session/load",
                Some(&config.requested_session_id),
            )),
        };
    }

    let timeout = super::serve_transport::remaining_turn_timeout(deadline)?;
    let url = super::serve_transport::workspace_request_url(
        &endpoint.attach_url,
        &["session"],
        &config.cwd,
    )?;
    let body = build_session_create_body();
    let created =
        super::super::opencode_serve::post_json_with_optional_timeout(&url, &body, timeout)
            .map_err(|failure| {
                if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                    super::serve_transport::turn_timeout_failure()
                } else {
                    super::serve_transport::request_failure(failure, "session/new", None)
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

pub(super) fn build_session_create_body() -> Value {
    json!({})
}
