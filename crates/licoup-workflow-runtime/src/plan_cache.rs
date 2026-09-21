//! Versioned, immutable, byte-bounded plan reuse with single-flight lowering.
//!
//! The cache answers one question: given the identity of a plan, what is the
//! lowered plan — lowering it at most once at a time, and never growing without
//! bound. What an entry *retains* is the definition plus the binding identity;
//! the lowered form is an index over that definition, so it can be dropped at
//! any moment and rebuilt under the same identity. Nothing here writes a
//! compiled plan anywhere: the durable form a store keeps is the definition and
//! the key, which is why an eviction costs work and never costs identity.
//!
//! Two rules make the cache safe to share between hosts and runs:
//!
//! * A key carries the full semantics identity, so an entry lowered for one
//!   semantics configuration is never served for another. Before an entry is
//!   admitted, the lowered definition is digested and checked against the key's
//!   revision, so a plan cannot be filed under a key it does not match.
//! * A key this profile cannot lower is refused by name rather than lowered
//!   approximately, and a run bound to semantics this host does not execute is
//!   handed off rather than advanced.

use std::collections::BTreeMap;
use std::fmt::{Display, Formatter};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use licoup_workflow::WorkflowValidationFailure;
use licoup_workflow::compile::{
    CompiledWorkflow, CompilerSemantics, InterpreterProfile, LoweringRefusal, PlanKey,
    PlanMismatch, RetainedPlan,
};

/// Longest message a lowering failure carries into the cache.
const MAX_MESSAGE_LENGTH: usize = 256;

/// Why a lowering attempt produced no lowered plan.
///
/// The message is a short code-shaped string: the pure compiler's own `Display`
/// prints the first diagnostic code and never the definition content, so this
/// value is safe to log, to return, and to hand to another waiting caller.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PlanCompileError {
    message: String,
}

impl PlanCompileError {
    pub fn new(message: impl Into<String>) -> Self {
        let message = message.into();
        let message = match message.char_indices().nth(MAX_MESSAGE_LENGTH) {
            Some((index, _)) => message[..index].to_owned(),
            None => message,
        };
        Self { message }
    }

    /// Render the pure compiler's failure for the cache.
    pub fn from_failure(failure: &WorkflowValidationFailure) -> Self {
        Self::new(failure.to_string())
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl Display for PlanCompileError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for PlanCompileError {}

/// Why the cache returned no plan.
#[derive(Debug)]
pub enum PlanCacheError {
    /// This host cannot lower a plan for the key.
    NotLowerable {
        key: PlanKey,
        refusal: LoweringRefusal,
    },
    /// The lowering attempt failed.
    LoweringFailed {
        key: PlanKey,
        failure: PlanCompileError,
    },
    /// The lowered plan is not the plan the key describes.
    KeyMismatch {
        key: PlanKey,
        mismatch: PlanMismatch,
    },
    /// The lowering attempt unwound before publishing a plan. Its waiters were
    /// released with this error instead of blocking on an abandoned flight.
    Abandoned { key: PlanKey },
}

impl Display for PlanCacheError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotLowerable { key, refusal } => write!(
                formatter,
                "plan_not_lowerable: {} {refusal}",
                key.binding_digest()
            ),
            Self::LoweringFailed { key, failure } => write!(
                formatter,
                "plan_lowering_failed: {} {failure}",
                key.binding_digest()
            ),
            Self::KeyMismatch { key, mismatch } => write!(
                formatter,
                "plan_key_mismatch: {} {mismatch}",
                key.binding_digest()
            ),
            Self::Abandoned { key } => {
                write!(
                    formatter,
                    "plan_lowering_abandoned: {}",
                    key.binding_digest()
                )
            }
        }
    }
}

impl std::error::Error for PlanCacheError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::LoweringFailed { failure, .. } => Some(failure),
            Self::KeyMismatch { mismatch, .. } => Some(mismatch),
            _ => None,
        }
    }
}

/// What the cache has done so far.
///
/// Eviction is deterministic, and it is counted here because a caller that sees
/// a plan gone needs to tell "evicted to stay under the bound" from "never
/// compiled": the first is routine, the second is a wiring bug.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CacheStats {
    /// Lowering attempts this cache performed. An attempt that failed or was
    /// abandoned counts: it really did run.
    pub compilations: u64,
    /// Callers that waited for another caller's lowering of the same key.
    pub single_flight_waits: u64,
    /// Callers served a plan without lowering: from a retained entry, or from a
    /// flight that finished while they waited on it.
    pub reuses: u64,
    /// Entries retained.
    pub admissions: u64,
    /// Entries dropped to stay under the byte bound.
    pub evictions: u64,
    /// Retained bytes dropped by eviction.
    pub evicted_bytes: u64,
    /// Lowered plans never retained: one plan alone exceeded the whole bound.
    pub oversized: u64,
    /// Retained bytes right now.
    pub retained_bytes: usize,
    /// Entries retained right now. Filled when the snapshot is taken.
    pub entries: usize,
}

/// A versioned, immutable, byte-bounded cache of lowered plans.
///
/// One cache serves one interpreter profile. Every entry is keyed by the full
/// plan identity, holds an immutable lowered plan behind an `Arc`, and is
/// charged the bytes of its retained form — the definition and the key — so the
/// bound limits exactly the bytes that survive an eviction.
pub struct PlanCache {
    profile: InterpreterProfile,
    byte_limit: usize,
    inner: Mutex<Inner>,
    ready: Condvar,
}

#[derive(Default)]
struct Inner {
    entries: BTreeMap<PlanKey, Entry>,
    flights: BTreeMap<PlanKey, Flight>,
    clock: u64,
    stats: CacheStats,
}

#[derive(Clone)]
struct Entry {
    plan: Arc<CompiledWorkflow>,
    retained_bytes: usize,
    last_touch: u64,
}

struct Flight {
    outcome: Option<Result<Arc<CompiledWorkflow>, FlightFailure>>,
    waiters: u32,
}

/// A failure carried from the lowering caller to its waiters. Every variant is
/// cloneable, because one outcome is reported to every caller that waited.
#[derive(Clone)]
enum FlightFailure {
    Lowering(PlanCompileError),
    Mismatch(PlanMismatch),
    Abandoned,
}

impl FlightFailure {
    fn into_error(self, key: &PlanKey) -> PlanCacheError {
        match self {
            Self::Lowering(failure) => PlanCacheError::LoweringFailed {
                key: key.clone(),
                failure,
            },
            Self::Mismatch(mismatch) => PlanCacheError::KeyMismatch {
                key: key.clone(),
                mismatch,
            },
            Self::Abandoned => PlanCacheError::Abandoned { key: key.clone() },
        }
    }
}

/// What one caller found when it looked for a flight.
enum FlightState {
    /// No flight for this key: this caller lowers.
    Lower,
    /// Another caller is lowering: wait for its outcome.
    Wait,
    /// The flight finished.
    Finished(Result<Arc<CompiledWorkflow>, FlightFailure>),
}

impl PlanCache {
    /// A cache for one interpreter profile, retaining at most `byte_limit` of
    /// definitions and binding identities.
    pub fn new(profile: InterpreterProfile, byte_limit: usize) -> Self {
        Self {
            profile,
            byte_limit,
            inner: Mutex::new(Inner::default()),
            ready: Condvar::new(),
        }
    }

    pub fn profile(&self) -> &InterpreterProfile {
        &self.profile
    }

    pub fn byte_limit(&self) -> usize {
        self.byte_limit
    }

    /// The lowered plan for `key`, lowered by `lower` if it is not retained.
    ///
    /// Concurrent callers asking for the same key compile once: the first one
    /// lowers, the others wait for its outcome and are served from it. Callers
    /// asking for different keys never block each other, because lowering runs
    /// outside the cache lock.
    pub fn plan(
        &self,
        key: &PlanKey,
        lower: impl FnOnce() -> Result<Arc<CompiledWorkflow>, PlanCompileError>,
    ) -> Result<Arc<CompiledWorkflow>, PlanCacheError> {
        self.profile
            .lowerable(key)
            .map_err(|refusal| PlanCacheError::NotLowerable {
                key: key.clone(),
                refusal,
            })?;
        // The cache lowers with the one compiler this binary contains, so a key
        // bound to compiler semantics this build does not implement has no
        // lowering here — even when the profile merely declares it. Refusing by
        // name keeps a foreign key from being filed under an index that a
        // different lowering produced.
        if key.compiler_semantics() != CompilerSemantics::CURRENT {
            return Err(PlanCacheError::NotLowerable {
                key: key.clone(),
                refusal: LoweringRefusal::CompilerSemantics {
                    build: CompilerSemantics::CURRENT,
                    bound: key.compiler_semantics(),
                },
            });
        }
        let mut inner = self.lock();
        let mut registered = false;
        loop {
            if let Some(plan) = reuse_entry(&mut inner, key) {
                if registered {
                    end_wait(&mut inner, key);
                }
                inner.stats.reuses += 1;
                return Ok(plan);
            }
            match flight_state(&inner, key) {
                FlightState::Lower => {
                    debug_assert!(!registered, "a lowering caller holds no wait");
                    inner.flights.insert(
                        key.clone(),
                        Flight {
                            outcome: None,
                            waiters: 0,
                        },
                    );
                    break;
                }
                FlightState::Wait => {
                    if !registered {
                        if let Some(flight) = inner.flights.get_mut(key) {
                            flight.waiters += 1;
                        }
                        registered = true;
                        inner.stats.single_flight_waits += 1;
                    }
                    inner = self.wait(inner);
                }
                FlightState::Finished(outcome) => {
                    if registered {
                        // The last reader drops the record, so the key can be
                        // lowered again once its waiters have the outcome.
                        end_wait(&mut inner, key);
                    } else if inner
                        .flights
                        .get(key)
                        .is_some_and(|flight| flight.waiters == 0)
                    {
                        // Nobody is waiting for this outcome, so a caller that
                        // arrived after the flight finished starts fresh instead
                        // of inheriting a result nobody else needs.
                        inner.flights.remove(key);
                        continue;
                    }
                    if outcome.is_ok() {
                        inner.stats.reuses += 1;
                    }
                    return outcome.map_err(|failure| failure.into_error(key));
                }
            }
        }
        // This caller owns the flight. The guard publishes an abandonment
        // outcome if the lowering unwinds, so a panicking lowering cannot leave
        // its waiters blocked on a flight nobody will ever finish.
        let mut publish = FlightPublish {
            cache: self,
            key,
            armed: true,
        };
        inner.stats.compilations += 1;
        drop(inner);
        // Everything measured over the definition happens outside the lock: a
        // caller lowering one key never holds up a caller using another.
        let prepared = match lower() {
            Ok(plan) => match RetainedPlan::of(&plan, key.clone())
                .and_then(|retained| retained.retained_bytes())
            {
                Ok(retained_bytes) => Ok((plan, retained_bytes)),
                Err(mismatch) => Err(FlightFailure::Mismatch(mismatch)),
            },
            Err(failure) => Err(FlightFailure::Lowering(failure)),
        };
        let mut inner = self.lock();
        let outcome = match prepared {
            Ok((plan, retained_bytes)) => {
                self.retain(&mut inner, key, &plan, retained_bytes);
                Ok(plan)
            }
            Err(failure) => Err(failure),
        };
        // The outcome is published only to callers that are already waiting.
        // With no waiters there is nobody to hand it to, and keeping the record
        // would hold a second reference to a plan the byte bound may have
        // evicted, so the finished flight is dropped instead.
        let waited = inner
            .flights
            .get(key)
            .is_some_and(|flight| flight.waiters > 0);
        if waited {
            if let Some(flight) = inner.flights.get_mut(key) {
                flight.outcome = Some(outcome.clone());
            }
        } else {
            inner.flights.remove(key);
        }
        let result = outcome.map_err(|failure| failure.into_error(key));
        drop(inner);
        self.ready.notify_all();
        publish.armed = false;
        result
    }

    /// The retained bytes charged for one plan, if it is retained.
    pub fn retained_bytes(&self, key: &PlanKey) -> Option<usize> {
        self.lock()
            .entries
            .get(key)
            .map(|entry| entry.retained_bytes)
    }

    /// Drop one entry. The binding identity is derived from the key, not from
    /// the entry, so a later request lowers the same definition under the same
    /// identity.
    pub fn forget(&self, key: &PlanKey) -> bool {
        let mut inner = self.lock();
        match inner.entries.remove(key) {
            Some(entry) => {
                inner.stats.retained_bytes -= entry.retained_bytes;
                true
            }
            None => false,
        }
    }

    pub fn stats(&self) -> CacheStats {
        let inner = self.lock();
        CacheStats {
            entries: inner.entries.len(),
            ..inner.stats
        }
    }

    /// Retain a lowered plan that has already been proved to be its key's plan,
    /// evicting deterministically to stay under the bound.
    fn retain(
        &self,
        inner: &mut Inner,
        key: &PlanKey,
        plan: &Arc<CompiledWorkflow>,
        retained_bytes: usize,
    ) {
        if retained_bytes > self.byte_limit {
            inner.stats.oversized += 1;
            return;
        }
        inner.clock = inner.clock.wrapping_add(1);
        let entry = Entry {
            plan: plan.clone(),
            retained_bytes,
            last_touch: inner.clock,
        };
        if let Some(previous) = inner.entries.insert(key.clone(), entry) {
            inner.stats.retained_bytes -= previous.retained_bytes;
        }
        inner.stats.retained_bytes += retained_bytes;
        inner.stats.admissions += 1;
        while inner.stats.retained_bytes > self.byte_limit {
            // Deterministic: the least recently used entry, ties broken by key
            // order, so the same traffic always evicts the same entries. The
            // entry just admitted has the newest touch, so it is never its own
            // victim.
            let Some(victim) = inner
                .entries
                .iter()
                .map(|(key, entry)| (entry.last_touch, key))
                .min()
                .map(|(_, key)| key.clone())
            else {
                break;
            };
            if let Some(entry) = inner.entries.remove(&victim) {
                inner.stats.retained_bytes -= entry.retained_bytes;
                inner.stats.evictions += 1;
                inner.stats.evicted_bytes += entry.retained_bytes as u64;
            }
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        // The state behind the lock is only ever replaced wholesale, and a
        // panicking lowering is turned into an outcome by `FlightPublish`, so a
        // poisoned lock is recovered rather than propagated to every caller.
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn wait<'a>(&self, inner: MutexGuard<'a, Inner>) -> MutexGuard<'a, Inner> {
        self.ready
            .wait(inner)
            .unwrap_or_else(PoisonError::into_inner)
    }
}

/// Publishes an abandonment outcome if the lowering unwinds.
struct FlightPublish<'a> {
    cache: &'a PlanCache,
    key: &'a PlanKey,
    armed: bool,
}

impl Drop for FlightPublish<'_> {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let mut inner = self.cache.lock();
        // As in `plan`: an abandoned flight with no waiters has nobody to
        // release and nothing worth retaining.
        let waited = inner
            .flights
            .get(self.key)
            .is_some_and(|flight| flight.waiters > 0);
        if waited {
            if let Some(flight) = inner.flights.get_mut(self.key) {
                flight.outcome = Some(Err(FlightFailure::Abandoned));
            }
        } else {
            inner.flights.remove(self.key);
        }
        drop(inner);
        self.cache.ready.notify_all();
    }
}

/// Serve a retained entry and mark it as most recently used.
fn reuse_entry(inner: &mut Inner, key: &PlanKey) -> Option<Arc<CompiledWorkflow>> {
    inner.clock = inner.clock.wrapping_add(1);
    let clock = inner.clock;
    let entry = inner.entries.get_mut(key)?;
    entry.last_touch = clock;
    Some(entry.plan.clone())
}

fn flight_state(inner: &Inner, key: &PlanKey) -> FlightState {
    match inner.flights.get(key) {
        None => FlightState::Lower,
        Some(flight) => match &flight.outcome {
            None => FlightState::Wait,
            Some(outcome) => FlightState::Finished(outcome.clone()),
        },
    }
}

/// Stop waiting on a flight and drop its record once no waiter needs the
/// outcome. The record outlives every registered waiter, so no waiter can wake
/// to a flight that vanished while its outcome was still unread.
fn end_wait(inner: &mut Inner, key: &PlanKey) {
    let Some(flight) = inner.flights.get_mut(key) else {
        return;
    };
    flight.waiters = flight.waiters.saturating_sub(1);
    if flight.outcome.is_some() && flight.waiters == 0 {
        inner.flights.remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use licoup_workflow::compile::{
        CompilerSemantics, DefinitionRevision, EngineSemantics, HandoffReason,
        LoweringCapabilities, RunAdmission,
    };
    use licoup_workflow::{
        ActorSlot, GraphState, GraphStateKind, ReducerEvent, ReducerOutput, RetryPolicy,
        RunSnapshot, Transition, TransitionEvent, TransitionMode, WORKFLOW_SCHEMA_VERSION,
        WorkflowDefinition, WorkflowLimits, WorkflowMetadata, compile_workflow, reduce,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    fn state(id: &str, kind: GraphStateKind) -> GraphState {
        GraphState {
            id: id.into(),
            kind,
            label: id.into(),
            instruction: String::new(),
            binding: None,
            runtime: None,
            entry: None,
            workset: None,
            retry: RetryPolicy::default(),
        }
    }

    fn transition(id: &str, event: TransitionEvent) -> Transition {
        Transition {
            id: id.into(),
            from: "work".into(),
            to: if event == TransitionEvent::Success {
                "done".into()
            } else {
                "blocked".into()
            },
            event,
            mode: TransitionMode::Flow,
            guard: None,
        }
    }

    /// A valid definition whose size is tunable, so a byte bound can be set to
    /// a known number of entries.
    fn definition(padding: usize) -> WorkflowDefinition {
        let mut work = state("work", GraphStateKind::Actor);
        work.binding = Some("worker".into());
        WorkflowDefinition {
            schema: WORKFLOW_SCHEMA_VERSION.into(),
            metadata: WorkflowMetadata {
                id: "plan-cache-test".into(),
                name: "Plan cache test".into(),
                version: "1".into(),
                description: "p".repeat(padding),
            },
            limits: WorkflowLimits::default(),
            actor_slots: vec![ActorSlot::required_actor("worker", "Worker")],
            runtimes: Vec::new(),
            worksets: Vec::new(),
            initial: "work".into(),
            states: vec![
                work,
                state("done", GraphStateKind::Succeed),
                state("blocked", GraphStateKind::Fail),
            ],
            transitions: vec![
                transition("finished", TransitionEvent::Success),
                transition("failed", TransitionEvent::Failure),
            ],
        }
    }

    fn key(
        definition: &WorkflowDefinition,
        engine_semantics: EngineSemantics,
        capabilities: LoweringCapabilities,
    ) -> PlanKey {
        PlanKey::for_definition(
            definition,
            CompilerSemantics::CURRENT,
            engine_semantics,
            capabilities,
        )
        .expect("a synthetic key types")
    }

    fn lower(
        definition: &WorkflowDefinition,
    ) -> impl Fn() -> Result<Arc<CompiledWorkflow>, PlanCompileError> + '_ {
        move || {
            compile_workflow(definition.clone())
                .map(Arc::new)
                .map_err(|failure| PlanCompileError::from_failure(&failure))
        }
    }

    /// A cache holding exactly `entries` plans of this definition, plus the
    /// bytes one entry is charged.
    fn cache_holding(
        definition: &WorkflowDefinition,
        key: &PlanKey,
        entries: usize,
    ) -> (PlanCache, usize) {
        let plan = Arc::new(compile_workflow(definition.clone()).expect("the definition compiles"));
        let bytes = RetainedPlan::of(&plan, key.clone())
            .expect("the plan is the key's plan")
            .retained_bytes()
            .expect("the retained form encodes");
        let profile = InterpreterProfile::current(LoweringCapabilities::none());
        (PlanCache::new(profile, bytes * entries), bytes)
    }

    /// One deterministic reducer step on a plan. Two lowerings execute the same
    /// when they produce the same output, which is what reuse has to preserve:
    /// a cache may remember a lowering, never change what a run does.
    fn execute(plan: &CompiledWorkflow, run_id: &str) -> ReducerOutput {
        let empty = RunSnapshot::empty(run_id, "definition", "semantics");
        let input = empty.input.clone();
        reduce(plan, &empty, ReducerEvent::Start { input }).expect("the fixture run starts")
    }

    /// Wait until a second caller is registered on a flight. The registration
    /// happens under the cache lock, so this observes the wait instead of
    /// guessing at it with a fixed sleep.
    fn wait_for_waiter(cache: &PlanCache) {
        for _ in 0..5_000 {
            if cache.stats().single_flight_waits == 1 {
                return;
            }
            thread::sleep(Duration::from_millis(1));
        }
        panic!("the second caller never registered as a waiter");
    }

    #[test]
    fn concurrent_callers_of_one_key_lower_it_once() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, _) = cache_holding(&definition, &plan_key, 2);
        let compilations = AtomicUsize::new(0);
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let fresh = compile_workflow(definition.clone()).expect("the definition compiles");
        let expected = execute(&fresh, "run-equivalence");

        thread::scope(|scope| {
            let (cache_ref, key_ref, compilations_ref) = (&cache, &plan_key, &compilations);
            let definition_ref = &definition;
            let winner = scope.spawn(move || {
                cache_ref
                    .plan(key_ref, move || {
                        compilations_ref.fetch_add(1, Ordering::SeqCst);
                        started_tx.send(()).expect("the test is listening");
                        release_rx.recv().expect("the test releases the lowering");
                        lower(definition_ref)()
                    })
                    .expect("the first caller lowers the plan")
            });
            started_rx.recv().expect("the first caller is lowering");
            // The flight is registered and unfinished, so a second caller for
            // the same key must wait for it rather than lower its own copy.
            let loser = scope.spawn(move || {
                cache_ref
                    .plan(key_ref, move || {
                        compilations_ref.fetch_add(1, Ordering::SeqCst);
                        lower(definition_ref)()
                    })
                    .expect("the second caller is served the first caller's plan")
            });
            wait_for_waiter(&cache);
            assert_eq!(
                compilations.load(Ordering::SeqCst),
                1,
                "the waiting caller lowered nothing"
            );
            release_tx.send(()).expect("the lowering is released");
            let winner = winner.join().expect("the lowering caller finished");
            let loser = loser.join().expect("the waiting caller finished");
            assert!(
                Arc::ptr_eq(&winner, &loser),
                "the waiting caller got the lowering caller's plan"
            );
            // Reuse is execution equivalence: the shared plan runs exactly like
            // a freshly lowered one, which is what the single flight had to
            // preserve.
            assert_eq!(execute(&winner, "run-equivalence"), expected);
            assert_eq!(execute(&loser, "run-equivalence"), expected);
        });

        assert_eq!(compilations.load(Ordering::SeqCst), 1);
        let stats = cache.stats();
        assert_eq!(stats.compilations, 1);
        assert_eq!(stats.single_flight_waits, 1);
        assert_eq!(stats.reuses, 1, "the waiter reused the winner's outcome");
    }

    #[test]
    fn different_keys_lower_without_waiting_for_each_other() {
        let definition = definition(0);
        let blocked = key(
            &definition,
            EngineSemantics::version(0).expect("an earlier version is nameable"),
            LoweringCapabilities::none(),
        );
        let free = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, _) = cache_holding(&definition, &free, 2);
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();

        thread::scope(|scope| {
            let (cache_ref, blocked_ref) = (&cache, &blocked);
            let definition_ref = &definition;
            let held = scope.spawn(move || {
                cache_ref.plan(blocked_ref, move || {
                    started_tx.send(()).expect("the test is listening");
                    release_rx.recv().expect("the test releases the lowering");
                    lower(definition_ref)()
                })
            });
            started_rx.recv().expect("the first lowering started");

            // A second key lowers to completion while the first one is still
            // inside its lowering closure: a flight holds up only its own key.
            let (done_tx, done_rx) = mpsc::channel();
            let free_ref = &free;
            scope.spawn(move || {
                let lowered = cache_ref.plan(free_ref, lower(definition_ref)).is_ok();
                done_tx.send(lowered).expect("the test is listening");
            });
            assert!(
                done_rx
                    .recv_timeout(Duration::from_secs(5))
                    .expect("the other key lowers while the first is held"),
                "the other key lowered"
            );
            assert!(cache.retained_bytes(&free).is_some());

            release_tx.send(()).expect("the lowering is released");
            let _ = held.join().expect("the held lowering finished");
        });
        assert_eq!(cache.stats().compilations, 2);
        assert_eq!(cache.stats().entries, 2);
    }

    #[test]
    fn a_retained_entry_is_served_without_lowering_it_again() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, _) = cache_holding(&definition, &plan_key, 2);
        let first = cache
            .plan(&plan_key, lower(&definition))
            .expect("the plan lowers");
        let second = cache
            .plan(
                &plan_key,
                || -> Result<Arc<CompiledWorkflow>, PlanCompileError> {
                    panic!("a retained plan is never lowered a second time")
                },
            )
            .expect("the retained plan is served");
        assert!(Arc::ptr_eq(&first, &second), "the entry was not replaced");
        assert_eq!(cache.stats().compilations, 1);
        assert_eq!(cache.stats().reuses, 1);

        // The retained plan is the same lowering, proved by the run it produces.
        let fresh = compile_workflow(definition.clone()).expect("the definition compiles");
        assert_eq!(
            execute(&first, "run-equivalence"),
            execute(&fresh, "run-equivalence")
        );

        // An entry can also be dropped outright. The identity lives in the key,
        // not in the entry, so the same key comes back under the same identity.
        assert!(cache.forget(&plan_key));
        assert_eq!(cache.retained_bytes(&plan_key), None);
        assert_eq!(
            Arc::strong_count(&first),
            2,
            "the cache released its reference: only the two caller handles remain"
        );
        assert!(!cache.forget(&plan_key), "an entry is dropped once");
        let third = cache
            .plan(&plan_key, lower(&definition))
            .expect("the plan lowers again");
        assert_eq!(cache.stats().compilations, 2);
        assert!(!Arc::ptr_eq(&first, &third));
        assert_eq!(
            DefinitionRevision::of(third.definition()).expect("the plan digests"),
            *plan_key.definition_revision()
        );
    }

    #[test]
    fn the_byte_bound_evicts_the_least_recently_used_entry() {
        let bound = definition(0);
        let older = key(
            &bound,
            EngineSemantics::version(0).expect("an earlier version is nameable"),
            LoweringCapabilities::none(),
        );
        let newer = key(
            &bound,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, entry_bytes) = cache_holding(&bound, &older, 1);
        assert_eq!(entry_bytes, cache.byte_limit(), "one entry fits the bound");

        let first = cache
            .plan(&older, lower(&bound))
            .expect("the first plan lowers");
        assert_eq!(cache.retained_bytes(&older), Some(entry_bytes));
        assert_eq!(cache.stats().retained_bytes, entry_bytes);

        let second = cache
            .plan(&newer, lower(&bound))
            .expect("the second plan lowers");
        assert_eq!(
            RetainedPlan::of(&second, newer.clone())
                .expect("the second plan is its key's plan")
                .retained_bytes()
                .expect("the retained form encodes"),
            entry_bytes,
            "both keys are charged the same bytes"
        );
        assert_eq!(cache.stats().admissions, 2);
        assert_eq!(cache.stats().evictions, 1);
        assert_eq!(cache.stats().evicted_bytes, entry_bytes as u64);
        assert_eq!(cache.stats().retained_bytes, entry_bytes);
        assert_eq!(
            cache.retained_bytes(&older),
            None,
            "the least recently used entry is the one evicted"
        );
        assert_eq!(cache.retained_bytes(&newer), Some(entry_bytes));
        assert!(!Arc::ptr_eq(&first, &second));
        assert_eq!(
            Arc::strong_count(&first),
            1,
            "the evicted entry is released, not held by a finished flight"
        );

        // What was evicted is rebuilt under the identity it already had.
        let rebuilt = cache
            .plan(&older, lower(&bound))
            .expect("the evicted plan is lowered again");
        assert_eq!(cache.stats().compilations, 3);
        assert_eq!(cache.retained_bytes(&newer), None);
        assert_eq!(cache.retained_bytes(&older), Some(entry_bytes));
        assert_eq!(
            DefinitionRevision::of(rebuilt.definition()).expect("the rebuilt plan digests"),
            *older.definition_revision(),
            "the rebuild keeps the binding identity"
        );
    }

    #[test]
    fn a_plan_larger_than_the_whole_bound_is_served_but_never_retained() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let profile = InterpreterProfile::current(LoweringCapabilities::none());
        let cache = PlanCache::new(profile, 1);
        let first = cache
            .plan(&plan_key, lower(&definition))
            .expect("the plan lowers");
        assert_eq!(cache.retained_bytes(&plan_key), None);
        assert_eq!(cache.stats().retained_bytes, 0, "the bound holds");
        assert_eq!(cache.stats().oversized, 1);

        let second = cache
            .plan(&plan_key, lower(&definition))
            .expect("the plan lowers again");
        assert_eq!(
            cache.stats().compilations,
            2,
            "nothing retained means nothing reused"
        );
        assert!(!Arc::ptr_eq(&first, &second));
        assert_eq!(cache.stats().retained_bytes, 0);
    }

    #[test]
    fn a_different_engine_semantics_never_reuses_an_entry() {
        let definition = definition(0);
        let current = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let earlier = key(
            &definition,
            EngineSemantics::version(0).expect("an earlier version is nameable"),
            LoweringCapabilities::none(),
        );
        let (cache, _) = cache_holding(&definition, &current, 2);
        cache
            .plan(&current, lower(&definition))
            .expect("the current plan lowers");
        cache
            .plan(&earlier, lower(&definition))
            .expect("the earlier plan lowers");
        assert_eq!(cache.stats().compilations, 2);
        assert_eq!(cache.stats().reuses, 0, "no entry was shared");
        assert_ne!(current.binding_digest(), earlier.binding_digest());
        assert!(cache.retained_bytes(&current).is_some());
        assert!(cache.retained_bytes(&earlier).is_some());

        // Lowering an index is semantics-neutral, but advancing a run is not.
        assert_eq!(
            cache.profile().admit_run(&current),
            RunAdmission::Compatible
        );
        assert_eq!(
            cache.profile().admit_run(&earlier),
            RunAdmission::Handoff {
                reason: HandoffReason::EngineSemantics
            }
        );
    }

    #[test]
    fn a_key_this_profile_cannot_lower_is_refused_by_name() {
        let definition = definition(0);
        let earlier_compiler = PlanKey::for_definition(
            &definition,
            CompilerSemantics::version(0).expect("an earlier version is nameable"),
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        )
        .expect("the key types");
        let wants_capability = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::declare(["vendor.example/render"])
                .expect("the tag is namespaced"),
        );
        let profile = InterpreterProfile::current(LoweringCapabilities::none());
        let cache = PlanCache::new(profile, 1 << 20);

        let refusal = cache.plan(&earlier_compiler, || {
            panic!("semantics this profile does not lower are never lowered")
        });
        assert!(matches!(
            refusal,
            Err(PlanCacheError::NotLowerable {
                refusal: LoweringRefusal::CompilerSemantics { .. },
                ..
            })
        ));
        let refusal = cache.plan(&wants_capability, || {
            panic!("plans needing an undeclared capability are never lowered")
        });
        assert!(matches!(
            refusal,
            Err(PlanCacheError::NotLowerable {
                refusal: LoweringRefusal::MissingCapability { capability },
                ..
            }) if capability == "vendor.example/render"
        ));
        assert_eq!(cache.stats().compilations, 0);
        assert_eq!(cache.stats().entries, 0);
    }

    #[test]
    fn a_failed_lowering_is_retryable_and_leaves_nothing_retained() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, entry_bytes) = cache_holding(&definition, &plan_key, 1);

        let failure = cache
            .plan(&plan_key, || {
                Err(PlanCompileError::new(
                    "workflow_validation_failed: synthetic",
                ))
            })
            .expect_err("the lowering failed");
        assert!(matches!(failure, PlanCacheError::LoweringFailed { .. }));
        assert_eq!(cache.retained_bytes(&plan_key), None);
        assert_eq!(cache.stats().entries, 0);
        assert_eq!(cache.stats().retained_bytes, 0);

        // The failure belonged to one attempt, not to the key: the next caller
        // lowers the same key for real.
        let plan = cache
            .plan(&plan_key, lower(&definition))
            .expect("the retry lowers");
        assert_eq!(cache.stats().compilations, 2);
        assert_eq!(cache.retained_bytes(&plan_key), Some(entry_bytes));
        let fresh = compile_workflow(definition.clone()).expect("the definition compiles");
        assert_eq!(
            execute(&plan, "run-equivalence"),
            execute(&fresh, "run-equivalence")
        );
    }

    #[test]
    fn a_shared_failure_reaches_every_waiter_and_the_key_stays_retryable() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, entry_bytes) = cache_holding(&definition, &plan_key, 1);
        let (started_tx, started_rx) = mpsc::channel::<()>();
        let (release_tx, release_rx) = mpsc::channel::<()>();

        let (owner, waiter) = thread::scope(|scope| {
            let (cache_ref, key_ref) = (&cache, &plan_key);
            let owner = scope.spawn(move || {
                cache_ref.plan(key_ref, move || {
                    started_tx.send(()).expect("the test is listening");
                    release_rx.recv().expect("the test releases the lowering");
                    Err(PlanCompileError::new(
                        "workflow_validation_failed: synthetic",
                    ))
                })
            });
            started_rx.recv().expect("the owner is lowering");
            let waiter =
                scope.spawn(move || cache_ref.plan(key_ref, || panic!("the waiter never lowers")));
            wait_for_waiter(&cache);
            release_tx.send(()).expect("the lowering is released");
            (
                owner.join().expect("the owner finished"),
                waiter.join().expect("the waiter finished"),
            )
        });

        // One attempt, one outcome: the waiter is told what happened instead of
        // lowering a second copy.
        let owner = owner.expect_err("the lowering failed");
        let waiter = waiter.expect_err("the waiter was told");
        assert_eq!(owner.to_string(), waiter.to_string());
        assert!(matches!(owner, PlanCacheError::LoweringFailed { .. }));

        // The failure did not poison the key.
        let plan = cache
            .plan(&plan_key, lower(&definition))
            .expect("the retry lowers");
        assert_eq!(cache.stats().compilations, 2);
        assert_eq!(cache.retained_bytes(&plan_key), Some(entry_bytes));
        let fresh = compile_workflow(definition.clone()).expect("the definition compiles");
        assert_eq!(
            execute(&plan, "run-equivalence"),
            execute(&fresh, "run-equivalence")
        );
    }

    #[test]
    fn a_panicking_lowering_releases_its_waiters_and_the_key() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, entry_bytes) = cache_holding(&definition, &plan_key, 1);
        let (gate_tx, gate_rx) = mpsc::channel::<()>();

        thread::scope(|scope| {
            let (cache_ref, key_ref) = (&cache, &plan_key);
            let waiter = scope.spawn(move || {
                gate_rx.recv().expect("the owner registers first");
                cache_ref.plan(key_ref, || panic!("the waiter never lowers"))
            });
            // The first caller owns the flight, lets the waiter register, and
            // then unwinds inside the lowering closure. Its waiters must be
            // released rather than left on a flight nobody will finish.
            let unwound = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                cache_ref.plan(key_ref, || {
                    gate_tx.send(()).expect("the waiter is listening");
                    wait_for_waiter(cache_ref);
                    panic!("the lowering unwound");
                })
            }));
            assert!(unwound.is_err(), "the lowering panicked");
            let outcome = waiter.join().expect("the waiter finished");
            assert!(matches!(outcome, Err(PlanCacheError::Abandoned { .. })));
        });

        // An abandoned flight is not a poisoned key.
        let plan = cache
            .plan(&plan_key, lower(&definition))
            .expect("the key lowers after the panic");
        assert_eq!(cache.stats().compilations, 2);
        assert_eq!(cache.retained_bytes(&plan_key), Some(entry_bytes));
        let fresh = compile_workflow(definition.clone()).expect("the definition compiles");
        assert_eq!(
            execute(&plan, "run-equivalence"),
            execute(&fresh, "run-equivalence")
        );
    }

    #[test]
    fn a_profile_cannot_lower_compiler_semantics_this_build_does_not_implement() {
        let definition = definition(0);
        let earlier = CompilerSemantics::version(CompilerSemantics::CURRENT.version_of() - 1)
            .expect("an earlier version of the line is nameable");
        let bound = PlanKey::for_definition(
            &definition,
            earlier,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        )
        .expect("the key types");
        // A profile that merely declares the older line is not a lowering: this
        // binary contains one compiler, and it lowers this build's semantics.
        let profile = InterpreterProfile::new(
            earlier,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let cache = PlanCache::new(profile, 1 << 20);
        let refusal = cache.plan(&bound, || panic!("no such lowering exists here"));
        assert!(matches!(
            refusal,
            Err(PlanCacheError::NotLowerable {
                refusal: LoweringRefusal::CompilerSemantics { .. },
                ..
            })
        ));
        assert_eq!(cache.stats().compilations, 0);
        assert_eq!(cache.stats().entries, 0);
    }

    #[test]
    fn one_retained_plan_serves_many_runs_without_changing_their_execution() {
        let definition = definition(0);
        let plan_key = key(
            &definition,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, _) = cache_holding(&definition, &plan_key, 1);
        let fresh = compile_workflow(definition.clone()).expect("the definition compiles");

        // Two runs of the same revision: the second is served the retained
        // lowering, and each run executes as a fresh lowering would.
        for run in ["run-a", "run-b"] {
            let plan = cache
                .plan(&plan_key, lower(&definition))
                .expect("the plan is served");
            assert_eq!(execute(&plan, run), execute(&fresh, run), "{run}");
        }
        assert_eq!(
            cache.stats().compilations,
            1,
            "one lowering served both runs"
        );
        assert_eq!(cache.stats().reuses, 1);
    }

    #[test]
    fn a_plan_filed_under_a_foreign_key_is_refused() {
        let plain = definition(0);
        let padded = definition(64);
        let plan_key = key(
            &padded,
            EngineSemantics::CURRENT,
            LoweringCapabilities::none(),
        );
        let (cache, _) = cache_holding(&padded, &plan_key, 2);
        let error = cache
            .plan(&plan_key, lower(&plain))
            .expect_err("a plan that is not the key's plan is not retained");
        assert!(matches!(
            error,
            PlanCacheError::KeyMismatch {
                mismatch: PlanMismatch::RevisionDrift { .. },
                ..
            }
        ));
        assert_eq!(cache.retained_bytes(&plan_key), None);
        assert_eq!(cache.stats().entries, 0);

        // The refusal was about the pair, not the key: the key's own plan is
        // accepted and carries the key's revision.
        let plan = cache
            .plan(&plan_key, lower(&padded))
            .expect("the key's own plan lowers");
        assert_eq!(
            DefinitionRevision::of(plan.definition()).expect("the plan digests"),
            *plan_key.definition_revision()
        );
        assert!(cache.retained_bytes(&plan_key).is_some());
    }
}
