//! Platform-neutral secret-custody contract for Secure Client Mesh.
//!
//! Cryptographic and persistence code depends on this port. Platform keychains,
//! biometric contexts, and in-memory test stores implement it in the outer layer.

// Linux exports this contract for cross-platform callers while native presence
// authorization remains unavailable and fail-closed.
#[cfg_attr(target_os = "linux", allow(dead_code))]
mod authorization;
// The port's memory-only implementation is composed by the platform store
// selection in `licoup-native` and by the pairwise and group test fixtures, so
// it is owned here beside the contract it implements.
mod ephemeral;
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
pub use ephemeral::EphemeralSecretStore;
pub use handle::SecretStoreHandle;
pub use port::SecureMeshSecretStore;
// The zeroize observation seam is read by callers outside this crate, so it is
// carried as the acceptance feature rather than as `cfg(test)`.
#[cfg(any(test, feature = "secure-mesh-acceptance-mock-kt"))]
pub use secret_bytes::SecretZeroizeProbe;
pub use secret_bytes::{MAX_SECRET_BYTES, SecretBytes, SecretBytesError};

// The macOS presence-batch digests are recomputed by the keychain backend in
// `licoup-native`, whose implementation of this contract is above the crate.
pub(crate) use authorization::{derive_presence_binding_digest, digest_matches};

#[cfg(test)]
mod tests;
