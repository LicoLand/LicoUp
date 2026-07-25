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
            "relayRegisteredEndpointId",
            "secretStorageStatus",
        ] {
            root.remove(key);
        }
    }
    true
}
