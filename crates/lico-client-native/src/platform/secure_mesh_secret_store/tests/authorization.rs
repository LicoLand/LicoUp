use anyhow::Result;

use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore,
};

#[test]
fn single_system_authorization_context_requires_one_completed_system_attempt() {
    let request = SecretStoreAuthorizationRequest::new("test batch", 3);
    let baseline = SecretStoreAuthorizationSession::new("macos-keychain", &request, true, true);
    assert!(!baseline.single_system_authorization_context_verified());

    let verified = baseline
        .clone()
        .with_test_system_authorization_outcome(1, true, false);
    assert!(verified.single_system_authorization_context_verified());

    let repeated_prompt = verified
        .clone()
        .with_test_system_authorization_outcome(2, true, false);
    assert!(!repeated_prompt.single_system_authorization_context_verified());

    let app_password_prompt = verified.with_test_system_authorization_outcome(1, true, true);
    assert!(!app_password_prompt.single_system_authorization_context_verified());
}

#[test]
fn authorization_session_enforces_operation_budget_across_clones() {
    let request = SecretStoreAuthorizationRequest::new("budgeted batch", 2);
    let session = SecretStoreAuthorizationSession::new("macos-keychain", &request, true, true);
    let clone = session.clone();

    session.record_secret_store_operation("read").unwrap();
    clone.record_secret_store_operation("write").unwrap();

    assert_eq!(session.consumed_operation_count(), 2);
    assert_eq!(clone.remaining_operation_count(), 0);
    assert!(session.authorization_batch_within_budget());
    assert!(clone.record_secret_store_operation("delete").is_err());
    assert_eq!(session.consumed_operation_count(), 2);
}

#[test]
fn default_session_methods_reject_required_shared_system_context() {
    struct SessionRequiredStore;

    impl SecureMeshSecretStore for SessionRequiredStore {
        fn backend(&self) -> &'static str {
            "session-required-test-store"
        }

        fn supported(&self) -> bool {
            true
        }

        fn set_secret(&self, _handle: &SecretStoreHandle, _secret: &str) -> Result<()> {
            Ok(())
        }

        fn get_secret(&self, _handle: &SecretStoreHandle) -> Result<Option<String>> {
            Ok(Some("secret".to_string()))
        }

        fn delete_secret(&self, _handle: &SecretStoreHandle) -> Result<()> {
            Ok(())
        }
    }

    let request = SecretStoreAuthorizationRequest::new("required auth", 1);
    let session =
        SecretStoreAuthorizationSession::new("session-required-test-store", &request, true, true);
    let handle = SecretStoreHandle::new("namespace", "key").unwrap();
    let store = SessionRequiredStore;

    assert!(
        store
            .set_secret_with_session(&session, &handle, "secret")
            .is_err()
    );
    assert!(store.get_secret_with_session(&session, &handle).is_err());
    assert!(store.delete_secret_with_session(&session, &handle).is_err());
}
