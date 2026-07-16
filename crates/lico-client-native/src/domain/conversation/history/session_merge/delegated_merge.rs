use std::collections::{HashMap, VecDeque};

use serde_json::{Value, json};

use super::stable_order::{message_order_key, message_role, session_order_key};

const MAX_SUBAGENT_PREVIEW_CHARS: usize = 180;

pub(super) fn merge_delegated_subagent_sessions(sessions: Vec<Value>) -> Vec<Value> {
    let mut indexed_sessions = sessions
        .into_iter()
        .enumerate()
        .map(|(index, session)| (index, session_order_key(&session, index), Some(session)))
        .collect::<Vec<_>>();

    merge_explicit_parent_child_lineages(&mut indexed_sessions);

    let mut main_sessions = Vec::<(usize, i128, Value)>::new();
    let mut subagent_cards = Vec::<(usize, i128, Value)>::new();
    for (index, order_key, session) in indexed_sessions {
        let Some(session) = session else {
            continue;
        };
        if let Some(card) = subagent_card_from_session(&session) {
            subagent_cards.push((index, order_key, card));
        } else {
            main_sessions.push((index, order_key, session));
        }
    }

    if main_sessions.is_empty() {
        return Vec::new();
    }
    for (card_index, card_order_key, card) in subagent_cards {
        if let Some(parent_index) =
            nearest_main_session_index(&main_sessions, card_index, card_order_key)
        {
            insert_subagent_card_into_session(&mut main_sessions[parent_index].2, card);
        }
    }
    main_sessions
        .into_iter()
        .map(|(_, _, session)| session)
        .collect()
}

/// Merge explicit child sessions from leaves toward their parents.
///
/// The child-count frontier is the reverse orientation of a topological sort:
/// each edge is processed once, nested descendants are already materialized
/// when their parent becomes ready, and cyclic components remain unmerged so
/// they can follow the bounded nearest-session fallback below.
fn merge_explicit_parent_child_lineages(indexed_sessions: &mut [(usize, i128, Option<Value>)]) {
    let native_ids = indexed_sessions
        .iter()
        .enumerate()
        .filter_map(|(slot, (_, _, session))| {
            session
                .as_ref()?
                .get("nativeSessionId")
                .and_then(Value::as_str)
                .map(|id| (id.to_string(), slot))
        })
        .collect::<HashMap<_, _>>();
    let parent_by_child = indexed_sessions
        .iter()
        .enumerate()
        .map(|(child_index, (_, _, session))| {
            let session = session.as_ref()?;
            if !session_is_delegated_subagent(session) {
                return None;
            }
            let parent_id = session.get("parentSessionId")?.as_str()?;
            let parent_index = *native_ids.get(parent_id)?;
            (parent_index != child_index).then_some(parent_index)
        })
        .collect::<Vec<_>>();

    let mut remaining_children = vec![0usize; indexed_sessions.len()];
    for parent_index in parent_by_child.iter().flatten() {
        remaining_children[*parent_index] += 1;
    }
    let mut ready = parent_by_child
        .iter()
        .enumerate()
        .filter_map(|(child_index, parent)| {
            (parent.is_some() && remaining_children[child_index] == 0).then_some(child_index)
        })
        .collect::<VecDeque<_>>();

    while let Some(child_index) = ready.pop_front() {
        let Some(parent_index) = parent_by_child[child_index] else {
            continue;
        };
        let Some(child_session) = indexed_sessions[child_index].2.take() else {
            continue;
        };
        if let Some(card) = subagent_card_from_session(&child_session)
            && let Some(parent_session) = indexed_sessions[parent_index].2.as_mut()
        {
            insert_subagent_card_into_session(parent_session, card);
        }
        remaining_children[parent_index] = remaining_children[parent_index].saturating_sub(1);
        if parent_by_child[parent_index].is_some() && remaining_children[parent_index] == 0 {
            ready.push_back(parent_index);
        }
    }
}

pub(super) fn nearest_main_session_index(
    main_sessions: &[(usize, i128, Value)],
    card_index: usize,
    card_order_key: i128,
) -> Option<usize> {
    main_sessions
        .iter()
        .enumerate()
        .min_by_key(|(_, (main_index, main_order_key, _))| {
            (
                main_order_key.abs_diff(card_order_key),
                main_index.abs_diff(card_index),
            )
        })
        .map(|(index, _)| index)
}

pub(super) fn insert_subagent_card_into_session(session: &mut Value, card: Value) {
    let Some(object) = session.as_object_mut() else {
        return;
    };
    let Some(message_count) = object
        .get_mut("messages")
        .and_then(Value::as_array_mut)
        .map(|messages| {
            let card_order_key = message_order_key(&card).unwrap_or(i128::MAX);
            let insert_at = messages
                .iter()
                .position(|message| {
                    message_order_key(message)
                        .map(|order_key| order_key > card_order_key)
                        .unwrap_or(false)
                })
                .unwrap_or(messages.len());
            messages.insert(insert_at, card);
            messages.len()
        })
    else {
        return;
    };
    object.insert("messageCount".to_string(), json!(message_count));
}

pub(super) fn subagent_card_from_session(session: &Value) -> Option<Value> {
    let messages = session.get("messages").and_then(Value::as_array)?;
    let prompt = messages
        .iter()
        .find(|message| message_role(message) == "subagent_prompt");
    if prompt.is_none() && !session_is_explicit_delegated_subagent(session) {
        return None;
    }
    let title = session
        .get("subagentTitle")
        .and_then(Value::as_str)
        .or_else(|| prompt.and_then(|message| message.get("subagentTitle").and_then(Value::as_str)))
        .filter(|title| !title.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| "Subagent task".to_string());
    let child_messages = messages
        .iter()
        .filter(|message| subagent_card_child_message_is_visible(message))
        .cloned()
        .collect::<Vec<_>>();
    if child_messages.is_empty() {
        return None;
    }
    let preview = child_messages
        .iter()
        .rev()
        .filter_map(|message| message.get("text").and_then(Value::as_str))
        .find(|text| !text.trim().is_empty())
        .map(subagent_card_preview_text)
        .unwrap_or_else(|| title.clone());
    let created_at = prompt
        .and_then(|message| message.get("createdAt").and_then(Value::as_str))
        .or_else(|| {
            child_messages
                .first()
                .and_then(|message| message.get("createdAt").and_then(Value::as_str))
        })
        .unwrap_or_default()
        .to_string();
    let source_path = session
        .get("sourcePath")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let card_id = session
        .get("id")
        .and_then(Value::as_str)
        .map(|id| format!("{}::subagent-card", id))
        .unwrap_or_else(|| "subagent-card".to_string());
    Some(json!({
        "id": card_id,
        "role": "subagent",
        "text": preview,
        "createdAt": created_at,
        "sourcePath": source_path,
        "cardType": "subagent",
        "cardTitle": title,
        "collapsed": true,
        "messages": child_messages
    }))
}

fn subagent_card_child_message_is_visible(message: &Value) -> bool {
    let role = message_role(message);
    !matches!(
        role.as_str(),
        "subagent_prompt" | "system" | "developer" | "metadata" | "tool" | "function"
    ) && message
        .get("text")
        .and_then(Value::as_str)
        .is_some_and(|text| !text.trim().is_empty())
}

pub(super) fn subagent_card_preview_text(text: &str) -> String {
    let preview = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default();
    let mut chars = preview.chars();
    let mut out = chars
        .by_ref()
        .take(MAX_SUBAGENT_PREVIEW_CHARS)
        .collect::<String>();
    if chars.next().is_some() {
        out.push_str("...");
    }
    out
}

pub(super) fn session_is_delegated_subagent(session: &Value) -> bool {
    session_is_explicit_delegated_subagent(session)
        || session
            .get("messages")
            .and_then(Value::as_array)
            .is_some_and(|messages| {
                messages
                    .iter()
                    .any(|message| message_role(message) == "subagent_prompt")
            })
}

fn session_is_explicit_delegated_subagent(session: &Value) -> bool {
    session
        .get("delegatedSubagent")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        && session
            .get("parentSessionId")
            .and_then(Value::as_str)
            .is_some_and(|id| !id.trim().is_empty())
}
