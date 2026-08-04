use crate::domain::mobile_relay::endpoint_trust::clear_pairing_presentation;
use crate::domain::mobile_relay::support::MOBILE_RELAY_E2EE_PROTOCOL_VERSION;
use serde_json::{Value, json};

pub(in crate::domain::mobile_relay) fn reset_incompatible_local_pairwise_protocol(
    config: &mut Value,
) -> bool {
    let incompatible = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("protocolVersion"))
        .and_then(Value::as_str)
        .map(str::trim)
        .is_some_and(|protocol| protocol != MOBILE_RELAY_E2EE_PROTOCOL_VERSION);
    if !incompatible {
        return false;
    }
    reset_local_pairwise_state(config);
    true
}

pub(in crate::domain::mobile_relay) fn force_reset_local_pairwise_protocol(config: &mut Value) {
    reset_local_pairwise_state(config);
}

fn reset_local_pairwise_state(config: &mut Value) {
    config["mobileRelayE2ee"] = json!({});
    config["pairingId"] = json!("");
    config["pcToken"] = json!("");
    config["mobileToken"] = json!("");
    config["paired"] = json!(false);
    config["relayEnabled"] = json!(false);
    clear_pairing_presentation(config);
    if let Some(root) = config.as_object_mut() {
        for key in [
            "mobileTokenPresent",
            "pairedDevices",
            "pcTokenPresent",
            "secretStorageStatus",
        ] {
            root.remove(key);
        }
    }
}
