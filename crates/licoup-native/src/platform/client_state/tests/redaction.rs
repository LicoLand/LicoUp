use serde_json::json;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }


#[test]
fn snapshot_redaction_covers_json_text_metadata_and_reference_exceptions() {
    let sv_token_canary = synthetic_value("token-canary");
    let sv_api_canary = synthetic_value("api-canary");
    let sv_canary = synthetic_value("canary");
    let sv_query_canary = synthetic_value("query-canary");
    let authorization_canary = ["Bearer", sv_token_canary.as_str()].join(" ");
    let api_canary = sv_api_canary.as_str();
    let query_canary = sv_query_canary.as_str();
    let local_path = ["/", "private", "local", "path"].join("/");
    let refresh_canary = ["refresh", sv_canary.as_str()].join("-");
    let content = json!({
        "headers": {"Authorization": authorization_canary},
        "apiKey": api_canary,
        "secretRef": "secret://local/ref",
        "url": format!("https://example.invalid/?access_token={query_canary}"),
    })
    .to_string();
    let redacted = super::super::redaction::redact_snapshot(
        &content,
        json!({
            "configPath": local_path,
            "refreshToken": refresh_canary
        }),
    )
    .unwrap();

    assert!(!redacted.content.contains(sv_token_canary.as_str()));
    assert!(!redacted.content.contains(sv_api_canary.as_str()));
    assert!(!redacted.content.contains(sv_query_canary.as_str()));
    assert!(redacted.content.contains("secret://local/ref"));
    assert_eq!(
        redacted.metadata["configPath"],
        super::super::policy::REDACTED_LOCAL_PATH
    );
    assert_eq!(
        redacted.metadata["refreshToken"],
        super::super::policy::REDACTED_SECRET
    );
    assert_eq!(redacted.evidence["applied"], true);
}

#[test]
fn text_private_key_blocks_are_removed_in_full() {
    let sv_private_key_canary = synthetic_value("private-key-canary");
    let private_key_block = [
        "-----BEGIN ",
        "PRIVATE KEY-----\n",
        format!("{}\n", sv_private_key_canary.clone()),
        "-----END ",
        "PRIVATE KEY-----",
    ]
    .concat();
    let content = format!("plain\n{private_key_block}\nplain");
    let redacted = super::super::redaction::redact_snapshot(&content, json!({})).unwrap();

    assert!(!redacted.content.contains(sv_private_key_canary.as_str()));
    assert!(
        redacted
            .content
            .contains(super::super::policy::REDACTED_PRIVATE_KEY)
    );
}

#[test]
fn redaction_fails_closed_above_the_nesting_limit() {
    let mut payload = json!("leaf");
    for _ in 0..=super::super::policy::MAX_REDACTION_DEPTH {
        payload = json!({"nested": payload});
    }

    assert!(super::super::redaction::redact_activity_payload(payload).is_err());
}
