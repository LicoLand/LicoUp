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
    let bundle = decode_mobile_relay_e2ee_secret_bundle(bundle_raw).unwrap();
    for (((field, material_field), secret_field), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .copied()
        .zip(MobileRelayE2eeSecretField::ALL)
        .zip(secret_values.iter().copied())
    {
        assert!(config["mobileRelayE2ee"].get(field).is_none());
        assert_eq!(config["mobileRelayE2ee"][material_field], "redacted");
        assert!(!serialized.contains(field));
        assert!(!serialized.contains(secret));
        assert_eq!(
            bundle
                .secret(secret_field)
                .and_then(|value| value.expose_utf8().ok()),
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
    let mut material = RuntimeSecretMaterial::new();
    hydrate_runtime_secret_material_from_secret_store(
        &config,
        &mut material,
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

    for (field, secret) in MobileRelayE2eeSecretField::ALL
        .into_iter()
        .zip(secret_values)
    {
        assert_eq!(
            material.e2ee_secret(field).unwrap().expose_utf8().unwrap(),
            secret,
        );
    }
    assert!(has_runtime_secret_overrides(&overrides));
    assert_eq!(
        secret_storage_backend_for_overrides(&overrides),
        "memory-only-ephemeral"
    );
}

fn persist_fixture_bundle(
    store: &EphemeralSecretStore,
    namespace: &str,
    material: &mut RuntimeSecretMaterial,
) {
    let bundle = material.take_e2ee_bundle().unwrap();
    let session = store
        .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
            "Fixture custody bundle persistence",
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
        ))
        .unwrap();
    store
        .set_secret_with_session(
            &session,
            &native_e2ee_secret_bundle_handle_for_namespace(namespace).unwrap(),
            encode_mobile_relay_e2ee_secret_bundle(bundle).unwrap(),
        )
        .unwrap();
}

#[test]
fn relay_custody_namespace_is_derived_from_the_data_home_config_path() {
    let home_a = temp_dir("mobile-relay-custody-namespace-a");
    let home_b = temp_dir("mobile-relay-custody-namespace-b");
    let previous = set_portable_data_dir_override(Some(home_a.to_path_buf()));
    let namespace_a = native_secret_store_namespace().unwrap();
    let shared_namespace_a = native_secret_store_shared_secret_classes_namespace().unwrap();
    let config_path_a = config_path().unwrap();

    set_portable_data_dir_override(Some(home_b.to_path_buf()));
    let namespace_b = native_secret_store_namespace().unwrap();
    let config_path_b = config_path().unwrap();

    assert_ne!(config_path_a, config_path_b);
    assert_ne!(namespace_a, namespace_b);
    assert_eq!(
        namespace_a,
        sha256_hex(config_path_a.to_string_lossy().as_bytes())
    );
    assert_eq!(
        namespace_b,
        sha256_hex(config_path_b.to_string_lossy().as_bytes())
    );
    assert_eq!(namespace_b, native_secret_store_namespace().unwrap());
    assert_ne!(
        shared_namespace_a,
        native_secret_store_shared_secret_classes_namespace().unwrap()
    );
    set_portable_data_dir_override(previous);
}

#[test]
fn same_home_hydration_preserves_identity_and_fingerprint() {
    let home = temp_dir("mobile-relay-custody-same-home");
    let previous = set_portable_data_dir_override(Some(home.to_path_buf()));
    let store = EphemeralSecretStore::new();
    let mut config = default_config();
    let mut material = RuntimeSecretMaterial::new();
    ensure_mobile_relay_endpoint_material(&mut config, &mut material, "desktop_sidecar").unwrap();
    let namespace = native_secret_store_namespace().unwrap();
    let identity_before = local_public_device_identity(&config).unwrap();
    let endpoint_fingerprint_before = local_endpoint_state(&config, &material)
        .unwrap()
        .fingerprint;
    assert!(
        material
            .e2ee_secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_some()
    );
    persist_fixture_bundle(&store, &namespace, &mut material);

    let mut hydrated = RuntimeSecretMaterial::new();
    let mut overrides = RuntimeSecretOverrides::default();
    hydrate_runtime_secret_material_from_secret_store(
        &config,
        &mut hydrated,
        &mut overrides,
        &store,
        &namespace,
    )
    .unwrap();
    assert!(
        hydrated
            .e2ee_secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_some()
    );
    assert_eq!(
        local_endpoint_state(&config, &hydrated)
            .unwrap()
            .fingerprint,
        endpoint_fingerprint_before
    );
    assert_eq!(
        local_public_device_identity(&config).unwrap(),
        identity_before
    );

    ensure_mobile_relay_endpoint_material(&mut config, &mut hydrated, "desktop_sidecar").unwrap();
    assert_eq!(
        local_public_device_identity(&config).unwrap(),
        identity_before
    );
    assert_eq!(
        local_endpoint_state(&config, &hydrated)
            .unwrap()
            .fingerprint,
        endpoint_fingerprint_before
    );
    set_portable_data_dir_override(previous);
}

#[test]
fn relocated_home_custody_miss_is_refused_without_identity_regeneration() {
    let home_a = temp_dir("mobile-relay-custody-relocation-a");
    let home_b = temp_dir("mobile-relay-custody-relocation-b");
    let previous = set_portable_data_dir_override(Some(home_a.to_path_buf()));
    let store = EphemeralSecretStore::new();
    let mut config = default_config();
    let mut material = RuntimeSecretMaterial::new();
    ensure_mobile_relay_endpoint_material(&mut config, &mut material, "desktop_sidecar").unwrap();
    let namespace_a = native_secret_store_namespace().unwrap();
    let identity_before = local_public_device_identity(&config).unwrap();
    persist_fixture_bundle(&store, &namespace_a, &mut material);
    save_config_raw(&mut config).unwrap();
    assert_eq!(
        config["mobileRelayE2ee"][CUSTODY_NAMESPACE_FIELD],
        namespace_a
    );

    set_portable_data_dir_override(Some(home_b.to_path_buf()));
    let namespace_b = native_secret_store_namespace().unwrap();
    assert_ne!(namespace_a, namespace_b);

    let mut relocated = config.clone();
    let before = relocated.clone();
    let mut relocated_material = RuntimeSecretMaterial::new();
    let mut relocated_overrides = RuntimeSecretOverrides::default();
    hydrate_runtime_secret_material_from_secret_store(
        &relocated,
        &mut relocated_material,
        &mut relocated_overrides,
        &store,
        &namespace_b,
    )
    .unwrap();
    assert!(
        relocated_material
            .e2ee_secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_none()
    );

    let error = ensure_mobile_relay_endpoint_material(
        &mut relocated,
        &mut relocated_material,
        "desktop_sidecar",
    )
    .unwrap_err()
    .to_string();

    assert!(error.contains("different data home"), "{error}");
    assert_eq!(relocated, before);
    assert_eq!(
        local_public_device_identity(&relocated).unwrap(),
        identity_before
    );
    assert!(
        relocated_material
            .e2ee_secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_none()
    );
    set_portable_data_dir_override(previous);
}

#[test]
fn same_home_custody_miss_keeps_documented_reprovisioning() {
    let home = temp_dir("mobile-relay-custody-same-home-miss");
    let previous = set_portable_data_dir_override(Some(home.to_path_buf()));
    let mut config = default_config();
    let mut material = RuntimeSecretMaterial::new();
    ensure_mobile_relay_endpoint_material(&mut config, &mut material, "desktop_sidecar").unwrap();
    save_config_raw(&mut config).unwrap();

    let mut lost = RuntimeSecretMaterial::new();
    ensure_mobile_relay_endpoint_material(&mut config, &mut lost, "desktop_sidecar").unwrap();
    assert!(
        lost.e2ee_secret(MobileRelayE2eeSecretField::PrivateKey)
            .is_some()
    );
    assert_eq!(
        config["mobileRelayE2ee"][CUSTODY_NAMESPACE_FIELD],
        native_secret_store_namespace().unwrap()
    );
    set_portable_data_dir_override(previous);
}
