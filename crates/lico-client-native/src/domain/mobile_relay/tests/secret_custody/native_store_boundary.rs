use super::super::test_support::*;
#[test]
fn mobile_relay_native_secret_store_boundary_invariant_persists_and_hydrates_redacted_config() {
    // store_secret_boundary_invariant: persisted config keeps redacted markers while E2EE
    // key material moves through SecureMeshSecretStore handles.
    let store = EphemeralSecretStore::new();
    let namespace = "native-secret-store-boundary-invariant";
    let secret_values = [
        "native-private-key-canary",
        "native-signing-key-canary",
        "native-signed-prekey-canary",
        "native-one-time-prekey-canary",
        "native-mlkem1024-prekey-seed-canary",
        "native-pairing-secret-canary",
    ];
    let mut config = json!({
        "mobileRelayE2ee": {}
    });
    for ((field, _), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .copied()
        .zip(secret_values.iter().copied())
    {
        config["mobileRelayE2ee"][field] = json!(secret);
    }

    assert_eq!(store.authorization_session_count(), 0);
    persist_config_secret_material_to_secret_store(&mut config, &store, namespace).unwrap();
    assert_eq!(store.authorization_session_count(), 1);
    assert_eq!(
        store.authorization_session_reasons()[0],
        "Mobile Relay E2EE secret bundle persistence"
    );
    assert_eq!(
        store.authorization_session_operation_counts()[0],
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
    );

    let serialized = serde_json::to_string(&config).unwrap();
    let bundle_handle = native_e2ee_secret_bundle_handle_for_namespace(namespace).unwrap();
    let bundle_raw = store
        .get_secret(&bundle_handle)
        .unwrap()
        .expect("native E2EE secret bundle should be persisted");
    let bundle = parse_native_e2ee_secret_bundle(&bundle_raw).unwrap();
    for ((field, material_field), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .copied()
        .zip(secret_values.iter().copied())
    {
        assert!(config["mobileRelayE2ee"].get(field).is_none());
        assert_eq!(config["mobileRelayE2ee"][material_field], "redacted");
        assert!(!serialized.contains(field));
        assert!(!serialized.contains(secret));
        assert_eq!(
            bundle
                .iter()
                .find(|(bundle_field, _)| *bundle_field == field)
                .map(|(_, bundle_secret)| bundle_secret.as_str()),
            Some(secret)
        );
        let handle = native_secret_store_handle_for_namespace(namespace, field).unwrap();
        assert!(store.get_secret(&handle).unwrap().is_none());
    }
    assert_eq!(
        config["mobileRelayE2ee"]["secretStorageStatus"],
        "memory-only-ephemeral"
    );
    assert_eq!(
        config["secretStorageStatus"]["selectedBackend"],
        "memory-only-ephemeral"
    );

    let mut overrides = RuntimeSecretOverrides::default();
    hydrate_config_secret_material_from_secret_store(
        &mut config,
        &mut overrides,
        &store,
        namespace,
    )
    .unwrap();
    assert_eq!(store.authorization_session_count(), 2);
    assert_eq!(
        store.authorization_session_reasons()[1],
        "Mobile Relay E2EE secret bundle hydration"
    );
    assert_eq!(
        store.authorization_session_operation_counts()[1],
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
    );

    for ((field, _), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .copied()
        .zip(secret_values.iter().copied())
    {
        assert_eq!(config["mobileRelayE2ee"][field], secret);
    }
    assert!(has_runtime_secret_overrides(&overrides));
    assert_eq!(
        secret_storage_backend_for_overrides(&overrides),
        "memory-only-ephemeral"
    );
}
