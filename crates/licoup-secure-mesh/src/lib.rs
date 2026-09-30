//! The single authority for LicoUp's secure-mesh family: the protocol status
//! and command policy that project it, the cryptographic primitives every mesh
//! ratchet is built from, the pairing trust authority with the peer-trust state
//! it persists, the verification-only Key Transparency client with this
//! endpoint's authority store and reset guard, the remote-approval envelopes,
//! the product readiness ledger, endpoint capability evidence and its proofs,
//! the content directory, the encrypted command responses, the ACP
//! protected-envelope binding, the endpoint lifecycle projections, and the
//! product-facing group (MLS) surface that runs against the endpoint's selected
//! custody.
//!
//! `core` holds twenty-four module trees: `secure_mesh`,
//! `secure_mesh_acp`, `secure_mesh_approval`, `secure_mesh_capability`,
//! `secure_mesh_capability_proof`, `secure_mesh_command`, `secure_mesh_crypto`,
//! `secure_mesh_directory`, `secure_mesh_file`, `secure_mesh_lifecycle`,
//! `secure_mesh_mlkem_braid`, `secure_mesh_mls`, `secure_mesh_mls_pq_epoch`,
//! `secure_mesh_mls_product`, `secure_mesh_pairwise`, `secure_mesh_pqxdh`,
//! `secure_mesh_prekey`, `secure_mesh_product_readiness`,
//! `secure_mesh_response`, `secure_mesh_secret_store`,
//! `secure_mesh_session_negotiation`, `secure_mesh_sparse_pq_ratchet`,
//! `secure_mesh_transparency` and `secure_mesh_trust`. `secure_mesh` is the
//! family root that projects the protocol status, validates the Lico Arc relay
//! envelope and answers the command policy over the rest.
//!
//! `platform` holds three: `secure_mesh_capability_probe`, which reports what
//! this endpoint can do without granting readiness authority of its own, and the
//! two stores the endpoint composes — `secure_mesh_mls_store`, the group state's
//! durable store bound to this endpoint's private-path hardener, and
//! `secure_mesh_secret_store`, the macOS Security.framework keychain, the
//! unmeasured Linux Secret Service probe and the fail-closed backends behind
//! them. Both stores authorize every access through the contracts in `core`.
//!
//! `domain` holds one: `secure_mesh_mls`, the product-facing group surface that
//! owns the native action registry, the group operations behind it, their
//! durable group state and security ledger, and the selected-custody context
//! each participant action runs under. The composition that owns this
//! endpoint's secret custody opens that context and supplies it, so this crate
//! selects no custody backend and loads no configuration store of its own.
//!
//! The `lico-secure-mesh-kt-mock` acceptance binary also lives here, behind
//! `secure-mesh-acceptance-mock-kt`.
//!
//! Outside this crate, and deliberately so: the `domain/secure_mesh_command_runtime`
//! composition remains in `licoup-native`, because it resolves the local Agent
//! inventory and the conversation history surface, which are not this crate's
//! to own. `licoup-native` keeps re-export facades at the former paths of every
//! tree that moved here, for the relay, FFI and lifecycle callers that later
//! Nodes extract.
//!
//! Nothing here reaches upward. The LicoUp crates below are
//! `licoup-protocol-bindings`, which owns the shared protocol formats,
//! `licoup-client-state`, which owns the portable state root every durable
//! store here lives under, and `licoup-foundation`, which owns the
//! cross-boundary protocol-identity vocabulary and the private-file
//! primitives.

#[cfg(all(feature = "secure-mesh-acceptance-mock-kt", not(debug_assertions)))]
compile_error!(
    "secure-mesh-acceptance-mock-kt is acceptance-only and cannot be compiled in a release profile"
);

/// The mesh protocol identity bound into every sealed payload's domain
/// separation. It changes only when protocol or security semantics become
/// incompatible; application versions and release-artifact identity are
/// deliberately not part of session negotiation.
pub const SECURE_MESH_PROTOCOL_VERSION: &str = "licomesh.secure-mesh.v1";

/// The protocol identity bound into every sealed command result and error
/// payload's domain separation. Its owner is the crate that seals those
/// payloads; `core/secure_mesh.rs` re-exports the former path.
pub const SECURE_MESH_RESULT_PROTOCOL_VERSION: &str = "licomesh.secure-mesh.result.v1";

/// Stable wire/security compatibility profile revision.
///
/// This changes only when protocol or security semantics become incompatible.
/// Application versions and release-artifact identity are deliberately not part
/// of session negotiation. `core/secure_mesh.rs` re-exports the former path.
pub const SECURE_MESH_PROTOCOL_BUILD_REVISION: u64 = 5;

pub mod core;
pub mod domain;
pub mod platform;

pub(crate) mod state_machines {
    include!(concat!(env!("OUT_DIR"), "/state_machines.rs"));
}
