use super::events::AgentEvent;
use super::tools::ToolRegistry;
use super::transport::LlmTransport;
use crate::domain::conversation::usage::extract_token_usage;
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
        if let Some(event) = response_usage(&response, model) {
            on_event(event);
        }
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

fn response_usage(response: &Value, requested_model: &str) -> Option<AgentEvent> {
    let usage = extract_token_usage(response)?;
    let concrete_model = |model: &str| {
        let model = model.trim();
        (!model.is_empty()
            && !["auto", "default", "unknown", "unspecified"]
                .into_iter()
                .any(|selector| model.eq_ignore_ascii_case(selector)))
        .then(|| model.to_owned())
    };
    let model = response
        .get("model")
        .and_then(Value::as_str)
        .and_then(concrete_model)
        .or_else(|| concrete_model(requested_model));
    Some(AgentEvent::Usage { model, usage })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_keeps_only_numeric_counters_and_explicit_response_options() {
        let event = response_usage(
            &json!({
                "model": "actual-model",
                "reasoning_effort": "high",
                "service_tier": "default",
                "usage": {
                    "prompt_tokens": 12,
                    "completion_tokens": 3,
                    "total_tokens": 15,
                    "prompt_tokens_details": {"cached_tokens": 4},
                    "private": "private-usage-canary"
                },
                "metadata": {"opaqueField": "private-metadata-canary"},
                "choices": [{"message": {"content": "private-content-canary"}}]
            }),
            "requested-model",
        )
        .unwrap();
        let AgentEvent::Usage { model, usage } = event else {
            panic!("expected usage event");
        };
        assert_eq!(model.as_deref(), Some("actual-model"));
        assert_eq!(usage["promptTokens"], 12);
        assert_eq!(usage["cachedInputTokens"], 4);
        assert_eq!(usage["completionTokens"], 3);
        assert_eq!(usage["totalTokens"], 15);
        assert_eq!(usage["reasoningEffort"], "high");
        assert_eq!(usage["fast"], false);
        assert!(!usage.to_string().contains("private-"));
    }

    #[test]
    fn usage_without_response_options_does_not_invent_effort_or_auto_model() {
        let response = json!({"usage": {"prompt_tokens": 2, "completion_tokens": 1}});
        for selector in ["auto", " Default ", "UNKNOWN", "unspecified", ""] {
            let AgentEvent::Usage { model, usage } = response_usage(&response, selector).unwrap()
            else {
                panic!("expected usage event");
            };
            assert!(model.is_none());
            assert!(usage.get("reasoningEffort").is_none());
            assert!(usage.get("fast").is_none());
        }
        let AgentEvent::Usage { model, .. } =
            response_usage(&response, "explicit-request-model").unwrap()
        else {
            panic!("expected usage event");
        };
        assert_eq!(model.as_deref(), Some("explicit-request-model"));
        assert!(response_usage(&json!({"model": "actual-model"}), "auto").is_none());
    }
}
