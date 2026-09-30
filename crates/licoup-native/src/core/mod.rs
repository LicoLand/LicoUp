// The work-queue, safe-archive and ACP wire primitives now live in
// `licoup-foundation`; the former paths stay reachable through this re-export.
pub use licoup_foundation::core::{acp, safe_archive, task_queue};
// The full data-root archive owner moved to `licoup-foundation` as well.
// `licoup-migrate` reaches it at this former path and is outside this change's
// write scope, so the path stays; every caller inside this crate names
// `licoup_foundation::core::full_data_root_archive` directly.
pub use licoup_foundation::core::full_data_root_archive;
// The content cipher, the PQXDH key schedule, the ML-KEM Braid session and the
// sparse post-quantum ratchet now live in `licoup-secure-mesh`; the former paths
// stay reachable through this re-export.
pub use licoup_secure_mesh::core::{
    secure_mesh_crypto, secure_mesh_mlkem_braid, secure_mesh_pqxdh, secure_mesh_sparse_pq_ratchet,
};
// Pairing trust, key transparency, the remote-approval envelopes and the product
// readiness ledger moved to `licoup-secure-mesh` as well. The relay's directory
// transparency, the lifecycle, command, session, custody and group (MLS)
// callers that are extracted by later Nodes still reach them at this former path.
pub use licoup_secure_mesh::core::{
    secure_mesh_approval, secure_mesh_product_readiness, secure_mesh_transparency,
    secure_mesh_trust,
};
// Endpoint capability evidence with its proofs, the content directory and the
// encrypted command responses moved to `licoup-secure-mesh` as well. The
// family root `secure_mesh` and the command, session, custody and group (MLS)
// callers that are extracted by later Nodes still reach them at this former
// path.
pub use licoup_secure_mesh::core::{
    secure_mesh_capability, secure_mesh_capability_proof, secure_mesh_directory,
    secure_mesh_response,
};
// The secret-store port, peer session negotiation and the secure command
// pipeline moved to `licoup-secure-mesh` as well, and the post-quantum MLS epoch
// rule is now reached there by the group (MLS) callers that are extracted by
// later Nodes. The former paths stay reachable through this re-export.
pub use licoup_secure_mesh::core::{
    secure_mesh_command, secure_mesh_mls_pq_epoch, secure_mesh_secret_store,
    secure_mesh_session_negotiation,
};
// The file-transfer surface, pairwise session state and its persistence, and
// the prekey records that bootstrap it, moved to `licoup-secure-mesh` last. The
// relay, lifecycle, ACP and group callers that are extracted by later Nodes
// still reach them at these former paths.
pub use licoup_secure_mesh::core::{secure_mesh_file, secure_mesh_pairwise, secure_mesh_prekey};

// The MCP core moved to `licoup-mcp`; callers inside this crate name
// `licoup_mcp::mcp` directly, and the former path stays reachable for the
// Agent-layer modules that are extracted later.
pub use licoup_mcp::mcp;
// The family root that projects the protocol status, the envelope validation and
// the command policy moved to `licoup-secure-mesh` last, with the trees it
// declares. The FFI, relay and lifecycle callers that are extracted by later
// Nodes still reach it at this former path.
pub use licoup_secure_mesh::core::secure_mesh;
// The ACP protected-envelope binding and the endpoint lifecycle projections
// moved to `licoup-secure-mesh` last. The family root `secure_mesh` above and
// the relay and group callers that are extracted by later Nodes still reach
// them at these former paths.
pub use licoup_secure_mesh::core::{secure_mesh_acp, secure_mesh_lifecycle};
// The group (MLS) surface and the product path that drives it moved to
// `licoup-secure-mesh` last, together with the `security.mls-operation` state
// machine their operation ledger replays. The family root `secure_mesh`, the
// lifecycle, relay and ACP callers, and the two platform stores are extracted by
// later Nodes and still reach them at these former paths.
pub use licoup_secure_mesh::core::{secure_mesh_mls, secure_mesh_mls_product};
