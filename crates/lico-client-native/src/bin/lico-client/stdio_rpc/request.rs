use super::*;

pub(crate) fn parse_stdio_rpc_request(
    bytes: &[u8],
) -> std::result::Result<StdioRpcRequest, StdioRpcRequestError> {
    let value = serde_json::from_slice::<Value>(bytes).map_err(|_| StdioRpcRequestError {
        id: None,
        workflow_id: None,
        code: "invalid_json",
    })?;
    let object = value.as_object().ok_or_else(|| StdioRpcRequestError {
        id: None,
        workflow_id: None,
        code: "invalid_request",
    })?;
    if object.get("protocol").and_then(Value::as_str) != Some(STDIO_RPC_PROTOCOL) {
        return Err(StdioRpcRequestError {
            id: None,
            workflow_id: None,
            code: "invalid_protocol",
        });
    }
    let id = object
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| valid_rpc_identifier(value))
        .map(str::to_string);
    let workflow_id = object
        .get("workflowId")
        .and_then(Value::as_str)
        .filter(|value| valid_rpc_identifier(value))
        .map(str::to_string);
    let invalid = |code| StdioRpcRequestError {
        id: id.clone(),
        workflow_id: workflow_id.clone(),
        code,
    };
    let request_id = id.clone().ok_or_else(|| invalid("invalid_request_id"))?;
    let request_workflow_id = workflow_id
        .clone()
        .ok_or_else(|| invalid("invalid_workflow_id"))?;
    let method = object
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("invalid_method"))?;
    let method = match method {
        "execute" => {
            let args = object
                .get("args")
                .and_then(Value::as_array)
                .filter(|args| !args.is_empty() && args.len() <= STDIO_RPC_MAX_ARGS)
                .ok_or_else(|| invalid("invalid_args"))?
                .iter()
                .map(|value| value.as_str().map(str::to_string))
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| invalid("invalid_args"))?;
            let portable_data_dir = parse_portable_data_dir(object, &invalid)?;
            StdioRpcMethod::Execute {
                args,
                portable_data_dir,
            }
        }
        "catalog.status" | "catalog.invalidate" | "catalog.refresh" | "catalog.receipt"
        | "catalog.purge" | "catalog.reconnect" | "catalog.list" | "catalog.observe" => {
            let operation = method
                .strip_prefix("catalog.")
                .unwrap_or(method)
                .to_string();
            let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
            if !params.is_object() {
                return Err(invalid("invalid_params"));
            }
            let portable_data_dir = parse_portable_data_dir(object, &invalid)?;
            StdioRpcMethod::Catalog {
                operation,
                params,
                portable_data_dir,
            }
        }
        "agent.conversation.open"
        | "agent.conversation.send"
        | "agent.conversation.cancel"
        | "agent.conversation.capabilities"
        | "agent.conversation.stream" => {
            let operation = method
                .strip_prefix("agent.conversation.")
                .unwrap_or(method)
                .to_string();
            let params = object.get("params").cloned().unwrap_or_else(|| json!({}));
            if !params.is_object() {
                return Err(invalid("invalid_params"));
            }
            let portable_data_dir = parse_portable_data_dir(object, &invalid)?;
            StdioRpcMethod::Conversation {
                operation,
                params,
                portable_data_dir,
            }
        }
        "shutdown" => StdioRpcMethod::Shutdown,
        _ => return Err(invalid("invalid_method")),
    };
    Ok(StdioRpcRequest {
        id: request_id,
        workflow_id: request_workflow_id,
        method,
    })
}

fn parse_portable_data_dir(
    object: &serde_json::Map<String, Value>,
    invalid: &impl Fn(&'static str) -> StdioRpcRequestError,
) -> std::result::Result<Option<PathBuf>, StdioRpcRequestError> {
    match object.get("portableDataDir") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => {
            let path = PathBuf::from(value);
            if !path.is_absolute() {
                return Err(invalid("invalid_portable_data_dir"));
            }
            Ok(Some(path))
        }
        _ => Err(invalid("invalid_portable_data_dir")),
    }
}

pub(crate) fn valid_rpc_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= STDIO_RPC_MAX_ID_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

pub(crate) fn rpc_command_writes_external_stdout(args: &[String]) -> bool {
    args.first().map(String::as_str) == Some("conversations")
        && args.get(1).map(String::as_str) == Some("stream")
}

pub(crate) fn rpc_command_reads_external_stdin(args: &[String]) -> bool {
    args.windows(2).any(|pair| pair == ["--stdin-json", "true"])
}
