//! LicoUp's neutral LicoArc relay codec and fixed-input protocol admission.
//!
//! LicoUp owns caller-side trust, key custody, persistence, and application
//! effects. This crate contains neutral relay wire encoding and authenticated
//! header handling, while authority artifacts are verified by the LicoArc Rust
//! SDK. An explicitly supplied artifact is either the fixed Candidate the SDK
//! verifies, or it is refused fail-closed with [`AUTHORIZATION_REQUIRED`]
//! before any persistent write, network I/O, or effect.
//!
//! The fixed input is pinned by the revision-pinned `licoarc` dependency in the
//! workspace manifest, so a different line can only arrive as a deliberate
//! upgrade rather than by following an upstream branch.

mod admission;
pub mod licoarc_relay;
mod padding;

pub use admission::{AUTHORIZATION_REQUIRED, AdmissionRefusal, AuthorityInput};
pub use licoarc::artifact::VerifiedProtocolLine;
pub use licoarc::error::{Error, ErrorCode};
pub use padding::{
    AuthenticatedPaddingBucketError, LARGE_PADDING_BUCKET_STEP_BYTES, MAX_PADDING_BUCKET_BYTES,
    MIN_PADDING_BUCKET_BYTES, POWER_OF_TWO_PADDING_LIMIT_BYTES,
    validate_authenticated_padding_bucket,
};

#[cfg(test)]
mod tests;
