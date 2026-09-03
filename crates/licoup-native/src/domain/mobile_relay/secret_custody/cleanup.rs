use super::*;
use crate::core::secure_mesh_secret_store::SecretBytes;

pub(in crate::domain::mobile_relay) fn e2ee_secret_store_cleanup_in(
    params: &Value,
) -> Result<Value> {
    ensure!(
        params
            .get("disposableProof")
            .and_then(Value::as_str)
            .map(str::trim)
            == Some("true"),
        "mobile relay secret-store cleanup requires explicit --disposable-proof true"
    );

    let config = load_config_for_disposable_cleanup()?;
    let pairwise_path = mobile_relay_pairwise_store_path()?;
    let pairwise_database_present_before = pairwise_path.exists();
    let pairwise_handles = if pairwise_database_present_before {
        let store = mobile_relay_pairwise_store()?;
        let handles = store.referenced_secret_snapshot_handles()?;
        drop(store);
        handles
    } else {
        Vec::new()
    };
    let pairwise_snapshot_handle_count = pairwise_handles.len();

    let (store, namespace) = disposable_cleanup_secret_store()?;
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let mut handles = disposable_cleanup_root_secret_handles(&config, &namespace)?;
    let root_secret_handle_count = handles.len();
    handles.extend(pairwise_handles);
    handles.sort_by(|left, right| {
        left.namespace()
            .cmp(right.namespace())
            .then_with(|| left.key().cmp(right.key()))
    });
    handles.dedup();
    let operation_count = handles.len();
    ensure!(
        operation_count > 0,
        "mobile relay disposable cleanup has no bounded secret-store operations"
    );

    let session =
        store.begin_authorized_session(&SecretStoreAuthorizationRequest::noninteractive(
            "Mobile Relay disposable proof secret cleanup",
            operation_count,
        ))?;
    for handle in &handles {
        store
            .delete_secret_with_session(&session, handle)
            .context("mobile relay disposable secret cleanup failed")?;
    }
    ensure!(
        session.consumed_operation_count() == operation_count
            && session.authorization_batch_within_budget()
            && session.remaining_operation_count() == 0,
        "mobile relay disposable cleanup operation budget mismatch"
    );

    let removed_pairwise_database_file_count =
        remove_mobile_relay_pairwise_store_files(&pairwise_path)?;
    Ok(json!({
        "ok": true,
        "status": "cleaned",
        "disposableProof": true,
        "deletedSecretHandleCount": operation_count,
        "rootSecretHandleCount": root_secret_handle_count,
        "pairwiseSnapshotHandleCount": pairwise_snapshot_handle_count,
        "pairwiseDatabasePresentBefore": pairwise_database_present_before,
        "pairwiseDatabaseRemoved": !pairwise_path.exists(),
        "removedPairwiseDatabaseFileCount": removed_pairwise_database_file_count,
        "secretStoreAuthorization": {
            "backend": session.backend(),
            "allowInteraction": session.allow_interaction(),
            "operationCount": session.operation_count(),
            "consumedOperationCount": session.consumed_operation_count(),
            "remainingOperationCount": session.remaining_operation_count(),
            "authorizationBatchWithinBudget": session.authorization_batch_within_budget()
        }
    }))
}

fn load_config_for_disposable_cleanup() -> Result<Value> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(normalize_config(json!({})));
    }
    let raw =
        fs::read_to_string(&path).context("mobile relay disposable cleanup config read failed")?;
    let parsed = serde_json::from_str::<Value>(&raw)
        .context("mobile relay disposable cleanup config is invalid")?;
    crate::domain::mobile_relay::validate_current_config_document(&parsed)?;
    Ok(normalize_config(parsed))
}

fn disposable_cleanup_secret_store() -> Result<(Arc<dyn SecureMeshSecretStore>, String)> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return Ok((
            store,
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE.to_string(),
        ));
    }
    ensure!(
        native_secret_store_enabled(),
        "mobile relay native secret store is required for disposable cleanup"
    );
    Ok((
        Arc::new(native_secret_store()),
        native_secret_store_namespace()?,
    ))
}

pub(in crate::domain::mobile_relay) fn disposable_cleanup_root_secret_handles(
    config: &Value,
    namespace: &str,
) -> Result<Vec<SecretStoreHandle>> {
    let mut handles = vec![native_e2ee_secret_bundle_handle_for_namespace(namespace)?];
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        handles.push(native_secret_store_handle_for_namespace(namespace, field)?);
    }
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        handles.push(native_secret_store_handle_for_namespace(namespace, field)?);
    }
    if let Some(devices) = config.get("pairedDevices").and_then(Value::as_array) {
        for device in devices {
            if let Some(key) = paired_device_token_secret_store_key(device) {
                handles.push(native_secret_store_handle_for_namespace(namespace, &key)?);
            }
        }
    }
    handles.sort_by(|left, right| {
        left.namespace()
            .cmp(right.namespace())
            .then_with(|| left.key().cmp(right.key()))
    });
    handles.dedup();
    Ok(handles)
}

fn remove_mobile_relay_pairwise_store_files(path: &Path) -> Result<usize> {
    let mut removed = 0usize;
    let mut candidates = vec![path.to_path_buf()];
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut candidate = path.as_os_str().to_os_string();
        candidate.push(suffix);
        candidates.push(PathBuf::from(candidate));
    }
    for candidate in candidates {
        match fs::remove_file(&candidate) {
            Ok(()) => removed = removed.saturating_add(1),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .context("mobile relay disposable pairwise database cleanup failed");
            }
        }
    }
    Ok(removed)
}

pub(in crate::domain::mobile_relay) fn native_secret_store() -> PlatformSecretStore {
    PlatformSecretStore::new(
        NATIVE_SECRET_STORE_SERVICE,
        NATIVE_SECRET_STORE_ACCOUNT_PREFIX,
    )
}

pub(in crate::domain::mobile_relay) fn native_secret_store_namespace() -> Result<String> {
    let path = config_path()?;
    Ok(sha256_hex(path.to_string_lossy().as_bytes()))
}

pub(in crate::domain::mobile_relay) fn native_secret_store_handle_for_namespace(
    namespace: &str,
    field: &str,
) -> Result<SecretStoreHandle> {
    SecretStoreHandle::new(
        format!("{}:{}", NATIVE_SECRET_STORE_ACCOUNT_PREFIX, namespace),
        field,
    )
}

pub(in crate::domain::mobile_relay) fn native_e2ee_secret_bundle_handle_for_namespace(
    namespace: &str,
) -> Result<SecretStoreHandle> {
    native_secret_store_handle_for_namespace(namespace, MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_KEY)
}

pub(in crate::domain::mobile_relay) fn native_secret_store_shared_secret_classes_namespace()
-> Result<String> {
    let path = config_path()?;
    Ok(format!(
        "{}:sharedSecretClasses",
        sha256_hex(path.to_string_lossy().as_bytes())
    ))
}

pub(in crate::domain::mobile_relay) fn verify_secret_class_round_trip_with_session(
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: impl Into<String>,
    secret_classes: &[&str],
) -> Result<SecretClassPersistenceProof> {
    let namespace = namespace.into();
    let mut stored_class_count = 0usize;
    let mut deleted_class_count = 0usize;
    let mut handles = Vec::new();
    for secret_class in secret_classes {
        let handle = SecretStoreHandle::new(&namespace, *secret_class)?;
        let proof_secret = format!("secure-mesh-secret-class-proof:{}", Uuid::new_v4());
        store.set_secret_with_session(
            session,
            &handle,
            SecretBytes::try_from_string(proof_secret.clone())?,
        )?;
        if store
            .get_secret_with_session(session, &handle)?
            .as_ref()
            .map(SecretBytes::expose_bytes)
            == Some(proof_secret.as_bytes())
        {
            stored_class_count = stored_class_count.saturating_add(1);
        }
        handles.push(handle);
    }
    for handle in &handles {
        store.delete_secret_with_session(session, handle)?;
        if store.get_secret_with_session(session, handle)?.is_none() {
            deleted_class_count = deleted_class_count.saturating_add(1);
        }
    }
    Ok(SecretClassPersistenceProof {
        backend: store.backend(),
        secret_classes: secret_classes
            .iter()
            .map(|secret_class| (*secret_class).to_string())
            .collect(),
        requested_class_count: secret_classes.len(),
        persisted_class_count: stored_class_count,
        deleted_class_count,
        all_classes_persisted: stored_class_count == secret_classes.len(),
        all_classes_deleted: deleted_class_count == secret_classes.len(),
        raw_secret_material_included: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disposable_cleanup_handle_set_is_deduplicated_and_bounded() {
        let config = json!({
            "pairedDevices": [
                {"id": "device-a", "pairingId": "pairing-a"},
                {"id": "device-b", "pairingId": "pairing-a"}
            ]
        });
        let handles = disposable_cleanup_root_secret_handles(&config, "fixture").unwrap();
        let expected = 1
            + MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS.len()
            + MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len()
            + 1;

        assert_eq!(handles.len(), expected);
        assert!(handles.windows(2).all(|pair| pair[0] != pair[1]));
    }
}
