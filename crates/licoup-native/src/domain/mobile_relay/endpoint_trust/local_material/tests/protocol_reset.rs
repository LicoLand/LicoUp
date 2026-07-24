use super::super::protocol_reset::reset_incompatible_local_pairwise_protocol;
use serde_json::json;

#[test]
fn incompatible_pairwise_protocol_resets_all_bound_local_state() {
    let mut config = json!({
        "mobileRelayE2ee": {"protocolVersion": "retired-protocol"},
        "pairingId": "pairing",
        "pcToken": "pc",
        "mobileToken": "mobile",
        "paired": true,
        "relayEnabled": true,
        "lastPairingCode": "code",
        "lastPairingExpiresAt": "later",
        "mobileRelayPairingInvite": {"present": true},
        "pairedDevices": [],
        "secretStorageStatus": {"present": true}
    });

    reset_incompatible_local_pairwise_protocol(&mut config);

    assert_eq!(config["mobileRelayE2ee"], json!({}));
    assert_eq!(config["pairingId"], "");
    assert_eq!(config["pcToken"], "");
    assert_eq!(config["mobileToken"], "");
    assert_eq!(config["paired"], false);
    assert_eq!(config["relayEnabled"], false);
    assert!(config.get("mobileRelayPairingInvite").is_none());
    assert!(config.get("pairedDevices").is_none());
    assert!(config.get("secretStorageStatus").is_none());
}

#[test]
fn compatible_pairwise_protocol_keeps_existing_state() {
    let mut config = json!({
        "mobileRelayE2ee": {
            "protocolVersion": crate::domain::mobile_relay::support::MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "marker": "kept"
        },
        "paired": true
    });

    reset_incompatible_local_pairwise_protocol(&mut config);

    assert_eq!(config["mobileRelayE2ee"]["marker"], "kept");
    assert_eq!(config["paired"], true);
}
