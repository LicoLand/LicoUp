//! Consumer-owned ports the client adapter must supply to the pinned LicoArc SDK.
//!
//! LicoUp owns custody, persistence, time, and transport; the SDK owns the
//! protocol. These traits are the caller side of that split, reduced from the
//! caller-owned requirements the pinned SDK revision actually declares.
//! Every item cites the SDK source it mirrors, read at revision
//! `244ce7186cac1690c18f091dbe02df36a0860ef4`
//! (`licoarc-rust/src/...`, package `licoarc`):
//!
//! | port | SDK requirement |
//! | --- | --- |
//! | [`KeyCustody`] | `state::KeyCustody`, `src/state/mod.rs:175-211` |
//! | [`AtomicState`] | `state::AtomicState`, `src/state/mod.rs:452-468` |
//! | [`Clock`] | `state::Clock`, `src/state/mod.rs:222-224` |
//! | [`Transport`] | `state::PacketCarrier` + `transport::TransportOutcome`, `src/state/mod.rs:470-472`, `src/transport.rs:214-230` |
//!
//! These are consumer-owned traits: no SDK type appears in their signature, so
//! this crate stays dependency-free and the adapter that satisfies both sides
//! lives in the crate that composes them. Nothing here re-implements protocol
//! policy: the SDK alone decides protocol outcomes, and a port only performs the
//! caller-owned operation it is asked for.
//!
//! The pairing and relay-control branches of `transport` are deliberately
//! absent. Pairing ships as an optional collaboration package, so a client
//! without it initializes no pairing state and starts no listener; the packet
//! path below is what a client without that package actually needs.

use core::fmt;

/// One definite, uncertain, or refused caller-owned operation.
///
/// The distinction is the one the SDK's own recovery logic turns on
/// (`Error::retryable`, `src/error.rs:54-71`): an uncertain outcome must re-drive
/// the same already-committed item, never a fresh one.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PortFailure {
    /// The operation definitely did not happen. The SDK maps this to a terminal
    /// `ProviderFailure` (`src/endpoint/mod.rs:1329`).
    Unavailable,
    /// The operation may or may not have happened. The SDK maps this to a
    /// retryable commit failure (`src/endpoint/mod.rs:1309`).
    Uncertain,
    /// The store's expected revision was not current, so nothing was applied.
    /// The SDK maps this to `Conflict` and then re-reads
    /// (`src/endpoint/mod.rs:1318-1330`).
    Conflict,
    /// A protocol bound would be exceeded. Mirrors `Revision::successor`
    /// (`src/state/mod.rs:240-245`).
    BoundExceeded,
}

impl PortFailure {
    /// Whether the caller must re-drive the same already-committed item.
    #[must_use]
    pub const fn retryable(self) -> bool {
        matches!(self, Self::Uncertain)
    }
}

impl fmt::Display for PortFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            Self::Unavailable => "unavailable",
            Self::Uncertain => "uncertain",
            Self::Conflict => "conflict",
            Self::BoundExceeded => "bound exceeded",
        };
        formatter.write_str(text)
    }
}

impl std::error::Error for PortFailure {}

/// Purpose of one custody object, mirroring the SDK's marker types
/// (`src/state/mod.rs:14-23`).
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum CustodyPurpose {
    Ed25519Signing,
    MlDsa65Signing,
    X25519Private,
    MlKem768Private,
    MlKemEncapsulationEntropy,
}

/// Whether a custody object is tentative or adopted, mirroring the SDK's
/// `StagedSecretHandle`/`SecretHandle` split (`src/state/mod.rs:46-132`).
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum CustodyLifecycle {
    Adopted,
    Staged,
}

/// One opaque custody reference: a non-secret token plus the purpose and
/// lifecycle the caller must re-check.
///
/// The SDK's marker types are erased when a handle crosses this boundary, so
/// purpose and lifecycle travel as values instead. An implementation must still
/// look the token up and verify its purpose, lifecycle, and permission for the
/// requested operation; the SDK requires exactly that of its own
/// implementations (`src/state/mod.rs:171-174`).
#[derive(Clone, Copy, Eq, Hash, PartialEq)]
pub struct CustodyHandle {
    token: u128,
    purpose: CustodyPurpose,
    lifecycle: CustodyLifecycle,
}

impl CustodyHandle {
    #[must_use]
    pub const fn adopted(token: u128, purpose: CustodyPurpose) -> Self {
        Self {
            token,
            purpose,
            lifecycle: CustodyLifecycle::Adopted,
        }
    }

    #[must_use]
    pub const fn staged(token: u128, purpose: CustodyPurpose) -> Self {
        Self {
            token,
            purpose,
            lifecycle: CustodyLifecycle::Staged,
        }
    }

    /// The non-secret token the caller's coupled state/custody backend keys on
    /// (`SecretHandle::custody_token`, `src/state/mod.rs:61-65`).
    #[must_use]
    pub const fn custody_token(self) -> u128 {
        self.token
    }

    #[must_use]
    pub const fn purpose(self) -> CustodyPurpose {
        self.purpose
    }

    #[must_use]
    pub const fn lifecycle(self) -> CustodyLifecycle {
        self.lifecycle
    }
}

impl fmt::Debug for CustodyHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The SDK redacts handles the same way (`src/state/mod.rs:74-78`).
        formatter.write_str("CustodyHandle([REDACTED])")
    }
}

/// Largest integer the authority permits for persisted generations
/// (`src/state/mod.rs:9`).
pub const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

/// One monotonically increasing protocol-state generation
/// (`src/state/mod.rs:226-246`).
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Revision(u64);

impl Revision {
    #[must_use]
    pub const fn initial() -> Self {
        Self(0)
    }

    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }

    pub fn successor(self) -> Result<Self, PortFailure> {
        if self.0 >= MAX_SAFE_INTEGER {
            return Err(PortFailure::BoundExceeded);
        }
        Ok(Self(self.0 + 1))
    }
}

/// One handle adoption or deletion committed together with the snapshot
/// (`src/state/mod.rs:156-169`).
///
/// `Adopt` carries a staged `X25519Private` or `MlKem768Private` handle;
/// `Delete` carries an adopted handle of a deletable purpose. The protocol layer
/// emits nothing else, and an implementation must refuse any other pairing.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum KeyMutation {
    Adopt(CustodyHandle),
    Delete(CustodyHandle),
}

/// Content-opaque identity of one committed delivery unit
/// (`src/state/mod.rs:293-307`).
#[derive(Clone, Copy, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct PendingId(u128);

impl PendingId {
    #[must_use]
    pub const fn from_token(token: u128) -> Self {
        Self(token)
    }
}

impl fmt::Debug for PendingId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PendingId([REDACTED])")
    }
}

/// The payload that crosses one post-commit boundary
/// (`src/state/mod.rs:309-320`). The protocol layer already bounded its length.
#[derive(Clone, Eq, PartialEq)]
pub enum PendingPayload {
    /// Outbound protected packet for [`Transport::submit`].
    Packet(Vec<u8>),
    /// Application effect.
    Effect(Vec<u8>),
    /// Inbound plaintext for the client's own receiver.
    Plaintext(Vec<u8>),
}

impl fmt::Debug for PendingPayload {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PendingPayload([REDACTED])")
    }
}

/// One committed delivery unit that is durable until its boundary settles it
/// (`src/state/mod.rs:322-363`).
#[derive(Clone, Eq, PartialEq)]
pub struct PendingItem {
    id: PendingId,
    payload: PendingPayload,
}

impl PendingItem {
    #[must_use]
    pub const fn packet(id: PendingId, packet: Vec<u8>) -> Self {
        Self {
            id,
            payload: PendingPayload::Packet(packet),
        }
    }

    #[must_use]
    pub const fn effect(id: PendingId, effect: Vec<u8>) -> Self {
        Self {
            id,
            payload: PendingPayload::Effect(effect),
        }
    }

    #[must_use]
    pub const fn plaintext(id: PendingId, plaintext: Vec<u8>) -> Self {
        Self {
            id,
            payload: PendingPayload::Plaintext(plaintext),
        }
    }

    #[must_use]
    pub const fn id(&self) -> PendingId {
        self.id
    }

    #[must_use]
    pub const fn payload(&self) -> &PendingPayload {
        &self.payload
    }
}

impl fmt::Debug for PendingItem {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingItem")
            .field("id", &self.id)
            .field("payload", &"[REDACTED]")
            .finish()
    }
}

/// One complete protocol snapshot at one revision, with the delivery units that
/// were committed with it (`src/state/mod.rs:248-291`).
#[derive(Clone, Eq, PartialEq)]
pub struct Versioned<S> {
    revision: Revision,
    state: S,
    pending: Vec<PendingItem>,
}

impl<S> Versioned<S> {
    #[must_use]
    pub const fn initial(state: S) -> Self {
        Self {
            revision: Revision::initial(),
            state,
            pending: Vec::new(),
        }
    }

    #[must_use]
    pub const fn revision(&self) -> Revision {
        self.revision
    }

    #[must_use]
    pub const fn state(&self) -> &S {
        &self.state
    }

    #[must_use]
    pub fn pending(&self) -> &[PendingItem] {
        &self.pending
    }
}

impl<S> fmt::Debug for Versioned<S> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Versioned")
            .field("revision", &self.revision)
            .field("state", &"[REDACTED]")
            .field("pending", &self.pending)
            .finish()
    }
}

/// The complete next snapshot plus every custody mutation it requires
/// (`src/state/mod.rs:375-439`).
///
/// A store applies it old-or-new: the snapshot, the adoptions, and the deletions
/// are one transaction that advances exactly one revision, or applies nothing.
#[derive(Clone, Eq, PartialEq)]
pub struct StateCommit<S> {
    next_state: S,
    key_mutations: Vec<KeyMutation>,
    pending: Vec<PendingItem>,
}

impl<S> StateCommit<S> {
    #[must_use]
    pub const fn new(
        next_state: S,
        key_mutations: Vec<KeyMutation>,
        pending: Vec<PendingItem>,
    ) -> Self {
        Self {
            next_state,
            key_mutations,
            pending,
        }
    }

    #[must_use]
    pub const fn next_state(&self) -> &S {
        &self.next_state
    }

    #[must_use]
    pub fn key_mutations(&self) -> &[KeyMutation] {
        &self.key_mutations
    }

    #[must_use]
    pub fn pending(&self) -> &[PendingItem] {
        &self.pending
    }

    /// Converts a store-validated commit into its next complete snapshot
    /// (`src/state/mod.rs:431-438`).
    pub fn into_versioned(self, expected: Revision) -> Result<Versioned<S>, PortFailure> {
        Ok(Versioned {
            revision: expected.successor()?,
            state: self.next_state,
            pending: self.pending,
        })
    }
}

impl<S> fmt::Debug for StateCommit<S> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StateCommit")
            .field("next_state", &"[REDACTED]")
            .field("key_mutations", &self.key_mutations)
            .field("pending", &self.pending)
            .finish()
    }
}

/// Performs only the fixed private operations the protocol needs
/// (`src/state/mod.rs:175-211`).
///
/// Implementations must look up every token in caller-owned custody and verify
/// its purpose and lifecycle for the requested operation. The handle's own
/// values are not proof that a token is authorized.
pub trait KeyCustody {
    fn ed25519_public(&self, handle: CustodyHandle) -> Result<[u8; 32], PortFailure>;
    fn ed25519_sign(&self, handle: CustodyHandle, message: &[u8]) -> Result<[u8; 64], PortFailure>;
    fn ml_dsa_65_public(&self, handle: CustodyHandle) -> Result<Vec<u8>, PortFailure>;
    fn ml_dsa_65_sign(&self, handle: CustodyHandle, message: &[u8])
    -> Result<Vec<u8>, PortFailure>;
    fn x25519_public(&self, handle: CustodyHandle) -> Result<[u8; 32], PortFailure>;
    fn x25519(&self, handle: CustodyHandle, public: &[u8; 32]) -> Result<[u8; 32], PortFailure>;
    fn ml_kem_768_public(&self, handle: CustodyHandle) -> Result<Vec<u8>, PortFailure>;
    fn ml_kem_768_encapsulate(
        &self,
        public: &[u8],
        entropy: CustodyHandle,
    ) -> Result<(Vec<u8>, [u8; 32]), PortFailure>;
    fn ml_kem_768_decapsulate(
        &self,
        handle: CustodyHandle,
        ciphertext: &[u8],
    ) -> Result<[u8; 32], PortFailure>;
    /// Makes a definitely uncommitted tentative object logically unreachable.
    /// This does not claim physical erasure of provider media
    /// (`src/state/mod.rs:205-210`).
    fn abort_x25519(&mut self, staged: CustodyHandle);
    /// Makes a definitely uncommitted tentative object logically unreachable.
    /// This does not claim physical erasure of provider media.
    fn abort_ml_kem_768(&mut self, staged: CustodyHandle);
}

/// One caller-owned durable protocol store (`src/state/mod.rs:452-468`).
///
/// `compare_and_swap` applies the complete snapshot and all handle
/// adoptions/deletions in one transaction owned by the caller's coupled
/// state/custody backend and advances exactly one revision, or applies nothing.
/// A backend unable to provide that old-or-new result does not satisfy this
/// contract.
pub trait AtomicState {
    /// The protocol snapshot the SDK evolves. It stays opaque here.
    type Snapshot;

    fn load(&self) -> Result<Versioned<Self::Snapshot>, PortFailure>;

    fn compare_and_swap(
        &mut self,
        expected: Revision,
        commit: StateCommit<Self::Snapshot>,
    ) -> Result<Revision, PortFailure>;

    /// Atomically removes exactly one pending item from `revision`, preserving
    /// the complete state and every other pending item, and advances once.
    fn settle(&mut self, revision: Revision, pending: PendingId) -> Result<Revision, PortFailure>;
}

/// Caller-owned time (`src/state/mod.rs:222-224`).
pub trait Clock {
    fn now_unix_seconds(&self) -> Result<u64, PortFailure>;
}

/// The SDK's own classification of one transport attempt
/// (`transport::classify_status`, `src/transport.rs:214-230`).
///
/// It is carried verbatim: a client must not add a fifth outcome, and
/// [`TransportOutcome::Ambiguous`] specifically means the attempt may or may not
/// have been accepted.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransportOutcome {
    Accepted,
    Rejected,
    Transient,
    Ambiguous,
}

/// Sends exactly one already-committed protected packet
/// (`state::PacketCarrier::send`, `src/state/mod.rs:470-472`).
///
/// The packet is bounded and committed before this call; the caller classifies
/// the relay response with the SDK and reports it back as a
/// [`TransportOutcome`].
pub trait Transport {
    fn submit(&mut self, packet: &[u8]) -> Result<TransportOutcome, PortFailure>;
}

#[cfg(test)]
mod tests {
    use super::{MAX_SAFE_INTEGER, PortFailure, Revision};

    #[test]
    fn revision_arithmetic_stops_at_the_protocol_bound() {
        assert_eq!(Revision::initial().value(), 0);
        assert_eq!(Revision::initial().successor().unwrap().value(), 1);
        let last = Revision(MAX_SAFE_INTEGER - 1);
        assert_eq!(last.successor().unwrap(), Revision(MAX_SAFE_INTEGER));
        assert_eq!(
            Revision(MAX_SAFE_INTEGER).successor(),
            Err(PortFailure::BoundExceeded)
        );
    }

    #[test]
    fn only_an_uncertain_failure_is_retryable() {
        for failure in [
            PortFailure::Unavailable,
            PortFailure::Conflict,
            PortFailure::BoundExceeded,
        ] {
            assert!(!failure.retryable());
        }
        assert!(PortFailure::Uncertain.retryable());
    }
}
