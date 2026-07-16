use super::super::test_support::*;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }

#[test]
fn public_config_save_preserves_internal_mobile_token() {
    let sv_mobile_token_preserve_ca = synthetic_value("mobile-token-preserve-canary");
    let dir = temp_dir("mobile-relay-preserve-token");
    let previous = set_portable_data_dir_override(Some(dir));
    let mut config = default_config();
    config["pairingId"] = json!("pair-preserve");
    config["mobileToken"] = json!(sv_mobile_token_preserve_ca.as_str());
    save_config(&mut config).unwrap();

    let saved = config_set(&json!({
        "pairingId": "pair-preserve",
        "mobileToken": "",
        "paired": true
    }))
    .unwrap();
    assert_eq!(saved["config"]["mobileToken"], "");
    assert_eq!(saved["config"]["mobileTokenPresent"], true);

    let (internal, _) = load_config_with_runtime_secret_overrides(&json!({})).unwrap();
    assert_eq!(internal["mobileToken"], sv_mobile_token_preserve_ca.as_str());
    set_portable_data_dir_override(previous);
}

#[test]
fn native_secret_store_restores_selected_device_without_raw_json_overrides() {
    let sv_paired_device_secret_sto = synthetic_value("paired-device-secret-store-canary");
    let dir = temp_dir("mobile-relay-native-secret-store-selected-device");
    let previous = set_portable_data_dir_override(Some(dir));
    let store = Arc::new(EphemeralSecretStore::new());
    let mut config = default_config();
    config["pairingId"] = json!("pair-active");
    config["mobileToken"] = json!("");
    config["pairedDevices"] = json!([
        {
            "id": "pc-selected",
            "pcClientId": "pc-selected",
            "pcClientName": "Selected Mac",
            "pairingId": "pair-selected",
            "mobileToken": sv_paired_device_secret_sto.as_str(),
            "credentialPresent": true,
            "gatewayUrl": "https://relay.example.test"
        }
    ]);
    persist_config_secret_material_to_secret_store(
        &mut config,
        store.as_ref(),
        MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
    )
    .unwrap();
    save_config(&mut config).unwrap();
    let baseline_session_count = store.authorization_session_count();

    let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
    let saved = with_mobile_relay_secret_store_override(store_override, || {
        config_set(&json!({
            "pairingId": "pair-selected",
            "mobileToken": "",
            "paired": true,
            "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
            "secretOverrides": {
                "mobileRelayE2eeSecretStore": {
                    "contract": "rust_secure_mesh_secret_store_handle_v1",
                    "namespace": MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                    "rawJsonSecretOverridesUsed": false
                }
            }
        }))
    })
    .unwrap();

    assert_eq!(saved["config"]["mobileTokenPresent"], true);
    assert_eq!(
        saved["config"]["pairedDevices"][0]["credentialPresent"],
        true
    );
    assert_eq!(
        store.authorization_session_count(),
        baseline_session_count + 1
    );
    let persisted = load_config().unwrap();
    let serialized = serde_json::to_string(&persisted).unwrap();
    assert_eq!(persisted["mobileToken"], "");
    assert_eq!(persisted["pairedDevices"][0]["mobileToken"], "");
    assert!(!serialized.contains(sv_paired_device_secret_sto.as_str()));
    assert_eq!(
        persisted["secretStorageStatus"]["selectedBackend"],
        "memory-only-ephemeral"
    );

    set_portable_data_dir_override(previous);
}

#[test]
fn runtime_secret_overrides_require_platform_transport_marker() {
    let sv_untrusted_runtime_overri = synthetic_value("untrusted-runtime-override-canary");
    let dir = temp_dir("mobile-relay-runtime-secret-overrides-marker");
    let previous = set_portable_data_dir_override(Some(dir));
    let mut config = default_config();
    config["pairingId"] = json!("pair-active");
    config["mobileToken"] = json!("");
    config["pairedDevices"] = json!([
        {
            "id": "pc-selected",
            "pcClientId": "pc-selected",
            "pcClientName": "Selected Mac",
            "pairingId": "pair-selected",
            "mobileToken": "",
            "credentialPresent": true,
            "gatewayUrl": "https://relay.example.test"
        }
    ]);
    save_config(&mut config).unwrap();

    let saved = config_set(&json!({
        "pairingId": "pair-selected",
        "mobileToken": "",
        "paired": true,
        "secretOverrides": {
            "pairedDevices": [
                {
                    "id": "pc-selected",
                    "pairingId": "pair-selected",
                    "mobileToken": sv_untrusted_runtime_overri.as_str()
                }
            ]
        }
    }))
    .unwrap();

    assert_eq!(saved["config"]["mobileTokenPresent"], false);
    assert_eq!(
        saved["config"]["pairedDevices"][0]["credentialPresent"],
        true
    );
    let persisted = load_config().unwrap();
    let serialized = serde_json::to_string(&persisted).unwrap();
    assert_eq!(persisted["mobileToken"], "");
    assert_eq!(persisted["pairedDevices"][0]["mobileToken"], "");
    assert!(!serialized.contains(sv_untrusted_runtime_overri.as_str()));
    assert!(persisted.get("secretStorageStatus").is_none());

    set_portable_data_dir_override(previous);
}

#[test]
fn runtime_secret_overrides_reject_raw_token_fields() {
    let sv_paired_token_raw_overrid = synthetic_value("paired-token-raw-override-canary");
    let sv_mobile_token_raw_overrid = synthetic_value("mobile-token-raw-override-canary");
    let mut config = default_config();
    let token_error = match apply_runtime_secret_overrides(
        &mut config,
        &json!({
            "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
            "secretOverrides": {
                "mobileToken": sv_mobile_token_raw_overrid.as_str()
            }
        }),
    ) {
        Ok(_) => panic!("raw token secretOverrides must be rejected"),
        Err(error) => format!("{error}"),
    };
    assert!(token_error.contains("raw token secretOverrides are disabled"));

    let paired_error = match apply_runtime_secret_overrides(
        &mut config,
        &json!({
            "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
            "secretOverrides": {
                "pairedDevices": [
                    {
                        "id": "pc-selected",
                        "pairingId": "pair-selected",
                        "mobileToken": sv_paired_token_raw_overrid.as_str()
                    }
                ]
            }
        }),
    ) {
        Ok(_) => panic!("raw paired-device token secretOverrides must be rejected"),
        Err(error) => format!("{error}"),
    };
    assert!(paired_error.contains("raw token secretOverrides are disabled"));
}

#[test]
fn e2ee_status_rejects_private_key_material_in_portable_config() {
    let dir = temp_dir("mobile-relay-e2ee-status-portable-secret-store");
    let previous = set_portable_data_dir_override(Some(dir));
    let mut pc_config = default_config();
    let pc_descriptor =
        ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
    let mut mobile_config = default_config();
    ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
    apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
    let private_key = mobile_config["mobileRelayE2ee"]["privateKeyBase64url"]
        .as_str()
        .unwrap()
        .to_string();
    save_config_raw(&mut mobile_config).unwrap();

    let status = e2ee_status(&json!({})).unwrap();

    assert_eq!(status["secureSessionEstablished"], false);
    assert_eq!(
        status["secretStore"]["selectedBackend"],
        "unsafe_portable_config"
    );
    assert_eq!(status["secretStore"]["privateKeyInSelectedCustody"], false);
    assert_eq!(
        status["secretStore"]["portableConfigPrivateKeyPresent"],
        true
    );
    assert_eq!(status["secretStore"]["unsafePersistenceDetected"], true);
    assert_eq!(
        status["secretStore"]["authorization"]["appPasswordPromptUsed"],
        false
    );
    assert_eq!(
        status["secretStore"]["custodyReason"],
        "secret_material_in_portable_config"
    );
    let serialized = serde_json::to_string(&status).unwrap();
    assert!(!serialized.contains(&private_key));

    set_portable_data_dir_override(previous);
}
