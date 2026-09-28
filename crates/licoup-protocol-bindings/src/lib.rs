//! Fixed-input admission for the LicoArc Candidate integrated by L03 (D22).
//!
//! LicoUp owns caller-side trust, custody, persistence, and application
//! effects. The Protocol Line, its definitions, and all cryptography stay with
//! LicoArc and the LicoArc Rust SDK. This crate is the one boundary between
//! them: an explicitly supplied authority artifact is either the fixed
//! Candidate the SDK verifies, or it is refused fail-closed with
//! [`AUTHORIZATION_REQUIRED`] before any persistent write, network I/O, or
//! effect.
//!
//! The fixed input is pinned by the revision-pinned `licoarc` dependency in the
//! workspace manifest, so a different line can only arrive as a deliberate
//! upgrade rather than by following an upstream branch.

mod admission;
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
