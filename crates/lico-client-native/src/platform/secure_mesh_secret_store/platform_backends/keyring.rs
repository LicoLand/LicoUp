use anyhow::{Result, anyhow};

use super::super::platform_store::PlatformSecretStore;
#[cfg(not(test))]
use crate::core::secure_mesh_secret_store::is_persistable_secret;
use crate::core::secure_mesh_secret_store::{SecretStoreAuthorizationSession, SecretStoreHandle};

pub(super) type RuntimeFailureHook = fn();

pub(super) fn ignore_runtime_failure() {}

pub(super) fn set_secret_with_session(
    store: &PlatformSecretStore,
    session: &SecretStoreAuthorizationSession,
    handle: &SecretStoreHandle,
    secret: &str,
    on_runtime_failure: RuntimeFailureHook,
) -> Result<()> {
    session.record_secret_store_operation("write")?;
    set_secret(store, handle, secret, on_runtime_failure)
}

pub(super) fn get_secret_with_session(
    store: &PlatformSecretStore,
    session: &SecretStoreAuthorizationSession,
    handle: &SecretStoreHandle,
    on_runtime_failure: RuntimeFailureHook,
) -> Result<Option<String>> {
    session.record_secret_store_operation("read")?;
    get_secret(store, handle, on_runtime_failure)
}

pub(super) fn delete_secret_with_session(
    store: &PlatformSecretStore,
    session: &SecretStoreAuthorizationSession,
    handle: &SecretStoreHandle,
    on_runtime_failure: RuntimeFailureHook,
) -> Result<()> {
    session.record_secret_store_operation("delete")?;
    delete_secret(store, handle, on_runtime_failure)
}

pub(super) fn set_secret(
    store: &PlatformSecretStore,
    handle: &SecretStoreHandle,
    secret: &str,
    on_runtime_failure: RuntimeFailureHook,
) -> Result<()> {
    #[cfg(test)]
    {
        let _ = (store, secret, on_runtime_failure);
        return Err(anyhow!(
            "real platform secret-store I/O is disabled in unit tests for {}; inject EphemeralSecretStore instead",
            handle.key()
        ));
    }
    #[cfg(not(test))]
    {
        let entry = keyring::Entry::new(store.service, &handle.account()).map_err(|_| {
            anyhow!(
                "secure mesh native secret store entry unavailable for {}",
                handle.key()
            )
        })?;
        entry.set_password(secret).map_err(|_| {
            on_runtime_failure();
            anyhow!(
                "secure mesh native secret store write failed for {}",
                handle.key()
            )
        })
    }
}

pub(super) fn get_secret(
    store: &PlatformSecretStore,
    handle: &SecretStoreHandle,
    on_runtime_failure: RuntimeFailureHook,
) -> Result<Option<String>> {
    #[cfg(test)]
    {
        let _ = (store, on_runtime_failure);
        return Err(anyhow!(
            "real platform secret-store I/O is disabled in unit tests for {}; inject EphemeralSecretStore instead",
            handle.key()
        ));
    }
    #[cfg(not(test))]
    {
        let entry = keyring::Entry::new(store.service, &handle.account()).map_err(|_| {
            anyhow!(
                "secure mesh native secret store entry unavailable for {}",
                handle.key()
            )
        })?;
        match entry.get_password() {
            Ok(secret) if is_persistable_secret(&secret) => Ok(Some(secret)),
            Ok(_) | Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => {
                on_runtime_failure();
                Err(anyhow!(
                    "secure mesh native secret store read failed for {}",
                    handle.key()
                ))
            }
        }
    }
}

pub(super) fn delete_secret(
    store: &PlatformSecretStore,
    handle: &SecretStoreHandle,
    on_runtime_failure: RuntimeFailureHook,
) -> Result<()> {
    #[cfg(test)]
    {
        let _ = (store, on_runtime_failure);
        return Err(anyhow!(
            "real platform secret-store I/O is disabled in unit tests for {}; inject EphemeralSecretStore instead",
            handle.key()
        ));
    }
    #[cfg(not(test))]
    {
        let entry = keyring::Entry::new(store.service, &handle.account()).map_err(|_| {
            anyhow!(
                "secure mesh native secret store entry unavailable for {}",
                handle.key()
            )
        })?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => {
                on_runtime_failure();
                Err(anyhow!(
                    "secure mesh native secret store delete failed for {}",
                    handle.key()
                ))
            }
        }
    }
}
