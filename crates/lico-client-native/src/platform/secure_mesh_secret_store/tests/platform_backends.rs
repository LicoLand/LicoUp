#[cfg(target_os = "macos")]
use super::super::macos_user_presence;
use super::super::platform_backends::fail_closed;
use super::super::platform_store::{PlatformSecretStore, SecretClassPersistenceProof};
use super::super::{PlatformSecretStoreRuntimeState, platform_native_secret_store_runtime_state};
use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreHandle, SecureMeshSecretStore,
};

#[test]
fn secret_store_handle_rejects_empty_or_key_separator_values() {
    assert!(SecretStoreHandle::new("", "privateKeyBase64url").is_err());
    assert!(SecretStoreHandle::new("mobileRelayE2ee", "").is_err());
    assert!(SecretStoreHandle::new("mobileRelayE2ee", "private:key").is_err());
}

#[test]
fn platform_store_builds_opaque_account_handle() {
    let store = PlatformSecretStore::new("app.licolite.test", "mobileRelayE2ee");
    assert_eq!(store.service, "app.licolite.test");
    let handle = store
        .handle_for_namespace("namespace", "privateKeyBase64url")
        .unwrap();
    assert_eq!(
        handle.account(),
        "mobileRelayE2ee:namespace:privateKeyBase64url"
    );
}

#[test]
fn platform_store_unit_test_io_is_noninteractive_and_fail_closed() {
    let store = PlatformSecretStore::new("app.licolite.test", "unitTestSecret");
    let handle = store
        .handle_for_namespace("noninteractive", "proof")
        .unwrap();
    let error = store.get_secret(&handle).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("lacks measured platform user authorization")
    );
}

#[test]
fn unmeasured_platform_backend_rejects_authorization_and_every_io_shape() {
    let store = PlatformSecretStore::new("app.licolite.test", "unmeasured");
    let handle = store.handle_for_namespace("namespace", "proof").unwrap();
    let request = SecretStoreAuthorizationRequest::new("unmeasured backend", 3);
    assert!(fail_closed::begin_authorized_session(&store, &request).is_err());

    let session = crate::core::secure_mesh_secret_store::SecretStoreAuthorizationSession::new(
        "unmeasured-test-store",
        &request,
        false,
        false,
    );
    assert!(fail_closed::set_secret_with_session(&store, &session, &handle, "secret").is_err());
    assert!(fail_closed::get_secret_with_session(&store, &session, &handle).is_err());
    assert!(fail_closed::delete_secret_with_session(&store, &session, &handle).is_err());
    assert!(fail_closed::set_secret(&store, &handle, "secret").is_err());
    assert!(fail_closed::get_secret(&store, &handle).is_err());
    assert!(fail_closed::delete_secret(&store, &handle).is_err());
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
#[test]
fn desktop_store_without_runtime_round_trip_stays_unverified() {
    assert_eq!(
        platform_native_secret_store_runtime_state(),
        PlatformSecretStoreRuntimeState::Unverified
    );
    let store = PlatformSecretStore::new("app.licolite.test", "unverifiedDesktop");
    assert!(!store.supported());
    let facts = store.capability_facts().unwrap();
    assert!(facts.iter().all(|fact| {
        fact.state == crate::core::secure_mesh_capability::CapabilityFactState::Unverified
            && fact.evidence_kind
                == crate::core::secure_mesh_capability::CapabilityEvidenceKind::NotMeasured
    }));
}

#[cfg(target_os = "macos")]
#[test]
fn macos_local_authentication_is_never_enabled_inside_unit_tests() {
    assert!(!macos_user_presence::available());
    let store = PlatformSecretStore::new("app.licolite.test", "macosFailClosed");
    let error = store
        .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
            "macOS user-presence fail-closed test",
            1,
        ))
        .unwrap_err();
    assert!(
        error
            .to_string()
            .contains("user-presence authorization is unavailable")
    );
}

#[test]
fn class_persistence_report_shape_is_redacted() {
    let report = SecretClassPersistenceProof {
        backend: "test-backend",
        secret_classes: vec!["pairwiseSessionSnapshot".to_string()],
        requested_class_count: 1,
        persisted_class_count: 1,
        deleted_class_count: 1,
        all_classes_persisted: true,
        all_classes_deleted: true,
        raw_secret_material_included: false,
    };
    assert!(report.all_classes_persisted);
    assert!(report.all_classes_deleted);
    assert!(!report.raw_secret_material_included);
}
