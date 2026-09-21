//! The admission fixture: an authority owner, a resource owner, and a scope
//! barrier owner in one process, with no database.
//!
//! It is deliberately strict, because the properties these tests are about are
//! ordering properties that a permissive fixture would hide:
//!
//! * **Authority is resolved, never supplied.** `active_authorization` answers
//!   from a map the test fills through `grant`/`revoke`, and `recheck` compares
//!   the caller's expectation against that same map. Every recheck is recorded,
//!   so a test can assert the boundary asked before it admitted.
//! * **A barrier and its recipients are one write.** `publish` opens exactly one
//!   transaction and journals both facts under that transaction id; a test reads
//!   the journal back and fails if the two are not in the same one. Publishing
//!   also records a violation when asked to freeze a visit that is not in
//!   flight, so a freeze of something imaginary is visible instead of stored.
//! * **Resources answer with state, not a boolean.** Observations and
//!   reservations are recorded, so a test can assert that a step which should
//!   never have run did not run — for example that an effect refused by a
//!   barrier never reached the resource owner at all.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use anyhow::{Result, anyhow};

use licoup_workflow_runtime::admission::{
    AdmissionBarrier, AdmissionDecision, AdmissionGate, AdmissionReceipt, AdmissionRefusal,
    AuthoritySource, BarrierKind, BarrierRequest, BarrierScope, ReservationDenial,
    ReservationOutcome, ReservationRef, ReservationRequest, ResourcePort, ResourceRequest,
    ResourceState, ResourceWaiting, ScopeBarrierPort, VerifiedCaller,
};
use licoup_workflow_runtime::node::NodeVisitKey;
use licoup_workflow_runtime::ports::{AuthorityPort, AuthorityRecheck, AuthorizationRef};

/// The run every test admits into.
pub const RUN: &str = "run-1";
/// The definition revision every test decides against.
pub const REVISION: &str = "revision-1";
/// The grant in force for [`REVISION`] until a test revokes it.
pub const GRANT: &str = "grant-1";
/// The semantics the grant was issued against.
pub const SEMANTICS: &str = "semantics-1";

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn reference(authorization_digest: &str) -> AuthorizationRef {
    AuthorizationRef {
        authorization_digest: authorization_digest.to_owned(),
        semantics_digest: SEMANTICS.to_owned(),
    }
}

/// The authority owner: one active grant per revision, and one revision per run.
#[derive(Debug, Default)]
pub struct AuthorityOwner {
    grants: Mutex<BTreeMap<String, AuthorizationRef>>,
    runs: Mutex<BTreeMap<String, String>>,
    rechecks: Mutex<Vec<AuthorityRecheck>>,
}

impl AuthorityOwner {
    /// An owner with a granted run, which is what most tests start from.
    pub fn granted() -> Arc<Self> {
        let owner = Arc::new(Self::default());
        owner.grant(REVISION, GRANT);
        owner.bind_run(RUN, REVISION);
        owner
    }

    /// An owner with no grant for anything.
    pub fn empty() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn grant(&self, revision_digest: &str, authorization_digest: &str) {
        lock(&self.grants).insert(revision_digest.to_owned(), reference(authorization_digest));
    }

    pub fn revoke(&self, revision_digest: &str) {
        lock(&self.grants).remove(revision_digest);
    }

    pub fn bind_run(&self, run_id: &str, revision_digest: &str) {
        lock(&self.runs).insert(run_id.to_owned(), revision_digest.to_owned());
    }

    /// The expectations the boundary rechecked, in order.
    pub fn rechecks(&self) -> Vec<AuthorityRecheck> {
        lock(&self.rechecks).clone()
    }
}

impl AuthorityPort for AuthorityOwner {
    fn active_authorization(&self, revision_digest: &str) -> Result<Option<AuthorizationRef>> {
        Ok(lock(&self.grants).get(revision_digest).cloned())
    }

    fn recheck(&self, request: &AuthorityRecheck) -> Result<bool> {
        lock(&self.rechecks).push(request.clone());
        let revision = lock(&self.runs).get(&request.run_id).cloned();
        let Some(revision) = revision else {
            return Ok(false);
        };
        Ok(lock(&self.grants).get(&revision).is_some_and(|grant| {
            grant.authorization_digest == request.expected_authorization_digest
                && grant.semantics_digest == request.expected_semantics_digest
        }))
    }
}

/// The resource owner: state per resource, and reservations by effect id.
///
/// It behaves like a real owner in the two ways the boundary depends on:
///
/// * a reservation is per effect id, so a retried admission reuses the one
///   already held instead of booking twice;
/// * it enforces its own cap when asked to reserve. The observation before the
///   reservation is a courtesy, not the boundary, and an effect that no longer
///   fits is answered with a wait — never with a failure.
#[derive(Debug, Default)]
pub struct ResourceOwner {
    states: Mutex<BTreeMap<String, ResourceState>>,
    observations: Mutex<Vec<ResourceRequest>>,
    reservations: Mutex<BTreeMap<String, ReservationRef>>,
    releases: Mutex<usize>,
    budget_configured: Mutex<bool>,
    /// When set, every reservation answers with this denial, as a contended
    /// writer or a rate-limited upstream would.
    denial: Mutex<Option<ReservationDenial>>,
}

impl ResourceOwner {
    /// An owner with one resource, four slots, none in use, and no budget
    /// configured: the deployment the plan says must not acquire a gate.
    pub fn new() -> Arc<Self> {
        let owner = Arc::new(Self::default());
        owner.state(ResourceState {
            resource_id: "workers".to_owned(),
            available: true,
            active: 0,
            capacity: 4,
            revision: 7,
        });
        owner
    }

    pub fn state(&self, state: ResourceState) {
        lock(&self.states).insert(state.resource_id.clone(), state);
    }

    pub fn configure_budget(&self, configured: bool) {
        *lock(&self.budget_configured) = configured;
    }

    /// Make the owner answer every reservation with this denial, as a contended
    /// single writer or a rate-limited upstream would.
    pub fn deny_reservations(&self, denial: Option<ReservationDenial>) {
        *lock(&self.denial) = denial;
    }

    pub fn observations(&self) -> Vec<ResourceRequest> {
        lock(&self.observations).clone()
    }

    pub fn reservations(&self) -> Vec<ReservationRef> {
        lock(&self.reservations).values().cloned().collect()
    }

    pub fn releases(&self) -> usize {
        *lock(&self.releases)
    }

    /// The slots this owner has promised, which is what its own cap counts
    /// against.
    fn held_slots(&self, resource_id: &str) -> u32 {
        lock(&self.reservations)
            .values()
            .filter(|reservation| reservation.resource_id == resource_id)
            .map(|reservation| reservation.slots)
            .sum()
    }
}

impl ResourcePort for ResourceOwner {
    fn observe(&self, request: &ResourceRequest) -> Result<ResourceState> {
        lock(&self.observations).push(request.clone());
        let mut state = lock(&self.states)
            .get(&request.resource_id)
            .cloned()
            .ok_or_else(|| anyhow!("resource_unknown: {}", request.resource_id))?;
        // The owner reports what it has promised as in use: an observation that
        // ignored its own holds would let a second effect read free capacity
        // that is already spoken for.
        state.active += self.held_slots(&request.resource_id);
        Ok(state)
    }

    fn reserve(&self, request: &ReservationRequest) -> Result<ReservationOutcome> {
        if !*lock(&self.budget_configured) {
            return Ok(ReservationOutcome::NotConfigured);
        }
        let mut reservations = lock(&self.reservations);
        if let Some(existing) = reservations.get(&request.effect_id) {
            return Ok(ReservationOutcome::Reserved(ReservationRef {
                reused: true,
                ..existing.clone()
            }));
        }
        let state = lock(&self.states)
            .get(&request.resource_id)
            .cloned()
            .ok_or_else(|| anyhow!("resource_unknown: {}", request.resource_id))?;
        let held = reservations
            .values()
            .filter(|reservation| reservation.resource_id == request.resource_id)
            .map(|reservation| reservation.slots)
            .sum::<u32>();
        let free = state.capacity.saturating_sub(state.active + held);
        if let Some(denial) = *lock(&self.denial) {
            return Ok(ReservationOutcome::Waiting(ResourceWaiting {
                resource_id: request.resource_id.clone(),
                effect_id: request.effect_id.clone(),
                denial,
                available_slots: Some(free),
            }));
        }
        if !state.available || free < request.slots {
            return Ok(ReservationOutcome::Waiting(ResourceWaiting {
                resource_id: request.resource_id.clone(),
                effect_id: request.effect_id.clone(),
                denial: ReservationDenial::Exhausted,
                available_slots: Some(free),
            }));
        }
        let reservation = ReservationRef {
            reservation_id: format!("reservation-{}", reservations.len() + 1),
            effect_id: request.effect_id.clone(),
            resource_id: request.resource_id.clone(),
            slots: request.slots,
            revision: reservations.len() as u64 + 1,
            reused: false,
        };
        reservations.insert(request.effect_id.clone(), reservation.clone());
        Ok(ReservationOutcome::Reserved(reservation))
    }

    fn release(&self, reservation: &ReservationRef) -> Result<()> {
        *lock(&self.releases) += 1;
        let mut reservations = lock(&self.reservations);
        // Releasing the reservation this ref names is idempotent: a second
        // release finds it gone and changes nothing.
        if reservations
            .get(&reservation.effect_id)
            .is_some_and(|held| held.reservation_id == reservation.reservation_id)
        {
            reservations.remove(&reservation.effect_id);
        }
        Ok(())
    }
}

/// What one barrier transaction wrote.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum JournalEntry {
    /// The barrier itself, in transaction `transaction`.
    Barrier {
        transaction: u64,
        scope: BarrierScope,
    },
    /// One frozen recipient, in transaction `transaction`.
    Recipient {
        transaction: u64,
        visit: NodeVisitKey,
    },
}

/// The scope barrier owner, with the journal that makes "one write" checkable.
#[derive(Debug, Default)]
pub struct BarrierOwner {
    inner: Mutex<BarrierStore>,
}

#[derive(Debug, Default)]
struct BarrierStore {
    live: BTreeSet<NodeVisitKey>,
    barriers: BTreeMap<BarrierScope, AdmissionBarrier>,
    journal: Vec<JournalEntry>,
    transactions: u64,
    violations: Vec<String>,
}

impl BarrierOwner {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Declare a visit to be in flight, as a driver's ledger would.
    pub fn live(&self, visit: NodeVisitKey) {
        lock(&self.inner).live.insert(visit);
    }

    pub fn live_visits(&self) -> BTreeSet<NodeVisitKey> {
        lock(&self.inner).live.clone()
    }

    pub fn journal(&self) -> Vec<JournalEntry> {
        lock(&self.inner).journal.clone()
    }

    pub fn transactions(&self) -> u64 {
        lock(&self.inner).transactions
    }

    pub fn violations(&self) -> Vec<String> {
        lock(&self.inner).violations.clone()
    }

    /// The transactions that wrote a barrier and the recipients of that
    /// barrier. One entry means the two facts share a write.
    pub fn barrier_transactions(&self) -> Vec<(u64, BarrierScope, usize)> {
        let store = lock(&self.inner);
        let mut per_transaction: BTreeMap<u64, (BarrierScope, usize)> = BTreeMap::new();
        for entry in &store.journal {
            match entry {
                JournalEntry::Barrier { transaction, scope } => {
                    per_transaction.insert(*transaction, (scope.clone(), 0));
                }
                JournalEntry::Recipient { transaction, .. } => {
                    if let Some((_, count)) = per_transaction.get_mut(transaction) {
                        *count += 1;
                    }
                }
            }
        }
        per_transaction
            .into_iter()
            .map(|(transaction, (scope, count))| (transaction, scope, count))
            .collect()
    }
}

impl ScopeBarrierPort for BarrierOwner {
    fn publish(&self, request: &BarrierRequest) -> Result<AdmissionBarrier> {
        let mut store = lock(&self.inner);
        // A stop is monotonic: a later pause does not clear it.
        if let Some(existing) = store.barriers.get(&request.scope)
            && existing.kind == BarrierKind::Stop
            && request.kind == BarrierKind::Pause
        {
            return Ok(existing.clone());
        }
        for visit in &request.recipients {
            if !store.live.contains(visit) {
                store.violations.push(format!(
                    "barrier_froze_a_visit_that_is_not_in_flight: {visit}"
                ));
            }
        }
        store.transactions += 1;
        let transaction = store.transactions;
        let barrier = AdmissionBarrier {
            scope: request.scope.clone(),
            kind: request.kind,
            reason: request.reason.clone(),
            recipients: request.recipients.clone(),
            written_at: transaction,
        };
        store.journal.push(JournalEntry::Barrier {
            transaction,
            scope: request.scope.clone(),
        });
        for visit in &request.recipients {
            store.journal.push(JournalEntry::Recipient {
                transaction,
                visit: visit.clone(),
            });
        }
        store
            .barriers
            .insert(request.scope.clone(), barrier.clone());
        Ok(barrier)
    }

    fn barrier(&self, scope: &BarrierScope) -> Result<Option<AdmissionBarrier>> {
        Ok(lock(&self.inner).barriers.get(scope).cloned())
    }
}

/// A caller a trusted surface proved. The fixture names one so tests do not
/// repeat the source, not because a source is something a test may choose
/// freely.
pub fn caller(principal: &str) -> VerifiedCaller {
    VerifiedCaller::from_verified_source(principal, AuthoritySource::ResolvedSession)
        .expect("the fixture's principal is a valid identifier")
}

/// A visit at its first entry.
pub fn visit(state_id: &str) -> NodeVisitKey {
    NodeVisitKey::new(state_id, 1)
}

/// The gate over the fixture owners.
pub fn gate(
    authority: Arc<AuthorityOwner>,
    resources: Arc<ResourceOwner>,
    barriers: Arc<BarrierOwner>,
) -> AdmissionGate {
    AdmissionGate::new(authority, resources, barriers)
}

/// An effect that must be admitted, or the test says why not.
pub fn admitted(decision: AdmissionDecision) -> AdmissionReceipt {
    match decision {
        AdmissionDecision::Admitted(receipt) => *receipt,
        AdmissionDecision::Refused(refusal) => panic!("expected an admission, got {refusal:?}"),
    }
}

/// A refusal, asserted to be exactly one.
pub fn refused(decision: AdmissionDecision) -> AdmissionRefusal {
    match decision {
        AdmissionDecision::Refused(refusal) => refusal,
        AdmissionDecision::Admitted(receipt) => {
            panic!("expected a refusal, got an admission: {receipt:?}")
        }
    }
}
