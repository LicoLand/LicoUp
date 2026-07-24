use super::*;

#[test]
fn event_projection_drops_raw_delta_arguments_and_extension_details() {
    let private_argument = ["private", "argument"].join("-");
    let projected = sanitized_event(&json!({
        "type": "message_update",
        "assistantMessageEvent": {
            "type": "text_delta",
            "delta": "private-message"
        },
        "arguments": {"secret": private_argument.clone()}
    }))
    .unwrap();
    assert_eq!(
        projected,
        json!({"type": "message_update", "deltaType": "text_delta"})
    );
    assert!(!projected.to_string().contains("private"));
    assert!(!projected.to_string().contains(&private_argument));

    let extension = sanitized_event(&json!({
        "type": "extension_error",
        "message": "private-extension-detail"
    }))
    .unwrap();
    assert_eq!(extension, json!({"type": "extension_error"}));
}
