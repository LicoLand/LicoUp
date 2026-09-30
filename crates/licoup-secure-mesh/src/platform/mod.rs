// Endpoint capability probing and evidence collection for the Secure Client
// Mesh, and the platform composition that opens the stores holding its key
// material. The probe reports what this endpoint can do; it grants no readiness
// authority of its own, and the stores authorize each access through the
// secret-store contract in `core`.
pub mod secure_mesh_capability_probe;
pub mod secure_mesh_mls_store;
pub mod secure_mesh_secret_store;
