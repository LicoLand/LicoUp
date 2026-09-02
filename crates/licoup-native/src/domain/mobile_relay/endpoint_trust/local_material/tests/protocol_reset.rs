use super::super::protocol_reset::ensure_local_pairwise_protocol_compatible;
use serde_json::json;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }


#[test]
fn incompatible_pairwise_protocol_fails_without_mutating_bound_local_state() {
    let sv_pc = synthetic_value("pc");
    let sv_code = synthetic_value("code");
    let sv_mobile = synthetic_value("mobile");
    let config = json!({
        "mobileRelayE2ee": {"protocolVersion": "retired-protocol"},
        "pairingId": "pairing",
        "pcToken": sv_pc.as_str(),
        "mobileToken": sv_mobile.as_str(),
        "paired": true,
        "relayEnabled": true,
        "lastPairingCode": sv_code.as_str(),
        "lastPairingExpiresAt": "later",
        "mobileRelayPairingInvite": {"present": true},
        "pairedDevices": [],
        "secretStorageStatus": {"present": true}
    });

    let preserved = config.clone();
    assert!(ensure_local_pairwise_protocol_compatible(&config).is_err());
    assert_eq!(config, preserved);
}

#[test]
fn compatible_pairwise_protocol_keeps_existing_state() {
    let config = json!({
        "mobileRelayE2ee": {
            "protocolVersion": crate::domain::mobile_relay::support::MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "marker": "kept"
        },
        "paired": true
    });

    ensure_local_pairwise_protocol_compatible(&config).unwrap();

    assert_eq!(config["mobileRelayE2ee"]["marker"], "kept");
    assert_eq!(config["paired"], true);
}
