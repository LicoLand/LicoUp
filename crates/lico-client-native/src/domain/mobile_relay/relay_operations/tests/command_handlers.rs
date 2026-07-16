use super::super::command_handlers::command_complete_with_config;
use serde_json::json;

#[test]
fn command_complete_requires_bound_delivery_and_lease_metadata() {
    let error = command_complete_with_config(&json!({}), &json!({}))
        .err()
        .expect("missing command id must be rejected");
    assert!(error.to_string().contains("requires --command-id"));
}
