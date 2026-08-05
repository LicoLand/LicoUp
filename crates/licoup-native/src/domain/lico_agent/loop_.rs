use super::events::AgentEvent;
use super::tools::ToolRegistry;
use super::transport::LlmTransport;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};

pub fn run_turn(
    transport: &dyn LlmTransport,
    model: &str,
    system_prompt: &str,
    history: &mut Vec<Value>,
    tools: &ToolRegistry,
    abort: &AtomicBool,
    mut on_event: impl FnMut(AgentEvent),
) -> Result<(), String> {
    on_event(AgentEvent::TurnStart);
    let tool_defs = tools.definitions_for_llm();
    let mut messages = vec![json!({"role": "system", "content": system_prompt})];
    messages.extend(history.iter().cloned());

    for _ in 0..8 {
        if abort.load(Ordering::SeqCst) {
            on_event(AgentEvent::Error {
                code: "aborted".into(),
                message: "turn aborted".into(),
            });
            break;
        }
        let response = transport
            .complete(model, &messages, &tool_defs)
            .map_err(|e| e.to_string())?;
        let choice = response
            .pointer("/choices/0/message")
            .cloned()
            .ok_or_else(|| "gateway_response_missing_message".to_string())?;
        let role = choice
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("assistant")
            .to_string();
        on_event(AgentEvent::MessageStart { role: role.clone() });
        if let Some(content) = choice.get("content").and_then(Value::as_str) {
            if !content.is_empty() {
                on_event(AgentEvent::MessageUpdate {
                    role: role.clone(),
                    delta: content.to_string(),
                });
                on_event(AgentEvent::MessageEnd {
                    role: role.clone(),
                    content: content.to_string(),
                });
            }
        }
        messages.push(choice.clone());
        history.push(choice.clone());

        let tool_calls = choice
            .get("tool_calls")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if tool_calls.is_empty() {
            break;
        }
        for call in tool_calls {
            let call_id = call
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or("tool")
                .to_string();
            let name = call
                .pointer("/function/name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let args_raw = call
                .pointer("/function/arguments")
                .and_then(Value::as_str)
                .unwrap_or("{}");
            let args: Value = serde_json::from_str(args_raw).unwrap_or(json!({}));
            on_event(AgentEvent::ToolExecutionStart {
                name: name.clone(),
                call_id: call_id.clone(),
            });
            let (ok, output) = match tools.get(&name) {
                Some(tool) => match tool.execute(&args) {
                    Ok(out) => (true, out),
                    Err(err) => (false, err.to_string()),
                },
                None => (false, format!("unknown_tool:{name}")),
            };
            on_event(AgentEvent::ToolExecutionEnd {
                name: name.clone(),
                call_id: call_id.clone(),
                ok,
                output: output.clone(),
            });
            let tool_msg = json!({
                "role": "tool",
                "tool_call_id": call_id,
                "content": output,
            });
            messages.push(tool_msg.clone());
            history.push(tool_msg);
        }
    }
    on_event(AgentEvent::TurnEnd);
    Ok(())
}
