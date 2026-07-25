//! Platform-neutral secret-custody contract for Secure Client Mesh.
//!
//! Cryptographic and persistence code depends on this port. Platform keychains,
//! biometric contexts, and in-memory test stores implement it in the outer layer.

mod authorization;
mod handle;
mod port;
mod secret_bytes;

pub use authorization::{
    MAX_SECRET_STORE_PRESENCE_GRANT_TTL, PresenceDecision, SecretStoreApprovedPresenceBatch,
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreCallerChannel,
    SecretStoreConsumedPresence, SecretStoreKeyClass, SecretStoreOperation,
    SecretStorePresenceBatchRequest, SecretStorePresenceError, SecretStorePresenceGrant,
    SecretStorePresenceNonce, SecretStorePresenceProvider, SecretStorePresencePurpose,
    SecretStorePresenceScope,
};
pub use handle::SecretStoreHandle;
pub use port::SecureMeshSecretStore;
#[cfg(test)]
pub use secret_bytes::SecretZeroizeProbe;
pub use secret_bytes::{MAX_SECRET_BYTES, SecretBytes, SecretBytesError};

pub(crate) use authorization::{derive_presence_binding_digest, digest_matches};

#[cfg(test)]
mod tests;
