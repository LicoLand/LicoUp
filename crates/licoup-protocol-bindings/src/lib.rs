//! LicoUp's neutral LicoArc relay codec and fixed-input protocol admission.
//!
//! LicoUp owns caller-side trust, key custody, persistence, and application
//! effects. This crate contains neutral relay wire encoding and authenticated
//! header handling, while authority artifacts are verified by the LicoArc Rust
//! SDK. An explicitly supplied artifact is either the fixed Candidate the SDK
//! verifies, or it is refused fail-closed with [`AUTHORIZATION_REQUIRED`]
//! before any persistent write, network I/O, or effect.
//!
//! The crate is the one boundary between LicoUp and that fixed SDK:
//!
//! * [`admission`] accepts an explicitly supplied authority artifact, or refuses
//!   it fail-closed before any persistent write, network I/O, or effect;
//! * [`version`] freezes the one Protocol Line version this client accepts and
//!   refuses any other version for that call only;
//! * [`inbound`] runs the SDK's own verification entries and records what they
//!   verified as an explicit [`TrustFacts`] value whose constructors are
//!   fallible and private, so local code cannot mint trusted facts;
//! * [`licoarc_relay`] encodes LicoUp's neutral relay envelope, which carries no
//!   protocol authority of its own.
//!
//! The fixed input is pinned by the revision-pinned `licoarc` dependency in the
//! workspace manifest, so a different line can only arrive as a deliberate
//! upgrade rather than by following an upstream branch.
//!
//! # Blocked scope
//!
//! No authority artifact is bundled implicitly. Calls without an explicitly
//! admitted artifact block only the branch that requires it; callers supplying
//! the fixed Candidate can exercise that branch. Local verification, admission
//! geometry, the version contract, and caller-owned ports stay unblocked.

mod admission;
mod durable_obligation;
mod inbound;
pub mod licoarc_relay;
mod padding;
mod version;

pub use admission::{AUTHORIZATION_REQUIRED, AdmissionRefusal, AuthorityInput};
pub use durable_obligation::{
    AdmittedObligation, DEFAULT_PRE_ADMISSION_BUDGET_BYTES,
    DEFAULT_PRE_ADMISSION_RETENTION_SECONDS, DURABLE_OBLIGATION_SCHEMA, DeliveryOutcome,
    DurableObligationRecord, ObligationId, ObligationLedger, ObligationLimits,
    PreAdmissionRefusal, Settled, SettlementRefusal, SweepOutcome,
};
pub use inbound::{
    AuthorFact, DeviceFact, EndpointConsumer, InboundRefusal, InboundSession, PermissionFact,
    ReplayIdentity, TrustFacts, UserRead,
};
pub use licoarc::artifact::VerifiedProtocolLine;
pub use licoarc::error::{Error, ErrorCode, Stage};
/// Fixed-revision SDK traits and state used by the platform endpoint adapters.
/// Core contracts remain SDK-free; adapters consume the same pinned boundary
/// through this re-export instead of declaring their own SDK dependency.
pub use licoarc::{endpoint, provider, state};
pub use padding::{
    AuthenticatedPaddingBucketError, LARGE_PADDING_BUCKET_STEP_BYTES, MAX_PADDING_BUCKET_BYTES,
    MIN_PADDING_BUCKET_BYTES, POWER_OF_TWO_PADDING_LIMIT_BYTES,
    validate_authenticated_padding_bucket,
};
pub use version::{
    ACCEPTED_GENERATION, ACCEPTED_PROTECTION_PROFILE_ID, ACCEPTED_PROTOCOL_LINE_ID,
    ACCEPTED_WIRE_ID, AcceptedVersion, ProtocolVersion, VersionRefusal,
};

/// One capability this build cannot exercise, with the named reason.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BlockedScope {
    /// The branch that is blocked.
    pub capability: &'static str,
    /// Why it is blocked, naming the missing input.
    pub reason: &'static str,
}

/// Branches requiring an explicit authority input, absent by default.
///
/// A blocked branch never blocks the client: it blocks the calls that need the
/// named input, and the rest of the boundary keeps working. No credential, key
/// material, or artifact substitute is fabricated for a blocked branch.
pub const BLOCKED_SCOPES: &[BlockedScope] = &[BlockedScope {
    capability: "pairing handshake, protected-record exchange, and transport submission",
    reason: "this build does not implicitly bundle a LicoArc v1 authority artifact; \
                  AuthorityBundle::admit needs the explicit fixed artifact to produce the \
                  pinned VerifiedProtocolLine for Endpoint construction; supply it through \
                 LICOARC_AUTHORITY_BUNDLE to unblock it",
}];

#[cfg(test)]
mod tests;
