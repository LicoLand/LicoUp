//! Canonical opaque relay envelope public facade.
//!
//! Cryptographic derivation, private-header framing, wire decoding, bounds, and tests live in
//! independently verifiable modules while this file preserves the stable client API.

mod aad;
mod codec;
mod constant_time;
mod constants;
mod delivery;
mod draft;
mod envelope;
mod mailbox;
mod private_header;
mod private_header_frame;
mod wire;

pub use constants::{
    SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES, SECURE_MESH_MAILBOX_PREVIOUS_WINDOW_COUNT,
    SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS, SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
    SECURE_MESH_RELAY_OUTER_FIELDS,
};
pub use delivery::{SecureMeshDeliverySecret, SecureMeshRelayChannelBinding};
pub use draft::SecureMeshRelayEnvelopeDraft;
pub use envelope::SecureMeshRelayEnvelope;
pub use mailbox::{SecureMeshMailboxDirection, SecureMeshMailboxSchedule, SecureMeshMailboxToken};
pub(crate) use private_header::{open_private_relay_header, seal_private_relay_header};

#[cfg(test)]
mod tests;
