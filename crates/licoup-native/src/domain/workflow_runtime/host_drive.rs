//! V7-I1: the production drive, owned by the runtime's continuous driver.
//!
//! Before this module the host drove runs itself: `StrategyService::drive_run`
//! claimed a whole batch of commands, joined them, and only then committed the
//! outcomes. The runtime side of the extraction (V7-R1) replaced that shape with
//! a driver that advances *per completion*, and V7-S1/S2 put the durable state
//! behind consumer-owned ports. This module is where those pieces meet the real
//! host: it composes
//!
//! ```text
//!   StrategyService (definitions, authorizations, effects, projections)
//!        │  invoke per claimed command (no commit)
//!        ▼
//!   licoup-workflow-runtime::driver::Driver
//!        │  StatePort  = RecoveryAssembly::fenced_state()
//!        │  EffectPort = the production command invocation
//!        │  barrier    = the controlled store's durable pause/stop tables
//!        ▼
//!   strategies.sqlite3 — the same file the production store has always written
//! ```
//!
//! Three properties are the point of the exercise:
//!
//! 1. **One owner.** Every drive takes its run through the driver's ownership
//!    fence, and the claim it presents to the store is the fenced
//!    `owner#generation` string. Two hosts, or two entry points in one process,
//!    cannot drive one run at the same time.
//! 2. **Advance per completion.** A successor becomes claimable as soon as its
//!    predecessor's outcome is committed; an effect still running cannot hold
//!    its siblings' successors back. The old batch join is gone.
//! 3. **The marker is committed before the effect.** `mark_started` is the
//!    driver's own call, so "recovery may treat a started-but-uncommitted
//!    command as in doubt" is a property of the loop rather than a convention
//!    the effect path has to remember.
//!
//! The drive reads its durable state through the store's recovery assembly, so
//! the checkpoint it advances is admitted by the same rules recovery uses: a
//! checkpoint this build must hand off is not reinterpreted as current
//! lowering. It leaves the run exactly where it is, and the successor path —
//! not a drive — decides what happens next.
//!
//! ## What is observed, and why
//!
//! The production host has work that happens *after* a transition commits:
//! the numeric Graph usage ledger, the Conversation projection of an actor's
//! result, retry/fallback issuance, and the Assistant's fail-once rule. The new
//! store commits through [`StatePort`], which has no observer argument, so
//! [`ProductionStatePort`] wraps the fenced state: it reads the checkpoint before
//! the commit, delegates the commit, and then hands the committed transition to
//! the service's own post-commit work. An observer error is logged and never
//! rolls the commit back — the durable facts are already written, and the
//! service's accounting repairs itself on the next transition.
//!
//! ## What is deliberately not here
//!
//! The delivery side (V7-R3's assembly, lane router and durable notice intents)
//! is not wired yet: this module writes no `NoticeRequest`, so no notice is
//! acknowledged on a lane's behalf. The legacy transition-intent observer still
//! runs through the service's post-commit pass, which is the same wake the host
//! used before; moving that wake onto the notice outbox is the follow-up wiring
//! step and is reported as not done rather than implied.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use crate::platform::work_context_ports::ControlDisposition;
use anyhow::{Result, anyhow};
use licoup_workflow::compile::{
    DefinitionRevision, InterpreterProfile, LoweringCapabilities, PlanKey, RecordedPlanKey,
};
use licoup_workflow::{
    CompiledWorkflow, FailureClass, ReducerEvent, RunCommand, RunSnapshot, WorkflowDefinition,
};
use licoup_workflow_runtime::admission::{
    AdmissionBarrier, BarrierKind, BarrierRequest, BarrierScope, ScopeBarrierPort,
};
use licoup_workflow_runtime::driver::{
    CancelConfirmation, CancelRequest, DriveReport, Driver, DriverError, DriverLimits,
    EffectOutcome, EffectPort, EffectRequest, OwnerId, RunOwnership, SteerRequest,
};
use licoup_workflow_runtime::node::NodeVisitKey;
use licoup_workflow_runtime::plan_cache::{PlanCache, PlanCompileError};
use licoup_workflow_runtime::ports::Notice;
use licoup_workflow_runtime::ports::NoticeSink;
use licoup_workflow_runtime::ports::{
    AuthorityPort, AuthorityRecheck, AuthorizationRef, StatePort,
};
use licoup_workflow_runtime::routing::lane::{LanePolicy, LaneWeights};
use licoup_workflow_runtime::successor::handoff::{
    ClaimAdmission, HandoffOutcome, LiveAttempt, SuccessorManifest, SuccessorPort, UnstartedIntent,
};
use licoup_workflow_runtime::successor::recovery::{
    CheckpointAdmission, EffectBoundary, RecoveryCause, RecoveryPort, RecoveryRequest,
};
use licoup_workflow_store::deliveries::{DeliveryAssembly, ReconcileReport, RetryPolicy};
use licoup_workflow_store::recovery::{RecoveryAssembly, StoreSuccessor};
use licoup_workflow_store::transactions::{StoreStatePort, WorkflowDatabase};
use rusqlite::OptionalExtension;
use serde_json::Value;

use crate::domain::workflow_runtime::authority_adapter::{
    BarrierKind as NativeBarrierKind, BarrierRequest as NativeBarrierRequest,
    BarrierScope as NativeBarrierScope, GrantVerdict, StoreAuthorityAdapter, StoreScopeBarrier,
};
use crate::domain::workflow_store::StrategyStore;

use super::service::StrategyService;

/// Read-only access to a runtime already admitted and held by the continuity
/// host. The callback never constructs, registers or replaces a runtime.
pub type ContinuityOwnerLookup = dyn Fn(
        &str,
        &str,
    ) -> Option<(
        licoup_agent_runtime::work_context::NativeWorkContextKey,
        Arc<licoup_agent_runtime::work_context::WorkContextRuntime>,
    )> + Send
    + Sync;

/// The root-scoped production bridge source. Membership and native-session
/// identity come from the same Conversation store that the continuity host
/// owns; the runtime itself is borrowed from that host, preserving Arc identity
/// and therefore its writer exclusion against non-workflow callers.
pub struct ContinuityEffectSessions {
    store: crate::domain::client_conversation::ConversationStore,
    lookup: Arc<ContinuityOwnerLookup>,
}

impl ContinuityEffectSessions {
    /// Resolve only from this root's existing host and current native binding.
    /// The placeholder matter/generation are never forwarded to an owner: the
    /// returned key always comes from the host registry.
    pub fn borrow_for(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> Option<super::service::EffectSessionHandles> {
        super::service::EffectSessionSource::handles(
            self,
            &licoup_agent_runtime::work_context::NativeWorkContextKey {
                conversation_id: conversation_id.to_owned(),
                membership_id: membership_id.to_owned(),
                matter_id: String::new(),
                generation: 0,
            },
        )
    }

    /// Borrow the owner registry from the already-open root service. This must
    /// not open another ConversationService: that would attach another host.
    pub fn from_service(
        service: &crate::domain::client_conversation::ConversationService,
    ) -> Option<Self> {
        let host = Arc::clone(service.continuity()?);
        Some(Self::new(
            service.store().clone(),
            Arc::new(move |conversation, membership| {
                host.workflow_runtime_for(conversation, membership)
            }),
        ))
    }

    pub fn new(
        store: crate::domain::client_conversation::ConversationStore,
        lookup: Arc<ContinuityOwnerLookup>,
    ) -> Self {
        Self { store, lookup }
    }
}

impl super::service::EffectSessionSource for ContinuityEffectSessions {
    fn governs(&self, conversation_id: Option<&str>) -> Result<bool> {
        let Some(conversation_id) = conversation_id.filter(|id| !id.is_empty()) else {
            return Ok(false);
        };
        // Ordinary conversations keep their existing turn owner. A child work
        // relation selects continuity ownership even if its runtime is missing:
        // in that case handles() refuses rather than opening a second owner.
        licoup_conversation::continuity::read_relation_for_child(&self.store, conversation_id)
            .map(|relation| relation.is_some())
            .map_err(|_| anyhow!("workflow_continuity_scope_unavailable"))
    }

    fn handles(
        &self,
        requested: &licoup_agent_runtime::work_context::NativeWorkContextKey,
    ) -> Option<super::service::EffectSessionHandles> {
        let conversation = self.store.get(&requested.conversation_id).ok()?;
        let membership = conversation.memberships.iter().find(|membership| {
            membership.id == requested.membership_id
                && membership.status == crate::domain::client_conversation::MembershipStatus::Active
        })?;
        let agent_id = membership.principal.agent_id.as_ref()?.clone();
        let (session, owner) = (self.lookup)(&requested.conversation_id, &requested.membership_id)?;
        if session.conversation_id != requested.conversation_id
            || session.membership_id != requested.membership_id
        {
            return None;
        }
        // This is the owner's persisted native binding, not a historical
        // catalog entry or a synthetic session id derived from a run.
        let binding = self
            .store
            .private_runtime_binding(&session.conversation_id, &session.membership_id)
            .ok()??;
        if binding.runtime_session_id.trim().is_empty() {
            return None;
        }
        let live_writer = owner.live_control(&session).ok()?.is_some();
        Some(super::service::EffectSessionHandles {
            session,
            agent_id,
            live_writer,
            owner,
            profiles: Arc::new(crate::platform::strategy_runtime::RuntimeRegistryAgentProfiles),
            dispatch: Arc::new(crate::platform::strategy_runtime::LaneEffectDispatch),
            fresh_native_session: Some(binding.runtime_session_id),
        })
    }
}

/// Bytes of retained lowered-plan identity one process keeps.
const PLAN_CACHE_BYTES: usize = 8 * 1024 * 1024;

/// The process-wide cache of lowered plans.
///
/// Every production load lowers through this cache — the host's own reads in
/// `workflow_store` and the drive's admission here — so a definition is compiled
/// once per process instead of once per transition. One cache serves the
/// build's current interpreter profile, and every entry is keyed by the full
/// plan identity (definition revision, compiler and engine semantics, declared
/// lowering capabilities), so a plan can never be served to a definition that a
/// different lowering produced.
pub(crate) fn plan_cache() -> &'static PlanCache {
    static CACHE: OnceLock<PlanCache> = OnceLock::new();
    CACHE.get_or_init(|| {
        PlanCache::new(
            InterpreterProfile::current(LoweringCapabilities::none()),
            PLAN_CACHE_BYTES,
        )
    })
}

/// The typed plan key one definition revision binds under this build.
pub(crate) fn plan_key_for_revision(revision_digest: &str) -> Result<PlanKey> {
    let revision = DefinitionRevision::from_wire(revision_digest)
        .map_err(|error| anyhow!("workflow_definition_revision_invalid: {error}"))?;
    Ok(plan_cache().profile().key_for(revision))
}

/// Lower one definition through the process cache.
///
/// The lowering runs at most once per plan identity; concurrent callers of the
/// same definition wait for that one lowering and share its `Arc`.
pub(crate) fn compiled_definition(workflow: &WorkflowDefinition) -> Result<Arc<CompiledWorkflow>> {
    let revision = DefinitionRevision::of(workflow)
        .map_err(|error| anyhow!("workflow_definition_revision_invalid: {error}"))?;
    let key = plan_cache().profile().key_for(revision);
    let definition = workflow.clone();
    plan_cache()
        .plan(&key, move || {
            licoup_workflow::compile_workflow(definition)
                .map(Arc::new)
                .map_err(|failure| PlanCompileError::from_failure(&failure))
        })
        .map_err(|error| anyhow!("workflow_plan_unavailable: {error}"))
}

/// How many times one `run_drive` call may restart the driver after a stop that
/// is not terminal: an authorization that just became resolvable, or a drive
/// budget that ran out with work left. A fence or a terminal status ends the
/// call; this bound keeps a pathological run from looping forever inside one
/// entry call.
const MAX_DRIVE_ROUNDS: usize = 8;

/// Effects one drive call may start. The old loop's per-call budget, kept so a
/// host call still yields at the same points it did before.
const MAX_EFFECTS_PER_DRIVE: usize = 512;

/// Notice obligations one pass carries.
const NOTICE_BUDGET: usize = 32;
/// How long a notice claim is held before another pass may take it.
const NOTICE_LEASE_MS: i64 = 30_000;
/// Retry backoff for a failed obligation.
const NOTICE_RETRY_BASE_MS: i64 = 1_000;
const NOTICE_RETRY_MAX_MS: i64 = 60_000;

/// The host fence every drive from this process presents.
///
/// A handoff names the *host*, not one of its generations: the successor may
/// restart or run several generations, and the fence must still admit it while
/// refusing the host it took the run from.
pub(crate) fn host_owner() -> String {
    format!("licoup-host-{}", std::process::id())
}

/// What a run's ownership looked like to a starting host.
pub(crate) enum OwnershipStart {
    /// No live owner: the run is this host's to drive.
    Free,
    /// A committed transfer gave the run to this host.
    TakenOver,
    /// A live owner holds the run and the transfer did not happen. Nothing may
    /// be started.
    Refused,
}

/// Decide who owns the run before any drive work starts.
///
/// A live foreign owner means the run has not been given to this host. The
/// successor handoff is the only way in: the manifest is built from the durable
/// boundary (revision, unstarted and live sets) and the store accepts or
/// refuses it whole. A refusal leaves the run exactly where it is — the old
/// owner may settle what it started, and this host starts nothing.
///
/// With no live foreign owner there is no transfer to make; the legacy
/// abandoned-host recovery applies to whatever the previous process left.
pub(crate) fn prepare_ownership(
    database: &Arc<WorkflowDatabase>,
    recovery: &RecoveryAssembly,
    run_id: &str,
) -> Result<OwnershipStart> {
    let owner = host_owner();
    let (live, lapsed) = foreign_claim_owners(database, run_id, &owner, now_unix_ms())?;
    if let Some(live_owner) = live {
        // A live writer has not agreed to anything. A new fence row is not
        // evidence that it will read it: the old generation may never consult
        // this table, so committing a transfer here would presume cooperation
        // the host does not have, and both writers could act. The run stays
        // with its owner and this host starts nothing.
        log::warn!("workflow_successor_live_owner: {run_id} {live_owner}");
        return Ok(OwnershipStart::Refused);
    }
    let Some(old_owner) = lapsed else {
        // No durable claim at all: the run is this host's to continue.
        return Ok(OwnershipStart::Free);
    };
    let state = StoreStatePort::new(database.clone());
    let successor = recovery.successor();
    if let Some(record) = successor.successor_of(run_id)? {
        // A transfer is already in force. If it names this host, the run is
        // ours; if it names someone else, the claim fence will say so.
        return Ok(if record.new_owner == owner {
            OwnershipStart::TakenOver
        } else {
            log::debug!("workflow_successor_fenced: {run_id} {}", record.new_owner);
            OwnershipStart::Refused
        });
    }
    let manifest = partner_manifest(database, &state, run_id, &owner, &old_owner)?;
    match successor.handoff(&manifest)? {
        HandoffOutcome::Committed { receipt } => {
            log::info!(
                "workflow_successor_committed: {} migrated {} kept {}",
                receipt.run_id,
                receipt.migrated.len(),
                receipt.started.len()
            );
            Ok(OwnershipStart::TakenOver)
        }
        HandoffOutcome::Refused { refusal } => {
            log::warn!("workflow_successor_refused: {run_id} {refusal:?}");
            Ok(OwnershipStart::Refused)
        }
    }
}

/// The process-wide ownership registry.
///
/// Shared so that two entry points in one process cannot drive one run even
/// though each builds its own driver: the driver's in-process fence is only a
/// fence if the registry is shared.
fn run_ownership() -> &'static Arc<RunOwnership> {
    static OWNERSHIP: OnceLock<Arc<RunOwnership>> = OnceLock::new();
    OWNERSHIP.get_or_init(|| Arc::new(RunOwnership::new()))
}

/// The drivers currently driving, so a control request from another entry
/// point finds the drive that would take it.
fn active_drivers() -> &'static Mutex<BTreeMap<String, Arc<Driver>>> {
    static DRIVERS: OnceLock<Mutex<BTreeMap<String, Arc<Driver>>>> = OnceLock::new();
    DRIVERS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

/// The driver currently holding `run_id`, if any.
///
/// A control request uses this instead of writing the run's cancellation fact
/// itself: the durable `CancelRequested` has to be committed by the same owner
/// that holds the run, or it would race the drive's own compare-and-set.
pub(crate) fn active_driver(run_id: &str) -> Option<Arc<Driver>> {
    let drivers = active_drivers()
        .lock()
        .unwrap_or_else(PoisonError::into_inner);
    drivers.get(run_id).cloned()
}

/// What one invoked command proved.
///
/// The effect port turns this into the driver's [`EffectOutcome`]; nothing here
/// commits anything, because the commit belongs to the drive.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum CommandVerdict {
    /// The effect happened; the output is what the machine's success event
    /// carries.
    Succeeded {
        output: serde_json::Value,
        group_streamed: bool,
    },
    /// The effect failed, with the class its adapter chose.
    Failed { class: FailureClass, code: String },
    /// An Assistant-owned run failed. The run fails as a whole, so the driver
    /// is told the failure is in doubt (it must not be retried by the generic
    /// path) and the service records the authentic Assistant event after the
    /// commit.
    AssistantFailed { class: FailureClass, code: String },
}

/// One production drive over one run.
struct HostDrive {
    service: StrategyService,
    run_id: String,
    database: Arc<WorkflowDatabase>,
    recovery: RecoveryAssembly,
    owner: OwnerId,
    limits: DriverLimits,
}

impl HostDrive {
    /// Assemble the drive over the production database.
    ///
    /// Returns `Ok(None)` when this build must not advance the run's
    /// checkpoint: a semantics handoff or a refused checkpoint is the successor
    /// path's decision, not something to reinterpret as current lowering.
    fn open(service: &StrategyService, run_id: &str) -> Result<Option<Self>> {
        let database = Arc::new(WorkflowDatabase::open(service.store().db_path())?);
        let recovery = RecoveryAssembly::assemble(database.clone())?;
        match recovery.recovery().checkpoint_admission(run_id)? {
            CheckpointAdmission::Advance => {}
            CheckpointAdmission::Handoff { reason } => {
                // A checkpoint this build cannot admit is the successor path's
                // decision, never something to reinterpret as current lowering.
                log::info!("workflow_checkpoint_handoff: {run_id} {reason:?}");
                return Ok(None);
            }
            CheckpointAdmission::Refused { code } => {
                log::warn!("workflow_checkpoint_refused: {run_id} {code}");
                return Ok(None);
            }
        }
        // Version selection at the drive entry: the run's revision is typed and
        // asked against this build's interpreter profile. A revision this build
        // cannot lower is refused rather than lowered by a compiler that is not
        // the one the run was recorded under.
        let run = service.store().run(run_id)?;
        let key = plan_key_for_revision(&run.definition_digest)?;
        if let Err(refusal) = plan_cache().profile().lowerable(&key) {
            log::warn!("workflow_plan_not_lowerable: {run_id} {refusal}");
            return Ok(None);
        }
        let limits = DriverLimits {
            max_in_flight: licoup_workflow::MAX_ACTIVE_EFFECTS,
            max_effects_per_drive: MAX_EFFECTS_PER_DRIVE,
            ..DriverLimits::default()
        };
        limits
            .validate()
            .map_err(|error| anyhow!(error.to_string()))?;
        Ok(Some(Self {
            service: service.clone(),
            run_id: run_id.to_owned(),
            database,
            recovery,
            owner: OwnerId::new(format!("licoup-host-{}", std::process::id())),
            limits,
        }))
    }

    /// The workflow database this drive reads and advances.
    fn database(&self) -> &Arc<WorkflowDatabase> {
        &self.database
    }

    /// Drive one run to the end of this call's work.
    fn run(&self) -> Result<DriveReport, DriverError> {
        self.recover()?;
        let state = Arc::new(ProductionStatePort {
            inner: StoreStatePort::new(self.database.clone()),
            successor: self.recovery.successor(),
            database: self.database.clone(),
            service: self.service.clone(),
            owner: host_owner(),
        });
        let effect = Arc::new(ProductionEffectPort {
            service: self.service.clone(),
            database: self.database.clone(),
        });
        let barrier = Arc::new(ProductionBarrierPort {
            run_id: self.run_id.clone(),
            barriers: StoreScopeBarrier::new(self.service.store().clone()),
        });
        let driver = Arc::new(
            Driver::with_ownership(
                state,
                effect,
                self.owner.clone(),
                self.limits,
                Arc::clone(run_ownership()),
            )?
            .with_barrier(barrier),
        );
        {
            let mut drivers = active_drivers()
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            drivers.insert(self.run_id.clone(), Arc::clone(&driver));
        }
        let report = driver.drive(&self.run_id);
        {
            let mut drivers = active_drivers()
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            if drivers
                .get(&self.run_id)
                .is_some_and(|current| Arc::ptr_eq(current, &driver))
            {
                drivers.remove(&self.run_id);
            }
        }
        report
    }

    /// Classify the run's outstanding attempts before the driver starts.
    ///
    /// This is V7-S2's recovery decision applied where the drive begins: a
    /// claim without the possible-effect marker is retried through the machine,
    /// a started attempt is held, and a live lease is never taken. It replaces
    /// the old loop's `recover_expired_commands`, which could only see the
    /// production store's own lease reading.
    fn recover(&self) -> Result<(), DriverError> {
        let recovery = self.recovery.recovery();
        let request = RecoveryRequest {
            run_id: self.run_id.clone(),
            cause: RecoveryCause::LeaseLapsed,
            now_unix_ms: now_unix_ms(),
        };
        recovery
            .sweep(&request)
            .map_err(DriverError::Port)
            .map(|_| ())
    }
}

/// Run one production drive, restarting it only for stops that carry new work.
pub(crate) fn run_drive(service: &StrategyService, run_id: &str) -> Result<()> {
    let t0 = std::time::Instant::now();
    let drive = HostDrive::open(service, run_id)?;
    let _ = t0;
    let Some(drive) = drive else {
        return Ok(());
    };
    // A run resumed after a crash delivers what its previous process committed
    // before this drive starts claiming new work.
    if let Err(error) =
        reconcile_notices(service, drive.database(), &host_claimant(), NOTICE_BUDGET)
    {
        log::warn!("workflow_notice_reconcile_failed: {error:#}");
    }
    let authority = authority_port(service.store());
    for _ in 0..MAX_DRIVE_ROUNDS {
        let report = drive.run().map_err(|error| anyhow!(error.to_string()))?;
        match report.stop {
            licoup_workflow_runtime::driver::DriveStop::Terminal { .. } => return Ok(()),
            licoup_workflow_runtime::driver::DriveStop::AwaitingAuthorization => {
                // The runtime-owned authority port answers whether a grant is
                // in force at all; the host then decides whether the gate can
                // be satisfied (a pending authorization command, or a
                // revocable authority failure to retry). Without a grant the
                // run stays exactly where it is.
                let in_force = service
                    .store()
                    .run(run_id)
                    .ok()
                    .and_then(|snapshot| {
                        authority
                            .active_authorization(&snapshot.definition_digest)
                            .ok()
                            .flatten()
                    })
                    .is_some();
                if !in_force || !service.settle_run_authorization(run_id)? {
                    return Ok(());
                }
            }
            licoup_workflow_runtime::driver::DriveStop::Quiescent {
                budget_exhausted: true,
            } => {}
            // A fence or plain quiescence: another entry point resumes the run
            // when the fact that unblocks it arrives.
            _ => return Ok(()),
        }
    }
    Ok(())
}

/// The production `StatePort`: the fenced store, the successor take-over, and
/// the notice intents a committed fact owes.
///
/// Three things happen here that the raw store port does not do:
///
/// 1. **The fence.** A claim is refused while a handoff names another owner, so
///    an old owner may settle what it started but never start new work.
/// 2. **The take-over.** When a live foreign owner holds the run, the first
///    claim builds the successor manifest from the durable boundary (revision,
///    unstarted and live sets) and commits the transfer under this drive's own
///    claimant. A refusal transfers nothing and the drive stops.
/// 3. **The notices.** A fact that owes downstream acceptance records its
///    intent in the same transaction as the event, the checkpoint, and the
///    commands; delivery is a separate, independently acknowledged pass.
struct ProductionStatePort {
    inner: StoreStatePort,
    successor: StoreSuccessor,
    database: Arc<WorkflowDatabase>,
    service: StrategyService,
    /// The host fence this drive presents to the successor admission.
    owner: String,
}

/// The foreign owners one run's durable claims name, split by whether their
/// lease is live at `now`.
///
/// Both halves come from the claims themselves: a live lease is evidence of a
/// writer that may still be running, a lapsed one of a writer that stopped
/// without settling.
fn foreign_claim_owners(
    database: &WorkflowDatabase,
    run_id: &str,
    host: &str,
    now: i64,
) -> Result<(Option<String>, Option<String>)> {
    let rows = database.read(|connection| {
        let mut statement = connection.prepare(
            "SELECT DISTINCT lease_owner, CASE WHEN lease_until > ?2 THEN 1 ELSE 0 END
             FROM strategy_commands
             WHERE run_id=?1 AND lease_owner IS NOT NULL",
        )?;
        let rows = statement
            .query_map(rusqlite::params![run_id, now], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    })?;
    let collect = |live: bool| -> Option<String> {
        let mut owners = rows
            .iter()
            .filter(|(_, is_live)| (*is_live == 1) == live)
            .map(|(owner, _)| owner.clone())
            // Our own generations are not a foreign owner: a claim this host's
            // earlier drive took is ours to continue.
            .filter(|owner| owner.split('#').next().unwrap_or(owner) != host)
            .collect::<Vec<_>>();
        owners.sort();
        owners.dedup();
        match owners.as_slice() {
            // No owner of that kind, or several at once — several is not a
            // boundary a manifest can name, and guessing which one is real
            // would be worse than stopping.
            [] => None,
            [owner] => Some(owner.clone()),
            _ => Some(owners.join(",")),
        }
    };
    Ok((collect(true), collect(false)))
}

/// Build the manifest the store will accept or refuse whole.
fn partner_manifest(
    database: &WorkflowDatabase,
    state: &StoreStatePort,
    run_id: &str,
    new_owner: &str,
    old_owner: &str,
) -> Result<SuccessorManifest> {
    let snapshot = state.checkpoint(run_id)?;
    let key = plan_key_for_revision(&snapshot.definition_digest)?;
    let mut unstarted = Vec::new();
    let mut started = Vec::new();
    database.read(|connection| {
        let mut statement = connection.prepare(
            "SELECT command_id, attempt_token, status, command_json
             FROM strategy_commands
             WHERE run_id=?1 AND status IN ('pending', 'claimed', 'running',
                                            'retryable', 'cancel-requested')
             ORDER BY command_id ASC",
        )?;
        let rows = statement
            .query_map(rusqlite::params![run_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        for (command_id, attempt_token, status, command_json) in rows {
            let command: RunCommand = serde_json::from_str(&command_json)?;
            match status.as_str() {
                "pending" | "retryable" => unstarted.push(UnstartedIntent {
                    command_id,
                    attempt_token,
                    node_id: command.state_id.clone(),
                    node_visit: command.state_visit,
                }),
                "claimed" => started.push(LiveAttempt {
                    command_id,
                    attempt_token,
                    node_id: command.state_id.clone(),
                    node_visit: command.state_visit,
                    phase: EffectBoundary::Claimed,
                }),
                "running" | "cancel-requested" => started.push(LiveAttempt {
                    command_id,
                    attempt_token,
                    node_id: command.state_id.clone(),
                    node_visit: command.state_visit,
                    phase: EffectBoundary::Started,
                }),
                other => {
                    log::warn!("workflow_handoff_unknown_status: {other}");
                }
            }
        }
        Ok(())
    })?;
    Ok(SuccessorManifest {
        handoff_id: format!("successor:{run_id}:{}", snapshot.sequence),
        run_id: run_id.to_owned(),
        expected_revision: snapshot.sequence,
        old_owner: old_owner.to_owned(),
        new_owner: new_owner.to_owned(),
        old_binding: RecordedPlanKey::from(&key),
        new_owner_profile: plan_cache().profile().clone(),
        unstarted,
        started,
    })
}

impl StatePort for ProductionStatePort {
    fn checkpoint(&self, run_id: &str) -> Result<RunSnapshot> {
        self.inner.checkpoint(run_id)
    }

    fn commit(
        &self,
        run_id: &str,
        expected_sequence: u64,
        event: ReducerEvent,
    ) -> Result<RunSnapshot> {
        // The before view is read outside the write transaction: the commit
        // itself re-checks the sequence, so a stale read fails there rather
        // than being applied here.
        let before = self.inner.checkpoint(run_id)?;
        // An Assistant-owned run records an effect failure with the machine's
        // own `AssistantEffectFailed` event: the run fails as a whole, nothing
        // is retried, and no fallback is issued. The driver's verdict is
        // deliberately "in doubt" so its generic path stays out of the way;
        // translating it here puts the authentic event in the *same*
        // transaction and compare-and-set the driver intended.
        let event = match &event {
            ReducerEvent::CommandFailed {
                command_id,
                attempt_token,
                ..
            } if before.assistant_membership_id.is_some() => {
                match self
                    .service
                    .drive_runtime()
                    .take_assistant_failure(command_id)
                {
                    Some((class, code)) => ReducerEvent::AssistantEffectFailed {
                        command_id: command_id.clone(),
                        attempt_token: attempt_token.clone(),
                        class,
                        code,
                    },
                    None => event,
                }
            }
            _ => event,
        };
        // The notices a committed fact owes are decided from the transition
        // itself and committed with it, so a crash can lose delivery but never
        // the obligation.
        let notices = self.service.drive_notices(&before, &event);
        let committed =
            self.inner
                .commit_with_notices(run_id, expected_sequence, event.clone(), &notices)?;
        let after = committed.snapshot;
        if let Err(error) = self.service.after_drive_commit(&before, &event, &after) {
            log::warn!("workflow_post_commit_failed: {error}");
        }
        // The obligation is durable; this pass is what carries it to its
        // owners. A failed pass leaves the notice pending for the next one.
        if let Err(error) = reconcile_notices(
            &self.service,
            &self.database,
            &host_claimant(),
            NOTICE_BUDGET,
        ) {
            log::warn!("workflow_notice_reconcile_failed: {error:#}");
        }
        // Post-commit work may have advanced the run; the freshest checkpoint
        // is what keeps the driver's next compare-and-set current.
        match self.inner.checkpoint(run_id) {
            Ok(snapshot) => Ok(snapshot),
            Err(_) => Ok(after),
        }
    }

    fn claim_next(
        &self,
        run_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<Option<RunCommand>> {
        // The fence is asked at host granularity: a committed handoff names the
        // host that took the run, and this drive presents one of that host's
        // generations. An owner whose host differs is refused — it may settle
        // what it started, but never start new work.
        match self.successor.claim_admission(run_id, &self.owner) {
            Ok(ClaimAdmission::Admitted) => {}
            Ok(ClaimAdmission::Fenced {
                handoff_id,
                new_owner,
            }) => {
                log::debug!(
                    "workflow_successor_fenced: {run_id} {handoff_id} {new_owner} {claimant}"
                );
                return Ok(None);
            }
            Err(error) => return Err(error),
        }
        let claimed = self.inner.claim_next(run_id, claimant, lease_until_unix_ms);
        claimed
    }

    fn renew_lease(
        &self,
        command_id: &str,
        claimant: &str,
        lease_until_unix_ms: i64,
    ) -> Result<()> {
        self.inner
            .renew_lease(command_id, claimant, lease_until_unix_ms)
    }

    fn mark_started(
        &self,
        run_id: &str,
        command_id: &str,
        attempt_token: &str,
    ) -> Result<RunSnapshot> {
        self.inner.mark_started(run_id, command_id, attempt_token)
    }

    fn result_ref(&self, run_id: &str, command_id: &str) -> Result<Option<String>> {
        self.inner.result_ref(run_id, command_id)
    }
}

/// The production `EffectPort`: one claimed command in, one verdict out.
struct ProductionEffectPort {
    service: StrategyService,
    database: Arc<WorkflowDatabase>,
}

impl EffectPort for ProductionEffectPort {
    fn submit(&self, request: &EffectRequest) -> Result<EffectOutcome> {
        // The claim the driver just took carries the fenced claimant in its
        // lease row. Reading it back is what lets the effect hold the same
        // one-shot permit the store issues, without the driver having to hand
        // its own identity to ports that must not own it.
        let claimant = lease_owner(&self.database, &request.command.id)?
            .ok_or_else(|| anyhow!("workflow_claimant_missing"))?;
        let verdict =
            self.service
                .invoke_claimed_command(&request.run_id, &request.command, &claimant)?;
        Ok(match verdict {
            CommandVerdict::Succeeded { output, .. } => EffectOutcome::Succeeded {
                result: ReducerEvent::CommandSucceeded {
                    command_id: request.command.id.clone(),
                    attempt_token: request.command.attempt_token.clone(),
                    output,
                },
            },
            CommandVerdict::Failed { class, code } => EffectOutcome::Failed { class, code },
            CommandVerdict::AssistantFailed { class, code } => {
                // An Assistant-owned run fails as a whole on any effect
                // failure, and the machine records that with its own event.
                // The driver cannot carry that event, so it is told the
                // outcome is in doubt — which stops the generic retry and
                // fallback path — and the service records the authentic
                // Assistant failure in its post-commit pass. The service
                // recorded the classified failure before returning the
                // verdict, so the correction is not reconstructed here.
                let _ = class;
                EffectOutcome::Failed {
                    class: FailureClass::InDoubt,
                    code,
                }
            }
        })
    }

    /// Ask the host's control surface to stop one in-flight turn.
    ///
    /// The answer is read for exactly what it states, in the lane's own control
    /// vocabulary: an accepted request is a fact about the request, never about
    /// the effect's fate, so the driver settles the attempt by its own outcome
    /// (or as cancellation-in-doubt). A transport failure has established no
    /// answer, so it may neither be called delivered nor treated as never
    /// asked. Only a surface that states the request never left the process may
    /// mean "not reached", and this driver has no such confirmation to give on
    /// its behalf.
    fn cancel(&self, request: &CancelRequest) -> Result<CancelConfirmation> {
        // A lane effect is controlled through the same bridge that admitted it:
        // the request's answer is the bridge's own honesty, and no answer of
        // its kind may claim the effect stopped.
        if let Some((bridge, handle)) = self
            .service
            .drive_runtime()
            .lane_effect(&request.command_id)
        {
            use crate::platform::work_context_ports::CancelOutcome;
            return Ok(match bridge.cancel(&handle) {
                CancelOutcome::Unavailable { .. } => CancelConfirmation::Unsupported,
                CancelOutcome::Requested { .. }
                | CancelOutcome::Unconfirmed { .. }
                | CancelOutcome::NotReached { .. }
                | CancelOutcome::AlreadyTerminal { .. } => CancelConfirmation::Unknown,
            });
        }
        let Some(control) = self.service.actor_control() else {
            // The host composed no control channel: that is a fact about this
            // host, not about the effect.
            return Ok(CancelConfirmation::Unsupported);
        };
        let Some((handle, params)) = self.service.drive_runtime().in_flight(&request.command_id)
        else {
            // The effect is not running under this host any more; its fate is
            // not something this call can establish.
            return Ok(CancelConfirmation::Unknown);
        };
        let mut control_params = params;
        control_params["turnHandle"] = Value::String(handle);
        control_params["commandId"] = Value::String(request.command_id.clone());
        let answer = match (control.cancel)(&control_params) {
            Ok(answer) => answer,
            Err(_) => {
                // The call failed after being attempted: no answer exists.
                return Ok(CancelConfirmation::Unknown);
            }
        };
        let disposition = control_disposition(&answer);
        Ok(match disposition {
            ControlDisposition::Unsupported => CancelConfirmation::Unsupported,
            ControlDisposition::NotDelivered => {
                // The surface established the request never left this process.
                // The driver has no "not delivered" answer of its own, and
                // claiming the effect stopped would be false, so the attempt
                // stays as it is and settles by its own outcome.
                CancelConfirmation::Unknown
            }
            ControlDisposition::Accepted
            | ControlDisposition::NoActiveTurn
            | ControlDisposition::SessionUnavailable => {
                // Reached the adapter; whether it stopped is unestablished.
                CancelConfirmation::Unknown
            }
            ControlDisposition::Unconfirmed => CancelConfirmation::Unknown,
        })
    }

    /// Deliver one steering instruction through the host's control surface.
    fn steer(&self, request: &SteerRequest) -> Result<()> {
        if let Some((bridge, handle)) = self
            .service
            .drive_runtime()
            .lane_effect(&request.command_id)
        {
            use crate::platform::work_context_ports::SteerOutcome;
            return match bridge.steer(&handle, &request.instruction) {
                SteerOutcome::Delivered { .. } => Ok(()),
                SteerOutcome::Unavailable { .. } => Err(anyhow!("effect_steer_unsupported")),
                SteerOutcome::Unconfirmed { .. } => Err(anyhow!("effect_steer_unconfirmed")),
                SteerOutcome::NotReached { .. } => Err(anyhow!("effect_steer_not_delivered")),
                SteerOutcome::AlreadyTerminal { .. } => Err(anyhow!("effect_already_terminal")),
                SteerOutcome::InvalidInstruction => Err(anyhow!("effect_steer_invalid")),
            };
        }
        let Some(control) = self.service.actor_control() else {
            return Err(anyhow!("effect_steer_unsupported"));
        };
        let Some((handle, params)) = self.service.drive_runtime().in_flight(&request.command_id)
        else {
            return Err(anyhow!("effect_not_in_flight"));
        };
        let mut control_params = params;
        control_params["turnHandle"] = Value::String(handle);
        control_params["text"] = Value::String(request.instruction.clone());
        let answer = (control.steer)(&control_params)
            .map_err(|error| anyhow!("effect_steer_failed: {error}"))?;
        match control_disposition(&answer) {
            ControlDisposition::Unsupported => Err(anyhow!("effect_steer_unsupported")),
            ControlDisposition::NotDelivered => Err(anyhow!("effect_steer_not_delivered")),
            _ => Ok(()),
        }
    }
}

/// The notice lanes this host serves.
///
/// A wake opens a turn and is served as control; an actor result is served as a
/// result; every master report is bulk. The classification is declared here
/// because this is the producer that knows what its kinds mean.
fn notice_lane_policy() -> Result<LanePolicy> {
    LanePolicy::new(
        [
            crate::domain::workflow_runtime::service::NOTICE_CALLBACK.to_owned(),
            crate::domain::workflow_runtime::service::NOTICE_TERMINAL.to_owned(),
            crate::domain::workflow_runtime::service::NOTICE_SETTLED.to_owned(),
        ],
        [crate::domain::workflow_runtime::service::NOTICE_RESULT_KIND.to_owned()],
        LaneWeights::equal(),
    )
}

/// The projection lane's sink: the Conversation timeline append.
struct ProjectionSink {
    service: StrategyService,
}

impl NoticeSink for ProjectionSink {
    fn accept(&self, notice: &Notice) -> Result<()> {
        self.service.deliver_notice_projection(notice)
    }
}

/// The wake lane's sink: one Assistant turn opener.
struct WakeSink {
    service: StrategyService,
}

impl NoticeSink for WakeSink {
    fn accept(&self, notice: &Notice) -> Result<()> {
        let result = self.service.deliver_notice_wake(notice);
        result
    }
}

/// Deliver every obligation whose owner is assembled here.
///
/// The assembly is the proof the lanes' tables exist; the router refuses a
/// second registration for one owner, so a host cannot swap the implementation
/// that accepted a fact halfway through. An owner with no sink is reported
/// `blocked` and its notices stay unacknowledged.
pub(crate) fn reconcile_notices(
    service: &StrategyService,
    database: &Arc<WorkflowDatabase>,
    claimant: &str,
    budget: usize,
) -> Result<ReconcileReport> {
    let assembly = DeliveryAssembly::assemble(database.clone())?;
    let mut router = assembly.router(
        notice_lane_policy()?,
        RetryPolicy::new(NOTICE_RETRY_BASE_MS, NOTICE_RETRY_MAX_MS)?,
    );
    router.register_sink(
        crate::domain::workflow_runtime::service::NOTICE_PROJECTION,
        Arc::new(ProjectionSink {
            service: service.clone(),
        }),
    )?;
    router.register_sink(
        crate::domain::workflow_runtime::service::NOTICE_WAKE,
        Arc::new(WakeSink {
            service: service.clone(),
        }),
    )?;
    router.reconcile(claimant, now_unix_ms(), NOTICE_LEASE_MS, budget)
}

/// The host identity a notice claim is taken under.
pub(crate) fn host_claimant() -> String {
    format!("licoup-host-{}", std::process::id())
}

/// Read a control answer for the fact it actually states.
///
/// The tokens are the ones the Conversation lane publishes for `cancel_turn` /
/// `steer_turn`. Only a surface that reports `not_delivered` has established
/// that the request never left the process; an unknown token, an empty status,
/// or a success flag contradicting the status is unconfirmed.
fn control_disposition(answer: &Value) -> ControlDisposition {
    let status = answer
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let ok = answer.get("ok").and_then(Value::as_bool);
    match (ok, status) {
        (Some(true), "cancel_requested" | "accepted" | "steer_requested") => {
            ControlDisposition::Accepted
        }
        (Some(false), "not_active" | "no_active_turn") => ControlDisposition::NoActiveTurn,
        (Some(false), "not_found" | "session_unavailable") => {
            ControlDisposition::SessionUnavailable
        }
        (Some(false), "unsupported") => ControlDisposition::Unsupported,
        (Some(false), "not_delivered") => ControlDisposition::NotDelivered,
        _ => ControlDisposition::Unconfirmed,
    }
}

/// The claimant a claim row holds for one command, if the row is live.
fn lease_owner(database: &WorkflowDatabase, command_id: &str) -> Result<Option<String>> {
    database.read(|connection| {
        let owner: Option<String> = connection
            .query_row(
                "SELECT lease_owner FROM strategy_commands WHERE command_id=?1",
                rusqlite::params![command_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(owner)
    })
}

/// The durable scope barrier over the production store's own tables.
struct ProductionBarrierPort {
    run_id: String,
    barriers: StoreScopeBarrier,
}

impl ProductionBarrierPort {
    /// The target key one visit uses in the durable tables.
    fn target_of(visit: &NodeVisitKey) -> String {
        format!("{}@{}", visit.state_id, visit.state_visit)
    }

    /// The recipients the durable pause/stop rows name, best-effort typed back.
    ///
    /// The durable tables store target keys, not visits, so a key that does not
    /// parse as one is reported for what it is rather than dropped: the
    /// barrier's `recipients` is informational, and its fence — the part
    /// admission reads — is the barrier itself.
    fn frozen_recipients(&self) -> Result<Vec<NodeVisitKey>> {
        let state = self.barriers.state(&self.run_id)?;
        Ok(state
            .pause_targets
            .iter()
            .chain(state.stop_targets.iter())
            .filter(|target| target.as_str() != "graph")
            .filter_map(|target| {
                target.rsplit_once('@').and_then(|(state_id, visit)| {
                    visit
                        .parse::<u64>()
                        .ok()
                        .map(|visit| NodeVisitKey::new(state_id, visit))
                })
            })
            .collect())
    }
}

impl ScopeBarrierPort for ProductionBarrierPort {
    fn publish(&self, request: &BarrierRequest) -> Result<AdmissionBarrier> {
        let (scope, targets) = match &request.scope {
            BarrierScope::Run(_) => (
                NativeBarrierScope::Graph,
                request
                    .recipients
                    .iter()
                    .map(Self::target_of)
                    .collect::<Vec<_>>(),
            ),
            BarrierScope::Node(visit) => (
                NativeBarrierScope::Node(Self::target_of(visit)),
                request
                    .recipients
                    .iter()
                    .map(Self::target_of)
                    .collect::<Vec<_>>(),
            ),
        };
        let published = self.barriers.publish(&NativeBarrierRequest {
            graph_id: self.run_id.clone(),
            scope,
            kind: match request.kind {
                BarrierKind::Pause => NativeBarrierKind::Pause,
                BarrierKind::Stop => NativeBarrierKind::Stop,
            },
            reason: request.reason.clone(),
            recipients: targets,
        })?;
        Ok(AdmissionBarrier {
            scope: request.scope.clone(),
            kind: request.kind,
            reason: request.reason.clone(),
            recipients: request.recipients.clone(),
            written_at: published.graph_revision.unwrap_or(0),
        })
    }

    fn barrier(&self, scope: &BarrierScope) -> Result<Option<AdmissionBarrier>> {
        if matches!(scope, BarrierScope::Node(_)) {
            // A node-scoped instruction acts on the recipients it froze; it
            // does not fence a new visit, so there is no run-scope barrier to
            // report for it.
            return Ok(None);
        }
        let state = self.barriers.state(&self.run_id)?;
        // The durable fence is `barrier_active`; the pause and stop target rows
        // are the same tables the controlled store writes, so a pause admitted
        // through any host control surface is visible here — a graph pause
        // admitted through the legacy proxy writes the pause row and not the
        // barrier flag, and it still fences new visits through this read.
        let stopped = state.stop_targets.contains("graph");
        let paused = state.pause_targets.contains("graph");
        let (kind, reason) = if stopped {
            (BarrierKind::Stop, "stop_requested")
        } else if state.barrier_active || paused {
            (BarrierKind::Pause, "pause_requested")
        } else {
            return Ok(None);
        };
        Ok(Some(AdmissionBarrier {
            scope: BarrierScope::Run(self.run_id.clone()),
            kind,
            reason: reason.to_owned(),
            recipients: self.frozen_recipients()?,
            written_at: state.graph_revision.unwrap_or(0),
        }))
    }
}

/// The store's authorization owner behind the runtime's `AuthorityPort`.
///
/// The production admission boundary still asks the typed native adapter (it
/// carries the *reason* a recheck refused, which the run records). This
/// implementation is the same owner behind the port the runtime declares, so a
/// runtime consumer does not have to know the native shape.
pub(crate) struct ProductionAuthorityPort {
    authority: StoreAuthorityAdapter,
}

impl AuthorityPort for ProductionAuthorityPort {
    fn active_authorization(&self, revision_digest: &str) -> Result<Option<AuthorizationRef>> {
        Ok(self
            .authority
            .active_grant(revision_digest)?
            .map(|grant| AuthorizationRef {
                authorization_digest: grant.authorization_digest,
                semantics_digest: grant.semantics_digest,
            }))
    }

    fn recheck(&self, request: &AuthorityRecheck) -> Result<bool> {
        let verdict = self
            .authority
            .recheck(&super::authority_adapter::GrantRecheck {
                run_id: request.run_id.clone(),
                expected_authorization_digest: request.expected_authorization_digest.clone(),
                expected_semantics_digest: request.expected_semantics_digest.clone(),
            })?;
        Ok(matches!(verdict, GrantVerdict::Covered { .. }))
    }
}

/// Open the runtime-owned authority port over the production store.
pub(crate) fn authority_port(store: &StrategyStore) -> ProductionAuthorityPort {
    ProductionAuthorityPort {
        authority: StoreAuthorityAdapter::new(store.clone()),
    }
}

fn now_unix_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}
