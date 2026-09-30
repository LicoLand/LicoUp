//! The authenticated padded-content bucket rule the Lico Arc envelope carries.
//!
//! This is a wire-format rule, not behaviour of the endpoint's cryptography: it
//! fixes which ciphertext lengths a well-formed envelope may carry, and the
//! envelope codec is what transports that padded content. `licoup-secure-mesh`
//! keeps the size behaviour that produces and consumes padding —
//! `padding_bucket_for_ciphertext_size`, `add_bucket_padding` and
//! `remove_authenticated_padding` — and names this rule downward instead of
//! restating it.

use anyhow::{Result, ensure};

/// Length of the AEAD authentication tag appended to one padded payload.
pub const AEAD_TAG_LEN: usize = 16;
/// Smallest ciphertext bucket the padded-content format accepts.
pub const MIN_PADDING_BUCKET_BYTES: usize = 256;
/// Largest ciphertext size still carried in a power-of-two bucket.
pub const POWER_OF_TWO_PADDING_LIMIT_BYTES: usize = 64 * 1024;
/// Alignment of every bucket above the power-of-two limit.
pub const LARGE_PADDING_BUCKET_STEP_BYTES: usize = 64 * 1024;
/// Largest ciphertext bucket the padded-content format accepts.
pub const MAX_PADDING_BUCKET_BYTES: usize = 16 * 1024 * 1024;
/// Magic prefix of one padded plaintext frame.
pub const PADDED_PLAINTEXT_MAGIC: &[u8] = b"LCOSM-PAD-v1";

pub fn validate_authenticated_padding_bucket(ciphertext_size: usize) -> Result<()> {
    ensure!(
        ciphertext_size >= MIN_PADDING_BUCKET_BYTES && ciphertext_size <= MAX_PADDING_BUCKET_BYTES,
        "secure mesh ciphertext bucket is outside bounds"
    );
    if ciphertext_size <= POWER_OF_TWO_PADDING_LIMIT_BYTES {
        ensure!(
            ciphertext_size.is_power_of_two(),
            "secure mesh ciphertext bucket is not a supported power-of-two bucket"
        );
    } else {
        ensure!(
            ciphertext_size % LARGE_PADDING_BUCKET_STEP_BYTES == 0,
            "secure mesh ciphertext bucket is not aligned to the large-payload step"
        );
    }
    Ok(())
}
