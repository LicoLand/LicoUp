//! Local MCP server for querying LicoUp-owned conversations.
//!
//! Tools: list / get / search / export / import against the parent-owned
//! projection store. Does not rewrite third-party native agent history.

use licoup_native::domain::owned_conversations::{
    OwnedConversationMatchMode, export_owned_conversations, get_owned_conversation,
    import_owned_conversations, list_owned_conversations, search_owned_conversations,
};
use serde_json::{Map, Value, json};
use std::{
    io::{self, BufRead, Write},
    process::ExitCode,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};

const MCP_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "lico-up-conversations";
const SERVER_VERSION: &str = "0.1.0";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;

fn main() -> ExitCode {
    let shared = Arc::new(ServerState::new());
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    loop {
        match read_line_bounded(&mut reader) {
            InputFrame::Eof => break,
            InputFrame::Oversized(prefix) => {
                write_json(&shared.output, rpc_error(extract_id(&prefix), -32600));
            }
            InputFrame::Line(line) => process_line(&shared, &line),
        }
    }
    ExitCode::SUCCESS
}

struct ServerState {
    initialized: AtomicBool,
    output: Mutex<io::Stdout>,
}

impl ServerState {
    fn new() -> Self {
        Self {
            initialized: AtomicBool::new(false),
            output: Mutex::new(io::stdout()),
        }
    }
}

enum InputFrame {
    Eof,
    Line(Vec<u8>),
    Oversized(Vec<u8>),
}

fn read_line_bounded(reader: &mut impl BufRead) -> InputFrame {
    let mut bytes = Vec::with_capacity(1024);
    let mut oversized = false;
    loop {
        let available = match reader.fill_buf() {
            Ok(value) => value,
            Err(_) => return InputFrame::Eof,
        };
        if available.is_empty() {
            if bytes.is_empty() && !oversized {
                return InputFrame::Eof;
            }
            return if oversized {
                InputFrame::Oversized(bytes)
            } else {
                InputFrame::Line(bytes)
            };
        }
        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(available.len(), |index| index + 1);
        let slice = &available[..consumed];
        if !oversized {
            let remaining = MAX_MCP_FRAME_BYTES
                .saturating_add(1)
                .saturating_sub(bytes.len());
            bytes.extend_from_slice(&slice[..slice.len().min(remaining)]);
            oversized = bytes.len() > MAX_MCP_FRAME_BYTES || slice.len() > remaining;
        }
        let reached_newline = slice.last() == Some(&b'\n');
        reader.consume(consumed);
        if reached_newline {
            if bytes.last() == Some(&b'\n') {
                bytes.pop();
            }
            return if oversized {
                InputFrame::Oversized(bytes)
            } else {
                InputFrame::Line(bytes)
            };
        }
    }
}

fn process_line(shared: &Arc<ServerState>, line: &[u8]) {
    let value: Value = match serde_json::from_slice(line) {
        Ok(value) => value,
        Err(_) => {
            write_json(&shared.output, rpc_error(Value::Null, -32700));
            return;
        }
    };
    let Some(object) = value.as_object() else {
        write_json(&shared.output, rpc_error(Value::Null, -32600));
        return;
    };
    let id = object.get("id").cloned();
    let method = object.get("method").and_then(Value::as_str);
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0") || method.is_none() {
        write_json(&shared.output, rpc_error(id.unwrap_or(Value::Null), -32600));
        return;
    }
    let method = method.unwrap_or_default();
    if id.is_none() {
        if method == "notifications/initialized" || method == "notifications/cancelled" {
            return;
        }
        return;
    }
    let id = id.unwrap_or(Value::Null);
    match method {
        "initialize" => initialize(shared, id, object.get("params")),
        "ping" => write_json(&shared.output, rpc_success(id, json!({}))),
        "tools/list" => {
            if !shared.initialized.load(Ordering::Acquire) {
                write_json(&shared.output, rpc_error(id, -32002));
            } else if !empty_object(object.get("params")) {
                write_json(&shared.output, rpc_error(id, -32602));
            } else {
                write_json(
                    &shared.output,
                    rpc_success(id, json!({"tools": tool_catalog()})),
                );
            }
        }
        "tools/call" => call_tool(shared, id, object.get("params")),
        _ => write_json(&shared.output, rpc_error(id, -32601)),
    }
}

fn initialize(shared: &ServerState, id: Value, params: Option<&Value>) {
    let Some(object) = params.and_then(Value::as_object) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    if object.get("protocolVersion").and_then(Value::as_str) != Some(MCP_VERSION)
        || !object.get("capabilities").is_some_and(Value::is_object)
        || !object.get("clientInfo").is_some_and(Value::is_object)
    {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    }
    shared.initialized.store(true, Ordering::Release);
    write_json(
        &shared.output,
        rpc_success(
            id,
            json!({
                "protocolVersion": MCP_VERSION,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}
            }),
        ),
    );
}

fn call_tool(shared: &ServerState, id: Value, params: Option<&Value>) {
    if !shared.initialized.load(Ordering::Acquire) {
        write_json(&shared.output, rpc_error(id, -32002));
        return;
    }
    let Some(object) = params.and_then(Value::as_object) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    let Some(name) = object.get("name").and_then(Value::as_str) else {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    };
    let arguments = object
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));
    if !arguments.is_object() {
        write_json(&shared.output, rpc_error(id, -32602));
        return;
    }
    let response = match execute_tool(name, &arguments) {
        Ok(value) => tool_success(id, value),
        Err(code) => tool_error(id, code),
    };
    write_json(&shared.output, response);
}

fn execute_tool(name: &str, arguments: &Value) -> Result<Value, String> {
    let object = arguments
        .as_object()
        .ok_or_else(|| "invalid_arguments".to_owned())?;
    match name {
        "lico_conversation_list" => {
            ensure_only_keys(object, &["limit"])?;
            let limit = object
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(50)
                .min(100) as usize;
            list_owned_conversations(limit).map_err(|error| error.to_string())
        }
        "lico_conversation_get" => {
            ensure_only_keys(object, &["conversationId", "id"])?;
            let id = object
                .get("conversationId")
                .or_else(|| object.get("id"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            if id.trim().is_empty() {
                return Err("conversation_id_required".into());
            }
            get_owned_conversation(id).map_err(|error| error.to_string())
        }
        "lico_conversation_search" => {
            ensure_only_keys(object, &["query", "matchMode", "limit"])?;
            let query = object
                .get("query")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if query.trim().is_empty() {
                return Err("query_required".into());
            }
            let mode = OwnedConversationMatchMode::parse(
                object
                    .get("matchMode")
                    .and_then(Value::as_str)
                    .unwrap_or("keyword"),
            )
            .map_err(|error| error.to_string())?;
            let limit = object
                .get("limit")
                .and_then(Value::as_u64)
                .unwrap_or(50)
                .min(100) as usize;
            search_owned_conversations(query, mode, limit).map_err(|error| error.to_string())
        }
        "lico_conversation_export" => {
            ensure_only_keys(object, &["path", "conversationIds"])?;
            let path = object
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if path.trim().is_empty() {
                return Err("path_required".into());
            }
            let ids = object
                .get("conversationIds")
                .and_then(Value::as_array)
                .map(|values| {
                    values
                        .iter()
                        .filter_map(|value| value.as_str().map(str::to_owned))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            export_owned_conversations(path, &ids).map_err(|error| error.to_string())
        }
        "lico_conversation_import" => {
            ensure_only_keys(object, &["path", "replaceExisting"])?;
            let path = object
                .get("path")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if path.trim().is_empty() {
                return Err("path_required".into());
            }
            let replace = object
                .get("replaceExisting")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            import_owned_conversations(path, replace).map_err(|error| error.to_string())
        }
        _ => Err("tool_not_found".into()),
    }
}

fn ensure_only_keys(object: &Map<String, Value>, allowed: &[&str]) -> Result<(), String> {
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(format!("unexpected_argument:{key}"));
        }
    }
    Ok(())
}

fn tool_catalog() -> Vec<Value> {
    vec![
        json!({
            "name": "lico_conversation_list",
            "description": "List LicoUp-owned conversations (local projections and the Lico group room).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100}
                },
                "additionalProperties": false
            }
        }),
        json!({
            "name": "lico_conversation_get",
            "description": "Exact lookup of one LicoUp-owned conversation by local id or nativeSessionId.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "conversationId": {"type": "string", "minLength": 1, "maxLength": 256},
                    "id": {"type": "string", "minLength": 1, "maxLength": 256}
                },
                "additionalProperties": false
            }
        }),
        json!({
            "name": "lico_conversation_search",
            "description": "Search LicoUp-owned conversations by keyword or regular expression across title, ids, paths, and message text.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "minLength": 1, "maxLength": 4096},
                    "matchMode": {"type": "string", "enum": ["keyword", "regex"]},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 100}
                },
                "required": ["query"],
                "additionalProperties": false
            }
        }),
        json!({
            "name": "lico_conversation_export",
            "description": "Export LicoUp-owned conversations to a JSON bundle path. Omit conversationIds to export all (bounded).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "minLength": 1, "maxLength": 4096},
                    "conversationIds": {
                        "type": "array",
                        "items": {"type": "string", "minLength": 1, "maxLength": 256},
                        "maxItems": 500
                    }
                },
                "required": ["path"],
                "additionalProperties": false
            }
        }),
        json!({
            "name": "lico_conversation_import",
            "description": "Import a LicoUp-owned conversation export bundle into the local projection store. Never writes third-party native history.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "minLength": 1, "maxLength": 4096},
                    "replaceExisting": {"type": "boolean"}
                },
                "required": ["path"],
                "additionalProperties": false
            }
        }),
    ]
}

fn tool_success(id: Value, payload: Value) -> Value {
    rpc_success(
        id,
        json!({
            "content": [{
                "type": "text",
                "text": payload.to_string()
            }],
            "structuredContent": payload,
            "isError": false
        }),
    )
}

fn tool_error(id: Value, code: String) -> Value {
    rpc_success(
        id,
        json!({
            "content": [{
                "type": "text",
                "text": json!({"ok": false, "code": code}).to_string()
            }],
            "structuredContent": {"ok": false, "code": code},
            "isError": true
        }),
    )
}

fn empty_object(params: Option<&Value>) -> bool {
    match params {
        None => true,
        Some(Value::Object(object)) => object.is_empty(),
        Some(Value::Null) => true,
        _ => false,
    }
}

fn write_json(output: &Mutex<io::Stdout>, value: Value) {
    let mut guard = output.lock().unwrap_or_else(|error| error.into_inner());
    let _ = writeln!(guard, "{value}");
    let _ = guard.flush();
}

fn rpc_success(id: Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn rpc_error(id: Value, code: i64) -> Value {
    let message = match code {
        -32700 => "Parse error",
        -32600 => "Invalid Request",
        -32601 => "Method not found",
        -32602 => "Invalid params",
        -32002 => "Server not initialized",
        _ => "Internal error",
    };
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

fn extract_id(prefix: &[u8]) -> Value {
    serde_json::from_slice::<Value>(prefix)
        .ok()
        .and_then(|value| value.get("id").cloned())
        .unwrap_or(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_catalog_names_are_stable() {
        let names: Vec<_> = tool_catalog()
            .into_iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str).map(str::to_owned))
            .collect();
        assert_eq!(
            names,
            vec![
                "lico_conversation_list",
                "lico_conversation_get",
                "lico_conversation_search",
                "lico_conversation_export",
                "lico_conversation_import",
            ]
        );
    }
}
