use super::{AdapterContract, LifecycleStage, Transition, TransitionReducer};
use serde_json::Value;
use std::collections::HashSet;

use crate::platform::local_service::{ServeModel, ServeModelCatalog, ServeReadiness};

pub(super) const CONTRACT: AdapterContract = AdapterContract::new("opencode", "http-sse");

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ServeEventFailure {
    InvalidJson,
}

#[derive(Debug)]
pub(in crate::platform) struct ServeMessage {
    pub(in crate::platform) output: String,
    pub(in crate::platform) transitions: Vec<Transition>,
}

pub(in crate::platform) struct ServeEventParser {
    session_id: String,
    assistant_messages: HashSet<String>,
}

impl ServeEventParser {
    pub(in crate::platform) fn new(session_id: &str) -> Self {
        Self {
            session_id: session_id.to_owned(),
            assistant_messages: HashSet::new(),
        }
    }

    pub(in crate::platform) fn observe(
        &mut self,
        frame: &str,
    ) -> Result<Option<String>, ServeEventFailure> {
        let event =
            serde_json::from_str::<Value>(frame).map_err(|_| ServeEventFailure::InvalidJson)?;
        let Some(event_type) = event.get("type").and_then(Value::as_str) else {
            return Ok(None);
        };
        let Some(properties) = event.get("properties") else {
            return Ok(None);
        };
        if event_type == "message.updated" {
            if let Some(info) = properties.get("info")
                && session_id(info) == Some(self.session_id.as_str())
                && info.get("role").and_then(Value::as_str) == Some("assistant")
                && let Some(message_id) = info.get("id").and_then(Value::as_str)
            {
                self.assistant_messages.insert(message_id.to_owned());
            }
            return Ok(None);
        }
        if event_type != "message.part.updated"
            || session_id(properties) != Some(self.session_id.as_str())
        {
            return Ok(None);
        }
        let Some(part) = properties.get("part") else {
            return Ok(None);
        };
        if part.get("type").and_then(Value::as_str) != Some("text") {
            return Ok(None);
        }
        let Some(message_id) = message_id(part) else {
            return Ok(None);
        };
        if !self.assistant_messages.contains(message_id) {
            return Ok(None);
        }
        Ok(part
            .get("text")
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_owned))
    }
}

pub(in crate::platform) fn health_ready(frame: &Value) -> bool {
    frame.get("healthy").and_then(Value::as_bool) == Some(true)
}

pub(in crate::platform) fn session_id(frame: &Value) -> Option<&str> {
    frame
        .get("sessionID")
        .or_else(|| frame.get("sessionId"))
        .or_else(|| frame.get("id"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

pub(in crate::platform) fn session_collection(frame: &Value) -> bool {
    frame.as_array().is_some()
}

pub(in crate::platform) fn readiness(
    health: &Value,
    sessions: &Value,
    config: &Value,
    providers: &Value,
) -> Option<ServeReadiness> {
    if !health_ready(health) || !session_collection(sessions) {
        return None;
    }
    let version = health.get("version")?.as_str()?.trim();
    if version.is_empty() {
        return None;
    }
    let provider_rows = providers
        .get("all")
        .or_else(|| providers.get("providers"))?
        .as_array()?;
    let mut models = Vec::<ServeModel>::new();
    let mut provider_order = Vec::<String>::new();
    for provider in provider_rows {
        let Some(provider_id) = provider
            .get("id")
            .or_else(|| provider.get("providerID"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        provider_order.push(provider_id.to_string());
        if let Some(rows) = provider.get("models").and_then(Value::as_object) {
            for model_id in rows.keys().map(String::as_str) {
                push_model(&mut models, provider_id, model_id);
            }
        } else if let Some(rows) = provider.get("models").and_then(Value::as_array) {
            for row in rows {
                if let Some(model_id) = row
                    .get("id")
                    .or_else(|| row.get("modelID"))
                    .and_then(Value::as_str)
                {
                    push_model(&mut models, provider_id, model_id);
                }
            }
        }
    }
    let defaults = providers.get("default").and_then(Value::as_object);
    let configured = configured_model(config, &models, &provider_order);
    let current = configured.or_else(|| {
        provider_order.iter().find_map(|provider_id| {
            let model_id = defaults?.get(provider_id)?.as_str()?.trim();
            (!model_id.is_empty()).then(|| ServeModel {
                provider_id: provider_id.clone(),
                model_id: model_id.to_string(),
            })
        })
    })?;
    push_model(&mut models, &current.provider_id, &current.model_id);
    Some(ServeReadiness {
        version: version.to_string(),
        catalog: ServeModelCatalog { current, models },
        health: serde_json::json!({"healthy": true, "version": version}),
    })
}

fn configured_model(
    config: &Value,
    models: &[ServeModel],
    provider_order: &[String],
) -> Option<ServeModel> {
    let value = config.get("model")?;
    if let Some(object) = value.as_object() {
        let provider_id = object
            .get("providerID")
            .or_else(|| object.get("providerId"))?
            .as_str()?
            .trim();
        let model_id = object
            .get("modelID")
            .or_else(|| object.get("modelId"))?
            .as_str()?
            .trim();
        return (!provider_id.is_empty() && !model_id.is_empty()).then(|| ServeModel {
            provider_id: provider_id.to_string(),
            model_id: model_id.to_string(),
        });
    }
    let selector = value.as_str()?.trim();
    if let Some(exact) = models.iter().find(|model| model.selector() == selector) {
        return Some(exact.clone());
    }
    let model_id_matches = models
        .iter()
        .filter(|model| model.model_id == selector)
        .collect::<Vec<_>>();
    if model_id_matches.len() == 1 {
        return Some(model_id_matches[0].clone());
    }
    if let Some(current_provider_match) = provider_order.iter().find_map(|provider| {
        model_id_matches
            .iter()
            .find(|model| model.provider_id == *provider)
            .copied()
    }) {
        return Some(current_provider_match.clone());
    }
    if let Some((provider_id, model_id)) = selector.split_once('/') {
        return (!provider_id.is_empty() && !model_id.is_empty()).then(|| ServeModel {
            provider_id: provider_id.to_string(),
            model_id: model_id.to_string(),
        });
    }
    None
}

fn push_model(models: &mut Vec<ServeModel>, provider_id: &str, model_id: &str) {
    let provider_id = provider_id.trim();
    let model_id = model_id.trim();
    if provider_id.is_empty() || model_id.is_empty() {
        return;
    }
    if !models
        .iter()
        .any(|model| model.provider_id == provider_id && model.model_id == model_id)
    {
        models.push(ServeModel {
            provider_id: provider_id.to_string(),
            model_id: model_id.to_string(),
        });
    }
}

pub(in crate::platform) fn message(frame: &Value) -> Option<ServeMessage> {
    let output = assistant_text(frame);
    if output.is_empty() {
        return None;
    }
    let transitions = completed_transitions_with_controls(&output, tool_controls(frame));
    Some(ServeMessage {
        output,
        transitions,
    })
}

fn message_id(value: &Value) -> Option<&str> {
    value
        .get("messageID")
        .or_else(|| value.get("messageId"))
        .and_then(Value::as_str)
}

fn assistant_text(response: &Value) -> String {
    let mut chunks = Vec::new();
    if let Some(parts) = response.get("parts").and_then(Value::as_array) {
        append_text_parts(parts, &mut chunks);
    }
    if chunks.is_empty()
        && let Some(items) = response.as_array()
    {
        for item in items {
            if let Some(parts) = item.get("parts").and_then(Value::as_array) {
                append_text_parts(parts, &mut chunks);
            }
        }
    }
    chunks.concat()
}

fn append_text_parts(parts: &[Value], chunks: &mut Vec<String>) {
    for part in parts {
        if part.get("type").and_then(Value::as_str) == Some("text")
            && let Some(text) = part.get("text").and_then(Value::as_str)
        {
            chunks.push(text.to_owned());
        }
    }
}

#[cfg(test)]
pub(in crate::platform) fn completed_transitions(output: &str) -> Vec<Transition> {
    completed_transitions_with_controls(output, Vec::new())
}

fn completed_transitions_with_controls(output: &str, controls: Vec<Transition>) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Accepted);
    transitions.extend(reducer.advance(LifecycleStage::Processing));
    transitions.extend(controls);
    if !output.is_empty() {
        transitions.extend(reducer.advance(LifecycleStage::Responding));
        transitions.push(Transition::Text {
            unit_id: "opencode:reply".to_owned(),
            text: output.to_owned(),
        });
    }
    transitions.extend(reducer.advance(LifecycleStage::Completed));
    transitions
}

pub(in crate::platform) fn failure_transitions(
    code: &str,
    stage: &str,
    message: &str,
) -> Vec<Transition> {
    let mut reducer = TransitionReducer::default();
    let mut transitions = reducer.advance(LifecycleStage::Submitted);
    if let Some(failure) = reducer.fail(code, stage, message) {
        transitions.push(failure);
    }
    transitions
}

fn tool_controls(response: &Value) -> Vec<Transition> {
    let mut controls = Vec::new();
    if let Some(parts) = response.get("parts").and_then(Value::as_array) {
        append_tool_controls(parts, &mut controls);
    }
    if let Some(items) = response.as_array() {
        for item in items {
            if let Some(parts) = item.get("parts").and_then(Value::as_array) {
                append_tool_controls(parts, &mut controls);
            }
        }
    }
    controls
}

fn append_tool_controls(parts: &[Value], controls: &mut Vec<Transition>) {
    for part in parts {
        if part.get("type").and_then(Value::as_str) != Some("tool") {
            continue;
        }
        let method = part
            .get("tool")
            .or_else(|| part.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("native_tool")
            .chars()
            .take(64)
            .collect();
        controls.push(Transition::Control {
            method,
            summary: "OpenCode reported a native tool interaction.".to_owned(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn serve_frames_decode_only_inside_the_opencode_component() {
        assert!(health_ready(&json!({"healthy": true})));
        assert_eq!(session_id(&json!({"id": "open-1"})), Some("open-1"));
        assert!(session_collection(&json!([])));
        let parsed = message(&json!({"parts": [
            {"type": "reasoning", "text": "hidden"},
            {"type": "text", "text": "answer"}
        ]}))
        .unwrap();
        assert_eq!(parsed.output, "answer");
    }

    #[test]
    fn serve_event_parser_is_exact_session_and_assistant_only() {
        let mut parser = ServeEventParser::new("open-1");
        let assistant = json!({
            "type": "message.updated",
            "properties": {"info": {
                "id": "agent", "role": "assistant", "sessionID": "open-1"
            }}
        });
        assert_eq!(parser.observe(&assistant.to_string()), Ok(None));
        let part = json!({
            "type": "message.part.updated",
            "properties": {
                "sessionId": "open-1",
                "part": {"messageID": "agent", "type": "text", "text": "delta"}
            }
        });
        assert_eq!(parser.observe(&part.to_string()), Ok(Some("delta".into())));
        assert_eq!(parser.observe("{"), Err(ServeEventFailure::InvalidJson));
    }

    #[test]
    fn serve_execution_produces_closed_typed_transitions() {
        let transitions = completed_transitions("answer");
        assert!(matches!(
            transitions.last(),
            Some(Transition::Lifecycle(LifecycleStage::Completed))
        ));
        let failed = failure_transitions("code", "serve/sse", "safe");
        assert!(matches!(
            failed.last(),
            Some(Transition::Failed { code, .. }) if code == "code"
        ));
    }

    #[test]
    fn readiness_uses_config_then_provider_order_and_never_session_models() {
        let providers = json!({
            "all": [
                {"id": "anthropic", "models": {"claude-current": {}}},
                {"id": "openai", "models": {"gpt-current": {}}}
            ],
            "default": {"anthropic": "claude-current", "openai": "gpt-current"}
        });
        let configured = readiness(
            &json!({"healthy": true, "version": "2.0.0"}),
            &json!([{"id": "old", "model": "stale-session-model"}]),
            &json!({"model": "openai/gpt-current"}),
            &providers,
        )
        .unwrap();
        assert_eq!(configured.catalog.current.selector(), "openai/gpt-current");
        let defaulted = readiness(
            &json!({"healthy": true, "version": "2.0.0"}),
            &json!([]),
            &json!({}),
            &providers,
        )
        .unwrap();
        assert_eq!(
            defaulted.catalog.current.selector(),
            "anthropic/claude-current"
        );
    }
}
