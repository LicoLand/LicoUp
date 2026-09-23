//! The contract fixture: one in-process implementation of both ports.
//!
//! The driver is written against `StatePort` and `EffectPort`, so it can be
//! driven without a database or an operating system: this fixture implements
//! both, sharing one lock and one ordered observation log. It is deliberately
//! strict rather than permissive, because the point of these tests is the
//! ordering the ports describe:
//!
//! * A **possible-effect marker must be durable before the effect is invoked**.
//!   Both ports record into one log, so the tests assert the marker step
//!   precedes the invocation step for every command, and the fixture itself
//!   files a violation when it is invoked for a command with no marker.
//! * **A success may only settle a running command**, mirroring the machine's own
//!   transition rule. A driver that settled a command it had cancelled, or
//!   settled one before marking it started, is refused here by the same rule the
//!   machine would apply.
//! * **A lease is held by one claimant**. `renew_lease` refuses a claimant that
//!   did not take the claim, which is what makes the fence checkable.
//!
//! What this fixture deliberately does not model: the store's real
//! dispatchability policy (which command of a compiled graph is ready) belongs
//! to V7-S1, and the pure machine's own transitions belong to `licoup-workflow`.
//! Here readiness is declared: a command is claimable once every predecessor in
//! its declared list has settled. That is enough to drive the driver's behaviour
//! and no more.
//!
//! This crate has no JSON dependency, so JSON values come from the machine's own
//! defaults (`RunSnapshot::empty(..).input`) rather than from a JSON type named
//! here.

use std::collections::BTreeMap;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use anyhow::{Result, anyhow, ensure};
use licoup_workflow::{
    CommandKind, CommandStatus, FailureClass, ReducerEvent, RunCommand, RunSnapshot,
    StrategyRunStatus,
};
use licoup_workflow_runtime::admission::{
    AdmissionBarrier, BarrierKind, BarrierRequest, BarrierScope, ScopeBarrierPort,
};
use licoup_workflow_runtime::driver::{
    CancelConfirmation, CancelRequest, DriveReport, Driver, DriverLimits, EffectOutcome,
    EffectPort, EffectRequest, OwnerId, SteerRequest,
};
use licoup_workflow_runtime::node::NodeVisitKey;
use licoup_workflow_runtime::ports::StatePort;

/// The run every test drives.
pub const RUN: &str = "run-1";

/// How long a test waits for the condition it asked for before failing.
const WAIT: Duration = Duration::from_secs(10);

/// A latch a test opens and the fixture waits on.
#[derive(Debug, Default)]
pub struct Gate {
    open: Mutex<bool>,
    wake: Condvar,
}

impl Gate {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn open(&self) {
        *self.open.lock().unwrap_or_else(PoisonError::into_inner) = true;
        self.wake.notify_all();
    }

    pub fn is_open(&self) -> bool {
        *self.open.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Wait until the gate is open, for no longer than the fixture's own bound.
    pub fn wait(&self) {
        let mut open = self.open.lock().unwrap_or_else(PoisonError::into_inner);
        while !*open {
            let (guard, timeout) = self
                .wake
                .wait_timeout(open, WAIT)
                .unwrap_or_else(PoisonError::into_inner);
            open = guard;
            if timeout.timed_out() && !*open {
                panic!("fixture_gate_never_opened");
            }
        }
    }
}

/// What one effect does when it is invoked.
#[derive(Clone, Debug)]
pub enum Script {
    /// Succeed at once, with a success event naming its own command.
    Succeed,
    /// Signal the invocation, wait for the gate, then succeed.
    Hold(Arc<Gate>),
    Fail {
        class: FailureClass,
        code: String,
    },
    Unknown {
        code: String,
    },
    /// Return an error from the adapter instead of a verdict.
    Error(String),
    /// End the thread without a verdict.
    Panic,
    /// Report a success event naming a different command: the driver must refuse
    /// it rather than settle someone else's fact.
    Misreport,
}

/// What the fixture saw, in the order it saw it.
#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    /// The possible-effect marker became durable.
    Marker { command_id: String },
    /// An adapter was entered.
    Invoked { command_id: String },
    /// An adapter returned a verdict.
    Returned { command_id: String },
    /// An invocation ended, by returning or by panicking.
    InvocationEnded { command_id: String },
    /// The store committed an event.
    Committed {
        command_id: Option<String>,
        event: &'static str,
    },
}

/// A read-only view for waiting predicates. A predicate runs with the fixture's
/// lock held, so it must only read this.
#[derive(Clone, Debug)]
pub struct Probe {
    pub invocations: Vec<String>,
    pub returns: Vec<String>,
    pub commits_entered: Vec<String>,
    pub steers: Vec<(String, String)>,
    pub cancels: Vec<(String, String)>,
}

impl Probe {
    pub fn invoked(&self, command_id: &str) -> bool {
        self.invocations.iter().any(|id| id == command_id)
    }

    pub fn returned(&self, command_id: &str) -> bool {
        self.returns.iter().any(|id| id == command_id)
    }

    pub fn cancel_asked(&self, command_id: &str) -> bool {
        self.cancels.iter().any(|(_, id)| id == command_id)
    }
}

/// A hook the fixture runs inside adapter methods, so a test can find out what an
/// adapter that tries to re-enter the driver gets, and whether driver locks are
/// held while adapter code runs.
pub type AdapterHook = Arc<dyn Fn(&str, &str) + Send + Sync>;

#[derive(Clone, Debug)]
struct Cmd {
    id: String,
    /// The state and visit the command runs in, as the machine emitted them.
    state_id: String,
    state_visit: u64,
    kind: CommandKind,
    /// The workset item this command runs, when it is one of a visit's items.
    ///
    /// The machine gives every ready item of a workset its own command over the
    /// same `state_id`/`state_visit`, so this is what tells two live effects of
    /// one visit apart.
    item_id: Option<String>,
    predecessors: Vec<String>,
    status: CommandStatus,
    attempt_token: String,
    claimed_by: Option<String>,
    result_ref: Option<String>,
}

struct State {
    order: Vec<Step>,
    sequence: u64,
    status: StrategyRunStatus,
    declarations: Vec<String>,
    commands: BTreeMap<String, Cmd>,
    gates: BTreeMap<String, Arc<Gate>>,
    scripts: BTreeMap<String, Script>,
    hook: Option<AdapterHook>,
    markers: BTreeMap<String, u64>,
    invocations: Vec<String>,
    returns: Vec<String>,
    running: usize,
    peak_running: usize,
    commits_entered: Vec<String>,
    cancels: Vec<(String, String)>,
    steers: Vec<(String, String)>,
    confirmations: BTreeMap<String, CancelConfirmation>,
    violations: Vec<String>,
    claims: Vec<(String, String)>,
    barriers: BTreeMap<BarrierScope, AdmissionBarrier>,
    barrier_requests: Vec<BarrierRequest>,
    barrier_writes: u64,
}

impl State {
    fn probe(&self) -> Probe {
        Probe {
            invocations: self.invocations.clone(),
            returns: self.returns.clone(),
            commits_entered: self.commits_entered.clone(),
            steers: self.steers.clone(),
            cancels: self.cancels.clone(),
        }
    }

    fn command(&self, command_id: &str) -> Result<&Cmd> {
        self.commands
            .get(command_id)
            .ok_or_else(|| anyhow!("fixture_command_unknown: {command_id}"))
    }

    fn command_mut(&mut self, command_id: &str) -> Result<&mut Cmd> {
        self.commands
            .get_mut(command_id)
            .ok_or_else(|| anyhow!("fixture_command_unknown: {command_id}"))
    }

    fn run_command(&self, command_id: &str) -> RunCommand {
        let command = self
            .commands
            .get(command_id)
            .expect("fixture_command_declared");
        RunCommand {
            id: command.id.clone(),
            state_id: command.state_id.clone(),
            state_visit: command.state_visit,
            kind: command.kind,
            status: command.status,
            attempt: 1,
            attempt_token: command.attempt_token.clone(),
            binding_id: None,
            runtime_id: None,
            entry: None,
            item_id: command.item_id.clone(),
            session_policy: Default::default(),
            binding_ordinal: 0,
            resume_session_id: None,
            input_digest: format!("digest-{}", command.id),
            input: RunSnapshot::empty("fixture", "fixture", "fixture").input,
            output_digest: None,
            failure_class: None,
            failure_code: None,
        }
    }

    fn snapshot(&self) -> RunSnapshot {
        let mut snapshot = RunSnapshot::empty(RUN, "fixture-definition", "fixture-semantics");
        snapshot.status = self.status;
        snapshot.sequence = self.sequence;
        for command_id in &self.declarations {
            let command = self.run_command(command_id);
            snapshot.commands.insert(command_id.clone(), command);
        }
        snapshot
    }
}

struct Inner {
    state: Mutex<State>,
    wake: Condvar,
}

/// The fixture: one object implementing both ports, sharing one observation log.
#[derive(Clone)]
pub struct Fixture {
    inner: Arc<Inner>,
}

impl Fixture {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Inner {
                state: Mutex::new(State {
                    order: Vec::new(),
                    sequence: 0,
                    status: StrategyRunStatus::Running,
                    declarations: Vec::new(),
                    commands: BTreeMap::new(),
                    gates: BTreeMap::new(),
                    scripts: BTreeMap::new(),
                    hook: None,
                    markers: BTreeMap::new(),
                    invocations: Vec::new(),
                    returns: Vec::new(),
                    running: 0,
                    peak_running: 0,
                    commits_entered: Vec::new(),
                    cancels: Vec::new(),
                    steers: Vec::new(),
                    confirmations: BTreeMap::new(),
                    violations: Vec::new(),
                    claims: Vec::new(),
                    barriers: BTreeMap::new(),
                    barrier_requests: Vec::new(),
                    barrier_writes: 0,
                }),
                wake: Condvar::new(),
            }),
        }
    }

    /// Declare one command, claimable once every predecessor has settled.
    ///
    /// One command of one ordinary node: its own state and one visit.
    pub fn declare(&self, command_id: &str, predecessors: &[&str]) {
        self.declare_command(
            command_id,
            &format!("node-{command_id}"),
            1,
            CommandKind::Actor,
            None,
            predecessors,
        );
    }

    /// Declare one item of a workset visit, as the machine emits it.
    ///
    /// Several items of one visit share `state_id` and `state_visit` and differ
    /// by their `item_id` and their command id. Readiness is the declared
    /// predecessor list, as in [`Self::declare`]; a workset item's real
    /// predecessor in the DAG is the command of the item it waits for.
    pub fn declare_item(
        &self,
        command_id: &str,
        state_id: &str,
        state_visit: u64,
        item_id: &str,
        predecessors: &[&str],
    ) {
        self.declare_command(
            command_id,
            state_id,
            state_visit,
            CommandKind::WorksetItem,
            Some(item_id),
            predecessors,
        );
    }

    fn declare_command(
        &self,
        command_id: &str,
        state_id: &str,
        state_visit: u64,
        kind: CommandKind,
        item_id: Option<&str>,
        predecessors: &[&str],
    ) {
        let mut state = self.lock();
        state.declarations.push(command_id.to_owned());
        state.commands.insert(
            command_id.to_owned(),
            Cmd {
                id: command_id.to_owned(),
                state_id: state_id.to_owned(),
                state_visit,
                kind,
                item_id: item_id.map(str::to_owned),
                predecessors: predecessors.iter().map(|id| (*id).to_owned()).collect(),
                status: CommandStatus::Pending,
                attempt_token: format!("token-{command_id}"),
                claimed_by: None,
                result_ref: None,
            },
        );
    }

    pub fn script(&self, command_id: &str, script: Script) {
        self.lock().scripts.insert(command_id.to_owned(), script);
    }

    /// A named gate. `commit:<command id>` gates that command's commit; any other
    /// name is a gate a script can wait on.
    pub fn gate(&self, name: &str) -> Arc<Gate> {
        let mut state = self.lock();
        Arc::clone(state.gates.entry(name.to_owned()).or_default())
    }

    pub fn set_adapter_hook(&self, hook: AdapterHook) {
        self.lock().hook = Some(hook);
    }

    /// What the fixture will answer when it is asked to cancel this command.
    pub fn confirm_cancel(&self, command_id: &str, confirmation: CancelConfirmation) {
        self.lock()
            .confirmations
            .insert(command_id.to_owned(), confirmation);
    }

    pub fn probe(&self) -> Probe {
        self.lock().probe()
    }

    /// Wait for an observation, failing loudly when it never arrives.
    pub fn wait_for(&self, label: &str, predicate: impl Fn(&Probe) -> bool) {
        let deadline = Instant::now() + WAIT;
        let mut state = self.lock();
        loop {
            if predicate(&state.probe()) {
                return;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                let probe = state.probe();
                panic!("fixture_wait_timed_out: {label} (observed {probe:?})");
            }
            let (guard, _) = self
                .inner
                .wake
                .wait_timeout(state, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            state = guard;
        }
    }

    pub fn order(&self) -> Vec<Step> {
        self.lock().order.clone()
    }

    /// Wait for a barrier publication, failing loudly when it never arrives.
    ///
    /// The predicate runs with the fixture's lock held, so it is handed the
    /// publications themselves rather than a handle it could take the lock
    /// again from.
    pub fn wait_for_barrier(&self, label: &str, predicate: impl Fn(&[BarrierRequest]) -> bool) {
        let deadline = Instant::now() + WAIT;
        let mut state = self.lock();
        loop {
            if predicate(&state.barrier_requests) {
                return;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                panic!(
                    "fixture_barrier_wait_timed_out: {label} (observed {:?})",
                    state.barrier_requests
                );
            }
            let (guard, _) = self
                .inner
                .wake
                .wait_timeout(state, remaining)
                .unwrap_or_else(PoisonError::into_inner);
            state = guard;
        }
    }
    pub fn violations(&self) -> Vec<String> {
        self.lock().violations.clone()
    }

    pub fn peak_running(&self) -> usize {
        self.lock().peak_running
    }

    pub fn sequence(&self) -> u64 {
        self.lock().sequence
    }

    pub fn status(&self) -> StrategyRunStatus {
        self.lock().status
    }

    pub fn command_status(&self, command_id: &str) -> CommandStatus {
        self.lock().commands[command_id].status
    }

    pub fn result_ref(&self, command_id: &str) -> Option<String> {
        self.lock().commands[command_id].result_ref.clone()
    }

    pub fn claims(&self) -> Vec<(String, String)> {
        self.lock().claims.clone()
    }

    pub fn cancels(&self) -> Vec<(String, String)> {
        self.lock().cancels.clone()
    }

    pub fn steers(&self) -> Vec<(String, String)> {
        self.lock().steers.clone()
    }

    /// The claimant this fixture handed the claim to, or `None` if it never did.
    pub fn claimant_of(&self, command_id: &str) -> Option<String> {
        self.lock().commands[command_id].claimed_by.clone()
    }

    /// Take a live claim away, the way another owner taking it over would.
    pub fn lose_lease(&self, command_id: &str) {
        let mut state = self.lock();
        if let Some(command) = state.commands.get_mut(command_id) {
            command.claimed_by = None;
        }
    }

    /// Publish a barrier directly, as an owner outside this drive would.
    pub fn publish_barrier(
        &self,
        scope: BarrierScope,
        kind: BarrierKind,
        reason: &str,
    ) -> AdmissionBarrier {
        ScopeBarrierPort::publish(
            self,
            &BarrierRequest {
                scope,
                kind,
                reason: reason.to_owned(),
                recipients: Vec::new(),
            },
        )
        .expect("fixture_barrier_publish")
    }

    /// The barrier in force for a scope, as a reader would see it.
    pub fn barrier_in_force(&self, scope: &BarrierScope) -> Option<AdmissionBarrier> {
        ScopeBarrierPort::barrier(self, scope).expect("fixture_barrier_read")
    }

    /// Every barrier publication this fixture accepted, in order.
    pub fn barrier_requests(&self) -> Vec<BarrierRequest> {
        self.lock().barrier_requests.clone()
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.inner
            .state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
    }

    fn notify(&self) {
        self.inner.wake.notify_all();
    }

    fn event_name(event: &ReducerEvent) -> &'static str {
        match event {
            ReducerEvent::CommandStarted { .. } => "command_started",
            ReducerEvent::CommandSucceeded { .. } => "command_succeeded",
            ReducerEvent::CommandFailed { .. } => "command_failed",
            ReducerEvent::CancelRequested => "cancel_requested",
            ReducerEvent::CancellationAcknowledged { .. } => "cancellation_acknowledged",
            ReducerEvent::CancellationUnknown { .. } => "cancellation_unknown",
            _ => "unmodelled",
        }
    }

    fn command_of(event: &ReducerEvent) -> Option<String> {
        match event {
            ReducerEvent::CommandStarted { command_id, .. }
            | ReducerEvent::CommandSucceeded { command_id, .. }
            | ReducerEvent::CommandFailed { command_id, .. }
            | ReducerEvent::CancellationAcknowledged { command_id, .. }
            | ReducerEvent::CancellationUnknown { command_id, .. } => Some(command_id.clone()),
            _ => None,
        }
    }

    fn run_hook(&self, operation: &str, command_id: &str) {
        let hook = self.lock().hook.clone();
        if let Some(hook) = hook {
            // Deliberately without the fixture's lock: a hook that asks the
            // fixture something must not deadlock the test harness.
            hook(operation, command_id);
        }
    }

    fn begin_invocation(&self, command_id: &str) -> Script {
        let script = {
            let mut state = self.lock();
            if !state.markers.contains_key(command_id) {
                state
                    .violations
                    .push(format!("fixture_invoked_before_marker: {command_id}"));
            }
            state.invocations.push(command_id.to_owned());
            state.order.push(Step::Invoked {
                command_id: command_id.to_owned(),
            });
            state.running = state.running.saturating_add(1);
            state.peak_running = state.peak_running.max(state.running);
            state
                .scripts
                .get(command_id)
                .cloned()
                .unwrap_or(Script::Succeed)
        };
        self.notify();
        script
    }

    fn finish_invocation(&self, command_id: &str) {
        {
            let mut state = self.lock();
            state.running = state.running.saturating_sub(1);
            state.order.push(Step::InvocationEnded {
                command_id: command_id.to_owned(),
            });
        }
        self.notify();
    }

    fn success_outcome(command_id: &str, attempt_token: &str) -> EffectOutcome {
        EffectOutcome::Succeeded {
            result: ReducerEvent::CommandSucceeded {
                command_id: command_id.to_owned(),
                attempt_token: attempt_token.to_owned(),
                output: RunSnapshot::empty("fixture", "fixture", "fixture").input,
            },
        }
    }
}

/// The node visit a fixture command belongs to. The fixture names a command's
/// node `node-<command id>`, at visit 1.
pub fn node_of(command_id: &str) -> NodeVisitKey {
    NodeVisitKey::new(format!("node-{command_id}"), 1)
}

impl Default for Fixture {
    fn default() -> Self {
        Self::new()
    }
}

/// Ends an invocation however it ends, a panic included.
struct Invocation {
    fixture: Fixture,
    command_id: String,
}

impl Invocation {
    fn return_now(&self) {
        {
            let mut state = self.fixture.lock();
            state.returns.push(self.command_id.clone());
            state.order.push(Step::Returned {
                command_id: self.command_id.clone(),
            });
        }
        self.fixture.notify();
    }
}

impl Drop for Invocation {
    fn drop(&mut self) {
        self.fixture.finish_invocation(&self.command_id);
    }
}

impl StatePort for Fixture {
    fn checkpoint(&self, _run_id: &str) -> Result<RunSnapshot> {
        Ok(self.lock().snapshot())
    }

    fn commit(
        &self,
        _run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
    ) -> Result<RunSnapshot> {
        // A test may gate one command's commit, which is how it holds the drive
        // loop at a known point. The gate is waited on with no lock held.
        let gated = Self::command_of(&event);
        if let Some(command_id) = &gated {
            let gate = {
                let mut state = self.lock();
                match state.gates.get(&format!("commit:{command_id}")).cloned() {
                    Some(gate) if !gate.is_open() => {
                        state.commits_entered.push(command_id.clone());
                        Some(gate)
                    }
                    _ => None,
                }
            };
            if let Some(gate) = gate {
                self.notify();
                gate.wait();
            }
        }
        let mut state = self.lock();
        ensure!(
            state.sequence == expected_sequence,
            "fixture_stale_sequence: expected {expected_sequence}, store at {}",
            state.sequence
        );
        let name = Self::event_name(&event);
        match &event {
            ReducerEvent::CommandStarted {
                command_id,
                attempt_token,
            } => {
                let current = state.command(command_id)?.status;
                ensure!(
                    matches!(current, CommandStatus::Pending | CommandStatus::Claimed),
                    "fixture_illegal_transition: {command_id} started from {current:?}"
                );
                let command = state.command_mut(command_id)?;
                ensure!(
                    command.attempt_token == *attempt_token,
                    "fixture_attempt_token_mismatch: {command_id}"
                );
                command.status = CommandStatus::Running;
            }
            ReducerEvent::CommandSucceeded {
                command_id,
                attempt_token,
                ..
            } => {
                // The machine only settles a running command, so the fixture
                // refuses anything else: a driver that settled a claimed,
                // cancelled, or already settled command is wrong here too.
                let current = state.command(command_id)?.status;
                ensure!(
                    current == CommandStatus::Running,
                    "fixture_illegal_transition: {command_id} succeeded from {current:?}"
                );
                let command = state.command_mut(command_id)?;
                ensure!(
                    command.attempt_token == *attempt_token,
                    "fixture_attempt_token_mismatch: {command_id}"
                );
                command.status = CommandStatus::Succeeded;
                command.result_ref = Some(format!("result-{command_id}"));
            }
            ReducerEvent::CommandFailed {
                command_id,
                attempt_token,
                class,
                code,
            } => {
                let current = state.command(command_id)?.status;
                ensure!(
                    matches!(
                        current,
                        CommandStatus::Pending | CommandStatus::Claimed | CommandStatus::Running
                    ),
                    "fixture_illegal_transition: {command_id} failed from {current:?}"
                );
                ensure!(
                    !code.is_empty()
                        && code.len() <= 96
                        && code.chars().all(|character| character.is_ascii_lowercase()
                            || character.is_ascii_digit()
                            || matches!(character, '-' | '_')),
                    "fixture_failure_code_invalid: {code}"
                );
                let command = state.command_mut(command_id)?;
                ensure!(
                    command.attempt_token == *attempt_token,
                    "fixture_attempt_token_mismatch: {command_id}"
                );
                command.status = if *class == FailureClass::InDoubt {
                    CommandStatus::InDoubt
                } else {
                    CommandStatus::Failed
                };
            }
            ReducerEvent::CancelRequested => {
                // The machine's own rule: what has not started is cancelled, what
                // is running is asked to stop, and the run only parks in
                // `CancelRequested` when something is still in flight.
                let mut in_flight = false;
                for command in state.commands.values_mut() {
                    match command.status {
                        CommandStatus::Pending
                        | CommandStatus::Claimed
                        | CommandStatus::Retryable => command.status = CommandStatus::Cancelled,
                        CommandStatus::Running => {
                            command.status = CommandStatus::CancelRequested;
                            in_flight = true;
                        }
                        CommandStatus::CancelRequested => in_flight = true,
                        _ => {}
                    }
                }
                state.status = if in_flight {
                    StrategyRunStatus::CancelRequested
                } else {
                    StrategyRunStatus::Cancelled
                };
            }
            ReducerEvent::CancellationAcknowledged { command_id, .. } => {
                let current = state.command(command_id)?.status;
                ensure!(
                    current == CommandStatus::CancelRequested,
                    "fixture_illegal_transition: {command_id} acknowledged from {current:?}"
                );
                state.command_mut(command_id)?.status = CommandStatus::Cancelled;
                settled_status(&mut state);
            }
            ReducerEvent::CancellationUnknown { command_id, .. } => {
                let current = state.command(command_id)?.status;
                ensure!(
                    current == CommandStatus::CancelRequested,
                    "fixture_illegal_transition: {command_id} unknown from {current:?}"
                );
                state.command_mut(command_id)?.status = CommandStatus::InDoubt;
                // The machine parks the run here rather than calling it
                // cancelled: an unconfirmed cancellation is not a cancellation.
                state.status = StrategyRunStatus::CancelInDoubt;
            }
            other => state
                .violations
                .push(format!("fixture_event_not_modelled: {other:?}")),
        }
        state.sequence = state.sequence.saturating_add(1);
        state.order.push(Step::Committed {
            command_id: gated,
            event: name,
        });
        let snapshot = state.snapshot();
        drop(state);
        self.notify();
        Ok(snapshot)
    }

    fn claim_next(
        &self,
        _run_id: &str,
        claimant: &str,
        _lease_until_unix_ms: i64,
    ) -> Result<Option<RunCommand>> {
        let mut state = self.lock();
        let ready = state
            .declarations
            .iter()
            .find(|command_id| {
                let command = &state.commands[*command_id];
                command.status == CommandStatus::Pending
                    && command.predecessors.iter().all(|predecessor| {
                        state
                            .commands
                            .get(predecessor)
                            .is_some_and(|predecessor| settled(predecessor.status))
                    })
            })
            .cloned();
        let Some(command_id) = ready else {
            return Ok(None);
        };
        state.claims.push((command_id.clone(), claimant.to_owned()));
        {
            let command = state.command_mut(&command_id)?;
            command.status = CommandStatus::Claimed;
            command.claimed_by = Some(claimant.to_owned());
        }
        let command = state.run_command(&command_id);
        drop(state);
        self.notify();
        Ok(Some(command))
    }

    fn renew_lease(
        &self,
        command_id: &str,
        claimant: &str,
        _lease_until_unix_ms: i64,
    ) -> Result<()> {
        let state = self.lock();
        let command = state.command(command_id)?;
        ensure!(
            command.claimed_by.as_deref() == Some(claimant),
            "fixture_lease_not_held: {command_id} is held by {:?}, not {claimant}",
            command.claimed_by
        );
        Ok(())
    }

    fn mark_started(
        &self,
        _run_id: &str,
        command_id: &str,
        attempt_token: &str,
    ) -> Result<RunSnapshot> {
        let mut state = self.lock();
        let current = state.command(command_id)?.status;
        ensure!(
            matches!(current, CommandStatus::Claimed | CommandStatus::Pending),
            "fixture_illegal_transition: {command_id} marked from {current:?}"
        );
        state.sequence = state.sequence.saturating_add(1);
        let sequence = state.sequence;
        {
            let command = state.command_mut(command_id)?;
            ensure!(
                command.attempt_token == attempt_token,
                "fixture_attempt_token_mismatch: {command_id}"
            );
            command.status = CommandStatus::Running;
        }
        state.markers.insert(command_id.to_owned(), sequence);
        state.order.push(Step::Marker {
            command_id: command_id.to_owned(),
        });
        let snapshot = state.snapshot();
        drop(state);
        self.notify();
        Ok(snapshot)
    }

    fn result_ref(&self, _run_id: &str, command_id: &str) -> Result<Option<String>> {
        Ok(self.lock().commands[command_id].result_ref.clone())
    }
}

impl EffectPort for Fixture {
    fn submit(&self, request: &EffectRequest) -> Result<EffectOutcome> {
        let command_id = request.command_id().to_owned();
        let attempt_token = request.attempt_token().to_owned();
        let script = self.begin_invocation(&command_id);
        let invocation = Invocation {
            fixture: self.clone(),
            command_id: command_id.clone(),
        };
        self.run_hook("submit", &command_id);
        let outcome = match script {
            Script::Succeed => Ok(Self::success_outcome(&command_id, &attempt_token)),
            Script::Hold(gate) => {
                gate.wait();
                Ok(Self::success_outcome(&command_id, &attempt_token))
            }
            Script::Fail { class, code } => Ok(EffectOutcome::Failed { class, code }),
            Script::Unknown { code } => Ok(EffectOutcome::Unknown { code }),
            Script::Error(detail) => Err(anyhow!("{detail}")),
            Script::Panic => panic!("fixture_effect_panicked"),
            Script::Misreport => Ok(EffectOutcome::Succeeded {
                result: ReducerEvent::CommandSucceeded {
                    command_id: "not-the-dispatched-command".to_owned(),
                    attempt_token,
                    output: RunSnapshot::empty("fixture", "fixture", "fixture").input,
                },
            }),
        };
        invocation.return_now();
        outcome
    }

    fn cancel(&self, request: &CancelRequest) -> Result<CancelConfirmation> {
        let command_id = request.command_id.clone();
        let confirmation = {
            let mut state = self.lock();
            state
                .cancels
                .push((request.control_request_id.clone(), command_id.clone()));
            state
                .confirmations
                .get(&command_id)
                .cloned()
                .unwrap_or(CancelConfirmation::Unsupported)
        };
        self.notify();
        self.run_hook("cancel", &command_id);
        Ok(confirmation)
    }

    fn steer(&self, request: &SteerRequest) -> Result<()> {
        let command_id = request.command_id.clone();
        {
            let mut state = self.lock();
            state
                .steers
                .push((request.control_request_id.clone(), command_id.clone()));
        }
        self.notify();
        self.run_hook("steer", &command_id);
        Ok(())
    }
}

/// The fixture as a barrier owner: an in-process store for the durable fence
/// a pause or stop writes.
///
/// The write is one step here, as C03 requires: the barrier and the recipients
/// it froze are stored together and answer with one position. What this fixture
/// deliberately does not model is a resume clearing a pause, or a stop refusing
/// to be cleared — those are the barrier owner's own rules, tested where that
/// owner lives.
impl ScopeBarrierPort for Fixture {
    fn publish(&self, request: &BarrierRequest) -> Result<AdmissionBarrier> {
        let mut state = self.lock();
        state.barrier_writes = state.barrier_writes.saturating_add(1);
        let barrier = AdmissionBarrier {
            scope: request.scope.clone(),
            kind: request.kind,
            reason: request.reason.clone(),
            recipients: request.recipients.clone(),
            written_at: state.barrier_writes,
        };
        state
            .barriers
            .insert(request.scope.clone(), barrier.clone());
        state.barrier_requests.push(request.clone());
        drop(state);
        self.notify();
        Ok(barrier)
    }

    fn barrier(&self, scope: &BarrierScope) -> Result<Option<AdmissionBarrier>> {
        Ok(self.lock().barriers.get(scope).cloned())
    }
}

/// A drive running on its own thread, collected under a bound.///
/// A drive that deadlocks must fail its test rather than hang the suite, which is
/// why the report comes back through a bounded receive instead of a bare join.
pub struct Driving {
    result: Receiver<Result<DriveReport, String>>,
    handle: JoinHandle<()>,
}

impl Driving {
    pub fn report(self) -> DriveReport {
        let outcome = self
            .result
            .recv_timeout(WAIT)
            .expect("driving_did_not_finish_within_the_bound");
        self.handle.join().expect("drive thread panicked");
        outcome.unwrap_or_else(|error| panic!("drive failed: {error}"))
    }

    /// Collect a drive that is expected to fail, with its error text.
    pub fn failure(self) -> String {
        let outcome = self
            .result
            .recv_timeout(WAIT)
            .expect("driving_did_not_finish_within_the_bound");
        self.handle.join().expect("drive thread panicked");
        match outcome {
            Ok(report) => panic!("expected the drive to fail, got {report:?}"),
            Err(error) => error,
        }
    }
}

/// Start a drive on its own thread.
pub fn drive_in_background(driver: Arc<Driver>) -> Driving {
    let (sender, result) = std::sync::mpsc::channel();
    let handle = std::thread::spawn(move || {
        let outcome = driver.drive(RUN).map_err(|error| error.to_string());
        let _ = sender.send(outcome);
    });
    Driving { result, handle }
}

/// A driver over one fixture, owning its own run registry.
pub fn driver(fixture: &Fixture, limits: DriverLimits) -> Arc<Driver> {
    Arc::new(
        Driver::new(
            Arc::new(fixture.clone()),
            Arc::new(fixture.clone()),
            OwnerId::new("host-a"),
            limits,
        )
        .expect("driver"),
    )
}

/// A driver over one fixture that is also its barrier owner.
pub fn driver_with_barrier(fixture: &Fixture, limits: DriverLimits) -> Arc<Driver> {
    Arc::new(
        Driver::new(
            Arc::new(fixture.clone()),
            Arc::new(fixture.clone()),
            OwnerId::new("host-a"),
            limits,
        )
        .expect("driver")
        .with_barrier(Arc::new(fixture.clone())),
    )
}

/// A limited-capacity drive: the shape most of these tests want.
pub fn limits(max_in_flight: usize) -> DriverLimits {
    DriverLimits {
        max_in_flight,
        ..DriverLimits::default()
    }
}

/// Wait until a running drive's own queue depths satisfy a condition.
///
/// The driver's channel depths are the only place a test can name the moment a
/// result path is backed up, which is what keeps the control-path test free of
/// timing guesses.
pub fn wait_for_queue(
    driver: &Driver,
    label: &str,
    predicate: impl Fn(&licoup_workflow_runtime::driver::DriveQueue) -> bool,
) -> licoup_workflow_runtime::driver::DriveQueue {
    let deadline = Instant::now() + WAIT;
    loop {
        // `None` means the drive thread has not registered yet (or has already
        // finished), which is a state to wait out rather than a failure.
        let queued = driver.queued(RUN);
        if let Some(queued) = queued
            && predicate(&queued)
        {
            return queued;
        }
        if Instant::now() >= deadline {
            panic!("fixture_queue_wait_timed_out: {label} (observed {queued:?})");
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// Mirror of the machine's own rule: once a cancellation is acknowledged and
/// nothing is left running, the run is cancelled.
fn settled_status(state: &mut State) {
    if state.commands.values().all(|command| {
        !matches!(
            command.status,
            CommandStatus::Running | CommandStatus::CancelRequested
        )
    }) {
        state.status = StrategyRunStatus::Cancelled;
    }
}

fn settled(status: CommandStatus) -> bool {
    matches!(
        status,
        CommandStatus::Succeeded
            | CommandStatus::Failed
            | CommandStatus::Cancelled
            | CommandStatus::InDoubt
    )
}
