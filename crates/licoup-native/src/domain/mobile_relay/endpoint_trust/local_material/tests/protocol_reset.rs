use super::super::protocol_reset::reset_incompatible_local_pairwise_protocol;
use serde_json::json;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }


#[test]
fn incompatible_pairwise_protocol_resets_all_bound_local_state() {
    let sv_pc = synthetic_value("pc");
    let sv_code = synthetic_value("code");
    let sv_mobile = synthetic_value("mobile");
    let mut config = json!({
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
