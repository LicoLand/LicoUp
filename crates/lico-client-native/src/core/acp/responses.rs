use super::types::{validate_implementation_value, validate_session_update_text};
use super::validation::{
    ensure_message_limit, normalized_text, optional_object, validate_optional_meta,
    validated_session_id,
};
use super::{
    AcpAgentCapabilities, AcpError, AcpInitializeResponse, AcpPromptResponse, AcpRequestId,
    AcpSessionMethod, AcpSessionResponse, AcpSessionUpdate, AcpSessionUpdateKind, AcpStopReason,
    DEFAULT_MAX_MESSAGE_BYTES, JSON_RPC_VERSION, PROTOCOL_VERSION, SESSION_UPDATE_METHOD,
};
use serde_json::{Map, Value};

pub fn validate_initialize_response(
    message: &Value,
    expected_id: impl Into<AcpRequestId>,
) -> Result<AcpInitializeResponse, AcpError> {
    let result = validated_result(message, expected_id.into())?
        .as_object()
        .ok_or(AcpError::ResultInvalid)?;
    let protocol_version = result
        .get("protocolVersion")
        .and_then(Value::as_u64)
        .and_then(|version| u16::try_from(version).ok())
        .ok_or(AcpError::ProtocolVersionInvalid)?;
    if protocol_version != PROTOCOL_VERSION {
        return Err(AcpError::UnsupportedProtocolVersion {
            received: protocol_version,
        });
    }
    if let Some(auth_methods) = result.get("authMethods")
        && !auth_methods.is_array()
    {
        return Err(AcpError::CapabilityInvalid);
    }
    if let Some(agent_info) = result.get("agentInfo")
        && !agent_info.is_null()
    {
        validate_implementation_value(agent_info)?;
    }

    let empty_capabilities = Map::new();
    let capabilities =
        optional_object(result.get("agentCapabilities"), AcpError::CapabilityInvalid)?
            .unwrap_or(&empty_capabilities);
    let empty_session_capabilities = Map::new();
    let session_capabilities = optional_object(
        capabilities.get("sessionCapabilities"),
        AcpError::CapabilityInvalid,
    )?
    .unwrap_or(&empty_session_capabilities);
    let empty_prompt_capabilities = Map::new();
    let prompt_capabilities = optional_object(
        capabilities.get("promptCapabilities"),
        AcpError::CapabilityInvalid,
    )?
    .unwrap_or(&empty_prompt_capabilities);
    let empty_mcp_capabilities = Map::new();
    let mcp_capabilities = optional_object(
        capabilities.get("mcpCapabilities"),
        AcpError::CapabilityInvalid,
    )?
    .unwrap_or(&empty_mcp_capabilities);

    Ok(AcpInitializeResponse {
        protocol_version,
        capabilities: AcpAgentCapabilities {
            load_session: optional_bool(capabilities, "loadSession")?,
            resume_session: capability_marker(session_capabilities, "resume")?,
            close_session: capability_marker(session_capabilities, "close")?,
            list_sessions: capability_marker(session_capabilities, "list")?,
            delete_session: capability_marker(session_capabilities, "delete")?,
            additional_directories: capability_marker(
                session_capabilities,
                "additionalDirectories",
            )?,
            image_prompts: optional_bool(prompt_capabilities, "image")?,
            audio_prompts: optional_bool(prompt_capabilities, "audio")?,
            embedded_context: optional_bool(prompt_capabilities, "embeddedContext")?,
            mcp_http: optional_bool(mcp_capabilities, "http")?,
            mcp_sse: optional_bool(mcp_capabilities, "sse")?,
        },
    })
}

pub fn validate_session_response(
    message: &Value,
    expected_id: impl Into<AcpRequestId>,
    method: AcpSessionMethod<'_>,
) -> Result<AcpSessionResponse, AcpError> {
    let result = validated_result(message, expected_id.into())?;
    if let AcpSessionMethod::Load(requested) = method {
        validated_session_id(requested)?;
        if !result.is_null() {
            return Err(AcpError::SessionResponseInvalid);
        }
        return Ok(AcpSessionResponse {
            session_id: None,
            modes: None,
            config_options: Vec::new(),
        });
    }
    let result = result.as_object().ok_or(AcpError::SessionResponseInvalid)?;
    let session_id = result
        .get("sessionId")
        .map(|value| {
            value
                .as_str()
                .ok_or(AcpError::SessionResponseInvalid)
                .and_then(validated_session_id)
                .map(str::to_owned)
        })
        .transpose()?;
    match method {
        AcpSessionMethod::New if session_id.is_none() => {
            return Err(AcpError::SessionResponseInvalid);
        }
        AcpSessionMethod::Resume(requested) => {
            validated_session_id(requested)?;
        }
        AcpSessionMethod::Load(_) => unreachable!("load responses return before object parsing"),
        AcpSessionMethod::New => {}
    }
    let modes = match result.get("modes") {
        None | Some(Value::Null) => None,
        Some(value @ Value::Object(_)) => Some(value.clone()),
        Some(_) => return Err(AcpError::SessionResponseInvalid),
    };
    let config_options = match result.get("configOptions") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(options)) => options.clone(),
        Some(_) => return Err(AcpError::SessionResponseInvalid),
    };
    Ok(AcpSessionResponse {
        session_id,
        modes,
        config_options,
    })
}

pub fn validate_prompt_response(
    message: &Value,
    expected_id: impl Into<AcpRequestId>,
) -> Result<AcpPromptResponse, AcpError> {
    let result = validated_result(message, expected_id.into())?
        .as_object()
        .ok_or(AcpError::ResultInvalid)?;
    let stop_reason = match result.get("stopReason").and_then(Value::as_str) {
        Some("end_turn") => AcpStopReason::EndTurn,
        Some("max_tokens") => AcpStopReason::MaxTokens,
        Some("max_turn_requests") => AcpStopReason::MaxTurnRequests,
        Some("refusal") => AcpStopReason::Refusal,
        Some("cancelled") => AcpStopReason::Cancelled,
        Some(_) => return Err(AcpError::StopReasonInvalid),
        None => return Err(AcpError::PromptResponseInvalid),
    };
    Ok(AcpPromptResponse { stop_reason })
}

pub fn validate_session_update(
    message: &Value,
    expected_session_id: Option<&str>,
) -> Result<AcpSessionUpdate, AcpError> {
    ensure_message_limit(message)?;
    let envelope = message
        .as_object()
        .ok_or(AcpError::NotificationEnvelopeInvalid)?;
    if !envelope
        .keys()
        .all(|key| matches!(key.as_str(), "jsonrpc" | "method" | "params"))
    {
        return Err(AcpError::NotificationEnvelopeInvalid);
    }
    if envelope.get("jsonrpc").and_then(Value::as_str) != Some(JSON_RPC_VERSION) {
        return Err(AcpError::JsonRpcVersionInvalid);
    }
    if envelope.get("method").and_then(Value::as_str) != Some(SESSION_UPDATE_METHOD) {
        return Err(AcpError::NotificationMethodInvalid);
    }
    let params = envelope
        .get("params")
        .and_then(Value::as_object)
        .ok_or(AcpError::SessionUpdateInvalid)?;
    if !params
        .keys()
        .all(|key| matches!(key.as_str(), "sessionId" | "update" | "_meta"))
    {
        return Err(AcpError::SessionUpdateInvalid);
    }
    validate_optional_meta(params.get("_meta"), AcpError::SessionUpdateInvalid)?;
    let session_id = params
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or(AcpError::SessionUpdateInvalid)
        .and_then(validated_session_id)?;
    if let Some(expected_session_id) = expected_session_id {
        validated_session_id(expected_session_id)?;
        if session_id != expected_session_id {
            return Err(AcpError::SessionMismatch);
        }
    }
    let update = params
        .get("update")
        .and_then(Value::as_object)
        .ok_or(AcpError::SessionUpdateInvalid)?;
    let kind = match update.get("sessionUpdate").and_then(Value::as_str) {
        Some("user_message_chunk") => AcpSessionUpdateKind::UserMessageChunk,
        Some("agent_message_chunk") => AcpSessionUpdateKind::AgentMessageChunk,
        Some("agent_thought_chunk") => AcpSessionUpdateKind::AgentThoughtChunk,
        Some("tool_call") => AcpSessionUpdateKind::ToolCall,
        Some("tool_call_update") => AcpSessionUpdateKind::ToolCallUpdate,
        Some("plan") => AcpSessionUpdateKind::Plan,
        Some("available_commands_update") => AcpSessionUpdateKind::AvailableCommandsUpdate,
        Some("current_mode_update") => AcpSessionUpdateKind::CurrentModeUpdate,
        Some("config_option_update") => AcpSessionUpdateKind::ConfigOptionUpdate,
        Some("session_info_update") => AcpSessionUpdateKind::SessionInfoUpdate,
        Some("usage_update") => AcpSessionUpdateKind::UsageUpdate,
        _ => return Err(AcpError::SessionUpdateInvalid),
    };
    match kind {
        AcpSessionUpdateKind::UserMessageChunk
        | AcpSessionUpdateKind::AgentMessageChunk
        | AcpSessionUpdateKind::AgentThoughtChunk
            if !matches!(update.get("content"), Some(Value::Object(_))) =>
        {
            return Err(AcpError::SessionUpdateInvalid);
        }
        AcpSessionUpdateKind::CurrentModeUpdate => {
            let mode = update
                .get("currentModeId")
                .and_then(Value::as_str)
                .ok_or(AcpError::SessionUpdateInvalid)?;
            validate_session_update_text(mode)?;
        }
        AcpSessionUpdateKind::ConfigOptionUpdate
            if !matches!(update.get("configOptions"), Some(Value::Array(_))) =>
        {
            return Err(AcpError::SessionUpdateInvalid);
        }
        AcpSessionUpdateKind::UsageUpdate
            if update.get("used").and_then(Value::as_u64).is_none()
                || update.get("size").and_then(Value::as_u64).is_none() =>
        {
            return Err(AcpError::SessionUpdateInvalid);
        }
        _ => {}
    }
    Ok(AcpSessionUpdate {
        session_id: session_id.to_owned(),
        kind,
        update: Value::Object(update.clone()),
    })
}

pub fn validate_close_session_response(
    message: &Value,
    expected_id: impl Into<AcpRequestId>,
) -> Result<(), AcpError> {
    let result = validated_result(message, expected_id.into())?
        .as_object()
        .ok_or(AcpError::CloseResponseInvalid)?;
    if !result.keys().all(|key| key == "_meta") {
        return Err(AcpError::CloseResponseInvalid);
    }
    validate_optional_meta(result.get("_meta"), AcpError::CloseResponseInvalid)
}

fn validated_result(message: &Value, expected_id: AcpRequestId) -> Result<&Value, AcpError> {
    expected_id.validate()?;
    ensure_message_limit(message)?;
    let envelope = message
        .as_object()
        .ok_or(AcpError::ResponseEnvelopeInvalid)?;
    if !envelope
        .keys()
        .all(|key| matches!(key.as_str(), "jsonrpc" | "id" | "result" | "error"))
    {
        return Err(AcpError::ResponseEnvelopeInvalid);
    }
    if envelope.get("jsonrpc").and_then(Value::as_str) != Some(JSON_RPC_VERSION) {
        return Err(AcpError::JsonRpcVersionInvalid);
    }
    let response_id = envelope
        .get("id")
        .ok_or(AcpError::ResponseIdInvalid)
        .and_then(AcpRequestId::from_value)?;
    if response_id != expected_id {
        return Err(AcpError::ResponseIdMismatch);
    }
    let has_result = envelope.contains_key("result");
    let has_error = envelope.contains_key("error");
    if has_result == has_error {
        return Err(AcpError::ResponseOutcomeInvalid);
    }
    if let Some(error) = envelope.get("error") {
        let error = error.as_object().ok_or(AcpError::ResponseOutcomeInvalid)?;
        if !error
            .keys()
            .all(|key| matches!(key.as_str(), "code" | "message" | "data"))
        {
            return Err(AcpError::ResponseOutcomeInvalid);
        }
        let code = error
            .get("code")
            .and_then(Value::as_i64)
            .ok_or(AcpError::ResponseOutcomeInvalid)?;
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .ok_or(AcpError::ResponseOutcomeInvalid)?;
        normalized_text(
            message,
            DEFAULT_MAX_MESSAGE_BYTES,
            AcpError::ResponseOutcomeInvalid,
        )?;
        return Err(AcpError::RemoteError { code });
    }
    envelope.get("result").ok_or(AcpError::ResultInvalid)
}

fn optional_bool(object: &Map<String, Value>, key: &str) -> Result<bool, AcpError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(AcpError::CapabilityInvalid),
    }
}

fn capability_marker(object: &Map<String, Value>, key: &str) -> Result<bool, AcpError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Object(_)) => Ok(true),
        Some(_) => Err(AcpError::CapabilityInvalid),
    }
}
