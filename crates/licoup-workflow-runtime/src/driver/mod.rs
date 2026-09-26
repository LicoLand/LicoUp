//! Sustained driving of one run by one owner.
//!
//! [`Driver`] is the consumer side of C01's flow: it claims dispatchable
//! commands, commits the possible-effect marker, invokes an adapter, and commits
//! the outcome — repeatedly, until the run has nothing left to do or the host's
//! budget for one call runs out. The shape follows the production driver in
//! `licoup-native/src/domain/workflow_runtime/service.rs`, because the ordering
//! is load-bearing rather than stylistic: the marker is committed **before** the
//! invocation, which is exactly why recovery may treat a started-but-uncommitted
//! command as in doubt instead of retrying it.
//!
//! Four properties are enforced here, and each is visible in a type or in the
//! trace rather than in a comment:
//!
//! 1. **One owner per run.** `drive` takes the run through
//!    [`RunOwnership`] for the whole call and presents a
//!    fenced claimant (`owner#generation`) to the durable store. A second
//!    attempt is refused with the holder's identity; see [`owner`].
//! 2. **Advance per completion, not per batch.** The loop admits effects up to
//!    its bound, then handles *one* result per turn and admits again before it
//!    waits for anything else, so a successor becomes claimable as soon as its
//!    predecessor's outcome is committed. It never joins a batch: an effect that
//!    is still running cannot hold its siblings' successors back.
//! 3. **Adapters cannot re-enter.** [`EffectRequest`] carries data only, so an
//!    adapter has no way to reach the loop through its inputs; and an adapter
//!    that drives anyway is refused by the ownership fence, because the run is
//!    taken for the whole call.
//! 4. **No callbacks under a lock.** Every lock here is held for a map or deque
//!    operation and released before adapter code or store calls run; the adapter
//!    is invoked on its own thread, so a slow adapter blocks nothing but itself.
//!
//! Control (cancel, steer, pause, stop) travels a channel of its own and is
//! handled before results, so a saturated result path cannot starve it; see
//! [`control`] for what a request is, and [`DriveQueue`] for what a running
//! drive reports about the two paths. A run-scoped pause or stop additionally
//! fences admission: the drive stops starting new effects, publishes the
//! barrier with the recipients its ledger froze when the instruction was
//! handled (when a [`ScopeBarrierPort`] is wired), and still settles every
//! effect that was already in flight by its own authenticated outcome.

pub mod control;
pub mod effect;
mod events;
pub mod owner;
pub mod trace;

use std::collections::BTreeMap;
use std::fmt::{Display, Formatter};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use licoup_workflow::{
    FailureClass, MAX_ACTIVE_EFFECTS, ReducerEvent, RunCommand, RunSnapshot, StrategyRunStatus,
};

use crate::admission::{
    AdmissionBarrier, BarrierKind, BarrierRequest, BarrierScope, ScopeBarrierPort,
};
use crate::node::{NodeLedger, NodeLifecycleError, NodeOutcome, NodeOutcomeKind, NodeVisitKey};
use crate::ports::StatePort;

pub use control::{
    ControlAccepted, ControlKind, ControlReceipt, ControlRequest, ControlTag, ControlTarget,
};
pub use effect::{
    CancelConfirmation, CancelRequest, EffectOutcome, EffectPort, EffectRequest, SteerRequest,
};
pub use owner::{OwnedRun, OwnerFence, OwnerId, OwnershipRefusal, RunOwnership};
pub use trace::{Admission, DriveEvent, DriveStop, DriveTrace, Settlement};

use events::{AdapterVerdict, Arrival, Completion, RunEvents, WaitOutcome, WorkerTicket};

/// How many control requests are handled back to back before the loop takes a
/// result.
///
/// Control has priority — that is what keeps a cancel from waiting behind a
/// queue of completions — but an unbounded priority would let a control flood
/// starve results. This bound gives the result path a guaranteed turn, so both
/// channels keep a reservation instead of one consuming the other's.
const CONTROL_BURST: usize = 4;

/// How long the loop waits for a completion before renewing its claims.
const DEFAULT_WAIT_MILLIS: u64 = 250;

/// The bounds one drive runs under.
///
/// The in-flight bound is the capacity limit the plan asks for, and it is
/// enforced where admission happens rather than sampled afterwards. The core's
/// `MAX_ACTIVE_EFFECTS` is the ceiling: a drive may run fewer effects at once
/// than the machine permits, never more.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DriverLimits {
    /// Effects this drive may have in flight at once.
    pub max_in_flight: usize,
    /// Effects one `drive` call may start. A host that needs more calls `drive`
    /// again: the call yields at quiescence with the budget named, instead of
    /// holding a lease it is not using.
    pub max_effects_per_drive: usize,
    /// Control requests that may wait for the drive loop. Bounded separately
    /// from results, so a backed-up result path cannot spend it.
    pub control_capacity: usize,
    /// How long a claim's lease lasts.
    pub lease_millis: i64,
    /// How long the loop waits for work before renewing leases. Must be shorter
    /// than the lease: a loop that renews after expiry is renewing a claim it may
    /// already have lost.
    pub wait_millis: u64,
}

impl Default for DriverLimits {
    fn default() -> Self {
        Self {
            max_in_flight: 4,
            max_effects_per_drive: 64,
            control_capacity: 16,
            lease_millis: 30_000,
            wait_millis: DEFAULT_WAIT_MILLIS,
        }
    }
}

impl DriverLimits {
    /// Refuse limits that cannot be honoured, by name.
    pub fn validate(&self) -> Result<(), DriverError> {
        if self.max_in_flight == 0 {
            return Err(DriverError::InvalidLimits {
                reason: "max_in_flight must be at least 1",
            });
        }
        if self.max_in_flight > MAX_ACTIVE_EFFECTS {
            return Err(DriverError::InvalidLimits {
                reason: "max_in_flight exceeds the core's MAX_ACTIVE_EFFECTS",
            });
        }
        if self.max_effects_per_drive == 0 {
            return Err(DriverError::InvalidLimits {
                reason: "max_effects_per_drive must be at least 1",
            });
        }
        if self.control_capacity == 0 {
            return Err(DriverError::InvalidLimits {
                reason: "control_capacity must be at least 1",
            });
        }
        if self.lease_millis <= 0 {
            return Err(DriverError::InvalidLimits {
                reason: "lease_millis must be positive",
            });
        }
        if self.wait_millis == 0 || self.wait_millis as i64 >= self.lease_millis {
            return Err(DriverError::InvalidLimits {
                reason: "wait_millis must be positive and shorter than lease_millis",
            });
        }
        Ok(())
    }
}

/// What one drive started and settled.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct EffectTally {
    /// Effects this drive claimed and marked.
    pub claimed: usize,
    pub succeeded: usize,
    pub failed: usize,
    /// Settled as cancelled after the effect port acknowledged the cancellation.
    pub cancelled: usize,
    /// Settled as unknown: the adapter reported an unknown position, could not
    /// report at all, or the cancellation could not be confirmed.
    pub unknown: usize,
    /// Effects whose thread ended without a verdict, counted inside `unknown`.
    pub lost: usize,
}

impl EffectTally {
    pub fn settled(&self) -> usize {
        self.succeeded + self.failed + self.cancelled + self.unknown
    }
}

/// What one `drive` call did.
#[derive(Clone, Debug)]
pub struct DriveReport {
    pub run_id: String,
    /// The fence this drive presented to the durable store.
    pub claimant: String,
    pub stop: DriveStop,
    /// The last run sequence this drive committed or read.
    pub sequence: u64,
    pub effects: EffectTally,
    /// The node visits whose effects settled in this call, in settlement order.
    pub settled_visits: Vec<NodeVisitKey>,
    pub trace: DriveTrace,
}

/// What a running drive has waiting in its two channels.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DriveQueue {
    /// Completions waiting to be committed.
    pub results: usize,
    /// Control requests waiting to be handled.
    pub control: usize,
}

/// Why a drive could not run.
#[derive(Debug)]
pub enum DriverError {
    InvalidLimits {
        reason: &'static str,
    },
    /// Another owner holds this run. The holder is named so the caller can act.
    RunAlreadyOwned {
        run_id: String,
        holder: OwnerId,
    },
    /// This process already has a drive for this run. Unreachable while the
    /// ownership fence holds, and refused rather than silently replaced if it
    /// ever is not.
    RunAlreadyDriven {
        run_id: String,
    },
    /// A control request named a run this driver is not driving. Refusing is
    /// more honest than queueing an instruction nobody will take.
    NotDriven {
        run_id: String,
    },
    /// The control queue is full. Visible to the caller, never dropped.
    ControlSaturated {
        run_id: String,
        capacity: usize,
        pending: usize,
    },
    /// An adapter reported a settlement that is not a success for the command
    /// and attempt it was dispatched for. The command stays in doubt rather than
    /// being settled by someone else's fact.
    SettlementRefused {
        command_id: String,
        attempt_token: String,
    },
    /// The drive's own account of a node visit would have become untrue.
    Lifecycle(NodeLifecycleError),
    /// A store or adapter call failed.
    Port(anyhow::Error),
}

impl Display for DriverError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidLimits { reason } => write!(formatter, "driver_limits_invalid: {reason}"),
            Self::RunAlreadyOwned { run_id, holder } => {
                write!(formatter, "run_already_owned: {run_id} is held by {holder}")
            }
            Self::RunAlreadyDriven { run_id } => {
                write!(formatter, "run_already_driven: {run_id}")
            }
            Self::NotDriven { run_id } => write!(formatter, "run_not_driven: {run_id}"),
            Self::ControlSaturated {
                run_id,
                capacity,
                pending,
            } => write!(
                formatter,
                "control_saturated: {run_id} has {pending} of {capacity} control slots in use"
            ),
            Self::SettlementRefused {
                command_id,
                attempt_token,
            } => write!(
                formatter,
                "effect_settlement_refused: {command_id} attempt {attempt_token} was not settled by \
                 the outcome its adapter reported"
            ),
            Self::Lifecycle(error) => write!(formatter, "{error}"),
            Self::Port(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for DriverError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Lifecycle(error) => Some(error),
            Self::Port(error) => error.source(),
            _ => None,
        }
    }
}

impl From<anyhow::Error> for DriverError {
    fn from(error: anyhow::Error) -> Self {
        Self::Port(error)
    }
}

impl From<NodeLifecycleError> for DriverError {
    fn from(error: NodeLifecycleError) -> Self {
        Self::Lifecycle(error)
    }
}

impl From<OwnershipRefusal> for DriverError {
    fn from(refusal: OwnershipRefusal) -> Self {
        Self::RunAlreadyOwned {
            run_id: refusal.run_id().to_owned(),
            holder: refusal.holder().clone(),
        }
    }
}

/// The mutable account one drive keeps while it runs.
struct DriveState {
    sequence: u64,
    ledger: NodeLedger,
    /// What the effect port said about each cancellation it was asked for.
    confirmations: BTreeMap<String, CancelConfirmation>,
    /// Why a dispatch never produced a thread, for the settlement that follows.
    unreported: BTreeMap<String, (&'static str, Option<String>)>,
    tally: EffectTally,
    settled_visits: Vec<NodeVisitKey>,
    trace: DriveTrace,
    /// The command whose outcome was committed immediately before the next
    /// admission, recorded so the trace can name it.
    last_settled: Option<String>,
    /// A run-level cancel has been handled: this drive starts no new effects.
    /// The durable admission barrier for new visits is V7-R2's; this is the
    /// in-drive half of it.
    cancel_requested: bool,
    /// A run-scoped pause or stop handled by this drive: no new effect starts
    /// for the rest of this call. Recorded as the instruction's kind, because a
    /// pause and a stop differ in whether a later resume may clear them.
    fence_kind: Option<BarrierKind>,
    /// The barrier the barrier owner reported at the last admission. A barrier
    /// in force outlives the instruction that wrote it, so the admission
    /// boundary reads it rather than trusting only what this call handled.
    observed_barrier: Option<AdmissionBarrier>,
    admitted_total: usize,
    budget_exhausted: bool,
    /// When this drive's claims next need renewing, in unix milliseconds.
    next_renewal_ms: i64,
    claimant: String,
}

impl DriveState {
    /// The fence that stopped this drive from starting new work, if one did.
    ///
    /// Both halves are named: an instruction this drive handled, and a barrier
    /// the barrier owner reported at admission.
    fn fence_in_force(&self) -> Option<BarrierKind> {
        self.fence_kind
            .or_else(|| self.observed_barrier.as_ref().map(|barrier| barrier.kind))
    }
}

/// Drives runs over the K0 ports.
///
/// A driver is shareable between threads: it holds no per-run state of its own,
/// every drive's account lives in its own `drive` call, and the only shared
/// mutable state is the ownership registry and the map of active drives — both
/// held for single operations and never across adapter code.
pub struct Driver {
    state: Arc<dyn StatePort>,
    effect: Arc<dyn EffectPort>,
    /// The owner of the scope admission barrier, when one is wired. Without it
    /// a run-scoped pause still fences this drive's own admissions, but no
    /// durable barrier is written and a later call cannot see the fence.
    barriers: Option<Arc<dyn ScopeBarrierPort>>,
    ownership: Arc<RunOwnership>,
    owner: OwnerId,
    limits: DriverLimits,
    /// Where a control request for a run finds the drive that would take it.
    drives: Mutex<BTreeMap<String, Arc<RunEvents>>>,
}

impl std::fmt::Debug for Driver {
    /// Identity and bounds, not the ports: a driver's debug form must never be a
    /// way to reach a store handle.
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Driver")
            .field("owner", &self.owner)
            .field("limits", &self.limits)
            .field("driving", &self.active_runs())
            .finish_non_exhaustive()
    }
}

impl Driver {
    /// A driver owning its own run registry.
    pub fn new(
        state: Arc<dyn StatePort>,
        effect: Arc<dyn EffectPort>,
        owner: OwnerId,
        limits: DriverLimits,
    ) -> Result<Self, DriverError> {
        Self::with_ownership(state, effect, owner, limits, Arc::new(RunOwnership::new()))
    }

    /// A driver sharing a run registry with other drivers.
    ///
    /// Two drivers that share a registry are two hosts in one process: the
    /// second cannot take a run the first holds, which is the same refusal a
    /// second process gets from the durable claimant fence.
    pub fn with_ownership(
        state: Arc<dyn StatePort>,
        effect: Arc<dyn EffectPort>,
        owner: OwnerId,
        limits: DriverLimits,
        ownership: Arc<RunOwnership>,
    ) -> Result<Self, DriverError> {
        limits.validate()?;
        Ok(Self {
            state,
            effect,
            barriers: None,
            ownership,
            owner,
            limits,
            drives: Mutex::new(BTreeMap::new()),
        })
    }

    /// Wire the owner of the scope admission barrier.
    ///
    /// A run-scoped pause or stop then writes a durable barrier together with
    /// the recipients this drive froze, and every admission re-reads the
    /// barrier in force, so a fence outlives the call that handled the
    /// instruction. Two drivers sharing one barrier owner see the same barrier;
    /// one that has none keeps the in-drive half of the fence only.
    pub fn with_barrier(mut self, barriers: Arc<dyn ScopeBarrierPort>) -> Self {
        self.barriers = Some(barriers);
        self
    }

    pub fn limits(&self) -> &DriverLimits {
        &self.limits
    }

    pub fn ownership(&self) -> &Arc<RunOwnership> {
        &self.ownership
    }

    /// The runs this driver is driving right now.
    pub fn active_runs(&self) -> Vec<String> {
        self.drives().keys().cloned().collect()
    }

    /// How much is waiting in a running drive's channels, or `None` when this
    /// driver is not driving that run.
    ///
    /// Counts only: the values themselves stay in the drive. This is the
    /// in-process half of C07's queue telemetry, and it is what makes a test
    /// able to name the moment a result path is backed up instead of guessing at
    /// one.
    pub fn queued(&self, run_id: &str) -> Option<DriveQueue> {
        let events = self.drives().get(run_id).cloned();
        let events = events?;
        Some(DriveQueue {
            results: events.result_depth(),
            control: events.control_depth(),
        })
    }

    /// Hand one control request to the drive that owns this run.
    ///
    /// Returns once the request is queued, not once it is acted on: the drive
    /// loop acts on it and records a [`ControlReceipt`] in the trace. A request
    /// for a run nobody is driving is refused rather than queued into the void.
    pub fn control(
        &self,
        run_id: &str,
        request: ControlRequest,
    ) -> Result<ControlAccepted, DriverError> {
        let events = self
            .drives()
            .get(run_id)
            .cloned()
            .ok_or_else(|| DriverError::NotDriven {
                run_id: run_id.to_owned(),
            })?;
        let request_id = request.request_id.clone();
        match events.push_control(request) {
            Ok(()) => Ok(ControlAccepted { request_id }),
            Err(_) => Err(DriverError::ControlSaturated {
                run_id: run_id.to_owned(),
                capacity: self.limits.control_capacity,
                pending: events.control_depth(),
            }),
        }
    }

    /// Drive one run until it has nothing left to do, its budget runs out, or it
    /// needs authorization.
    pub fn drive(&self, run_id: &str) -> Result<DriveReport, DriverError> {
        // The whole call holds the run: a second owner is refused here, and an
        // adapter that tries to drive the same run again while this call runs
        // gets that refusal instead of interleaving with it.
        let owned = self.ownership.acquire(run_id, &self.owner)?;
        let events = self.begin(run_id)?;
        let result = self.drive_owned(run_id, &owned, &events);
        self.end(run_id, &events);
        result
    }

    fn drive_owned(
        &self,
        run_id: &str,
        owned: &OwnedRun,
        events: &Arc<RunEvents>,
    ) -> Result<DriveReport, DriverError> {
        let checkpoint = self.state.checkpoint(run_id)?;
        let mut state = DriveState {
            sequence: checkpoint.sequence,
            ledger: NodeLedger::new(),
            confirmations: BTreeMap::new(),
            unreported: BTreeMap::new(),
            tally: EffectTally::default(),
            settled_visits: Vec::new(),
            trace: DriveTrace::default(),
            last_settled: None,
            cancel_requested: false,
            fence_kind: None,
            observed_barrier: None,
            admitted_total: 0,
            budget_exhausted: false,
            next_renewal_ms: now_unix_ms().saturating_add(self.limits.lease_millis / 2),
            claimant: owned.claimant(),
        };
        state.trace.push(DriveEvent::Owned {
            claimant: state.claimant.clone(),
        });

        let stop = loop {
            // (1) Control first, for a bounded burst: a cancel must not wait
            // behind the completions it is running against.
            let mut controls_in_a_row = 0usize;
            while controls_in_a_row < CONTROL_BURST {
                let Some(request) = events.take_control() else {
                    break;
                };
                let results_pending = events.result_depth();
                let receipt = self.handle_control(run_id, request, &mut state, results_pending)?;
                if receipt.kind == ControlTag::Cancel {
                    state.cancel_requested = true;
                }
                state.trace.push(DriveEvent::Control(receipt));
                controls_in_a_row += 1;
            }

            // (2) Admission, bounded and after the previous outcome was
            // committed. This is where a settled predecessor's successors become
            // claimable, without waiting for the rest of the in-flight set.
            //
            // A fence this drive handled, or a barrier the barrier owner reports
            // for the run scope, stops a new node visit from starting here —
            // which is why a pause that arrived before a predecessor settled
            // cannot be overtaken by that predecessor's successor.
            state.budget_exhausted = state.admitted_total >= self.limits.max_effects_per_drive;
            if !state.cancel_requested && state.fence_kind.is_none() && !state.budget_exhausted {
                self.admit(run_id, events, &mut state)?;
            }

            // (3) One completion per turn, and one fact about the result path:
            // whether a verdict is waiting, whether effects are still running, or
            // whether every admitted effect has ended without one. Reading those
            // together is what keeps an effect whose completion is in flight from
            // being settled as one that never reported.
            match events.take_completion() {
                Arrival::Completion(completion) => {
                    self.settle(run_id, *completion, &mut state)?;
                    continue;
                }
                // (4) An effect whose thread ended without a verdict cannot
                // settle itself; the drive records it as in doubt rather than
                // waiting for a completion nobody will produce.
                Arrival::Ended if state.ledger.in_flight() > 0 => {
                    self.settle_unreported(run_id, &mut state)?;
                    continue;
                }
                Arrival::Ended | Arrival::Waiting => {}
            }

            // (5) Nothing in flight: the run has no work this drive may start.
            // A request that arrived during the last turn is still taken before
            // the drive ends, because control is not conditioned on effects
            // being in flight — a run with nothing running is exactly where a
            // cancel stops what has not started.
            if state.ledger.in_flight() == 0 {
                let Some(request) = events.take_control() else {
                    break self.stop_reason(run_id, &state)?;
                };
                let results_pending = events.result_depth();
                let receipt = self.handle_control(run_id, request, &mut state, results_pending)?;
                if receipt.kind == ControlTag::Cancel {
                    state.cancel_requested = true;
                }
                state.trace.push(DriveEvent::Control(receipt));
                continue;
            }

            // A timed-out wait is when the claims are looked at again. Renewing
            // sooner than the lease needs would write to the store for nothing;
            // renewing after it expired would renew a claim that may already be
            // someone else's.
            if events.wait(Duration::from_millis(self.limits.wait_millis)) == WaitOutcome::TimedOut
                && now_unix_ms() >= state.next_renewal_ms
            {
                self.renew_leases(&state)?;
                state.next_renewal_ms = now_unix_ms().saturating_add(self.limits.lease_millis / 2);
            }
        };

        state.trace.push(DriveEvent::Stopped(stop.clone()));
        Ok(DriveReport {
            run_id: run_id.to_owned(),
            claimant: state.claimant,
            stop,
            sequence: state.sequence,
            effects: state.tally,
            settled_visits: state.settled_visits,
            trace: state.trace,
        })
    }

    /// Claim and dispatch effects until the in-flight bound is reached.
    ///
    /// The barrier read comes first: a fence that outlived the call that
    /// published it is exactly what a new drive call must honour, and reading it
    /// at the same boundary that takes claims is what makes "a new visit does
    /// not start under a paused scope" a check rather than a hope.
    ///
    /// The claim and the possible-effect marker are separate statements here on
    /// purpose: an admission gate that checks authority and resources
    /// (V7-R2's, wired by the composition that owns the run) belongs between
    /// them, so a refused effect is never marked as possibly having happened.
    fn admit(
        &self,
        run_id: &str,
        events: &Arc<RunEvents>,
        state: &mut DriveState,
    ) -> Result<(), DriverError> {
        if let Some(barriers) = &self.barriers {
            let scope = BarrierScope::Run(run_id.to_owned());
            let barrier = barriers.barrier(&scope)?;
            let blocking = barrier
                .as_ref()
                .is_some_and(AdmissionBarrier::blocks_new_visits);
            state.observed_barrier = barrier;
            if blocking {
                return Ok(());
            }
        }
        while state.ledger.in_flight() < self.limits.max_in_flight {
            let Some(command) = self.state.claim_next(
                run_id,
                &state.claimant,
                now_unix_ms().saturating_add(self.limits.lease_millis),
            )?
            else {
                return Ok(());
            };
            // The marker is committed before anything can invoke the effect.
            // That order is the boundary recovery rests on: a started command
            // may already have had its effect happen, so it is in doubt rather
            // than retryable.
            let snapshot = self
                .state
                .mark_started(run_id, &command.id, &command.attempt_token)?;
            state.sequence = snapshot.sequence;
            state.ledger.record_claim(&command)?;
            state
                .ledger
                .record_started(&command.id, &command.attempt_token)?;
            state.tally.claimed = state.tally.claimed.saturating_add(1);
            state.admitted_total = state.admitted_total.saturating_add(1);
            // The claim just taken carries a fresh lease, so the next renewal is
            // half a lease away rather than immediately due.
            state.next_renewal_ms = now_unix_ms().saturating_add(self.limits.lease_millis / 2);
            state.trace.push(DriveEvent::Admitted(Admission {
                command_id: command.id.clone(),
                node: NodeVisitKey::from_command(&command),
                claimant: state.claimant.clone(),
                marker_sequence: snapshot.sequence,
                after: state.last_settled.take(),
                in_flight: state.ledger.in_flight(),
            }));
            self.dispatch(run_id, &command, events, state)?;
        }
        Ok(())
    }

    /// Start one effect on its own thread.
    ///
    /// Nothing is held across this call: the queue's mutex was released by
    /// admission, the registry's by `acquire`, and the adapter runs on a thread
    /// of its own. An adapter that blocks here blocks nobody else, and an
    /// adapter that tries to drive the run again is refused by the fence rather
    /// than deadlocking on a lock this loop would have been holding.
    fn dispatch(
        &self,
        run_id: &str,
        command: &RunCommand,
        events: &Arc<RunEvents>,
        state: &mut DriveState,
    ) -> Result<(), DriverError> {
        let request = EffectRequest::from_command(run_id, command);
        let command_id = request.command_id().to_owned();
        let attempt_token = request.attempt_token().to_owned();
        let node = request.node();
        let effect = Arc::clone(&self.effect);
        let queue = Arc::clone(events);
        let undelivered_command = command_id.clone();
        let undelivered_node = node.clone();
        // Created before the thread and moved into it, so it is dropped exactly
        // once whether the effect returns, panics, or never starts.
        let ticket = WorkerTicket::new(events);
        let spawned = std::thread::Builder::new()
            .name(format!(
                "licoup-effect-{}",
                &command_id.chars().take(24).collect::<String>()
            ))
            .spawn(move || {
                let verdict = match effect.submit(&request) {
                    Ok(outcome) => AdapterVerdict::Verdict(outcome),
                    Err(error) => AdapterVerdict::Unreported {
                        code: "effect_adapter_failed",
                        detail: Some(brief(&error.to_string())),
                    },
                };
                queue.push_result(Completion {
                    command_id,
                    attempt_token,
                    node,
                    verdict,
                });
                drop(ticket);
            });
        if let Err(error) = spawned {
            // The marker is already durable, so the honest report is "unknown",
            // which is what the settlement below records. Pretending the effect
            // never started would invite a retry of something that may have run.
            let detail = brief(&error.to_string());
            state.trace.push(DriveEvent::EffectLost {
                command_id: undelivered_command.clone(),
                node: undelivered_node,
                detail: Some(format!("effect_dispatch_failed: {detail}")),
            });
            state.unreported.insert(
                undelivered_command,
                ("effect_dispatch_failed", Some(detail)),
            );
        }
        Ok(())
    }

    /// Commit one effect's outcome and take it out of the live set.
    fn settle(
        &self,
        run_id: &str,
        completion: Completion,
        state: &mut DriveState,
    ) -> Result<(), DriverError> {
        let command_id = completion.command_id.clone();
        let attempt_token = completion.attempt_token.clone();
        let node = completion.node.clone();
        let observed = match &completion.verdict {
            AdapterVerdict::Verdict(outcome) => outcome_kind(outcome),
            AdapterVerdict::Unreported { .. } => NodeOutcomeKind::Unknown,
        };
        let cancelled = state.ledger.is_cancel_requested(&command_id);
        let (event, outcome) = if cancelled {
            // A cancellation was requested for this effect, so the run's own
            // event stream has it in "cancel requested": the completion settles
            // it as what the effect port confirmed, and nothing else. A late
            // success is not read as a cancellation.
            match state.confirmations.get(&command_id) {
                Some(CancelConfirmation::Acknowledged) => (
                    ReducerEvent::CancellationAcknowledged {
                        command_id: command_id.clone(),
                        attempt_token: attempt_token.clone(),
                    },
                    NodeOutcome::Cancelled,
                ),
                _ => (
                    ReducerEvent::CancellationUnknown {
                        command_id: command_id.clone(),
                        attempt_token: attempt_token.clone(),
                    },
                    NodeOutcome::Unknown,
                ),
            }
        } else {
            match completion.verdict {
                AdapterVerdict::Verdict(EffectOutcome::Succeeded { result }) => (
                    self.accept_success(&command_id, &attempt_token, result)?,
                    NodeOutcome::Succeeded,
                ),
                AdapterVerdict::Verdict(EffectOutcome::Failed { class, code }) => {
                    let code = sanitize_code(&code, "effect_failed");
                    (
                        ReducerEvent::CommandFailed {
                            command_id: command_id.clone(),
                            attempt_token: attempt_token.clone(),
                            class,
                            code: code.clone(),
                        },
                        NodeOutcome::Failed { class, code },
                    )
                }
                AdapterVerdict::Verdict(EffectOutcome::Unknown { code }) => {
                    let code = sanitize_code(&code, "effect_unknown");
                    (
                        ReducerEvent::CommandFailed {
                            command_id: command_id.clone(),
                            attempt_token: attempt_token.clone(),
                            class: FailureClass::InDoubt,
                            code: code.clone(),
                        },
                        NodeOutcome::Unknown,
                    )
                }
                AdapterVerdict::Unreported { code, detail } => {
                    if let Some(detail) = detail {
                        state.trace.push(DriveEvent::AdapterError {
                            command_id: command_id.clone(),
                            operation: "submit",
                            detail,
                        });
                    }
                    (
                        ReducerEvent::CommandFailed {
                            command_id: command_id.clone(),
                            attempt_token: attempt_token.clone(),
                            class: FailureClass::InDoubt,
                            code: code.to_owned(),
                        },
                        NodeOutcome::Unknown,
                    )
                }
            }
        };
        let snapshot = self
            .state
            .commit(run_id, state.sequence, event)
            .map_err(DriverError::Port)?;
        state.sequence = snapshot.sequence;
        let settlement = state.ledger.settle(&command_id, outcome)?;
        let settled_kind = settlement.outcome.kind();
        if cancelled && observed != settled_kind {
            state.trace.push(DriveEvent::LateOutcome {
                command_id: command_id.clone(),
                observed,
                settled: settled_kind,
            });
        }
        match settled_kind {
            NodeOutcomeKind::Succeeded => {
                state.tally.succeeded = state.tally.succeeded.saturating_add(1);
            }
            NodeOutcomeKind::Failed => {
                state.tally.failed = state.tally.failed.saturating_add(1);
            }
            NodeOutcomeKind::Cancelled => {
                state.tally.cancelled = state.tally.cancelled.saturating_add(1);
            }
            NodeOutcomeKind::Unknown => {
                state.tally.unknown = state.tally.unknown.saturating_add(1);
            }
        }
        state.settled_visits.push(node.clone());
        state.trace.push(DriveEvent::Settled(Settlement {
            command_id: command_id.clone(),
            node,
            outcome: settled_kind,
            sequence: state.sequence,
            in_flight: state.ledger.in_flight(),
        }));
        state.last_settled = Some(command_id);
        Ok(())
    }

    /// Accept the settlement an adapter reported for a success.
    ///
    /// The payload is the one thing only the adapter can produce, so it travels
    /// inside the machine's own success event. The identity beside it is not
    /// taken on trust: an event that is not a success for exactly this command
    /// and attempt is refused, and the committed event is rebuilt with this
    /// drive's identity, so an adapter cannot settle a command it was not
    /// dispatched for.
    fn accept_success(
        &self,
        command_id: &str,
        attempt_token: &str,
        result: ReducerEvent,
    ) -> Result<ReducerEvent, DriverError> {
        match result {
            ReducerEvent::CommandSucceeded {
                command_id: adapter_command,
                attempt_token: adapter_attempt,
                output,
            } if adapter_command == command_id && adapter_attempt == attempt_token => {
                Ok(ReducerEvent::CommandSucceeded {
                    command_id: command_id.to_owned(),
                    attempt_token: attempt_token.to_owned(),
                    output,
                })
            }
            _ => Err(DriverError::SettlementRefused {
                command_id: command_id.to_owned(),
                attempt_token: attempt_token.to_owned(),
            }),
        }
    }

    /// Settle every effect whose thread has ended without reporting.
    fn settle_unreported(&self, run_id: &str, state: &mut DriveState) -> Result<(), DriverError> {
        for command_id in state.ledger.in_flight_commands() {
            let Some(effect) = state.ledger.effect(&command_id) else {
                continue;
            };
            let node = effect.key().clone();
            let attempt_token = effect.attempt_token().to_owned();
            let (code, detail) = state
                .unreported
                .remove(&command_id)
                .unwrap_or(("effect_adapter_lost", None));
            state.trace.push(DriveEvent::EffectLost {
                command_id: command_id.clone(),
                node: node.clone(),
                detail: detail.clone(),
            });
            state.tally.lost = state.tally.lost.saturating_add(1);
            self.settle(
                run_id,
                Completion {
                    command_id,
                    attempt_token,
                    node,
                    verdict: AdapterVerdict::Unreported { code, detail },
                },
                state,
            )?;
        }
        Ok(())
    }

    /// Take one control request.
    fn handle_control(
        &self,
        run_id: &str,
        request: ControlRequest,
        state: &mut DriveState,
        results_pending: usize,
    ) -> Result<ControlReceipt, DriverError> {
        let kind = request.tag();
        let mut confirmations = Vec::new();
        let mut published = None;
        let frozen = match &request.kind {
            ControlKind::Cancel => {
                // The durable request comes first: what the run has been asked
                // to do is a committed fact, and each effect's completion is
                // what settles it.
                let snapshot =
                    self.state
                        .commit(run_id, state.sequence, ReducerEvent::CancelRequested)?;
                state.sequence = snapshot.sequence;
                let frozen = state.ledger.freeze(&ControlTarget::Run);
                for command_id in &frozen.commands {
                    state.ledger.mark_cancel_requested(command_id);
                    let Some(effect) = state.ledger.effect(command_id) else {
                        continue;
                    };
                    let cancel = CancelRequest {
                        control_request_id: request.request_id.clone(),
                        run_id: run_id.to_owned(),
                        command_id: command_id.clone(),
                        attempt_token: effect.attempt_token().to_owned(),
                    };
                    // Adapter code, called with no lock held: control must not
                    // run under the queue's mutex or the registry's.
                    let confirmation = match self.effect.cancel(&cancel) {
                        Ok(confirmation) => confirmation,
                        Err(error) => {
                            state.trace.push(DriveEvent::AdapterError {
                                command_id: command_id.clone(),
                                operation: "cancel",
                                detail: brief(&error.to_string()),
                            });
                            CancelConfirmation::Unknown
                        }
                    };
                    confirmations.push((command_id.clone(), confirmation.clone()));
                    state.confirmations.insert(command_id.clone(), confirmation);
                }
                frozen
            }
            ControlKind::Steer {
                target,
                instruction,
            } => {
                let frozen = state.ledger.freeze(target);
                for command_id in &frozen.commands {
                    let Some(effect) = state.ledger.effect(command_id) else {
                        continue;
                    };
                    let steer = SteerRequest {
                        control_request_id: request.request_id.clone(),
                        run_id: run_id.to_owned(),
                        command_id: command_id.clone(),
                        attempt_token: effect.attempt_token().to_owned(),
                        instruction: instruction.clone(),
                    };
                    if let Err(error) = self.effect.steer(&steer) {
                        state.trace.push(DriveEvent::AdapterError {
                            command_id: command_id.clone(),
                            operation: "steer",
                            detail: brief(&error.to_string()),
                        });
                    }
                }
                frozen
            }
            ControlKind::Fence {
                target,
                kind,
                reason,
            } => {
                // The recipients are frozen before anything is published: a
                // barrier and the set it froze are one write (C03), and this
                // ledger is the only place that knows what was in flight when
                // the instruction was handled.
                let frozen = state.ledger.freeze(target);
                let scope = barrier_scope(target, run_id);
                if let Some(barriers) = &self.barriers {
                    let request = BarrierRequest {
                        scope: scope.clone(),
                        kind: *kind,
                        reason: reason.clone(),
                        recipients: frozen.visits.clone(),
                    };
                    published = Some(barriers.publish(&request)?);
                }
                // A node-scoped instruction does not fence a new visit (C03);
                // only the run scope stops this drive from admitting.
                if scope.blocks_new_visits() {
                    state.fence_kind = Some(*kind);
                }
                frozen
            }
        };
        Ok(ControlReceipt {
            request_id: request.request_id,
            kind,
            frozen,
            confirmations,
            barrier: published,
            results_pending,
            in_flight: state.ledger.in_flight(),
        })
    }

    /// Keep this drive's claims alive while it waits.
    fn renew_leases(&self, state: &DriveState) -> Result<(), DriverError> {
        let lease_until = now_unix_ms().saturating_add(self.limits.lease_millis);
        for command_id in state.ledger.in_flight_commands() {
            // A lease this owner no longer holds fails here, and the drive
            // stops: an owner whose claim was taken must not commit an outcome
            // for it. The durable marker is what recovery reads instead.
            self.state
                .renew_lease(&command_id, &state.claimant, lease_until)?;
        }
        Ok(())
    }

    /// Why the drive found no more work.
    fn stop_reason(&self, run_id: &str, state: &DriveState) -> Result<DriveStop, DriverError> {
        let snapshot: RunSnapshot = self.state.checkpoint(run_id)?;
        Ok(match snapshot.status {
            // Completed, Failed, Cancelled and CancelInDoubt are reported as
            // themselves: a run whose cancellation could not be confirmed is not
            // advancing, and reconciling it is not a drive's decision. A
            // terminal status also outranks a fence, because a run that finished
            // did not become paused and its results are not rewritten by a later
            // instruction.
            StrategyRunStatus::Completed
            | StrategyRunStatus::Failed
            | StrategyRunStatus::Cancelled
            | StrategyRunStatus::CancelInDoubt => DriveStop::Terminal {
                status: snapshot.status,
            },
            StrategyRunStatus::AuthorizationRequired => DriveStop::AwaitingAuthorization,
            // A fence is reported before quiescence: "this drive may not start
            // the work that exists" is a different fact from "there is no work",
            // and a caller that retried on the first would silently unfence it.
            _ => match state.fence_in_force() {
                Some(kind) => DriveStop::Fenced { kind },
                None => DriveStop::Quiescent {
                    budget_exhausted: state.budget_exhausted,
                },
            },
        })
    }

    fn begin(&self, run_id: &str) -> Result<Arc<RunEvents>, DriverError> {
        let events = RunEvents::new(self.limits.max_in_flight, self.limits.control_capacity);
        let mut drives = self.drives();
        if drives.contains_key(run_id) {
            return Err(DriverError::RunAlreadyDriven {
                run_id: run_id.to_owned(),
            });
        }
        drives.insert(run_id.to_owned(), Arc::clone(&events));
        Ok(events)
    }

    fn end(&self, run_id: &str, events: &Arc<RunEvents>) {
        self.drives().remove(run_id);
        events.close();
    }

    fn drives(&self) -> MutexGuard<'_, BTreeMap<String, Arc<RunEvents>>> {
        self.drives.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn outcome_kind(outcome: &EffectOutcome) -> NodeOutcomeKind {
    match outcome {
        EffectOutcome::Succeeded { .. } => NodeOutcomeKind::Succeeded,
        EffectOutcome::Failed { .. } => NodeOutcomeKind::Failed,
        EffectOutcome::Unknown { .. } => NodeOutcomeKind::Unknown,
    }
}

/// The scope a control target addresses.
///
/// A run target is the graph scope of the run being driven; a node target names
/// one visit. The distinction is load-bearing: only the run scope stops a new
/// visit from starting.
fn barrier_scope(target: &ControlTarget, run_id: &str) -> BarrierScope {
    match target {
        ControlTarget::Run => BarrierScope::Run(run_id.to_owned()),
        ControlTarget::Node(key) => BarrierScope::Node(key.clone()),
    }
}

/// Normalize an adapter's failure code to what durable state accepts.
///
/// The machine refuses a code that is empty, over-long, or not lowercase
/// `[a-z0-9_-]`. Normalizing at this boundary keeps a badly formulated adapter
/// string from either poisoning the run or being silently accepted as a
/// different code.
fn sanitize_code(code: &str, fallback: &str) -> String {
    let cleaned: String = code
        .to_ascii_lowercase()
        .chars()
        .filter(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '-' | '_')
        })
        .take(96)
        .collect();
    if cleaned.is_empty() {
        fallback.to_owned()
    } else {
        cleaned
    }
}

/// Shorten adapter text for the in-process trace. It is never durable state.
fn brief(text: &str) -> String {
    const MAX: usize = 160;
    match text.char_indices().nth(MAX) {
        Some((index, _)) => format!("{}...", &text[..index]),
        None => text.to_owned(),
    }
}

fn now_unix_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}
