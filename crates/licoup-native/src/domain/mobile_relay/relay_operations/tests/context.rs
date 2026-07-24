use super::super::context::canonical_relay_context;
use crate::domain::mobile_relay::config::default_config;
use serde_json::json;

#[test]
fn canonical_context_rejects_disabled_relay_before_scope_resolution() {
    let error = canonical_relay_context(&json!({}), &default_config())
        .err()
        .expect("disabled relay must fail closed");
    assert!(error.to_string().contains("mobile relay is disabled"));
}
