//! Privacy-minimal projection of structured runtime skill-call events.
//!
//! Vendor payloads remain inside their adapters. Only an allowlisted skill id
//! is projected, and only when the surrounding structured event explicitly
//! identifies a skill invocation. Prompts, arguments, paths, and tool results
//! are never copied.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const MAX_NODES: usize = 64;
const MAX_SKILL_ID_BYTES: usize = 128;
const MAX_RAW_INVOCATION_ID_BYTES: usize = 512;

pub(in crate::platform) fn project_skill_invocations(value: &Value) -> Vec<Value> {
    let mut remaining = MAX_NODES;
    let mut events = Vec::new();
    inspect_node(value, &mut remaining, &mut events);
    events
}

fn inspect_node(value: &Value, remaining: &mut usize, events: &mut Vec<Value>) {
    if *remaining == 0 {
        return;
    }
    *remaining -= 1;
    if let Some(event) = skill_invocation_from_node(value) {
        events.push(event);
    }
    for child in known_children(value) {
        inspect_node(child, remaining, events);
    }
}

fn known_children(value: &Value) -> Vec<&Value> {
    let mut children = Vec::new();
    if let Some(items) = value.as_array() {
        children.extend(items.iter());
        return children;
    }
    for path in [
        "/content",
        "/parts",
        "/message/content",
        "/params/item",
        "/params/update",
        "/properties/part",
    ] {
        let Some(child) = value.pointer(path) else {
            continue;
        };
        if let Some(items) = child.as_array() {
            children.extend(items.iter());
        } else if child.is_object() {
            children.push(child);
        }
    }
    children
}

fn skill_invocation_from_node(value: &Value) -> Option<Value> {
    let marker = first_text(
        value,
        &[
            "/event",
            "/type",
            "/sessionUpdate",
            "/kind",
            "/toolCall/kind",
        ],
    )?
    .to_ascii_lowercase();
    let tool_name = first_text(
        value,
        &[
            "/toolName",
            "/tool",
            "/tool/name",
            "/toolCall/name",
            "/toolCall/title",
            "/name",
            "/title",
        ],
    );
    let explicit_skill_event = matches!(
        marker.as_str(),
        "skill_invoked"
            | "skill.invoked"
            | "skill-invoked"
            | "skillinvocation"
            | "skill_invocation"
            | "skill_invocation_start"
            | "skill.invocation.started"
    );
    let skill_tool = tool_name.is_some_and(is_skill_tool_name);
    let single_call_or_start = matches!(
        marker.as_str(),
        "tool_call"
            | "toolcall"
            | "dynamic_tool_call"
            | "dynamictoolcall"
            | "tool_execution_start"
            | "tool_use"
            | "tool"
    );
    if !explicit_skill_event && !(single_call_or_start && skill_tool) {
        return None;
    }

    let candidate = first_text(
        value,
        &[
            "/skillId",
            "/skill/id",
            "/input/skillId",
            "/input/skill",
            "/input/name",
            "/arguments/skillId",
            "/arguments/skill",
            "/arguments/name",
            "/args/skillId",
            "/args/skill",
            "/args/name",
            "/rawInput/skillId",
            "/rawInput/skill",
            "/toolCall/input/skillId",
            "/toolCall/input/skill",
            "/toolCall/arguments/skillId",
            "/toolCall/arguments/skill",
            "/state/input/skillId",
            "/state/input/skill",
            "/state/input/name",
            "/metadata/skillId",
        ],
    )
    .or_else(|| tool_name.and_then(skill_id_from_tool_name))
    .or_else(|| {
        explicit_skill_event
            .then(|| first_text(value, &["/name", "/title"]))
            .flatten()
    })?;
    let skill_id = safe_skill_id(candidate)?;
    let mut event = json!({"event": "skill.invoked", "skillId": skill_id});
    if let Some(digest) = invocation_id_digest(value) {
        event["invocationIdDigest"] = json!(digest);
    }
    Some(event)
}

fn invocation_id_digest(value: &Value) -> Option<String> {
    let raw_id = first_text(
        value,
        &[
            "/toolCallId",
            "/tool_call_id",
            "/toolCall/id",
            "/callId",
            "/callID",
            "/call/id",
            "/invocationId",
            "/invocation/id",
            "/itemId",
            "/id",
        ],
    )?;
    if raw_id.len() > MAX_RAW_INVOCATION_ID_BYTES {
        return None;
    }
    let mut digest = Sha256::new();
    digest.update(b"licoup.skill-invocation.v1\0");
    digest.update(raw_id.as_bytes());
    Some(format!("sha256:{:x}", digest.finalize()))
}

fn first_text<'a>(value: &'a Value, paths: &[&str]) -> Option<&'a str> {
    paths
        .iter()
        .find_map(|path| value.pointer(path).and_then(Value::as_str))
        .map(str::trim)
        .filter(|text| !text.is_empty())
}

fn is_skill_tool_name(value: &str) -> bool {
    let normalized = value.trim().to_ascii_lowercase();
    matches!(normalized.as_str(), "skill" | "skills" | "skill.invoke")
        || normalized.starts_with("skill:")
        || normalized.starts_with("skill/")
}

fn skill_id_from_tool_name(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    trimmed
        .strip_prefix("skill:")
        .or_else(|| trimmed.strip_prefix("Skill:"))
        .or_else(|| trimmed.strip_prefix("skill/"))
        .or_else(|| trimmed.strip_prefix("Skill/"))
}

fn safe_skill_id(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.len() > MAX_SKILL_ID_BYTES
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return None;
    }
    Some(trimmed.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_only_explicit_structured_skill_calls() {
        let events = project_skill_invocations(&json!({
            "type": "assistant",
            "message": {"content": [
                {"type": "tool_use", "name": "Skill", "input": {"skill": "review-helper"}},
                {"type": "tool_use", "name": "Read", "input": {"skill": "not-a-call"}}
            ]}
        }));
        assert_eq!(
            events,
            vec![json!({
                "event": "skill.invoked",
                "skillId": "review-helper"
            })]
        );

        assert_eq!(
            project_skill_invocations(&json!({
                "parts": [{
                    "type": "tool",
                    "tool": "Skill",
                    "state": {"input": {"name": "release-check"}}
                }]
            })),
            vec![json!({
                "event": "skill.invoked",
                "skillId": "release-check"
            })]
        );

        assert_eq!(
            project_skill_invocations(&json!({
                "type": "tool_execution_start",
                "toolName": "Skill",
                "args": {"skill": "runtime-audit"}
            })),
            vec![json!({
                "event": "skill.invoked",
                "skillId": "runtime-audit"
            })]
        );

        assert_eq!(
            project_skill_invocations(&json!({
                "type": "dynamicToolCall",
                "name": "Skill",
                "arguments": {"name": "repo-audit"}
            })),
            vec![json!({
                "event": "skill.invoked",
                "skillId": "repo-audit"
            })]
        );
    }

    #[test]
    fn rejects_free_text_paths_and_arguments() {
        let payload = json!({
            "sessionUpdate": "tool_call",
            "name": "Skill",
            "arguments": {"skill": "invalid.skill.id", "prompt": "synthetic-sensitive-text"}
        });
        assert!(project_skill_invocations(&payload).is_empty());
        assert!(
            project_skill_invocations(&json!({
                "type": "agent_message",
                "text": "skill:review-helper"
            }))
            .is_empty()
        );
    }

    #[test]
    fn preserves_call_instances_and_hashes_stable_runtime_ids() {
        let distinct = project_skill_invocations(&json!({
            "content": [
                {
                    "type": "tool_use",
                    "id": "raw-call-one",
                    "name": "Skill",
                    "input": {"skill": "review-helper"}
                },
                {
                    "type": "tool_use",
                    "id": "raw-call-two",
                    "name": "Skill",
                    "input": {"skill": "review-helper"}
                }
            ]
        }));
        assert_eq!(distinct.len(), 2);
        assert_eq!(distinct[0]["skillId"], "review-helper");
        assert_eq!(distinct[1]["skillId"], "review-helper");
        assert_ne!(
            distinct[0]["invocationIdDigest"],
            distinct[1]["invocationIdDigest"]
        );
        assert!(
            !serde_json::to_string(&distinct)
                .unwrap()
                .contains("raw-call")
        );

        let repeated_payload = json!({
            "sessionUpdate": "tool_call",
            "toolCallId": "opaque-runtime-call",
            "title": "Skill",
            "rawInput": {"skill": "review-helper"}
        });
        let first = project_skill_invocations(&repeated_payload);
        let repeated = project_skill_invocations(&repeated_payload);
        assert_eq!(
            first[0]["invocationIdDigest"],
            repeated[0]["invocationIdDigest"]
        );
        assert!(
            !serde_json::to_string(&first)
                .unwrap()
                .contains("opaque-runtime-call")
        );

        let without_ids = project_skill_invocations(&json!({
            "content": [
                {"type": "tool_use", "name": "Skill", "input": {"skill": "review-helper"}},
                {"type": "tool_use", "name": "Skill", "input": {"skill": "review-helper"}}
            ]
        }));
        assert_eq!(without_ids.len(), 2);
        assert!(
            without_ids
                .iter()
                .all(|event| event.get("invocationIdDigest").is_none())
        );
    }
}
