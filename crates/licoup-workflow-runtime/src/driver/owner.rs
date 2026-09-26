//! Who owns a run, and why a second driver cannot take it.
//!
//! Two mechanisms, and both are visible rather than conventional:
//!
//! * **In this process**, [`RunOwnership`] hands out exactly one [`OwnedRun`]
//!   per run. A second `acquire` is refused with the holder's identity, so a
//!   re-entrant `Driver::drive` call from inside an adapter — or a second host
//!   thread — is a typed refusal and never a silent interleave. The guard is a
//!   *ticket*, not a mutex guard: the registry lock is held for the map
//!   operation that takes or returns the run, and nothing else. No adapter call
//!   and no store call ever runs under it, which is also why an adapter that
//!   tries to drive again gets an answer instead of deadlocking.
//! * **Across processes**, every ownership carries a generation, and the string
//!   the holder presents to the durable store is `owner#generation`
//!   ([`OwnedRun::claimant`]). `StatePort::claim_next` and
//!   `StatePort::renew_lease` take that claimant, so the durable claim is fenced
//!   by the same identity the in-process registry hands out: a late host's
//!   `renew_lease` fails because the claimant it presents is not the claimant
//!   that took the claim. [`RunOwnership::is_current`] is the same check for a
//!   host that wants to ask before it acts.
//!
//! Generations are never reissued for a run, so a fence that has been released
//! cannot come back into force; and a guard that has been superseded cannot
//! release its successor's ownership.

use std::collections::BTreeMap;
use std::fmt::{Display, Formatter};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// Stable identity of a driver.
///
/// An identity, not a thread id or a handle: two runs of the same owner name in
/// two processes are still two owners, and the generation is what separates
/// them.
#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct OwnerId(String);

impl OwnerId {
    pub fn new(owner: impl Into<String>) -> Self {
        Self(owner.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Display for OwnerId {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// The fence one ownership holds.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnerFence {
    owner: OwnerId,
    generation: u64,
}

impl OwnerFence {
    pub fn owner(&self) -> &OwnerId {
        &self.owner
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// The string this owner presents wherever a claimant is required.
    ///
    /// It names the exact ownership, so a store comparing claimants separates
    /// two successive owners of one run, and not just two names.
    pub fn claimant(&self) -> String {
        format!("{}#{}", self.owner.0, self.generation)
    }
}

/// Why a run could not be taken.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OwnershipRefusal {
    run_id: String,
    holder: OwnerId,
    generation: u64,
}

impl OwnershipRefusal {
    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    /// The owner that holds the run, so a refused caller has something to act on.
    pub fn holder(&self) -> &OwnerId {
        &self.holder
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
}

impl Display for OwnershipRefusal {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "run_already_owned: {} is held by {}#{}",
            self.run_id, self.holder, self.generation
        )
    }
}

impl std::error::Error for OwnershipRefusal {}

#[derive(Clone, Debug, Default)]
struct Slot {
    holder: Option<OwnerId>,
    /// The last generation issued for this run. Kept when the run is released so
    /// the next owner gets a strictly newer one.
    generation: u64,
}

/// The single-owner registry for runs.
#[derive(Debug, Default)]
pub struct RunOwnership {
    runs: Mutex<BTreeMap<String, Slot>>,
}

impl RunOwnership {
    pub fn new() -> Self {
        Self::default()
    }

    /// Take a run, or refuse because someone else holds it.
    pub fn acquire(
        self: &Arc<Self>,
        run_id: &str,
        owner: &OwnerId,
    ) -> Result<OwnedRun, OwnershipRefusal> {
        let mut runs = self.lock();
        let slot = runs.entry(run_id.to_owned()).or_default();
        if let Some(holder) = slot.holder.clone() {
            return Err(OwnershipRefusal {
                run_id: run_id.to_owned(),
                holder,
                generation: slot.generation,
            });
        }
        slot.generation = slot.generation.saturating_add(1);
        slot.holder = Some(owner.clone());
        let fence = OwnerFence {
            owner: owner.clone(),
            generation: slot.generation,
        };
        drop(runs);
        Ok(OwnedRun {
            run_id: run_id.to_owned(),
            fence,
            registry: Arc::clone(self),
            released: false,
        })
    }

    /// Who holds this run right now, if anyone.
    pub fn holder(&self, run_id: &str) -> Option<OwnerId> {
        self.lock().get(run_id)?.holder.clone()
    }

    /// The newest generation issued for this run.
    pub fn generation(&self, run_id: &str) -> Option<u64> {
        self.lock().get(run_id).map(|slot| slot.generation)
    }

    /// Whether a fence still corresponds to the run's current ownership.
    ///
    /// `false` means the fence is stale: either it was released, or a newer
    /// owner has taken the run. A caller that decided something from a stale
    /// fence must not have that decision applied.
    pub fn is_current(&self, run_id: &str, fence: &OwnerFence) -> bool {
        self.lock().get(run_id).is_some_and(|slot| {
            slot.generation == fence.generation && slot.holder.as_ref() == Some(&fence.owner)
        })
    }

    /// The runs currently held, for observability.
    pub fn held_runs(&self) -> Vec<String> {
        self.lock()
            .iter()
            .filter(|(_, slot)| slot.holder.is_some())
            .map(|(run_id, _)| run_id.clone())
            .collect()
    }

    /// Return a run to the registry, but only if this fence still holds it.
    fn release(&self, run_id: &str, fence: &OwnerFence) {
        let mut runs = self.lock();
        let Some(slot) = runs.get_mut(run_id) else {
            return;
        };
        if slot.generation == fence.generation && slot.holder.as_ref() == Some(&fence.owner) {
            slot.holder = None;
        }
    }

    /// The registry's own lock, held for map operations only.
    ///
    /// Poisoning is absorbed rather than propagated: a holder that panicked
    /// while driving left a map of names and counters, and refusing every future
    /// ownership because of that would take the run down with it. The invariant
    /// this lock protects — one holder per run — is re-established by the very
    /// next `acquire`.
    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, Slot>> {
        self.runs.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

/// The right to drive one run while this guard lives.
///
/// Dropping it releases the run; the registry lock is taken in `Drop` for the
/// same map operation as everywhere else, and no callback runs under it.
#[derive(Debug)]
pub struct OwnedRun {
    run_id: String,
    fence: OwnerFence,
    registry: Arc<RunOwnership>,
    released: bool,
}

impl OwnedRun {
    pub fn run_id(&self) -> &str {
        &self.run_id
    }

    pub fn fence(&self) -> &OwnerFence {
        &self.fence
    }

    /// The claimant this ownership presents to the durable store.
    pub fn claimant(&self) -> String {
        self.fence.claimant()
    }

    /// Release the run now instead of at the end of the enclosing scope.
    pub fn release(&mut self) {
        if self.released {
            return;
        }
        self.registry.release(&self.run_id, &self.fence);
        self.released = true;
    }
}

impl Drop for OwnedRun {
    fn drop(&mut self) {
        self.release();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn registry() -> Arc<RunOwnership> {
        Arc::new(RunOwnership::new())
    }

    #[test]
    fn one_owner_per_run_and_the_holder_is_named() {
        let ownership = registry();
        let first = ownership
            .acquire("run-1", &OwnerId::new("host-a"))
            .expect("first owner");
        let refusal = ownership
            .acquire("run-1", &OwnerId::new("host-b"))
            .expect_err("second owner must be refused");
        assert_eq!(refusal.holder().as_str(), "host-a");
        assert_eq!(
            ownership.holder("run-1").as_ref(),
            Some(&OwnerId::new("host-a"))
        );
        assert!(ownership.is_current("run-1", first.fence()));
        drop(first);
        assert!(ownership.holder("run-1").is_none());
        assert!(!ownership.is_current("run-1", &fence_of("host-a", 1)));
    }

    #[test]
    fn generations_are_never_reissued() {
        let ownership = registry();
        let first = ownership
            .acquire("run-1", &OwnerId::new("host-a"))
            .expect("first owner");
        assert_eq!(first.fence().generation(), 1);
        drop(first);
        let second = ownership
            .acquire("run-1", &OwnerId::new("host-a"))
            .expect("second owner");
        assert_eq!(second.fence().generation(), 2);
        assert_ne!(second.claimant(), fence_of("host-a", 1).claimant());
        assert!(!ownership.is_current("run-1", &fence_of("host-a", 1)));
    }

    #[test]
    fn a_superseded_fence_cannot_release_its_successor() {
        let ownership = registry();
        let mut first = ownership
            .acquire("run-1", &OwnerId::new("host-a"))
            .expect("first owner");
        first.release();
        let _second = ownership
            .acquire("run-1", &OwnerId::new("host-a"))
            .expect("second owner");
        // The stale guard's Drop must not return the successor's run.
        drop(first);
        assert_eq!(ownership.holder("run-1"), Some(OwnerId::new("host-a")));
        assert_eq!(ownership.generation("run-1"), Some(2));
    }

    fn fence_of(owner: &str, generation: u64) -> OwnerFence {
        OwnerFence {
            owner: OwnerId::new(owner),
            generation,
        }
    }
}
