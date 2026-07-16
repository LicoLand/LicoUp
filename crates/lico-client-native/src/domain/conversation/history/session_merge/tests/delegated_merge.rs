use serde_json::{Value, json};

use super::super::delegated_merge::{
    merge_delegated_subagent_sessions, subagent_card_preview_text,
};

fn session(id: &str, parent: Option<&str>, delegated: bool, messages: Vec<Value>) -> Value {
    let message_count = messages.len();
    let mut session = json!({
        "id": id,
        "nativeSessionId": id,
        "sourcePath": format!("fixture/{id}"),
        "messages": messages,
        "messageCount": message_count,
        "delegatedSubagent": delegated,
        "subagentTitle": id
    });
    if let Some(parent) = parent {
        session["parentSessionId"] = json!(parent);
    }
    session
}

#[test]
fn nested_delegated_lineage_merges_leaf_to_root_without_flattening_children() {
    let main = session(
        "main",
        None,
        false,
        vec![json!({"role": "user", "text": "Start", "createdAt": 0})],
    );
    let child = session(
        "child",
        Some("main"),
        true,
        vec![json!({"role": "assistant", "text": "Child result", "createdAt": 2})],
    );
    let grandchild = session(
        "grandchild",
        Some("child"),
        true,
        vec![json!({"role": "assistant", "text": "Nested result", "createdAt": 1})],
    );

    let merged = merge_delegated_subagent_sessions(vec![main, child, grandchild]);
    assert_eq!(merged.len(), 1);
    let main_messages = merged[0]["messages"].as_array().unwrap();
    let child_card = main_messages
        .iter()
        .find(|message| message["cardTitle"] == "child")
        .expect("child card");
    let nested = child_card["messages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|message| message["cardTitle"] == "grandchild")
        .expect("nested grandchild card");
    assert_eq!(nested["messages"][0]["text"], "Nested result");
}

#[test]
fn delegated_cycles_fail_closed_to_bounded_fallback_and_preview_is_bounded() {
    let main = session(
        "main",
        None,
        false,
        vec![json!({"role": "user", "text": "Start", "createdAt": 0})],
    );
    let left = session(
        "left",
        Some("right"),
        true,
        vec![json!({"role": "assistant", "text": "Left", "createdAt": 1})],
    );
    let right = session(
        "right",
        Some("left"),
        true,
        vec![json!({"role": "assistant", "text": "Right", "createdAt": 2})],
    );
    let merged = merge_delegated_subagent_sessions(vec![main, left, right]);
    assert_eq!(merged.len(), 1);
    assert_eq!(
        merged[0]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|message| message["role"] == "subagent")
            .count(),
        2
    );

    let preview = subagent_card_preview_text(&"界".repeat(181));
    assert_eq!(preview.chars().count(), 183);
    assert!(preview.ends_with("..."));
}
