//! Resource state as it actually is, and what admission does with it.
//!
//! C01 asks admission to "recheck current authority/resources at effect
//! admission boundary" and to reserve budget by `effectId` "or explicit
//! NotConfigured". Two consequences shape this module:
//!
//! * **A receipt carries observations, not a boolean.** [`ResourceState`] is
//!   what the owner said was true — whether it was available, how many slots
//!   are in use, what its capacity is, and its revision. An admitted effect is
//!   recorded with the state it was admitted against, which is what makes a
//!   later "why did this run when the disk was full?" answerable.
//! * **A refusal names what was missing.** The refusal carries the claim that
//!   was made and the state that answered it, so "capacity" and "availability"
//!   and "the owner moved under you" stay distinguishable instead of collapsing
//!   into `false`.
//!
//! An unconfigured budget is not a refusal. [`ReservationOutcome::NotConfigured`]
//! is a fact reported to the caller; the plan is explicit that a deployment
//! which configured no budget must not silently acquire a gate.
//!
//! A configured owner that will not hold capacity right now answers
//! [`ReservationOutcome::Waiting`] — a wait, not a failure. That distinction is
//! the whole point of the variant: an exhausted pool, a contended single writer
//! and an upstream rate limit are all "try again later", and an owner forced to
//! answer them through `Result::Err` would report a limit as a broken effect.
//! Nothing is held and nothing ran, so work in flight keeps running and the next
//! attempt may succeed.
//!
//! What this module does not own: the durable reservation ledger and its
//! idempotent release across the budget database and the graph database belong
//! to the economic leaf (V7-EC1) and to reconciliation (V7-S2). Here the port
//! states the shape it must answer in, and the rule that a reservation for an
//! effect that may already have run is not released early.

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// What one effect asks a resource owner for.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceClaim {
    pub resource_id: String,
    /// How many units this effect occupies while it runs.
    pub slots: u32,
    /// The owner revision the caller decided against, when it named one.
    ///
    /// A mismatch is reported as a moved revision rather than as an
    /// unavailable resource: one is "read again and retry", the other is "this
    /// will not fit".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expected_revision: Option<u64>,
}

impl ResourceClaim {
    pub fn new(resource_id: impl Into<String>, slots: u32) -> Self {
        Self {
            resource_id: resource_id.into(),
            slots,
            expected_revision: None,
        }
    }

    pub fn with_expected_revision(mut self, revision: u64) -> Self {
        self.expected_revision = Some(revision);
        self
    }
}

/// The question one observation asks its owner.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ResourceRequest {
    pub resource_id: String,
    pub run_id: String,
    /// The effect identity the observation is for (C01's `effectId`).
    pub effect_id: String,
}

/// What a resource owner said was true when it was asked.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceState {
    pub resource_id: String,
    /// Whether the owner is available at all. A resource that is present and
    /// full is still `available`, with `active == capacity`.
    ///
    /// An owner that is holding new work back — contended by another writer,
    /// rate-limited upstream — reports itself unavailable rather than failing:
    /// the answer is a refusal the caller waits on, not an error.
    pub available: bool,
    /// Units currently in use, as the owner counts them.
    pub active: u32,
    /// Units the owner will allow at once.
    pub capacity: u32,
    /// The owner's own revision for this resource at observation time. Read
    /// back with the counts, because a resource that changed under the caller
    /// must be reported as changed, not as unavailable.
    pub revision: u64,
}

impl ResourceState {
    pub fn free_slots(&self) -> u32 {
        self.capacity.saturating_sub(self.active)
    }

    /// Whether one claim fits in the reported state.
    pub fn admits(&self, claim: &ResourceClaim) -> bool {
        self.available && self.free_slots() >= claim.slots
    }
}

/// What one effect asks a resource owner to hold for it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ReservationRequest {
    /// The effect the reservation belongs to (C01's `effectId`).
    pub effect_id: String,
    /// The attempt this reservation is being taken for. Kept beside the effect
    /// id because the id is stable across attempts and the attempt is what a
    /// receipt is a replay guard for.
    pub attempt_token: String,
    pub resource_id: String,
    pub slots: u32,
}

/// A reservation the owner durably holds.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReservationRef {
    pub reservation_id: String,
    /// The effect identity this holds capacity for. A reservation is never
    /// booked under a run or a node: a released effect must release its own
    /// reservation and no one else's.
    pub effect_id: String,
    pub resource_id: String,
    pub slots: u32,
    pub revision: u64,
    /// True when the owner answered with the reservation it already held for
    /// this effect id, so a retried admission reuses that one instead of
    /// booking a second. The receipt then shows the reuse rather than hiding
    /// it, which is what a replay check reads.
    pub reused: bool,
}

/// Why a resource owner would not hold capacity right now.
///
/// Every variant is a wait: the owner is configured, it answered, and it holds
/// nothing for this effect. None of them means the effect failed.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ReservationDenial {
    /// The owner has nothing available for new work. Work in flight keeps
    /// running and nothing already started is affected.
    Exhausted,
    /// This effect alone asks for more than the owner will make available; the
    /// same request will not fit later either without a different size.
    ExceedsRemaining,
    /// Another writer, or an upstream limit the owner respects, currently holds
    /// the resource. The same request may succeed once that clears.
    Contended,
}

/// A configured owner's answer that this effect waits.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResourceWaiting {
    pub resource_id: String,
    pub effect_id: String,
    pub denial: ReservationDenial,
    /// The units the owner reports free at the moment it refused, when it
    /// reports a number at all. Absent is not zero: it means the owner did not
    /// put a figure on the wait.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_slots: Option<u32>,
}

/// The answer to a reservation attempt.
///
/// [`Self::NotConfigured`] and [`Self::Waiting`] are both answers rather than
/// failures: C01 asks for the explicit "not configured" fact, and a configured
/// owner that is exhausted, contended or rate-limited says so instead of
/// failing the call.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "reservation")]
pub enum ReservationOutcome {
    Reserved(ReservationRef),
    NotConfigured,
    Waiting(ResourceWaiting),
}

impl ReservationOutcome {
    pub fn reserved(&self) -> Option<&ReservationRef> {
        match self {
            Self::Reserved(reference) => Some(reference),
            Self::NotConfigured | Self::Waiting(_) => None,
        }
    }

    pub fn waiting(&self) -> Option<&ResourceWaiting> {
        match self {
            Self::Waiting(waiting) => Some(waiting),
            Self::Reserved(_) | Self::NotConfigured => None,
        }
    }
}

/// Where an effect actually is, as far as its own reservation is concerned.
///
/// C03's rule, in reservation terms: only known-not-executed work may be
/// retried or released as if nothing happened, and a started or unknown effect
/// keeps its capacity because it may already be running (and, for a metered
/// resource, already spending).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EffectPosition {
    NotStarted,
    Started,
    Settled,
    Unknown,
}

/// Whether a reservation may be given back now.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReservationSettlement {
    /// The reservation may be released; the effect cannot spend more.
    Release,
    /// Hold it until the effect is reconciled: releasing early would hand the
    /// same capacity to a second effect while the first may still be running.
    HoldUntilReconciled,
}

/// The reservation rule for one effect position.
pub fn settlement_for(position: EffectPosition) -> ReservationSettlement {
    match position {
        EffectPosition::NotStarted | EffectPosition::Settled => ReservationSettlement::Release,
        EffectPosition::Started | EffectPosition::Unknown => {
            ReservationSettlement::HoldUntilReconciled
        }
    }
}

/// Resource state, reservation, and release, as its owner answers them.
///
/// `observe` is read-only and must report the owner's own revision, not a
/// cached one: admission is the boundary where a stale answer becomes a running
/// effect. `release` is idempotent, because the caller that releases an orphaned
/// reservation may not know whether an earlier reconcile already did.
pub trait ResourcePort: Send + Sync {
    /// What this resource actually is right now.
    fn observe(&self, request: &ResourceRequest) -> Result<ResourceState>;

    /// Hold capacity for one effect, or answer that none is configured or that
    /// this effect waits.
    ///
    /// The reservation is per effect id: repeating the call for an effect that
    /// already holds capacity returns that same reservation with `reused` set,
    /// so a retried admission cannot double-book. The owner enforces its own
    /// capacity here — the observation before this call is a courtesy, and an
    /// effect that no longer fits is answered with [`ReservationOutcome::Waiting`]
    /// rather than an error, because a full pool is a wait, not a failure.
    fn reserve(&self, request: &ReservationRequest) -> Result<ReservationOutcome>;

    /// Give capacity back. Idempotent: releasing a released reservation is not
    /// an error, so a retried reconcile cannot fail on its own earlier success.
    fn release(&self, reservation: &ReservationRef) -> Result<()>;
}
