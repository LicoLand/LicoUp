// The three `pub` protocol-identity names this file used to declare —
// `SECURE_MESH_MLS_CIPHER_SUITE`, `SECURE_MESH_GROUP_MLS_PROTOCOL_VERSION` and
// `SECURE_MESH_MLS_STATUS` — are identity vocabulary that the pairwise tree and
// the group tree both read from opposite sides of the mesh crate boundary, so
// they live in `licoup_foundation::core::secure_mesh`. What stays here is this
// tree's own internal wire vocabulary.

pub(super) const MLS_PAYLOAD_EXPORT_LABEL: &str = "licomesh.secure-mesh.mls.payload-content-key.v2";
pub(super) const MLS_PAYLOAD_EXPORT_CONTEXT_MAGIC: &[u8] = b"LCOSM-MLS-PAYLOAD-EXPORT-v2";
pub(crate) const SECURE_MESH_MLS_APPLICATION_PUBLIC_AAD: &[u8] =
    b"licomesh.secure-mesh.mls.application.public-domain-profile.v2";
pub(super) const MLS_PRIVATE_CONTEXT_PAYLOAD_MAGIC: &[u8] = b"LCOSM-MLS-PRIVATE-CONTEXT-PAYLOAD-v2";
pub(super) const MLS_PAYLOAD_CONTENT_KEY_LEN: usize = 32;
pub(super) const MLS_PROVIDER_SECRET_SCHEMA_VERSION: u32 = 2;
pub(super) const MLS_KEY_PACKAGE_MAGIC: &[u8] = b"LCOSM-MLS-KEYPACKAGE-MLKEM1024-v1";
pub(super) const MLS_EPOCH_SECRET_STORE_CLASS: &str = "mlsEpochSecret";
pub(super) const MLS_RECOVERY_SECRET_STORE_CLASS: &str = "recoverySecret";
pub(super) const MLS_PUBLIC_STATE_DIGEST_AUTHENTICATED_BACKFILL: &str =
    "pending:selected-custody-authenticated-backfill";
pub(crate) const MLS_CAPABILITY_EXTENSION_TYPE_ID: u16 = 0xff10;
pub(crate) const MLS_CAPABILITY_EXTENSION_SCHEMA_VERSION: u32 = 2;
