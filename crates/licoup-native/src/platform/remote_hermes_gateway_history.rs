use super::hermes_tui_gateway::{GatewayClient, GatewayFailure, RUNTIME_PROTOCOL};
use super::virtual_machine::SshRuntimeConnection;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::time::{Duration, Instant};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_STDOUT_BYTES: usize = 20 * 1024 * 1024;
const MAX_STDERR_BYTES: usize = 512 * 1024;
const MAX_PAGE_LIMIT: usize = 500;
const MAX_MESSAGES: usize = 2_000;
const MAX_MESSAGE_TEXT_BYTES: usize = 2 * 1024 * 1024;

pub(crate) fn conversation_list_with_connection(
    params: &Value,
    connection: &SshRuntimeConnection,
) -> Result<Value> {
    if !connection.is_hermes_tui_gateway() {
        return Err(anyhow!("hermes_gateway_connection_required"));
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
    let deadline = Instant::now() + REQUEST_TIMEOUT;
    let mut client = GatewayClient::connect(connection, MAX_STDOUT_BYTES, MAX_STDERR_BYTES)
        .map_err(gateway_error)?;
    client.wait_ready(deadline).map_err(gateway_error)?;

    let mut sessions = if let Some(session_id) = session_id {
        let result = client
            .request(
                "session.resume",
                json!({
                    "session_id": session_id,
                    "lazy": true,
                    "source": "desktop",
                }),
                deadline,
                |_| Ok(()),
            )
            .map_err(gateway_error)?;
        vec![resumed_session_projection(
            session_id,
            connection.working_directory(),
            &result,
        )?]
    } else {
        let wanted = offset.saturating_add(limit).saturating_add(1);
        let result = client
            .request(
                "session.list",
                json!({"limit": wanted.min(MAX_PAGE_LIMIT)}),
                deadline,
                |_| Ok(()),
            )
            .map_err(gateway_error)?;
        listed_session_projections(&result, offset, limit)?
    };
    client.finish().map_err(gateway_error)?;

    let has_more = session_id.is_none() && sessions.len() > limit;
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
        "agentId": "hermes",
        "adapterId": "hermes",
        "adapterLabel": "Hermes Agent - CLI",
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
            "protocol": RUNTIME_PROTOCOL,
            "filesSeen": 0,
            "directoryEntriesSeen": 0,
            "skipped": []
        }
    }))
}

fn listed_session_projections(result: &Value, offset: usize, limit: usize) -> Result<Vec<Value>> {
    let rows = result
        .get("sessions")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("hermes_gateway_session_list_invalid"))?;
    rows.iter()
        .skip(offset)
        .take(limit.saturating_add(1))
        .map(listed_session_projection)
        .collect()
}

fn listed_session_projection(row: &Value) -> Result<Value> {
    let native_session_id = bounded_required_text(row.get("id"), 512)
        .ok_or_else(|| anyhow!("hermes_gateway_session_list_invalid"))?;
    let title = bounded_optional_text(row.get("title"), 240)
        .filter(|value| !value.is_empty())
        .or_else(|| bounded_optional_text(row.get("preview"), 240))
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "Hermes conversation".to_string());
    let created_at = epoch_timestamp(row.get("started_at"));
    let message_count = row
        .get("message_count")
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok())
        .unwrap_or(0);
    Ok(session_projection(
        &native_session_id,
        &title,
        &created_at,
        "",
        message_count,
        Vec::new(),
        false,
    ))
}

fn resumed_session_projection(
    requested_session_id: &str,
    fallback_cwd: &str,
    result: &Value,
) -> Result<Value> {
    let resumed = bounded_optional_text(
        result.get("resumed").or_else(|| result.get("session_key")),
        512,
    )
    .ok_or_else(|| anyhow!("hermes_gateway_session_resume_invalid"))?;
    if resumed != requested_session_id {
        return Err(anyhow!("hermes_gateway_session_identity_mismatch"));
    }
    let projection = project_messages(result.get("messages"))?;
    let cwd = bounded_optional_text(result.pointer("/info/cwd"), 4096)
        .filter(|value| value.starts_with('/'))
        .unwrap_or_else(|| fallback_cwd.to_string());
    let started_at = epoch_timestamp(result.get("started_at"));
    let title = bounded_optional_text(result.pointer("/info/title"), 240)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "Hermes conversation".to_string());
    Ok(session_projection(
        requested_session_id,
        &title,
        &started_at,
        &cwd,
        projection.declared_count,
        projection.messages,
        projection.truncated,
    ))
}

struct MessageProjection {
    messages: Vec<Value>,
    declared_count: usize,
    truncated: bool,
}

fn project_messages(value: Option<&Value>) -> Result<MessageProjection> {
    let rows = value
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("hermes_gateway_session_history_invalid"))?;
    let mut messages = Vec::new();
    let mut total_text_bytes = 0usize;
    let mut truncated = false;
    for (index, row) in rows.iter().enumerate() {
        if messages.len() >= MAX_MESSAGES {
            truncated = true;
            break;
        }
        let Some(role) = row.get("role").and_then(Value::as_str) else {
            continue;
        };
        let role = match role {
            "user" => "user",
            "assistant" => "assistant",
            _ => continue,
        };
        let Some(text) = bounded_optional_text(row.get("text"), MAX_MESSAGE_TEXT_BYTES) else {
            continue;
        };
        if text.is_empty() {
            continue;
        }
        total_text_bytes = total_text_bytes.saturating_add(text.len());
        if total_text_bytes > MAX_MESSAGE_TEXT_BYTES {
            truncated = true;
            break;
        }
        messages.push(json!({
            "id": format!("remote-hermes-message-{index}"),
            "role": role,
            "text": text,
            "createdAt": "",
            "layer": "thread"
        }));
    }
    Ok(MessageProjection {
        messages,
        declared_count: rows.len(),
        truncated,
    })
}

#[allow(clippy::too_many_arguments)]
fn session_projection(
    native_session_id: &str,
    title: &str,
    updated_at: &str,
    working_directory: &str,
    message_count: usize,
    messages: Vec<Value>,
    history_truncated: bool,
) -> Value {
    json!({
        "id": native_session_id,
        "agentId": "hermes",
        "adapterId": "hermes",
        "adapterLabel": "Hermes Agent - CLI",
        "sourceTool": "hermes",
        "sourceClient": "hermes",
        "sourceClientLabel": "Hermes Agent - CLI",
        "sourceLabel": "Virtual machine Hermes gateway",
        "sourceKind": "remote-hermes-gateway",
        "sourcePath": "",
        "nativeSessionId": native_session_id,
        "importMode": "precise-adapter",
        "title": title,
        "createdAt": updated_at,
        "updatedAt": updated_at,
        "workingDirectory": working_directory,
        "native": true,
        "readOnly": true,
        "exactResume": true,
        "messageCount": message_count,
        "historyTruncated": history_truncated,
        "messages": messages
    })
}

fn gateway_error(failure: GatewayFailure) -> anyhow::Error {
    anyhow!(failure.code())
}

fn unsigned_param(params: &Value, key: &str) -> Option<usize> {
    params.get(key).and_then(|value| {
        value
            .as_u64()
            .or_else(|| value.as_str()?.trim().parse().ok())
            .and_then(|value| usize::try_from(value).ok())
    })
}

fn bounded_required_text(value: Option<&Value>, max_chars: usize) -> Option<String> {
    let text = value?.as_str()?.trim();
    (!text.is_empty() && text.chars().count() <= max_chars).then(|| text.to_string())
}

fn bounded_optional_text(value: Option<&Value>, max_chars: usize) -> Option<String> {
    let text = value?.as_str()?;
    Some(text.chars().take(max_chars).collect())
}

fn epoch_timestamp(value: Option<&Value>) -> String {
    let seconds = value.and_then(|value| {
        value
            .as_f64()
            .or_else(|| value.as_i64().map(|value| value as f64))
    });
    let Some(seconds) = seconds.filter(|value| value.is_finite() && *value >= 0.0) else {
        return String::new();
    };
    OffsetDateTime::from_unix_timestamp(seconds.floor() as i64)
        .ok()
        .and_then(|timestamp| timestamp.format(&Rfc3339).ok())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn list_projection_is_bounded_and_keeps_durable_identity() {
        let result = json!({
            "sessions": [
                {
                    "id": "durable-1",
                    "title": "Visible title",
                    "preview": "preview",
                    "started_at": 1_700_000_000,
                    "message_count": 4,
                    "source": "tui"
                }
            ]
        });
        let sessions = listed_session_projections(&result, 0, 10).unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["nativeSessionId"], "durable-1");
        assert_eq!(sessions[0]["messageCount"], 4);
        assert_eq!(sessions[0]["sourcePath"], "");
    }

    #[test]
    fn resume_projection_filters_internal_and_tool_messages() {
        let result = json!({
            "resumed": "durable-1",
            "messages": [
                {"role": "system", "text": "private instructions"},
                {"role": "user", "text": "hello"},
                {"role": "tool", "name": "shell"},
                {"role": "assistant", "text": "hi"}
            ],
            "info": {"cwd": "/workspace"}
        });
        let session = resumed_session_projection("durable-1", "/fallback", &result).unwrap();
        assert_eq!(session["messages"].as_array().unwrap().len(), 2);
        assert_eq!(session["messages"][0]["role"], "user");
        assert_eq!(session["messages"][1]["role"], "assistant");
        assert_eq!(session["workingDirectory"], "/workspace");
    }

    #[test]
    fn resume_projection_rejects_cross_session_response() {
        let error = resumed_session_projection(
            "durable-1",
            "/fallback",
            &json!({
                "resumed": "durable-2",
                "messages": [],
                "info": {}
            }),
        )
        .unwrap_err();
        assert!(error.to_string().contains("identity_mismatch"));
    }
}
