use super::*;
use crate::core::secure_mesh_secret_store::SecretBytes;

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
        .is_some_and(|e2ee| {
            MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
                .iter()
                .any(|(field, _)| {
                    e2ee.get(*field)
                        .and_then(Value::as_str)
                        .is_some_and(is_unredacted_secret)
                })
        })
}

pub(in crate::domain::mobile_relay) fn hydrate_runtime_secret_material_from_native_store(
    config: &Value,
    material: &mut RuntimeSecretMaterial,
    overrides: &mut RuntimeSecretOverrides,
) -> Result<()> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return hydrate_runtime_secret_material_from_secret_store(
            config,
            material,
            overrides,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        );
    }
    let store = selected_mobile_relay_secret_store();
    let namespace = native_secret_store_namespace()?;
    hydrate_runtime_secret_material_from_secret_store(
        config,
        material,
        overrides,
        store.as_ref(),
        &namespace,
    )
}

pub(in crate::domain::mobile_relay) fn hydrate_runtime_secret_material_from_native_store_with_batch(
    config: &Value,
    material: &mut RuntimeSecretMaterial,
    overrides: &mut RuntimeSecretOverrides,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some((store, session, namespace)) = batch.authorization()? else {
        return Ok(());
    };
    hydrate_runtime_secret_material_from_store_with_session(
        config,
        material,
        overrides,
        store.as_ref(),
        &session,
        &namespace,
    )
}

pub(in crate::domain::mobile_relay) fn hydrate_runtime_secret_material_from_secret_store(
    config: &Value,
    material: &mut RuntimeSecretMaterial,
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
    hydrate_runtime_secret_material_from_store_with_session(
        config, material, overrides, store, &session, namespace,
    )
}

fn hydrate_runtime_secret_material_from_store_with_session(
    config: &Value,
    material: &mut RuntimeSecretMaterial,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    overrides.mark_secret_store_authorization(session);
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        let handle = native_secret_store_handle_for_namespace(namespace, field)?;
        if let Some(secret) = store.get_secret_with_session(session, &handle)? {
            material.set_token(field, secret);
            mark_native_secret_override(overrides, field);
        }
    }
    if let Some(devices) = config.get("pairedDevices").and_then(Value::as_array) {
        for device in devices {
            let Some(handle_key) = paired_device_token_secret_store_key(device) else {
                continue;
            };
            let handle = native_secret_store_handle_for_namespace(namespace, &handle_key)?;
            let Some(secret) = store.get_secret_with_session(session, &handle)? else {
                continue;
            };
            material.set_paired_device_token(handle_key, secret);
            overrides
                .paired_device_tokens
                .push(PairedDeviceSecretOverride {
                    id: paired_device_id(device),
                    pairing_id: paired_device_pairing_id(device),
                });
        }
    }
    if let Some(bundle) = read_native_e2ee_secret_bundle(store, session, namespace)? {
        for field in MobileRelayE2eeSecretField::ALL {
            if bundle.secret(field).is_some() {
                mark_native_secret_override(overrides, field.config_field());
            }
        }
        material.merge_e2ee_bundle(bundle);
    }
    overrides.mark_e2ee_secret_store(store.backend());
    overrides.mark_secret_store_authorization(session);
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

pub(in crate::domain::mobile_relay) fn persist_runtime_secret_material_to_native_store_with_batch(
    material: &mut RuntimeSecretMaterial,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some(incoming) = material.take_e2ee_bundle() else {
        return Ok(());
    };
    let Some((store, session, namespace)) = batch.authorization()? else {
        material.merge_e2ee_bundle(incoming);
        return Ok(());
    };
    let bundle = match read_native_e2ee_secret_bundle(store.as_ref(), &session, &namespace)? {
        Some(existing) => existing.merge_replacing(incoming)?,
        None => incoming,
    };
    let handle = native_e2ee_secret_bundle_handle_for_namespace(&namespace)?;
    store.set_secret_with_session(
        &session,
        &handle,
        encode_mobile_relay_e2ee_secret_bundle(bundle)?,
    )?;
    let persisted = read_native_e2ee_secret_bundle(store.as_ref(), &session, &namespace)?
        .ok_or_else(|| anyhow!("mobile relay E2EE secret bundle disappeared after persistence"))?;
    material.merge_e2ee_bundle(persisted);
    Ok(())
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

fn take_secret(object: &mut Map<String, Value>, field: &str) -> Result<Option<SecretBytes>> {
    let Some(value) = object.remove(field) else {
        return Ok(None);
    };
    let Some(value) = value
        .as_str()
        .map(str::trim)
        .filter(|value| is_unredacted_secret(value))
    else {
        object.insert(field.to_string(), value);
        return Ok(None);
    };
    Ok(Some(SecretBytes::try_from_string(value.to_owned())?))
}

fn persist_config_secret_material_to_secret_store_with_session(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        let secret = config
            .as_object_mut()
            .map(|object| take_secret(object, field))
            .transpose()?
            .flatten();
        let Some(secret) = secret else { continue };
        let handle = native_secret_store_handle_for_namespace(namespace, field)?;
        store.set_secret_with_session(session, &handle, secret)?;
        config[field] = json!("");
        config[format!("{field}Present")] = json!(true);
    }
    if let Some(devices) = config
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            let Some(handle_key) = paired_device_token_secret_store_key(device) else {
                continue;
            };
            let secret = device
                .as_object_mut()
                .map(|object| take_secret(object, "mobileToken"))
                .transpose()?
                .flatten();
            let Some(secret) = secret else { continue };
            let handle = native_secret_store_handle_for_namespace(namespace, &handle_key)?;
            store.set_secret_with_session(session, &handle, secret)?;
            device["mobileToken"] = json!("");
            device["credentialPresent"] = json!(true);
        }
    }
    let incoming = take_e2ee_bundle(config)?;
    if let Some(incoming) = incoming {
        let bundle = match read_native_e2ee_secret_bundle(store, session, namespace)? {
            Some(existing) => existing.merge_replacing(incoming)?,
            None => incoming,
        };
        let handle = native_e2ee_secret_bundle_handle_for_namespace(namespace)?;
        store.set_secret_with_session(
            session,
            &handle,
            encode_mobile_relay_e2ee_secret_bundle(bundle)?,
        )?;
        if let Some(e2ee) = config
            .get_mut("mobileRelayE2ee")
            .and_then(Value::as_object_mut)
        {
            for (_, material_field) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
                e2ee.insert(material_field.to_string(), json!("redacted"));
            }
            e2ee.insert("secretStorageStatus".to_string(), json!(store.backend()));
        }
    }
    config["secretStorageStatus"] = json!({
        "tokenMaterial": "redacted",
        "mobileRelayPrivateKeyMaterial": "redacted",
        "selectedBackend": store.backend(),
        "unsafePersistenceForbidden": true
    });
    Ok(())
}

fn take_e2ee_bundle(config: &mut Value) -> Result<Option<MobileRelayE2eeSecretBundle>> {
    let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    else {
        return Ok(None);
    };
    let mut fields = Vec::new();
    for field in MobileRelayE2eeSecretField::ALL {
        if let Some(secret) = take_secret(e2ee, field.config_field())? {
            fields.push((field, secret));
        }
    }
    if fields.is_empty() {
        Ok(None)
    } else {
        Ok(Some(MobileRelayE2eeSecretBundle::try_from_fields(fields)?))
    }
}

fn read_native_e2ee_secret_bundle(
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<Option<MobileRelayE2eeSecretBundle>> {
    let handle = native_e2ee_secret_bundle_handle_for_namespace(namespace)?;
    store
        .get_secret_with_session(session, &handle)?
        .map(decode_mobile_relay_e2ee_secret_bundle)
        .transpose()
        .map_err(anyhow::Error::from)
}

#[allow(dead_code)]
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
    for handle in disposable_cleanup_root_secret_handles(config, namespace)? {
        store.delete_secret_with_session(session, &handle)?;
    }
    Ok(())
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
    !matches!(
        env::var(NATIVE_SECRET_STORE_MODE_ENV)
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "disabled" | "portable"
    )
}

pub(in crate::domain::mobile_relay) fn native_secret_store_supported() -> bool {
    platform_native_secret_store_supported()
}
