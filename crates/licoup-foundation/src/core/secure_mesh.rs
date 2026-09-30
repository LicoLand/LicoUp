//! The secure-mesh protocol identity vocabulary.
//!
//! These are the names two trees on opposite sides of the mesh crate boundary
//! have to agree on: the group (MLS) tree and the pairwise tree both bind the
//! cipher suite and the group protocol version into their domain separation,
//! and the group status is reported by the adapter while its group surface is
//! still above this crate. They are identity strings, not behaviour, so they
//! live below both readers instead of being owned by either.

/// The MLS cipher suite the secure mesh selects for its group surface.
pub const SECURE_MESH_MLS_CIPHER_SUITE: &str =
    "MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519+ML_KEM_1024_EPOCH_PAYLOAD_HYBRID";

/// The group (MLS) protocol identity bound into every group transcript.
pub const SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION: &str =
    "licomesh.secure-mesh.group-mls.mlkem1024-epoch-payload-hybrid.v1";

/// The reported state of the group (MLS) surface.
pub const SECURE_MESH_MLS_STATUS: &str = "openmls_classical_control_plane_mlkem1024_epoch_hybrid_payload_selected_custody_durable_group_state_identity_bound_capability_negotiated";
