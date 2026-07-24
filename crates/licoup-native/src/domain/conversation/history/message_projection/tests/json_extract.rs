use serde_json::{Value, json};

use super::super::json_extract::{
    extract_native_session_id, extract_role, extract_text, extract_timestamp, find_string,
};

#[test]
fn recursive_json_extraction_keeps_text_and_rejects_tool_or_system_payloads() {
    assert_eq!(
        extract_text(&json!({"message": {"content": {"type": "text", "text": "visible"}}}))
            .as_deref(),
        Some("visible")
    );
    assert!(
        extract_text(&json!({
            "content": {"type": "tool_result", "text": "must not project"}
        }))
        .is_none()
    );
    assert_eq!(
        extract_text(&Value::String(
            r#"{"type":"text","text":"decoded"}"#.to_string()
        ))
        .as_deref(),
        Some("decoded")
    );
}

#[test]
fn recursive_extraction_and_string_lookup_have_explicit_depth_bounds() {
    let mut value = json!("too deep");
    for _ in 0..18 {
        value = json!({"message": value});
    }
    assert!(extract_text(&value).is_none());
    assert!(find_string(&value, &["role"]).is_none());
}

#[test]
fn role_time_and_session_projection_are_stable() {
    let value = json!({
        "type": 1,
        "created_at": "2026-01-01T00:00:00Z",
        "message": {"session_id": "session-1"}
    });
    assert_eq!(extract_role(&value), "user");
    assert_eq!(
        extract_timestamp(&value).as_deref(),
        Some("2026-01-01T00:00:00Z")
    );
    assert_eq!(
        extract_native_session_id(&value).as_deref(),
        Some("session-1")
    );
}
