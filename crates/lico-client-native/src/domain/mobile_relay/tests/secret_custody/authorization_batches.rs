use super::super::test_support::*;
fn synthetic_value(label: &str) -> String { format!("{label}-{}", uuid::Uuid::new_v4()) }

#[test]
fn mobile_relay_user_level_config_mutation_reuses_single_secret_store_authorization_batch() {
    let dir = temp_dir("mobile-relay-user-level-secret-store-batch");
    let previous = set_portable_data_dir_override(Some(dir));
    let store = Arc::new(EphemeralSecretStore::new());
    let mut config = default_config();
    ensure_mobile_relay_endpoint_descriptor(&mut config, "mobile").unwrap();
    persist_config_secret_material_to_secret_store(
        &mut config,
        store.as_ref(),
        MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
    )
    .unwrap();
    save_config(&mut config).unwrap();
    let baseline_session_count = store.authorization_session_count();

    let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
    let output = with_mobile_relay_secret_store_override(store_override, || {
        config_set(&json!({
            "relayEnabled": false
        }))
    })
    .unwrap();

    assert_eq!(output["ok"], true);
    assert_eq!(
        store.authorization_session_count(),
        baseline_session_count + 1
    );
    assert_eq!(
        store.authorization_session_reasons()[baseline_session_count],
        "Mobile Relay E2EE secret store authorization batch"
    );
    assert_eq!(
        store.authorization_session_operation_counts()[baseline_session_count],
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
    );
    let persisted = fs::read_to_string(config_path().unwrap()).unwrap();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        assert!(!persisted.contains(field));
    }

    set_portable_data_dir_override(previous);
}

#[test]
fn mobile_relay_native_secret_store_cleanup_uses_single_authorization_batch() {
    let sv_cleanup_batch_seed_canar = synthetic_value("cleanup-batch-seed-canary");
    let sv_cleanup_pc_token_canary = synthetic_value("cleanup-pc-token-canary");
    let sv_cleanup_one_time_prekey_ = synthetic_value("cleanup-one-time-prekey-canary");
    let sv_cleanup_pairing_secret_c = synthetic_value("cleanup-pairing-secret-canary");
    let sv_cleanup_signing_key_cana = synthetic_value("cleanup-signing-key-canary");
    let sv_cleanup_mobile_token_can = synthetic_value("cleanup-mobile-token-canary");
    let sv_cleanup_private_key_cana = synthetic_value("cleanup-private-key-canary");
    let sv_cleanup_signed_prekey_ca = synthetic_value("cleanup-signed-prekey-canary");
    let sv_cleanup_paired_token_can = synthetic_value("cleanup-paired-token-canary");
    let store = EphemeralSecretStore::new();
    let namespace = "native-secret-store-cleanup-batch";
    let mut config = json!({
        "pcToken": sv_cleanup_pc_token_canary.as_str(),
        "mobileToken": sv_cleanup_mobile_token_can.as_str(),
        "mobileRelayE2ee": {},
        "pairedDevices": [
            {
                "id": "cleanup-device",
                "pairingId": "cleanup-pairing",
                "mobileToken": sv_cleanup_paired_token_can.as_str()
            }
        ]
    });
    for ((field, _), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.iter().copied().zip(
        [
            sv_cleanup_private_key_cana.as_str(),
            sv_cleanup_signing_key_cana.as_str(),
            sv_cleanup_signed_prekey_ca.as_str(),
            sv_cleanup_one_time_prekey_.as_str(),
            sv_cleanup_pairing_secret_c.as_str(),
        ]
        .into_iter(),
    ) {
        config["mobileRelayE2ee"][field] = json!(secret);
    }
    persist_config_secret_material_to_secret_store(&mut config, &store, namespace).unwrap();
    let handles = disposable_cleanup_root_secret_handles(&config, namespace).unwrap();
    assert!(!handles.is_empty());
    // Root cleanup deletes the full handle set (bundle + token + field + paired-device
    // keys). Seed any missing handles so the single-batch delete budget is observable.
    for handle in &handles {
        if store.get_secret(handle).unwrap().is_none() {
            store
                .set_secret(handle, sv_cleanup_batch_seed_canar.as_str())
                .unwrap();
        }
        assert!(store.get_secret(handle).unwrap().is_some());
    }
    let baseline_session_count = store.authorization_session_count();

    cleanup_native_secret_store_fields_for_store(&config, &store, namespace).unwrap();

    assert_eq!(
        store.authorization_session_count(),
        baseline_session_count + 1
    );
    assert_eq!(
        store.authorization_session_reasons()[baseline_session_count],
        "Mobile Relay E2EE secret store cleanup authorization batch"
    );
    assert_eq!(
        store.authorization_session_operation_counts()[baseline_session_count],
        handles.len()
    );
    assert_eq!(
        store.authorization_session_consumed_operation_counts()[baseline_session_count],
        handles.len()
    );
    for handle in &handles {
        assert!(store.get_secret(handle).unwrap().is_none());
    }
}
