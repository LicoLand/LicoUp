//! Local MCP binding for the canonical client-owned Conversation authority.
//! Framing and server semantics are shared through `core::mcp`.

use licoup_native::core::mcp::{
    McpApplication, McpApplicationError, McpServerDefinition, McpServerEngine, McpToolCallContext,
    serve_stdio,
};
use licoup_native::domain::client_conversation::ConversationService;
use licoup_native::platform::paths::portable_data_dir;
use serde_json::{Map, Value, json};
use std::io;
use std::process::ExitCode;
use std::sync::Mutex;

const MCP_VERSION: &str = "2025-06-18";
const SERVER_NAME: &str = "lico-up-conversations";
const SERVER_VERSION: &str = "0.1.0";
const MAX_MCP_FRAME_BYTES: usize = 64 * 1024;

fn main() -> ExitCode {
    let engine = McpServerEngine::new(
        McpServerDefinition {
            protocol_revision: MCP_VERSION,
            compatible_protocol_revisions: &[],
            server_name: SERVER_NAME,
            server_version: SERVER_VERSION,
            max_message_bytes: MAX_MCP_FRAME_BYTES,
        },
        ConversationMcpApplication {
            service: Mutex::new(None),
        },
    );
    let Ok(engine) = engine else {
        return ExitCode::FAILURE;
    };
    let stdin = io::stdin();
    match serve_stdio(&engine, &(), stdin.lock(), io::stdout()) {
        Ok(_) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}

struct ConversationMcpApplication {
    service: Mutex<Option<ConversationService>>,
}

impl ConversationMcpApplication {
    fn execute(&self, request: Value) -> Result<Value, McpApplicationError> {
        let mut slot = self
            .service
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let service = match slot.as_ref() {
            Some(service) => service.clone(),
            None => {
                let root = portable_data_dir().map_err(|_| state_unavailable())?;
                let service = ConversationService::open(&root).map_err(|_| state_unavailable())?;
                *slot = Some(service.clone());
                service
            }
        };
        drop(slot);
        service.execute(request).map_err(|_| state_unavailable())
    }
}

impl McpApplication for ConversationMcpApplication {
    type CallerContext = ();

    fn tool_catalog(&self) -> Vec<Value> {
        tool_catalog()
    }

    fn validate_tool_arguments(&self, name: &str, arguments: &Map<String, Value>) -> bool {
        validate(name, arguments)
    }

    fn call_tool(
        &self,
        _context: McpToolCallContext<'_, Self::CallerContext>,
        name: &str,
        arguments: &Map<String, Value>,
    ) -> Result<Value, McpApplicationError> {
        match name {
            "lico_conversation_list" => {
                let value = self.execute(json!({
                    "action": "conversation.list",
                    "includeArchived": arguments.get("includeArchived").and_then(Value::as_bool).unwrap_or(false),
                }))?;
                let limit = arguments.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
                let conversations = value.as_array().cloned().unwrap_or_default();
                Ok(json!({
                    "ok": true,
                    "total": conversations.len(),
                    "count": conversations.len().min(limit),
                    "conversations": conversations.into_iter().take(limit).collect::<Vec<_>>(),
                }))
            }
            "lico_conversation_get" => self.execute(json!({
                "action": "conversation.get",
                "conversationId": arguments["conversationId"],
            })),
            "lico_conversation_search" => {
                let value = self.execute(json!({
                    "action": "conversation.events.search",
                    "query": arguments["query"],
                    "limit": arguments.get("limit").and_then(Value::as_u64).unwrap_or(50),
                }))?;
                Ok(json!({
                    "ok": true,
                    "count": value.as_array().map(Vec::len).unwrap_or(0),
                    "events": value,
                }))
            }
            "lico_conversation_export" => self.execute(json!({
                "action": "conversation.export",
                "path": arguments["path"],
                "conversationIds": arguments.get("conversationIds").cloned().unwrap_or_else(|| json!([])),
            })),
            "lico_conversation_import" => self.execute(json!({
                "action": "conversation.import",
                "path": arguments["path"],
            })),
            _ => Err(McpApplicationError::permanent("tool_not_found", "tool/select")),
        }
    }
}

fn state_unavailable() -> McpApplicationError {
    McpApplicationError::retryable("conversation_state_unavailable", "conversation/store")
}

fn tool_catalog() -> Vec<Value> {
    vec![
        tool(
            "lico_conversation_list",
            json!({
                "limit": {"type":"integer", "minimum":1, "maximum":100},
                "includeArchived": {"type":"boolean"}
            }),
            &[],
        ),
        tool(
            "lico_conversation_get",
            json!({
                "conversationId": {"type":"string", "minLength":1, "maxLength":256}
            }),
            &["conversationId"],
        ),
        tool(
            "lico_conversation_search",
            json!({
                "query": {"type":"string", "minLength":1, "maxLength":4096},
                "limit": {"type":"integer", "minimum":1, "maximum":100}
            }),
            &["query"],
        ),
        tool(
            "lico_conversation_export",
            json!({
                "path": {"type":"string", "minLength":1, "maxLength":4096},
                "conversationIds": {"type":"array", "maxItems":500}
            }),
            &["path"],
        ),
        tool(
            "lico_conversation_import",
            json!({
                "path": {"type":"string", "minLength":1, "maxLength":4096}
            }),
            &["path"],
        ),
    ]
}

fn tool(name: &str, properties: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": name,
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": required,
        }
    })
}

fn validate(name: &str, arguments: &Map<String, Value>) -> bool {
    let allowed: &[&str] = match name {
        "lico_conversation_list" => &["limit", "includeArchived"],
        "lico_conversation_get" => &["conversationId"],
        "lico_conversation_search" => &["query", "limit"],
        "lico_conversation_export" => &["path", "conversationIds"],
        "lico_conversation_import" => &["path"],
        _ => return false,
    };
    if arguments.keys().any(|key| !allowed.contains(&key.as_str())) {
        return false;
    }
    match name {
        "lico_conversation_list" => {
            optional_limit(arguments)
                && arguments
                    .get("includeArchived")
                    .is_none_or(Value::is_boolean)
        }
        "lico_conversation_get" => bounded_text(arguments.get("conversationId"), 256),
        "lico_conversation_search" => {
            bounded_text(arguments.get("query"), 4096) && optional_limit(arguments)
        }
        "lico_conversation_export" => {
            bounded_text(arguments.get("path"), 4096)
                && arguments
                    .get("conversationIds")
                    .is_none_or(|value| value.as_array().is_some_and(|values| values.len() <= 500))
        }
        "lico_conversation_import" => bounded_text(arguments.get("path"), 4096),
        _ => false,
    }
}

fn bounded_text(value: Option<&Value>, max: usize) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|value| !value.is_empty() && value.len() <= max)
}

fn optional_limit(arguments: &Map<String, Value>) -> bool {
    arguments.get("limit").is_none_or(|value| {
        value
            .as_u64()
            .is_some_and(|value| (1..=100).contains(&value))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conversation_binding_keeps_exact_catalog_order() {
        assert_eq!(
            tool_catalog()
                .iter()
                .filter_map(|tool| tool.get("name").and_then(Value::as_str))
                .collect::<Vec<_>>(),
            [
                "lico_conversation_list",
                "lico_conversation_get",
                "lico_conversation_search",
                "lico_conversation_export",
                "lico_conversation_import",
            ]
        );
    }
}
