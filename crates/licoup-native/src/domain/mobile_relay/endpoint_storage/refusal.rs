//! Stable refusal classes, continuity facts, and status DTOs.
//!
//! These are the only values this module returns on its own (non-SDK) entry
//! points, so the composition root and peer transports can branch on a stable
//! code instead of parsing text. A refusal never carries key material, payload
//! bytes, or paths.
//!
//! The class list is deliberately small: every code names one condition a
//! caller can act on. An SDK refusal is carried verbatim through
//! [`EndpointV7StorageError::sdk_error`].

use core::fmt;

use licoup_protocol_bindings::{Error, ErrorCode, Stage};

/// One refused endpoint-storage operation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EndpointV7StorageError {
    code: &'static str,
    sdk: Option<Error>,
}

impl EndpointV7StorageError {
    /// The root is already open for writing by another handle or process.
    pub const ROOT_LOCKED: &'static str = "endpoint_storage_root_locked";
    /// The durable schema is newer than this build understands. Nothing is
    /// migrated, downgraded, or overwritten for this condition.
    pub const SCHEMA_UNSUPPORTED: &'static str = "endpoint_storage_schema_unsupported";
    /// A durable generation is ahead of what can be presented, so continuing
    /// would reuse a message sequence that was already committed.
    pub const ROLLED_BACK: &'static str = "endpoint_storage_rolled_back";
    /// The root carries a committed session whose ratchet snapshot did not
    /// survive the process. An explicit new session is required.
    pub const CONTINUITY_LOST: &'static str = "endpoint_storage_continuity_lost";
    /// The root was explicitly revoked. It stays terminal until a new root.
    pub const REVOKED: &'static str = "endpoint_storage_revoked";
    /// No authorised new session was requested before the operation.
    pub const NOT_RECOVERED: &'static str = "endpoint_storage_not_recovered";
    /// The selected platform custody backend is unavailable.
    pub const PLATFORM_UNSUPPORTED: &'static str = "endpoint_storage_platform_unsupported";
    /// A custody token is unknown, fenced, revoked, or of the wrong purpose
    /// or lifecycle for the requested operation.
    pub const CUSTODY_REFUSED: &'static str = "endpoint_storage_custody_refused";
    /// A requested key material object is missing from the platform store.
    pub const MATERIAL_UNAVAILABLE: &'static str = "endpoint_storage_material_unavailable";
    /// The durable commit did not happen. Nothing was applied.
    pub const COMMIT_REFUSED: &'static str = "endpoint_storage_commit_refused";
    /// The durable store could not be read, written, or locked as required.
    pub const IO: &'static str = "endpoint_storage_io";

    pub(crate) const fn new(code: &'static str) -> Self {
        Self { code, sdk: None }
    }

    pub(crate) const fn with_sdk(code: &'static str, sdk: Error) -> Self {
        Self {
            code,
            sdk: Some(sdk),
        }
    }

    pub(crate) const fn sdk(error: Error) -> Self {
        Self {
            code: Self::COMMIT_REFUSED,
            sdk: Some(error),
        }
    }

    /// The stable class of this refusal.
    #[must_use]
    pub const fn code(self) -> &'static str {
        self.code
    }

    /// The SDK cause, when the refusal came from the pinned SDK contract.
    #[must_use]
    pub const fn sdk_error(self) -> Option<Error> {
        self.sdk
    }

    /// Whether the caller may retry the same call unchanged.
    ///
    /// An uncertain result (`retryable`) must re-drive the same already
    /// committed item; nothing else here is retryable in place.
    #[must_use]
    pub const fn retryable(self) -> bool {
        matches!(self.sdk, Some(error) if error.retryable)
    }
}

impl From<Error> for EndpointV7StorageError {
    fn from(error: Error) -> Self {
        Self::sdk(error)
    }
}

impl fmt::Display for EndpointV7StorageError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.sdk {
            Some(error) => write!(formatter, "{}: {error}", self.code),
            None => formatter.write_str(self.code),
        }
    }
}

impl std::error::Error for EndpointV7StorageError {}

/// SDK-side refusals this adapter produces for custody and state contract
/// violations. They are opaque on purpose: a caller learns that the operation
/// was refused, not which token or material existed.
pub(crate) const fn provider_refusal() -> Error {
    Error::terminal(ErrorCode::ProviderFailure, Stage::Provider)
}

pub(crate) const fn commit_conflict() -> Error {
    Error::terminal(ErrorCode::Conflict, Stage::Commit)
}

pub(crate) const fn continuity_lost_sdk() -> Error {
    Error::terminal(ErrorCode::StateRollback, Stage::Validation)
}

pub(crate) const fn revoked_sdk() -> Error {
    Error::terminal(ErrorCode::Deleted, Stage::Validation)
}

pub(crate) const fn bound_exceeded() -> Error {
    Error::terminal(ErrorCode::BoundExceeded, Stage::Validation)
}

/// What happened to the previous durable session at open, if any.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointV7Continuity {
    /// No committed session in this epoch; the store starts from its initial
    /// snapshot at revision 0.
    Fresh,
    /// A committed session exists but its ratchet snapshot is not restorable.
    /// Loading is refused until [`super::EndpointV7Storage::begin_new_session`]
    /// explicitly opens a new one.
    ContinuityLost,
    /// A durable generation is ahead of the presented state (restored older
    /// database, deleted database under a live anchor, or lost anchor). Loading
    /// stays refused; only an explicit new session moves forward.
    RolledBack,
    /// The root was revoked. It is terminal.
    Revoked,
}

impl EndpointV7Continuity {
    /// Stable class string.
    #[must_use]
    pub const fn code(self) -> &'static str {
        match self {
            Self::Fresh => "fresh",
            Self::ContinuityLost => "continuity_lost",
            Self::RolledBack => "rolled_back",
            Self::Revoked => "revoked",
        }
    }

    /// Whether a load can proceed without an explicit new session.
    #[must_use]
    pub const fn loadable(self) -> bool {
        matches!(self, Self::Fresh)
    }
}

/// Content kind of one fenced delivery record. Payload bytes stay in the
/// durable store until a caller drains them explicitly.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EndpointV7PendingKind {
    Packet,
    Effect,
    Plaintext,
}

impl EndpointV7PendingKind {
    pub(crate) fn from_str(value: &str) -> Option<Self> {
        match value {
            "packet" => Some(Self::Packet),
            "effect" => Some(Self::Effect),
            "plaintext" => Some(Self::Plaintext),
            _ => None,
        }
    }
}

/// One already-committed delivery record of a lost session.
///
/// The record was committed by an SDK revision that no longer exists in
/// memory, so it is fenced rather than auto-attached: the caller decides
/// whether to re-drive the exact item or discard it. It is never re-created
/// with a new identity.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EndpointV7FencedPending {
    pub id: u128,
    pub kind: EndpointV7PendingKind,
}

/// What the durable record contained at open, before an explicit new session.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EndpointV7RecoveredFacts {
    /// Durable session epoch the record belongs to.
    pub epoch: u64,
    /// Last committed generation in that epoch.
    pub generation: u64,
    /// Committed delivery records of the lost session, still durable.
    pub fenced_pending: Vec<EndpointV7FencedPending>,
    /// Tentative keys that were never adopted; they were aborted and their
    /// material made unreachable.
    pub staged_keys_aborted: u64,
    /// Adopted session keys of the lost session; they were fenced and can
    /// never be used by another session.
    pub session_keys_fenced: u64,
    /// Whether a rollback of the durable record was detected.
    pub rollback_suspected: bool,
}

/// One drained payload of a fenced delivery record.
#[derive(Clone, Eq, PartialEq)]
pub enum EndpointV7PendingPayload {
    Packet(Vec<u8>),
    Effect(Vec<u8>),
    Plaintext(Vec<u8>),
}

impl fmt::Debug for EndpointV7PendingPayload {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("EndpointV7PendingPayload([REDACTED])")
    }
}

/// A stable status projection for the composition root, UI projection, and
/// peer transports. It contains no key material and no payload bytes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EndpointV7StorageStatus {
    pub schema_version: u32,
    pub epoch: u64,
    pub generation: u64,
    pub pending_count: u32,
    pub fenced_pending_count: u32,
    pub custody_backend: &'static str,
    pub revoked: bool,
    pub continuity: EndpointV7Continuity,
    pub root_locked: bool,
    pub session_keys_fenced: u64,
    pub staged_keys_aborted: u64,
}
