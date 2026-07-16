//! Protocol labels and allocation bounds shared by relay-envelope leaves.

use crate::core::secure_mesh_crypto::MAX_PADDING_BUCKET_BYTES;

pub const SECURE_MESH_RELAY_ENVELOPE_SCHEMA: &str = "licolite.secure-mesh.relay-envelope.v2";
pub const SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS: u64 = 15 * 60;
pub const SECURE_MESH_MAILBOX_PREVIOUS_WINDOW_COUNT: usize = 1;
pub const SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES: usize = 4 * 1024;
pub const SECURE_MESH_RELAY_OUTER_FIELDS: [&str; 6] = [
    "schema",
    "deliveryId",
    "mailboxToken",
    "encryptedHeader",
    "ciphertextBucket",
    "ciphertext",
];

pub(super) const DELIVERY_SECRET_BYTES: usize = 32;
pub(super) const CHANNEL_BINDING_BYTES: usize = 32;
pub(super) const DELIVERY_ID_BYTES: usize = 24;
pub(super) const MAILBOX_TOKEN_BYTES: usize = 32;
pub(super) const RELAY_HEADER_KEY_BYTES: usize = 32;
pub(super) const RELAY_HEADER_NONCE_BYTES: usize = 24;
pub(super) const RELAY_HEADER_TAG_BYTES: usize = 16;
pub(super) const RELAY_HEADER_FRAME_BYTES: usize =
    SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES - RELAY_HEADER_NONCE_BYTES - RELAY_HEADER_TAG_BYTES;
pub(super) const RELAY_HEADER_FRAME_MAGIC: &[u8] =
    b"LICO-SECURE-MESH-PRIVATE-RELAY-HEADER-XCHACHA20POLY1305-v3";
pub(super) const RELAY_HEADER_LENGTH_BYTES: usize = 4;
pub(super) const MAX_RELAY_PRIVATE_HEADER_BYTES: usize =
    RELAY_HEADER_FRAME_BYTES - RELAY_HEADER_FRAME_MAGIC.len() - RELAY_HEADER_LENGTH_BYTES;
pub(super) const JSON_SAFE_INTEGER_MAX: u64 = 9_007_199_254_740_991;
pub(super) const MAX_RELAY_ENVELOPE_JSON_BYTES: usize = ((MAX_PADDING_BUCKET_BYTES + 2) / 3) * 4
    + ((SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES + 2) / 3) * 4
    + 16 * 1024;
pub(super) const MAILBOX_HKDF_SALT: &[u8] = b"licolite.secure-mesh.mailbox.hkdf-salt.v1";
pub(super) const MAILBOX_HKDF_INFO: &[u8] = b"licolite.secure-mesh.mailbox.hkdf-info.v1";
pub(super) const OUTER_AAD_MAGIC: &[u8] = b"LICO-SECURE-MESH-RELAY-OUTER-AAD-v2";
