//! Platform-neutral secret-custody contract for Secure Client Mesh.
//!
//! Cryptographic and persistence code depends on this port. Platform keychains,
//! biometric contexts, and in-memory test stores implement it in the outer layer.

mod authorization;
mod handle;
mod port;

pub use authorization::{SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession};
pub use handle::SecretStoreHandle;
pub use port::SecureMeshSecretStore;

pub(crate) use handle::is_persistable_secret;

#[cfg(test)]
mod tests;
