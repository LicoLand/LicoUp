use super::super::material_mutation::ensure_mobile_relay_endpoint_material;
use serde_json::json;

#[test]
fn endpoint_material_builds_complete_pqxdh_inventory() {
    let mut config = json!({});

    ensure_mobile_relay_endpoint_material(&mut config, "desktop").unwrap();

    let state = config["mobileRelayE2ee"].as_object().unwrap();
    for field in [
        "privateKeyBase64url",
        "publicKeyBase64url",
        "signingKeyBase64url",
        "signingPublicKeyBase64url",
        "signedPrekeyId",
        "signedPrekeyPrivateKeyBase64url",
        "signedPrekeyPublicKeyBase64url",
        "oneTimePrekeyId",
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPublicKeyBase64url",
        "oneTimeMlKem1024PrekeyId",
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeyPublicKeyBase64url",
    ] {
        assert!(
            state
                .get(field)
                .and_then(|value| value.as_str())
                .is_some_and(|value| !value.is_empty()),
            "missing local material field: {field}"
        );
    }
    assert_eq!(state["prekeyPublicationVersion"], 1);
}
