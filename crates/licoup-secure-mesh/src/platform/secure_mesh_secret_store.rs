// Linux capability reporting includes fail-closed states that are exercised by
// platform verification even when the production backend is unavailable.
#[cfg_attr(target_os = "linux", allow(dead_code))]
mod capability;
#[cfg(any(target_os = "linux", test))]
#[cfg_attr(target_os = "linux", allow(dead_code))]
mod linux_secret_service;
#[cfg(target_os = "macos")]
// The macOS keychain effects, the presence batch coordinator and the injected
// test doubles are composed by the LLM API key vault that stayed in
// `licoup-native`, so the module is consumed across this crate's boundary.
pub mod macos_user_presence;
mod platform_backends;
#[cfg_attr(target_os = "linux", allow(dead_code))]
mod platform_store;
mod selection;

pub use crate::core::secure_mesh_secret_store::{
    SecretBytes, SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession,
    SecretStoreHandle, SecureMeshSecretStore,
};
pub use capability::{
    LinuxSecretServiceProbeSnapshot, PlatformSecretStoreRuntimeState,
    platform_linux_secret_service_probe_snapshot, platform_native_secret_store_backend,
    platform_native_secret_store_runtime_state, platform_native_secret_store_supported,
};
// The memory-only implementation moved into `licoup-secure-mesh` beside the
// contract it implements; the former path stays reachable through this
// re-export.
pub use crate::core::secure_mesh_secret_store::EphemeralSecretStore;
#[cfg(target_os = "macos")]
pub use macos_user_presence::MacosAuthorizedPresence;
pub use platform_backends::NATIVE_SECRET_STORE_BACKEND_UNSUPPORTED;
pub use platform_store::{PlatformSecretStore, SecretClassPersistenceProof};
pub use selection::SecureMeshSecretStoreSelection;

#[cfg(target_os = "macos")]
#[doc(hidden)]
pub fn set_macos_test_user_presence_disabled(disabled: bool) -> bool {
    macos_user_presence::set_test_user_presence_disabled(disabled)
}

#[cfg(test)]
mod tests;
