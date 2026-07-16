use anyhow::{Result, ensure};

use super::super::capability::{
    PlatformSecretStoreRuntimeState, platform_native_secret_store_runtime_state,
    platform_secret_store_capability_facts,
};
use super::super::macos_user_presence;
use super::super::platform_store::PlatformSecretStore;
use super::{fail_closed, keyring};
use crate::core::secure_mesh_capability::{
    CapabilityEvidenceKind, CapabilityFact, capability_catalog, mandatory_protocol_facts,
};
use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore,
};

pub(super) const BACKEND: &str = "macos-keychain";

pub(super) fn supported() -> bool {
    platform_native_secret_store_runtime_state() == PlatformSecretStoreRuntimeState::Available
}

pub(super) fn capability_facts() -> Result<Vec<CapabilityFact>> {
    platform_secret_store_capability_facts()
}

pub(super) fn begin_authorized_session(
    store: &PlatformSecretStore,
    request: &SecretStoreAuthorizationRequest,
) -> Result<SecretStoreAuthorizationSession> {
    if request.allow_interaction() {
        ensure!(
            macos_user_presence::available(),
            "secure mesh macOS user-presence authorization is unavailable"
        );
        let mut facts = store.capability_facts()?;
        facts.extend(macos_user_presence::capability_facts());
        let mut protocol = mandatory_protocol_facts(CapabilityEvidenceKind::SourceContract)?;
        protocol.extend(facts);
        let report = capability_catalog()?.evaluate(&protocol)?.report();
        return Ok(
            macos_user_presence::begin_session(store.backend(), request)?
                .with_capability_report(report),
        );
    }
    fail_closed::begin_authorized_session(store, request)
}

pub(super) fn set_secret_with_session(
    store: &PlatformSecretStore,
    session: &SecretStoreAuthorizationSession,
    handle: &SecretStoreHandle,
    secret: &str,
) -> Result<()> {
    if session.shared_system_context_required() {
        return macos_user_presence::set_secret(store.service, session, handle, secret);
    }
    keyring::set_secret_with_session(
        store,
        session,
        handle,
        secret,
        keyring::ignore_runtime_failure,
    )
}

pub(super) fn get_secret_with_session(
    store: &PlatformSecretStore,
    session: &SecretStoreAuthorizationSession,
    handle: &SecretStoreHandle,
) -> Result<Option<String>> {
    if session.shared_system_context_required() {
        return macos_user_presence::get_secret(store.service, session, handle);
    }
    keyring::get_secret_with_session(store, session, handle, keyring::ignore_runtime_failure)
}

pub(super) fn delete_secret_with_session(
    store: &PlatformSecretStore,
    session: &SecretStoreAuthorizationSession,
    handle: &SecretStoreHandle,
) -> Result<()> {
    if session.shared_system_context_required() {
        return macos_user_presence::delete_secret(store.service, session, handle);
    }
    keyring::delete_secret_with_session(store, session, handle, keyring::ignore_runtime_failure)
}

pub(super) fn set_secret(
    store: &PlatformSecretStore,
    handle: &SecretStoreHandle,
    secret: &str,
) -> Result<()> {
    fail_closed::set_secret(store, handle, secret)
}

pub(super) fn get_secret(
    store: &PlatformSecretStore,
    handle: &SecretStoreHandle,
) -> Result<Option<String>> {
    fail_closed::get_secret(store, handle)
}

pub(super) fn delete_secret(store: &PlatformSecretStore, handle: &SecretStoreHandle) -> Result<()> {
    fail_closed::delete_secret(store, handle)
}
