use super::*;

pub(in crate::domain::mobile_relay) const MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS: [(&str, &str);
    6] = [
    ("privateKeyBase64url", "privateKeyMaterial"),
    ("signingKeyBase64url", "signingKeyMaterial"),
    (
        "signedPrekeyPrivateKeyBase64url",
        "signedPrekeyPrivateKeyMaterial",
    ),
    (
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPrivateKeyMaterial",
    ),
    (
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeySeedMaterial",
    ),
    ("pairingSecretBase64url", "pairingSecretMaterial"),
];
pub(in crate::domain::mobile_relay) const MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS: [&str; 2] =
    ["pcToken", "mobileToken"];
pub(in crate::domain::mobile_relay) const MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_KEY: &str =
    "mobileRelayE2eeSecretBundle.pqxdhMlKem1024";
const MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_SCHEMA_VERSION: &str =
    "licolite.mobile-relay.e2ee-secret-bundle.pqxdh-mlkem1024.v1";

pub(in crate::domain::mobile_relay) fn mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
-> usize {
    MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .len()
        .saturating_mul(2)
        .saturating_add(
            MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS
                .len()
                .saturating_mul(2),
        )
        .saturating_add(5)
}

pub(in crate::domain::mobile_relay) fn mobile_relay_secret_store_self_test_authorization_batch_operation_count()
-> usize {
    mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        .saturating_add(
            NATIVE_SECRET_STORE_SHARED_SECRET_CLASSES
                .len()
                .saturating_mul(4),
        )
        .saturating_add(4)
}

pub(in crate::domain::mobile_relay) fn config_contains_native_store_secret_material(
    config: &Value,
) -> bool {
    config
        .get("mobileRelayE2ee")
        .and_then(Value::as_object)
        .map(|e2ee| {
            MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
                .iter()
                .any(|(field, _)| {
                    e2ee.get(*field)
                        .and_then(Value::as_str)
                        .is_some_and(is_unredacted_secret)
                })
        })
        .unwrap_or(false)
}

pub(in crate::domain::mobile_relay) fn hydrate_config_secret_material_from_native_store(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
) -> Result<()> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return hydrate_config_secret_material_from_secret_store(
            config,
            overrides,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        );
    }
    let store = selected_mobile_relay_secret_store();
    let namespace = native_secret_store_namespace()?;
    hydrate_config_secret_material_from_secret_store(config, overrides, store.as_ref(), &namespace)
}

pub(in crate::domain::mobile_relay) fn hydrate_config_secret_material_from_native_store_with_batch(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some((store, session, namespace)) = batch.authorization()? else {
        return Ok(());
    };
    hydrate_config_secret_material_from_secret_store_with_session(
        config,
        overrides,
        store.as_ref(),
        &session,
        &namespace,
    )
}

pub(in crate::domain::mobile_relay) fn hydrate_config_secret_material_from_secret_store(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    namespace: &str,
) -> Result<()> {
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Mobile Relay E2EE secret bundle hydration",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    ))?;
    hydrate_config_secret_material_from_secret_store_with_session(
        config, overrides, store, &session, namespace,
    )
}

fn hydrate_config_secret_material_from_secret_store_with_session(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    overrides.mark_secret_store_authorization(session);
    hydrate_config_token_secret_material_from_secret_store_with_session(
        config, overrides, store, session, namespace,
    )?;
    let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    else {
        overrides.mark_secret_store_authorization(session);
        return Ok(());
    };
    let mut hydrated_fields = Vec::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if e2ee
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(is_unredacted_secret)
        {
            hydrated_fields.push(field);
        }
    }
    if hydrated_fields.len() < MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len() {
        let bundle = read_native_e2ee_secret_bundle(store, &session, namespace)?;
        if let Some(bundle) = bundle {
            for (field, secret) in bundle {
                if e2ee
                    .get(field)
                    .and_then(Value::as_str)
                    .is_some_and(is_unredacted_secret)
                {
                    continue;
                }
                e2ee.insert(field.to_string(), json!(secret));
                hydrated_fields.push(field);
            }
        }
    }
    if !hydrated_fields.is_empty() {
        for field in hydrated_fields {
            mark_native_secret_override(overrides, field);
        }
        e2ee.insert("secretStorageStatus".to_string(), json!(store.backend()));
        overrides.mark_e2ee_secret_store(store.backend());
    }
    overrides.mark_secret_store_authorization(session);
    Ok(())
}

fn hydrate_config_token_secret_material_from_secret_store_with_session(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let mut hydrated_any = false;
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        if config
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(is_unredacted_secret)
        {
            continue;
        }
        let handle = native_secret_store_handle_for_namespace(namespace, field)?;
        if let Some(secret) = store.get_secret_with_session(session, &handle)? {
            let secret = secret.trim();
            if is_unredacted_secret(secret) {
                config[field] = json!(secret);
                mark_native_secret_override(overrides, field);
                hydrated_any = true;
            }
        }
    }

    if let Some(devices) = config
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            if device
                .get("mobileToken")
                .and_then(Value::as_str)
                .is_some_and(is_unredacted_secret)
            {
                continue;
            }
            let Some(handle_key) = paired_device_token_secret_store_key(device) else {
                continue;
            };
            let handle = native_secret_store_handle_for_namespace(namespace, &handle_key)?;
            let Some(secret) = store.get_secret_with_session(session, &handle)? else {
                continue;
            };
            let secret = secret.trim();
            if !is_unredacted_secret(secret) {
                continue;
            }
            device["mobileToken"] = json!(secret);
            device["credentialPresent"] = json!(true);
            hydrated_any = true;
            overrides
                .paired_device_tokens
                .push(PairedDeviceSecretOverride {
                    id: paired_device_id(device),
                    pairing_id: paired_device_pairing_id(device),
                });
        }
    }
    if hydrated_any {
        overrides.mark_e2ee_secret_store(store.backend());
    }
    Ok(())
}

pub(in crate::domain::mobile_relay) fn persist_config_secret_material_to_native_store(
    config: &mut Value,
) -> Result<()> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return persist_config_secret_material_to_secret_store(
            config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        );
    }
    let store = selected_mobile_relay_secret_store();
    let namespace = native_secret_store_namespace()?;
    persist_config_secret_material_to_secret_store(config, store.as_ref(), &namespace)
}

pub(in crate::domain::mobile_relay) fn persist_config_secret_material_to_native_store_with_batch(
    config: &mut Value,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some((store, session, namespace)) = batch.authorization()? else {
        return Ok(());
    };
    persist_config_secret_material_to_secret_store_with_session(
        config,
        store.as_ref(),
        &session,
        &namespace,
    )
}

pub(in crate::domain::mobile_relay) fn persist_config_secret_material_to_secret_store(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    namespace: &str,
) -> Result<()> {
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Mobile Relay E2EE secret bundle persistence",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    ))?;
    persist_config_secret_material_to_secret_store_with_session(config, store, &session, namespace)
}

fn persist_config_secret_material_to_secret_store_with_session(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    persist_config_token_secret_material_to_secret_store_with_session(
        config, store, session, namespace,
    )?;
    let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    else {
        return Ok(());
    };
    let incoming = collect_unredacted_e2ee_secret_fields(e2ee);
    if incoming.is_empty() {
        return Ok(());
    }
    let complete = incoming.len() == MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len();
    let bundle = if complete {
        incoming
    } else {
        merge_e2ee_secret_bundles(
            read_native_e2ee_secret_bundle(store, &session, namespace)?.unwrap_or_default(),
            incoming,
        )
    };
    let handle = native_e2ee_secret_bundle_handle_for_namespace(namespace)?;
    store.set_secret_with_session(
        &session,
        &handle,
        &serialize_native_e2ee_secret_bundle(&bundle)?,
    )?;
    for (field, material_field) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if bundle
            .iter()
            .any(|(bundle_field, _)| *bundle_field == field)
        {
            e2ee.remove(field);
            e2ee.insert(material_field.to_string(), json!("redacted"));
        }
    }
    e2ee.insert("secretStorageStatus".to_string(), json!(store.backend()));
    config["secretStorageStatus"] = json!({
        "tokenMaterial": "redacted",
        "mobileRelayPrivateKeyMaterial": "redacted",
        "selectedBackend": store.backend(),
        "unsafePersistenceForbidden": true
    });
    Ok(())
}

fn persist_config_token_secret_material_to_secret_store_with_session(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let mut persisted = false;
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        let Some(secret) = config
            .get(field)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| is_unredacted_secret(value))
            .map(str::to_string)
        else {
            continue;
        };
        let handle = native_secret_store_handle_for_namespace(namespace, field)?;
        store.set_secret_with_session(session, &handle, &secret)?;
        config[field] = json!("");
        config[format!("{field}Present")] = json!(true);
        persisted = true;
    }

    if let Some(devices) = config
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            let Some(secret) = device
                .get("mobileToken")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| is_unredacted_secret(value))
                .map(str::to_string)
            else {
                continue;
            };
            let Some(handle_key) = paired_device_token_secret_store_key(device) else {
                continue;
            };
            let handle = native_secret_store_handle_for_namespace(namespace, &handle_key)?;
            store.set_secret_with_session(session, &handle, &secret)?;
            device["mobileToken"] = json!("");
            device["credentialPresent"] = json!(true);
            persisted = true;
        }
    }

    if persisted {
        config["secretStorageStatus"] = json!({
            "tokenMaterial": "redacted",
            "mobileRelayPrivateKeyMaterial": "redacted",
            "selectedBackend": store.backend(),
            "unsafePersistenceForbidden": true
        });
    }
    Ok(())
}

#[allow(dead_code)] // unit-tested; matrix source check requires the symbol
pub(in crate::domain::mobile_relay) fn cleanup_native_secret_store_fields_for_store(
    config: &Value,
    store: &dyn SecureMeshSecretStore,
    namespace: &str,
) -> Result<()> {
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let handles = disposable_cleanup_root_secret_handles(config, namespace)?;
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Mobile Relay E2EE secret store cleanup authorization batch",
        handles.len().max(1),
    ))?;
    cleanup_native_secret_store_fields_for_store_with_session(config, store, &session, namespace)
}

pub(in crate::domain::mobile_relay) fn cleanup_native_secret_store_fields_for_store_with_session(
    config: &Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let handles = disposable_cleanup_root_secret_handles(config, namespace)?;
    for handle in &handles {
        store.delete_secret_with_session(session, handle)?;
    }
    Ok(())
}

fn collect_unredacted_e2ee_secret_fields(
    e2ee: &serde_json::Map<String, Value>,
) -> Vec<(&'static str, String)> {
    MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .filter_map(|(field, _)| {
            e2ee.get(*field)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| is_unredacted_secret(value))
                .map(|secret| (*field, secret.to_string()))
        })
        .collect()
}

fn read_native_e2ee_secret_bundle(
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<Option<Vec<(&'static str, String)>>> {
    let handle = native_e2ee_secret_bundle_handle_for_namespace(namespace)?;
    let Some(raw) = store.get_secret_with_session(session, &handle)? else {
        return Ok(None);
    };
    parse_native_e2ee_secret_bundle(&raw).map(Some)
}

fn merge_e2ee_secret_bundles(
    existing: Vec<(&'static str, String)>,
    incoming: Vec<(&'static str, String)>,
) -> Vec<(&'static str, String)> {
    let mut merged = Vec::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if let Some((_, secret)) = incoming
            .iter()
            .find(|(incoming_field, _)| *incoming_field == field)
        {
            merged.push((field, secret.clone()));
        } else if let Some((_, secret)) = existing
            .iter()
            .find(|(existing_field, _)| *existing_field == field)
        {
            merged.push((field, secret.clone()));
        }
    }
    merged
}

pub(in crate::domain::mobile_relay) fn serialize_native_e2ee_secret_bundle(
    secrets: &[(&'static str, String)],
) -> Result<String> {
    ensure!(
        !secrets.is_empty(),
        "mobile relay native E2EE secret bundle cannot be empty"
    );
    let mut secret_values = serde_json::Map::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if let Some((_, secret)) = secrets
            .iter()
            .find(|(secret_field, _)| *secret_field == field)
        {
            secret_values.insert(field.to_string(), json!(secret));
        }
    }
    ensure!(
        !secret_values.is_empty(),
        "mobile relay native E2EE secret bundle has no supported fields"
    );
    Ok(serde_json::to_string(&json!({
        "schemaVersion": MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_SCHEMA_VERSION,
        "secrets": secret_values
    }))?)
}

pub(in crate::domain::mobile_relay) fn parse_native_e2ee_secret_bundle(
    raw: &str,
) -> Result<Vec<(&'static str, String)>> {
    let parsed = serde_json::from_str::<Value>(raw)
        .map_err(|_| anyhow!("mobile relay native E2EE secret bundle is invalid"))?;
    ensure!(
        parsed.get("schemaVersion").and_then(Value::as_str)
            == Some(MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_SCHEMA_VERSION),
        "mobile relay native E2EE secret bundle schema is invalid"
    );
    let secrets = parsed
        .get("secrets")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("mobile relay native E2EE secret bundle is missing secrets"))?;
    let mut bundle = Vec::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if let Some(secret) = secrets
            .get(field)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| is_unredacted_secret(value))
        {
            bundle.push((field, secret.to_string()));
        }
    }
    ensure!(
        !bundle.is_empty(),
        "mobile relay native E2EE secret bundle has no usable secret fields"
    );
    Ok(bundle)
}

fn mark_native_secret_override(overrides: &mut RuntimeSecretOverrides, field: &str) {
    match field {
        "pcToken" => overrides.pc_token = true,
        "mobileToken" => overrides.mobile_token = true,
        "privateKeyBase64url" => overrides.e2ee_private_key = true,
        "signingKeyBase64url" => overrides.e2ee_signing_key = true,
        "signedPrekeyPrivateKeyBase64url" => overrides.e2ee_signed_prekey_private_key = true,
        "oneTimePrekeyPrivateKeyBase64url" => overrides.e2ee_one_time_prekey_private_key = true,
        "oneTimeMlKem1024PrekeySeedBase64url" => {
            overrides.e2ee_one_time_mlkem1024_prekey_seed = true
        }
        "pairingSecretBase64url" => overrides.e2ee_pairing_secret = true,
        _ => {}
    }
}

pub(in crate::domain::mobile_relay) fn native_secret_store_enabled() -> bool {
    native_secret_store_permitted() && native_secret_store_supported()
}

pub(in crate::domain::mobile_relay) fn native_secret_store_permitted() -> bool {
    if cfg!(test) {
        return false;
    }
    if matches!(
        env::var(NATIVE_SECRET_STORE_MODE_ENV)
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "disabled" | "portable"
    ) {
        return false;
    }
    true
}

pub(in crate::domain::mobile_relay) fn native_secret_store_supported() -> bool {
    platform_native_secret_store_supported()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_e2ee_secrets_round_trip_only_allowlisted_fields() {
        let encoded = serialize_native_e2ee_secret_bundle(&[
            ("privateKeyBase64url", "fixture-private".to_string()),
            ("signingKeyBase64url", "fixture-signing".to_string()),
        ])
        .unwrap();
        let decoded = parse_native_e2ee_secret_bundle(&encoded).unwrap();

        assert_eq!(decoded.len(), 2);
        assert!(parse_native_e2ee_secret_bundle(
            r#"{"schemaVersion":"licolite.mobile-relay.e2ee-secret-bundle.v1","secrets":{"unknownField":"value"}}"#
        )
        .is_err());
    }
}
