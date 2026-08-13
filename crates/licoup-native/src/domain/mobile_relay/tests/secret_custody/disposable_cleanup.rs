use super::super::test_support::*;
use crate::core::secure_mesh_secret_store::{SecretBytes, SecretZeroizeProbe};
#[test]
fn mobile_relay_disposable_secret_cleanup_is_complete_noninteractive_and_exactly_budgeted() {
    let dir = temp_dir("mobile-relay-disposable-secret-cleanup");
    let previous = set_portable_data_dir_override(Some(dir.to_path_buf()));
    let secret_store = Arc::new(EphemeralSecretStore::new());
    let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
    let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

    with_mobile_relay_secret_store_override(mobile_store_override, || {
        with_pairwise_secret_store_override(pairwise_store_override, || {
            let mut pc_config = default_config();
            let mut mobile_config = default_config();
            pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

            let pairwise_path = mobile_relay_pairwise_store_path()?;
            assert!(pairwise_path.exists());
            let pairwise_handles = {
                let store = mobile_relay_pairwise_store()?;
                store.referenced_secret_snapshot_handles()?
            };
            assert!(!pairwise_handles.is_empty());
            for handle in &pairwise_handles {
                assert!(secret_store.get_secret(handle)?.is_some());
            }

            let mut config = default_config();
            config["pairedDevices"] = json!([
                {
                    "id": "cleanup-device-a",
                    "pairingId": "cleanup-pairing-a",
                    "mobileToken": "",
                    "credentialPresent": true
                },
                {
                    "id": "cleanup-device-b",
                    "pairingId": "cleanup-pairing-b",
                    "mobileToken": "",
                    "credentialPresent": true
                }
            ]);
            save_config_raw(&mut config)?;
            let root_handles = disposable_cleanup_root_secret_handles(
                &config,
                MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            )?;
            assert_eq!(
                root_handles.len(),
                1 + MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS.len()
                    + MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len()
                    + 2
            );
            let mut cleanup_probes = Vec::new();
            for handle in &root_handles {
                let probe = SecretZeroizeProbe::new();
                secret_store.set_secret(
                    handle,
                    SecretBytes::try_from_bytes_with_test_zeroize_probe(
                        b"synthetic-disposable-cleanup-canary".to_vec(),
                        probe.clone(),
                    )?,
                )?;
                cleanup_probes.push(probe);
            }

            let mut all_handles = root_handles.clone();
            all_handles.extend(pairwise_handles.clone());
            let baseline_session_count = secret_store.authorization_session_count();
            let output = e2ee_secret_store_cleanup(&json!({
                "disposableProof": "true"
            }))?;

            let operation_count = all_handles.len();
            assert_eq!(output["ok"], true);
            assert_eq!(output["status"], "cleaned");
            assert_eq!(output["rootSecretHandleCount"], root_handles.len());
            assert_eq!(
                output["pairwiseSnapshotHandleCount"],
                pairwise_handles.len()
            );
            assert_eq!(output["deletedSecretHandleCount"], operation_count);
            assert_eq!(output["pairwiseDatabasePresentBefore"], true);
            assert_eq!(output["pairwiseDatabaseRemoved"], true);
            assert!(!pairwise_path.exists());
            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay disposable proof secret cleanup"
            );
            assert_eq!(
                secret_store.authorization_session_operation_counts()[baseline_session_count],
                operation_count
            );
            assert_eq!(
                secret_store.authorization_session_consumed_operation_counts()
                    [baseline_session_count],
                operation_count
            );
            assert!(
                !secret_store.authorization_session_allow_interactions()[baseline_session_count]
            );
            for handle in &all_handles {
                assert!(secret_store.get_secret(handle)?.is_none());
            }
            for probe in cleanup_probes {
                assert_eq!(
                    probe.observations(),
                    vec![vec![0; b"synthetic-disposable-cleanup-canary".len()]],
                    "cleanup must wipe each removed owned secret before releasing its backing"
                );
            }

            let second_baseline = secret_store.authorization_session_count();
            let second = e2ee_secret_store_cleanup(&json!({
                "disposableProof": "true"
            }))?;
            assert_eq!(second["ok"], true);
            assert_eq!(second["pairwiseSnapshotHandleCount"], 0);
            assert_eq!(second["pairwiseDatabasePresentBefore"], false);
            assert_eq!(second["pairwiseDatabaseRemoved"], true);
            assert_eq!(second["deletedSecretHandleCount"], root_handles.len());
            assert_eq!(
                secret_store.authorization_session_count(),
                second_baseline + 1
            );
            assert_eq!(
                secret_store.authorization_session_operation_counts()[second_baseline],
                root_handles.len()
            );
            assert_eq!(
                secret_store.authorization_session_consumed_operation_counts()[second_baseline],
                root_handles.len()
            );
            assert!(!secret_store.authorization_session_allow_interactions()[second_baseline]);
            Ok(())
        })
    })
    .unwrap();

    set_portable_data_dir_override(previous);
}

#[test]
fn mobile_relay_disposable_secret_cleanup_requires_exact_confirmation_and_accepts_empty_root() {
    let dir = temp_dir("mobile-relay-disposable-secret-cleanup-empty-root");
    let previous = set_portable_data_dir_override(Some(dir.to_path_buf()));
    let secret_store = Arc::new(EphemeralSecretStore::new());

    for params in [
        json!({}),
        json!({"disposableProof": false}),
        json!({"disposableProof": true}),
        json!({"disposableProof": "false"}),
    ] {
        let error = e2ee_secret_store_cleanup(&params).unwrap_err().to_string();
        assert!(error.contains("--disposable-proof true"));
    }
    assert_eq!(secret_store.authorization_session_count(), 0);

    let store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
    let output = with_mobile_relay_secret_store_override(store_override, || {
        e2ee_secret_store_cleanup(&json!({
            "disposableProof": "true"
        }))
    })
    .unwrap();
    assert_eq!(output["ok"], true);
    assert_eq!(output["pairwiseSnapshotHandleCount"], 0);
    assert_eq!(output["pairwiseDatabasePresentBefore"], false);
    assert_eq!(output["pairwiseDatabaseRemoved"], true);
    assert_eq!(secret_store.authorization_session_count(), 1);
    assert_eq!(
        secret_store.authorization_session_operation_counts()[0],
        1 + MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS.len()
            + MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len()
    );
    assert_eq!(
        secret_store.authorization_session_operation_counts(),
        secret_store.authorization_session_consumed_operation_counts()
    );
    assert_eq!(
        secret_store.authorization_session_allow_interactions(),
        vec![false]
    );

    set_portable_data_dir_override(previous);
}

#[test]
fn mobile_relay_disposable_secret_cleanup_propagates_delete_failures() {
    struct DeleteFailingSecretStore {
        inner: EphemeralSecretStore,
        rejected_key: &'static str,
    }

    impl SecureMeshSecretStore for DeleteFailingSecretStore {
        fn backend(&self) -> &'static str {
            self.inner.backend()
        }

        fn supported(&self) -> bool {
            self.inner.supported()
        }

        fn begin_authorized_session(
            &self,
            request: &SecretStoreAuthorizationRequest,
        ) -> Result<SecretStoreAuthorizationSession> {
            self.inner.begin_authorized_session(request)
        }

        fn set_secret(&self, handle: &SecretStoreHandle, secret: SecretBytes) -> Result<()> {
            self.inner.set_secret(handle, secret)
        }

        fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<SecretBytes>> {
            self.inner.get_secret(handle)
        }

        fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
            if handle.key() == self.rejected_key {
                return Err(anyhow!("injected disposable cleanup delete failure"));
            }
            self.inner.delete_secret(handle)
        }
    }

    let dir = temp_dir("mobile-relay-disposable-secret-cleanup-delete-failure");
    let previous = set_portable_data_dir_override(Some(dir.to_path_buf()));
    let store = Arc::new(DeleteFailingSecretStore {
        inner: EphemeralSecretStore::new(),
        rejected_key: "mobileToken",
    });
    let rejected_handle = native_secret_store_handle_for_namespace(
        MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        "mobileToken",
    )
    .unwrap();
    store
        .set_secret(
            &rejected_handle,
            SecretBytes::try_from_bytes(b"synthetic-delete-failure-canary".to_vec()).unwrap(),
        )
        .unwrap();
    let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();

    let error = with_mobile_relay_secret_store_override(store_override, || {
        e2ee_secret_store_cleanup(&json!({
            "disposableProof": "true"
        }))
    })
    .unwrap_err()
    .to_string();

    assert!(error.contains("disposable secret cleanup failed"));
    assert!(store.get_secret(&rejected_handle).unwrap().is_some());
    assert_eq!(store.inner.authorization_session_count(), 1);
    assert_eq!(
        store.inner.authorization_session_allow_interactions(),
        vec![false]
    );

    set_portable_data_dir_override(previous);
}
