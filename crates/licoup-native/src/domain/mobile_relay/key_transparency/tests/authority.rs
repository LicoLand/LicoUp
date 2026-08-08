use crate::domain::mobile_relay::key_transparency::config::CONFIG_SCHEMA_VERSION;
use crate::domain::mobile_relay::key_transparency::projection::authority_challenge_response;
use serde_json::json;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }


#[test]
fn challenge_projection_exposes_only_confirmation_metadata() {
    let sv_must_not_escape = synthetic_value("must-not-escape");
    let challenge = json!({
        "challengeId": "challenge-test",
        "proposalDigest": "digest-test",
        "expiresAtEpochSeconds": 42,
        "requiresSecurityReset": true,
        "confirmationSecret": sv_must_not_escape.as_str()
    });
    let response = authority_challenge_response(&challenge, CONFIG_SCHEMA_VERSION);
    assert_eq!(response["status"], json!("confirmation_required"));
    assert_eq!(response["requiresUserPresence"], json!(true));
    assert!(response.get("privateKeyMaterial").is_none());
    assert!(response.get("confirmationSecret").is_none());
}
