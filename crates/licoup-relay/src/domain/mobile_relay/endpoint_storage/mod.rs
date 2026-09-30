//! Durable protocol state, key custody, and old-or-new recovery for one
//! pinned-SDK v7 endpoint.
//!
//! This is the caller side of the pinned LicoArc Candidate contract (C06): the
//! SDK owns every protocol decision and the cryptography, and this module owns
//! what the SDK declares caller-owned — the durable snapshot, the bounded
//! pending delivery set, the coupled handle lifecycle, the exclusive writer
//! lock, and restart/rollback classification.
//!
//! # The pieces
//!
//! * [`EndpointV7Storage`] — one durable root: exclusive advisory lock,
//!   additive schema, anti-rollback anchor, and the explicit recovery gate.
//! * [`EndpointV7StateStore`] — the SDK's `AtomicState<EndpointState>`: one
//!   transaction per complete snapshot plus its handle mutations.
//! * [`EndpointV7Custody`] — the SDK's `KeyCustody` over the selected platform
//!   secret store, with purpose/lifecycle/class checks on every token.
//!
//! # Use
//!
//! ```ignore
//! let storage = EndpointV7Storage::open(
//!     root,                       // this endpoint's durable directory
//!     EndpointState::responder(), // the live snapshot a new session starts from
//!     selected_platform_store,    // chosen by the composition root
//!     "licoup.endpoint-v7.storage",
//! )?;
//! if !storage.status()?.continuity.loadable() {
//!     let facts = storage.recovered_facts()?.unwrap_or_default();
//!     storage.begin_new_session()?;      // explicit, never automatic
//!     // hand `facts` to the caller-owned delivery path
//! }
//! let endpoint = Endpoint::responder(line, provider, storage.custody(), storage.state_store())?;
//! ```
//!
//! # Guarantees
//!
//! * **Old-or-new.** A crash leaves the complete previous generation or the
//!   complete next one: state, pending records, and handle lifecycle always
//!   agree, because they commit in one transaction.
//! * **No handle resurrection.** A tentative token that was never adopted is
//!   aborted by the next open; an adopted session token is fenced by the next
//!   open; a deleted token is tombstoned and never reissued.
//! * **No silent restart.** A committed session whose ratchet snapshot did not
//!   survive the process is never resumed: loading stays refused until an
//!   explicit new session, and its committed delivery records are fenced facts,
//!   not silently attached or forgotten.
//! * **One writer.** The root lock is held for the life of the handle; a second
//!   open — in this process or another — is refused.
//!
//! # Not claimed
//!
//! Physical erasure (a platform store may retain bytes a logical delete made
//! unreachable), hardware-backed custody, protection from a compromised
//! process, and rollback of the entire root directory including its anchor.
//! The pinned SDK leaves the same boundaries unclaimed.
//!
//! # Platform boundary
//!
//! Key material lives in the platform owner's [`SecureMeshSecretStore`]
//! implementation, selected by the composition root (the platform keychain
//! where available, an explicitly injected non-production store in isolated
//! tests). This module never reads a user's real keychain, never exports
//! private material, and never treats a fixture as hardware custody.
//!
//! [`SecureMeshSecretStore`]:
//!     licoup_secure_mesh::core::secure_mesh_secret_store::SecureMeshSecretStore

mod custody;
mod refusal;
mod root;
mod store;

pub use custody::{EndpointV7Custody, EndpointV7IdentityPublicKeys};
pub use refusal::{
    EndpointV7Continuity, EndpointV7FencedPending, EndpointV7PendingKind, EndpointV7PendingPayload,
    EndpointV7RecoveredFacts, EndpointV7StorageError, EndpointV7StorageStatus,
};
pub use root::{ENDPOINT_V7_STORAGE_SCHEMA_VERSION, EndpointV7Storage};
pub use store::EndpointV7StateStore;
