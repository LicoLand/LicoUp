//! Native-history message token extraction and model attribution.

use super::contract::{AgentDef, HistoryUsageSummary, MessageUsage, number_field, text_field};
use super::window::UsageWindow;
use crate::domain::conversations;
use serde_json::{Value, json};

pub(super) fn summarize_native_history(
    def: &AgentDef,
    params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
) -> HistoryUsageSummary {
    let mut conversation_params = params.clone();
    if let Some(object) = conversation_params.as_object_mut() {
        object.insert("agent".to_owned(), json!(def.id));
    }
    let listed = match conversations::conversation_list(&conversation_params) {
        Ok(value) => value,
        Err(_) => {
            warnings.push(json!({
                "code": "native_history_scan_failed",
                "agentId": def.id
            }));
            return HistoryUsageSummary::default();
        }
    };
    let mut summary = HistoryUsageSummary::default();
    if let Some(sessions) = listed.get("sessions").and_then(Value::as_array) {
        for session in sessions {
            if session
                .get("sourcePath")
                .and_then(Value::as_str)
                .is_some_and(|path| !path.trim().is_empty())
            {
                summary
                    .source_paths
                    .insert("native-history-store".to_owned());
            }
            let messages = session
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let session_model = session_model_label(session);
            let session_date = session_date_key(session, window);
            let before = summary.total_tokens();
            if session.get("usage").is_some() {
                if add_message_usage(
                    session,
                    &mut summary,
                    session_date,
                    session_model.clone(),
                    window,
                ) {
                    summary.message_count = summary.message_count.saturating_add(1);
                }
            } else {
                let mut pending_segment = Vec::<(MessageUsage, String)>::new();
                for message in messages {
                    let date_key =
                        message_date_key(&message, window).or_else(|| session_date.clone());
                    let added_messages = collect_message_usage_tree(
                        &message,
                        &mut summary,
                        &mut pending_segment,
                        date_key,
                        session_model.clone(),
                        window,
                    );
                    summary.message_count = summary.message_count.saturating_add(added_messages);
                }
                summary.message_count =
                    summary
                        .message_count
                        .saturating_add(flush_pending_message_usage(
                            &mut pending_segment,
                            &mut summary,
                        ));
            }
            if summary.total_tokens() > before {
                summary.session_count = summary.session_count.saturating_add(1);
            }
        }
    }
    if let Some(skipped) = listed
        .get("sources")
        .and_then(|sources| sources.get("skipped"))
        .and_then(Value::as_array)
    {
        summary.skipped = skipped
            .iter()
            .map(|item| {
                json!({
                    "code": text_field(item, &["code", "reason"])
                        .unwrap_or_else(|| "history_source_skipped".to_owned()),
                    "agentId": def.id
                })
            })
            .collect();
    }
    summary
}

fn message_date_key(message: &Value, window: &UsageWindow) -> Option<String> {
    text_field(
        message,
        &[
            "createdAt",
            "updatedAt",
            "timestamp",
            "time",
            "date",
            "created_at",
            "updated_at",
        ],
    )
    .and_then(|value| window.date_key(&value))
}

fn session_date_key(session: &Value, window: &UsageWindow) -> Option<String> {
    text_field(
        session,
        &[
            "updatedAt",
            "createdAt",
            "timestamp",
            "time",
            "date",
            "updated_at",
            "created_at",
        ],
    )
    .and_then(|value| window.date_key(&value))
}

fn add_message_usage(
    message: &Value,
    summary: &mut HistoryUsageSummary,
    date_key: Option<String>,
    default_model: Option<String>,
    window: &UsageWindow,
) -> bool {
    let Some(date_key) = date_key.filter(|value| window.contains(value)) else {
        return false;
    };
    let before = summary.total_tokens();
    let Some(usage) = message_usage(message, default_model) else {
        return false;
    };
    summary.add(usage, Some(date_key));
    summary.total_tokens() > before
}

fn message_usage(message: &Value, default_model: Option<String>) -> Option<MessageUsage> {
    if let Some(usage) = message.get("usage") {
        let mut prompt_tokens =
            number_field(usage, &["promptTokens", "prompt_tokens"]).unwrap_or(0);
        let mut completion_tokens =
            number_field(usage, &["completionTokens", "completion_tokens"]).unwrap_or(0);
        let field_total = prompt_tokens.saturating_add(completion_tokens);
        let total_tokens = number_field(usage, &["totalTokens", "total_tokens"])
            .filter(|value| *value > 0)
            .unwrap_or(field_total);
        if field_total != total_tokens {
            if field_total > total_tokens {
                completion_tokens = completion_tokens.min(total_tokens);
                prompt_tokens = total_tokens.saturating_sub(completion_tokens);
            } else if prompt_tokens > 0 {
                prompt_tokens = prompt_tokens.min(total_tokens);
                completion_tokens = total_tokens.saturating_sub(prompt_tokens);
            } else {
                completion_tokens = completion_tokens.min(total_tokens);
                prompt_tokens = total_tokens.saturating_sub(completion_tokens);
            }
        }
        if total_tokens == 0 {
            return None;
        }
        return Some(MessageUsage {
            prompt_tokens,
            cached_input_tokens: number_field(
                usage,
                &[
                    "cachedInputTokens",
                    "cached_input_tokens",
                    "cacheReadInputTokens",
                    "cache_read_input_tokens",
                ],
            )
            .unwrap_or(0)
            .min(prompt_tokens),
            completion_tokens,
            total_tokens,
            model: message_model_label(message).or(default_model),
            explicit: true,
        });
    }
    let role = message
        .get("role")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if role == "metadata" {
        return None;
    }
    let text = message
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let tokens = estimate_tokens(text);
    if tokens == 0 {
        return None;
    }
    Some(if role == "agent" {
        MessageUsage {
            completion_tokens: tokens,
            total_tokens: tokens,
            model: message_model_label(message).or(default_model),
            explicit: false,
            ..MessageUsage::default()
        }
    } else {
        MessageUsage {
            prompt_tokens: tokens,
            total_tokens: tokens,
            model: message_model_label(message).or(default_model),
            explicit: false,
            ..MessageUsage::default()
        }
    })
}

fn collect_message_usage_tree(
    message: &Value,
    summary: &mut HistoryUsageSummary,
    pending_segment: &mut Vec<(MessageUsage, String)>,
    fallback_date: Option<String>,
    default_model: Option<String>,
    window: &UsageWindow,
) -> u64 {
    if let Some(children) = message.get("messages").and_then(Value::as_array)
        && !children.is_empty()
    {
        let mut added = children
            .iter()
            .map(|child| {
                let date_key = message_date_key(child, window).or_else(|| fallback_date.clone());
                collect_message_usage_tree(
                    child,
                    summary,
                    pending_segment,
                    date_key,
                    default_model.clone(),
                    window,
                )
            })
            .sum();
        if message.get("usage").is_some() {
            added += collect_message_usage(
                message,
                summary,
                pending_segment,
                fallback_date,
                default_model,
                window,
                true,
            );
        }
        return added;
    }
    collect_message_usage(
        message,
        summary,
        pending_segment,
        fallback_date,
        default_model,
        window,
        false,
    )
}

fn collect_message_usage(
    message: &Value,
    summary: &mut HistoryUsageSummary,
    pending_segment: &mut Vec<(MessageUsage, String)>,
    date_key: Option<String>,
    default_model: Option<String>,
    window: &UsageWindow,
    parent_scope: bool,
) -> u64 {
    let Some(usage) = message_usage(message, default_model) else {
        return 0;
    };
    if usage.explicit {
        let usage_scope = message
            .get("usageScope")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let covers_pending_segment = parent_scope
            || matches!(
                usage_scope,
                "request-response" | "pending-segment" | "turn" | "session"
            );
        let mut added = if covers_pending_segment {
            pending_segment.clear();
            0
        } else {
            flush_pending_message_usage(pending_segment, summary)
        };
        if let Some(date_key) = date_key.filter(|value| window.contains(value)) {
            summary.add(usage, Some(date_key));
            added = added.saturating_add(1);
        }
        return added;
    }
    if let Some(date_key) = date_key.filter(|value| window.contains(value)) {
        pending_segment.push((usage, date_key));
    }
    0
}

fn flush_pending_message_usage(
    pending_segment: &mut Vec<(MessageUsage, String)>,
    summary: &mut HistoryUsageSummary,
) -> u64 {
    let added = pending_segment.len() as u64;
    for (usage, date_key) in pending_segment.drain(..) {
        summary.add(usage, Some(date_key));
    }
    added
}

fn session_model_label(session: &Value) -> Option<String> {
    text_field(
        session,
        &[
            "model",
            "modelId",
            "model_id",
            "modelName",
            "model_name",
            "modelLabel",
            "model_label",
        ],
    )
    .or_else(|| {
        session
            .pointer("/modelConfig/modelName")
            .and_then(|value| value.as_str().map(|text| text.trim().to_owned()))
    })
    .map(normalize_model_label)
}

fn message_model_label(message: &Value) -> Option<String> {
    text_field(
        message,
        &[
            "model",
            "modelId",
            "model_id",
            "modelName",
            "model_name",
            "modelLabel",
            "model_label",
        ],
    )
    .or_else(|| {
        message.get("modelInfo").and_then(|info| {
            text_field(
                info,
                &["modelName", "model_name", "model", "modelId", "model_id"],
            )
        })
    })
    .or_else(|| {
        message.get("usage").and_then(|usage| {
            text_field(
                usage,
                &[
                    "model",
                    "modelId",
                    "model_id",
                    "modelName",
                    "model_name",
                    "modelLabel",
                    "model_label",
                ],
            )
        })
    })
    .map(normalize_model_label)
}

fn normalize_model_label(value: String) -> String {
    if value.eq_ignore_ascii_case("default") {
        "cursor-auto".to_owned()
    } else {
        value
    }
}

pub(super) fn estimate_tokens(text: &str) -> u64 {
    let mut cjk = 0usize;
    let mut other = 0usize;
    for ch in text.chars().filter(|ch| !ch.is_whitespace()) {
        if is_cjk(ch) {
            cjk += 1;
        } else {
            other += 1;
        }
    }
    ((cjk as f64 * 0.9) + (other as f64 / 4.0)).ceil() as u64
}

fn is_cjk(ch: char) -> bool {
    matches!(
        ch as u32,
        0x4E00..=0x9FFF | 0x3400..=0x4DBF | 0x3040..=0x30FF | 0xAC00..=0xD7AF
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn window() -> UsageWindow {
        UsageWindow::from_params(&json!({"now": "2026-07-15T12:00:00Z"}))
    }

    #[test]
    fn explicit_usage_reconciles_totals_cache_and_model() {
        let usage = message_usage(
            &json!({
                "role": "agent",
                "modelInfo": {"modelName": "default"},
                "usage": {
                    "prompt_tokens": 100,
                    "cache_read_input_tokens": 120,
                    "completion_tokens": 20,
                    "total_tokens": 110
                }
            }),
            None,
        )
        .unwrap();
        assert_eq!(usage.prompt_tokens, 90);
        assert_eq!(usage.cached_input_tokens, 90);
        assert_eq!(usage.completion_tokens, 20);
        assert_eq!(usage.total_tokens, 110);
        assert_eq!(usage.model.as_deref(), Some("cursor-auto"));
        assert!(usage.explicit);
    }

    #[test]
    fn parent_usage_replaces_estimates_for_covered_content() {
        let message = json!({
            "createdAt": "2026-07-10T10:00:00Z",
            "messages": [
                {"role": "user", "text": "estimated prompt"},
                {"role": "agent", "text": "estimated response"}
            ],
            "usage": {
                "prompt_tokens": 8,
                "completion_tokens": 5,
                "total_tokens": 13
            }
        });
        let mut summary = HistoryUsageSummary::default();
        let mut pending = Vec::new();
        let added = collect_message_usage_tree(
            &message,
            &mut summary,
            &mut pending,
            Some("2026-07-10".to_owned()),
            Some("model-a".to_owned()),
            &window(),
        );
        assert_eq!(added, 1);
        assert!(pending.is_empty());
        assert_eq!(summary.total_tokens(), 13);
        assert_eq!(summary.explicit_records, 1);
        assert_eq!(summary.estimated_records, 0);
    }

    #[test]
    fn uncovered_tail_remains_estimated_after_explicit_turn_usage() {
        let window = window();
        let mut summary = HistoryUsageSummary::default();
        let mut pending = Vec::new();
        let date = Some("2026-07-10".to_owned());
        collect_message_usage(
            &json!({"role": "user", "text": "question"}),
            &mut summary,
            &mut pending,
            date.clone(),
            Some("model-a".to_owned()),
            &window,
            false,
        );
        collect_message_usage(
            &json!({
                "role": "agent",
                "usageScope": "request-response",
                "usage": {
                    "prompt_tokens": 8,
                    "completion_tokens": 5,
                    "total_tokens": 13
                }
            }),
            &mut summary,
            &mut pending,
            date.clone(),
            Some("model-a".to_owned()),
            &window,
            false,
        );
        collect_message_usage(
            &json!({"role": "user", "text": "abcd"}),
            &mut summary,
            &mut pending,
            date,
            Some("model-a".to_owned()),
            &window,
            false,
        );
        flush_pending_message_usage(&mut pending, &mut summary);
        assert_eq!(summary.total_tokens(), 14);
        assert_eq!(summary.explicit_records, 1);
        assert_eq!(summary.estimated_records, 1);
    }

    #[test]
    fn estimator_is_bounded_and_language_aware() {
        assert_eq!(estimate_tokens(""), 0);
        assert_eq!(estimate_tokens("abcd"), 1);
        assert_eq!(estimate_tokens("中文"), 2);
    }
}
