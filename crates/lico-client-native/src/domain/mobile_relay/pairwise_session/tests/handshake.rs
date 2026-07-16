use super::super::handshake::initialize_mobile_relay_pairwise_session;
use crate::core::secure_mesh_trust::DeviceTrustPublicIdentity;
use ed25519_dalek::SigningKey;
use rand::rngs::OsRng;
use serde_json::json;

#[test]
fn handshake_bootstrap_fails_closed_without_local_endpoint_state() {
    let signing = SigningKey::generate(&mut OsRng);
    let peer =
        DeviceTrustPublicIdentity::new("peer", [7u8; 32], signing.verifying_key().to_bytes(), 1)
            .unwrap();
    assert!(initialize_mobile_relay_pairwise_session(&mut json!({}), &json!({}), &peer).is_err());
}
