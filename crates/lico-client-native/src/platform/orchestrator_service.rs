//! Persistent single-instance owner-private orchestrator service lifecycle.

use super::{
    file_security,
    orchestrator_ipc::{
        MAX_FRAME_BYTES, OrchestratorIpcError, OrchestratorIpcHandler, OrchestratorIpcReceipt,
        OrchestratorIpcRequest, OrchestratorIpcServer, OrchestratorIpcServerConfig,
        PROTOCOL_VERSION,
        client::{
            DiscoveryRecord, PrivateCapabilityBootstrap, capability_bootstrap_path, discovery_path,
            endpoint_from_discovery, read_discovery, short_runtime_dir, write_frame,
        },
    },
};
use crate::domain::agent_orchestration::{
    ArtifactRef, CrashBoundary, CrashBoundaryInjector, DispatchOutcome, DispatchPort,
    EngineErrorCode, EngineLimits, ExternalDriveStep, PersistentWorkflowEngine, PolicyDocument,
    StepState, WorkflowCommand, WorkflowEvent, WorkflowSnapshot, WorkflowState,
    store::{DurableWorkflowStore, StoreLimits},
};
use anyhow::{Result, anyhow};
use fs2::FileExt;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet, hash_map::Entry},
    fs::{self, OpenOptions},
    io::{self, Read},
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

#[cfg(unix)]
use std::os::unix::{
    fs::OpenOptionsExt,
    net::{UnixListener, UnixStream},
};

const DISCOVERY_MAX_BYTES: usize = 512;
const MAX_WORKFLOWS: usize = 1024;
const MUTATION_LANES: usize = 32;

#[path = "orchestrator_service/artifact_store.rs"]
mod artifact_store;
#[path = "orchestrator_service/governed_dispatch.rs"]
mod governed_dispatch;
#[path = "orchestrator_service/local_bridge.rs"]
mod local_bridge;
#[path = "orchestrator_service/test_support.rs"]
#[cfg(debug_assertions)]
pub mod test_support;
// DeterministicGovernedDispatchRegistration is a debug-only downstream seam.

pub use artifact_store::PrivateArtifactStore;

#[derive(Clone, Debug)]
pub struct OrchestratorServiceOptions {
    pub state_root: PathBuf,
    pub ready_file: Option<PathBuf>,
    pub acceptance_control_root: Option<PathBuf>,
}

#[derive(Clone, Debug)]
pub struct OrchestratorServiceFailure {
    pub code: &'static str,
}

pub struct OrchestratorServiceLifecycle;
impl OrchestratorServiceLifecycle {
    pub fn discover_or_start(
        state_root: &Path,
    ) -> std::result::Result<(), OrchestratorServiceFailure> {
        if service_is_discoverable(state_root) {
            return Ok(());
        }
        let mut executable = std::env::current_exe().map_err(|_| OrchestratorServiceFailure {
            code: "service_unavailable",
        })?;
        if executable.file_stem().and_then(|value| value.to_str()) != Some("lico-client") {
            executable.set_file_name(format!("lico-client{}", std::env::consts::EXE_SUFFIX));
        }
        if !executable.is_file() {
            return Err(OrchestratorServiceFailure {
                code: "service_unavailable",
            });
        }
        std::process::Command::new(executable)
            .args([
                "orchestrator",
                "serve",
                "--autostarted",
                "--background-service",
                "--owner-private",
            ])
            .env_clear()
            .env("LICO_ARC_STATE_ROOT", state_root)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|_| OrchestratorServiceFailure {
                code: "service_unavailable",
            })?;
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if service_is_discoverable(state_root) {
                return Ok(());
            }
            thread::sleep(Duration::from_millis(20));
        }
        Err(OrchestratorServiceFailure {
            code: "service_unavailable",
        })
    }
    pub fn serve_foreground(
        options: OrchestratorServiceOptions,
    ) -> std::result::Result<(), OrchestratorServiceFailure> {
        run_service(options)
    }
    pub fn rotate() -> String {
        uuid::Uuid::new_v4().simple().to_string()
    }
    pub fn drain(shared: &ServiceShared) {
        shared.draining.store(true, Ordering::Release);
    }
    pub fn stop(shared: &ServiceShared) {
        shared.stopped.store(true, Ordering::Release);
    }
}

pub fn default_orchestrator_state_root() -> Result<PathBuf> {
    if let Some(value) = std::env::var_os("LICO_ARC_STATE_ROOT") {
        // Autostart clears the child environment before providing this single
        // owner-private bootstrap value. Reading it is process-global-state safe;
        // the control-plane service never forwards its environment to workers.
        let path = PathBuf::from(value);
        if !path.is_absolute() || path.as_os_str().as_encoded_bytes().len() > 4096 {
            return Err(anyhow!("orchestrator state bootstrap is invalid"));
        }
        return Ok(path);
    }
    super::paths::portable_data_dir()
}

fn service_is_discoverable(state_root: &Path) -> bool {
    let Ok(record) = read_discovery(state_root) else {
        return false;
    };
    let Ok(endpoint) = endpoint_from_discovery(state_root, &record) else {
        return false;
    };
    #[cfg(unix)]
    {
        UnixStream::connect(endpoint).is_ok()
    }
    #[cfg(not(unix))]
    {
        let _ = endpoint;
        false
    }
}

#[derive(Clone)]
struct Capabilities {
    workflow: String,
    status_only: String,
    lifecycle: String,
}
impl Capabilities {
    fn issue() -> Self {
        Self {
            workflow: opaque_handle(),
            status_only: opaque_handle(),
            lifecycle: opaque_handle(),
        }
    }
    fn operations(&self, handle: &str) -> Option<HashSet<String>> {
        let values: &[&str] = if constant_time_eq(handle, &self.workflow) {
            &[
                "workflow.submit",
                "workflow.preview",
                "policy.register",
                "policy.activate",
                "workflow.status",
                "workflow.cancel",
                "workflow.approve",
                "workflow.events",
                "workflow.wait",
                "workflow.message",
                "service.status",
            ]
        } else if constant_time_eq(handle, &self.status_only) {
            &["service.status"]
        } else if constant_time_eq(handle, &self.lifecycle) {
            &["service.status", "service.stop"]
        } else {
            return None;
        };
        Some(values.iter().map(|value| (*value).to_owned()).collect())
    }
}

fn opaque_handle() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}
fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.bytes()
        .zip(right.bytes())
        .fold(0_u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

#[derive(Default)]
struct Diagnostics {
    transport_closed: u64,
    pre_handler_rejected: u64,
    last_error_code: Option<&'static str>,
}

pub struct ServiceShared {
    draining: AtomicBool,
    stopped: AtomicBool,
    active: AtomicUsize,
    wait: (Mutex<()>, Condvar),
    admissions: Mutex<HashSet<String>>,
    diagnostics: Mutex<Diagnostics>,
}

impl Default for ServiceShared {
    fn default() -> Self {
        Self {
            draining: AtomicBool::new(false),
            stopped: AtomicBool::new(false),
            active: AtomicUsize::new(0),
            wait: (Mutex::new(()), Condvar::new()),
            admissions: Mutex::new(HashSet::new()),
            diagnostics: Mutex::new(Diagnostics::default()),
        }
    }
}

#[derive(Clone)]
struct ServiceHandler {
    shared: Arc<ServiceShared>,
    engine: Arc<Mutex<PersistentWorkflowEngine>>,
    dispatch: Arc<dyn DispatchPort>,
    artifacts: Arc<PrivateArtifactStore>,
    bridge: Arc<local_bridge::LocalBridge>,
    async_runtime: Arc<tokio::runtime::Runtime>,
    drive_permits: Arc<tokio::sync::Semaphore>,
    scheduled_workflows: Arc<Mutex<HashMap<String, bool>>>,
    mutations: Arc<AtomicUsize>,
    mutation_lanes: Arc<MutationLanes>,
    service_instance_id: Arc<str>,
    endpoint_generation: Arc<str>,
}

impl ServiceHandler {
    fn new(
        shared: Arc<ServiceShared>,
        service_instance_id: String,
        endpoint_generation: String,
        state_root: &Path,
    ) -> std::result::Result<Self, &'static str> {
        let store = DurableWorkflowStore::open_after_exclusive_process_lock(
            state_root,
            StoreLimits::default(),
        )
        .map_err(engine_error_code)?;
        let artifacts =
            Arc::new(PrivateArtifactStore::open(state_root).map_err(|_| "service_unavailable")?);
        let bridge = Arc::new(local_bridge::LocalBridge::default());
        let dispatch = selected_dispatch_port(Arc::clone(&artifacts), Arc::clone(&bridge));
        let worker_threads = std::thread::available_parallelism()
            .map(usize::from)
            .unwrap_or(4)
            .clamp(2, 8);
        let async_runtime = Arc::new(
            tokio::runtime::Builder::new_multi_thread()
                .worker_threads(worker_threads)
                .max_blocking_threads(32)
                .enable_time()
                .thread_name("lico-local-bridge")
                .build()
                .map_err(|_| "service_unavailable")?,
        );
        let engine = PersistentWorkflowEngine::open_active(
            store,
            Arc::clone(&dispatch),
            Arc::new(SystemClock),
            Arc::new(NoCrash),
            EngineLimits {
                max_events_per_page: 256,
                ..EngineLimits::default()
            },
        )
        .map_err(engine_error_code)?;
        Ok(Self {
            shared,
            engine: Arc::new(Mutex::new(engine)),
            dispatch,
            artifacts,
            bridge,
            async_runtime,
            drive_permits: Arc::new(tokio::sync::Semaphore::new(32)),
            scheduled_workflows: Arc::new(Mutex::new(HashMap::new())),
            mutations: Arc::new(AtomicUsize::new(0)),
            mutation_lanes: Arc::new(MutationLanes::default()),
            service_instance_id: service_instance_id.into(),
            endpoint_generation: endpoint_generation.into(),
        })
    }
    fn status_result(&self) -> Value {
        let diagnostics = self
            .shared
            .diagnostics
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let mut admissions = self
            .shared
            .admissions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .cloned()
            .collect::<Vec<_>>();
        admissions.sort();
        json!({
            "state": "running",
            "serviceInstanceId": self.service_instance_id.as_ref(),
            "endpointGeneration": self.endpoint_generation.as_ref(),
            "transportDiagnostics": {
                "transportClosed": diagnostics.transport_closed,
                "preHandlerRejected": diagnostics.pre_handler_rejected,
                "handlerMutations": self.mutations.load(Ordering::Acquire),
                "lastErrorCode": diagnostics.last_error_code,
            },
            "admissionDiagnostics": { "inFlightAdmissionIds": admissions }
            ,"localBridge": {
                "level": "bidirectional",
                "waitMode": "wakeable",
                "nativeFirst": true,
                "fallback": "interrupt_then_exact_session_resume",
                "maxConcurrentDispatches": 32,
                "maxPendingMessagesPerWorkflow": local_bridge::MAX_PENDING_MESSAGES,
                "maxLiveEventsPerWorkflow": local_bridge::MAX_BRIDGE_EVENTS,
                "maxWaitMs": local_bridge::MAX_WAIT_MS,
            }
        })
    }

    fn recover_and_drive(&self) -> std::result::Result<(), &'static str> {
        let snapshots = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .recover_all()
            .map_err(engine_error_code)?;
        for snapshot in snapshots {
            self.bridge.register_workflow(&snapshot.workflow_id);
            if snapshot.state.is_terminal() {
                self.bridge.mark_workflow_state(
                    &snapshot.workflow_id,
                    state_name(snapshot.state),
                    true,
                );
                continue;
            }
            if snapshot.steps.iter().any(|step| {
                matches!(
                    step.state,
                    StepState::Dispatching | StepState::Running | StepState::Validating
                )
            }) {
                let fence = self
                    .engine
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .owner_fence();
                let receipt = self
                    .engine
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .terminalize_unproven_active(
                        &snapshot.workflow_id,
                        &format!("recovery-unknown-{fence}-{}", snapshot.workflow_id),
                    )
                    .map_err(engine_error_code)?;
                if let Some(receipt) = receipt {
                    self.bridge.mark_workflow_state(
                        &receipt.workflow_id,
                        state_name(receipt.state),
                        receipt.state.is_terminal(),
                    );
                }
            } else {
                self.spawn_drive(snapshot.workflow_id);
            }
        }
        Ok(())
    }

    fn spawn_drive(&self, workflow_id: String) {
        let should_spawn = {
            let mut scheduled = self
                .scheduled_workflows
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            match scheduled.entry(workflow_id.clone()) {
                Entry::Occupied(mut entry) => {
                    *entry.get_mut() = true;
                    false
                }
                Entry::Vacant(entry) => {
                    entry.insert(false);
                    true
                }
            }
        };
        if !should_spawn {
            return;
        }
        let engine = Arc::clone(&self.engine);
        let dispatch = Arc::clone(&self.dispatch);
        let bridge = Arc::clone(&self.bridge);
        let permits = Arc::clone(&self.drive_permits);
        let scheduled = Arc::clone(&self.scheduled_workflows);
        let permit = BackgroundPermit::new(Arc::clone(&self.shared));
        self.async_runtime.spawn(async move {
            let mut scheduled_guard = ScheduledWorkflowGuard {
                workflows: Arc::clone(&scheduled),
                workflow_id: workflow_id.clone(),
                registered: true,
            };
            let Ok(concurrency_permit) = permits.acquire_owned().await else {
                return;
            };
            let _ = tokio::task::spawn_blocking(move || {
                let _permit = permit;
                let _concurrency_permit = concurrency_permit;
                loop {
                    drive_workflow_once(&engine, &dispatch, &bridge, &workflow_id);
                    if !scheduled_guard.finish_or_rerun() {
                        break;
                    }
                }
            })
            .await;
        });
    }
}

struct ScheduledWorkflowGuard {
    workflows: Arc<Mutex<HashMap<String, bool>>>,
    workflow_id: String,
    registered: bool,
}

impl ScheduledWorkflowGuard {
    fn finish_or_rerun(&mut self) -> bool {
        let mut workflows = self
            .workflows
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if workflows.get(&self.workflow_id).copied() == Some(true) {
            workflows.insert(self.workflow_id.clone(), false);
            return true;
        }
        workflows.remove(&self.workflow_id);
        self.registered = false;
        false
    }
}

impl Drop for ScheduledWorkflowGuard {
    fn drop(&mut self) {
        if self.registered {
            self.workflows
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .remove(&self.workflow_id);
        }
    }
}

fn drive_workflow_once(
    engine: &Arc<Mutex<PersistentWorkflowEngine>>,
    dispatch: &Arc<dyn DispatchPort>,
    bridge: &Arc<local_bridge::LocalBridge>,
    workflow_id: &str,
) {
    let fence = engine
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .owner_fence();
    for sequence in 0..=MAX_WORKFLOWS {
        let key = format!("drive-{workflow_id}-{fence}-{sequence}");
        let prepared = {
            let locked = engine.lock().unwrap_or_else(|error| error.into_inner());
            match locked.prepare_external_drive_step(workflow_id, &key) {
                Ok(ExternalDriveStep::Quiescent(receipt)) => {
                    bridge.mark_workflow_state(
                        workflow_id,
                        state_name(receipt.state),
                        receipt.state.is_terminal(),
                    );
                    return;
                }
                Ok(ExternalDriveStep::Progressed(receipt)) => {
                    bridge.mark_workflow_state(
                        workflow_id,
                        state_name(receipt.state),
                        receipt.state.is_terminal(),
                    );
                    continue;
                }
                Ok(ExternalDriveStep::Ready(prepared)) => prepared,
                Err(EngineErrorCode::TerminalState | EngineErrorCode::InvalidCommand) => return,
                Err(_) => return,
            }
        };
        let mut attempt = 1u32;
        let outcome = loop {
            let out = dispatch.dispatch(prepared.request.clone());
            let retryable = matches!(
                out,
                DispatchOutcome::KnownFailure {
                    retryable: true,
                    ..
                }
            );
            if retryable && attempt < prepared.max_attempts {
                attempt += 1;
                continue;
            }
            break out;
        };
        let receipt = engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .record_dispatch_outcome(
                workflow_id,
                &prepared.step_id,
                prepared.owner_fence,
                outcome,
            );
        let Ok(receipt) = receipt else { return };
        bridge.mark_workflow_state(
            workflow_id,
            state_name(receipt.state),
            receipt.state.is_terminal(),
        );
    }
}

impl OrchestratorIpcHandler for ServiceHandler {
    fn handle(&self, request: &OrchestratorIpcRequest) -> OrchestratorIpcReceipt {
        let mutation_binding = mutation_lane_scope(request);
        let mutation_lane =
            mutation_binding.map(|(scope, key)| self.mutation_lanes.index(scope, key));
        let _mutation_guard = mutation_lane.map(|lane| {
            self.mutation_lanes.lanes[lane]
                .lock()
                .unwrap_or_else(|error| error.into_inner())
        });
        let command_binding = request.idempotency_key.as_deref().map(|key| {
            let scope = format!("{}:{key}", request.method);
            let digest = format!(
                "{:x}",
                Sha256::digest(serde_json::to_vec(&request.params).unwrap_or_default())
            );
            (scope, digest)
        });
        if let Some((scope, digest)) = command_binding.as_ref()
            && let Ok(Some((stored_digest, encoded))) = self
                .engine
                .lock()
                .unwrap_or_else(|error| error.into_inner())
                .control_receipt(scope)
        {
            if stored_digest != *digest {
                return OrchestratorIpcReceipt::failure(
                    &request.request_id,
                    "idempotency_conflict",
                );
            }
            if let Ok(receipt) = serde_json::from_str(&encoded) {
                return receipt;
            }
        }
        let result = self.execute_request(request);
        let receipt = match result {
            Ok(value) => OrchestratorIpcReceipt::success(&request.request_id, value),
            Err(code) => OrchestratorIpcReceipt::failure(&request.request_id, code),
        };
        if receipt.ok
            && let Some((scope, digest)) = command_binding.as_ref()
        {
            if let Ok(encoded) = serde_json::to_string(&receipt) {
                let _ = self
                    .engine
                    .lock()
                    .unwrap_or_else(|error| error.into_inner())
                    .save_control_receipt(scope, digest, &encoded);
            }
            self.mutations.fetch_add(1, Ordering::AcqRel);
        }
        receipt
    }
    fn mutation_count(&self) -> usize {
        self.mutations.load(Ordering::Acquire)
    }
}

struct MutationLanes {
    lanes: [Mutex<()>; MUTATION_LANES],
}

impl Default for MutationLanes {
    fn default() -> Self {
        Self {
            lanes: std::array::from_fn(|_| Mutex::new(())),
        }
    }
}

impl MutationLanes {
    fn index(&self, scope: &str, key: &str) -> usize {
        let digest = Sha256::digest(format!("{scope}:{key}"));
        usize::from(digest[0]) % MUTATION_LANES
    }
}

fn mutation_lane_scope(request: &OrchestratorIpcRequest) -> Option<(&str, &str)> {
    if matches!(
        request.method.as_str(),
        "workflow.message" | "workflow.cancel" | "workflow.approve"
    ) {
        request
            .params
            .get("workflowId")
            .and_then(Value::as_str)
            .map(|workflow_id| ("workflow", workflow_id))
    } else {
        request
            .idempotency_key
            .as_deref()
            .map(|key| (request.method.as_str(), key))
    }
}

impl ServiceHandler {
    fn execute_request(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        match request.method.as_str() {
            "service.status" => Ok(self.status_result()),
            "service.stop" => Ok(json!({"state": "stopped"})),
            "policy.register" => self.register_policy(&request.params["policy"]),
            "policy.activate" => self.activate_policy(
                request.params["policyRevisionId"]
                    .as_str()
                    .unwrap_or_default(),
            ),
            "workflow.submit" => self.submit_workflow(request),
            "workflow.status" => {
                self.workflow_status(request.params["workflowId"].as_str().unwrap_or_default())
            }
            "workflow.events" => self.workflow_events(request),
            "workflow.wait" => self.workflow_wait(request),
            "workflow.message" => self.workflow_message(request),
            "workflow.cancel" => self.cancel_workflow(request),
            "workflow.approve" => self.approve_workflow(request),
            "workflow.preview" => Err("operation_forbidden"),
            _ => Err("unknown_method"),
        }
    }

    fn register_policy(&self, value: &Value) -> std::result::Result<Value, &'static str> {
        if value.get("schemaVersion").and_then(Value::as_u64) != Some(3) {
            return Err("policy_schema_unsupported");
        }
        let policy: PolicyDocument =
            serde_json::from_value(value.clone()).map_err(|_| "policy_schema_invalid")?;
        let revision = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .register_policy(policy)
            .map_err(|error| match error {
                EngineErrorCode::Compile => "policy_schema_invalid",
                _ => engine_error_code(error),
            })?;
        Ok(json!({"policyRevisionId": revision, "state": "registered"}))
    }

    fn activate_policy(&self, revision: &str) -> std::result::Result<Value, &'static str> {
        let activated = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .activate_policy(revision)
            .map_err(engine_error_code)?;
        if !activated {
            return Err("policy_revision_unavailable");
        }
        Ok(json!({"policyRevisionId": revision, "state": "active"}))
    }

    fn submit_workflow(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        let revision = request.params["policyRevisionId"]
            .as_str()
            .ok_or("invalid_request")?;
        let engine = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let policy = engine
            .registered_policy(revision)
            .map_err(engine_error_code)?
            .ok_or("policy_revision_unavailable")?;
        if !engine
            .policy_is_active(revision)
            .map_err(engine_error_code)?
        {
            return Err("policy_revision_inactive");
        }
        if engine.recover_all().map_err(engine_error_code)?.len() >= MAX_WORKFLOWS {
            return Err("capacity_exceeded");
        }
        let key = request
            .idempotency_key
            .as_deref()
            .ok_or("invalid_request")?;
        let digest = request.params["inputDigest"]
            .as_str()
            .ok_or("invalid_request")?;
        let handle = request.params["inputArtifactHandle"]
            .as_str()
            .ok_or("invalid_request")?;
        if self.artifacts.read_verified(handle, digest).is_err() {
            return Err("input_artifact_unavailable");
        }
        let input_artifact = ArtifactRef {
            opaque_handle: handle.into(),
            digest: digest.into(),
        };
        let workflow_id = format!(
            "workflow-{:x}",
            Sha256::digest(format!("{revision}:{handle}:{digest}:{key}"))
        );
        engine
            .handle(WorkflowCommand::Submit {
                idempotency_key: format!("engine-submit-{key}"),
                workflow_id: workflow_id.clone(),
                policy,
                input_artifact,
            })
            .map_err(engine_error_code)?;
        drop(engine);
        self.bridge.register_workflow(&workflow_id);
        self.spawn_drive(workflow_id.clone());
        Ok(json!({"workflowId": workflow_id, "policyRevisionId": revision, "state": "admitted"}))
    }

    fn workflow_status(&self, workflow_id: &str) -> std::result::Result<Value, &'static str> {
        let snapshot = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .workflow(workflow_id)
            .map_err(engine_error_code)?;
        Ok(project_snapshot(&snapshot))
    }

    fn workflow_events(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        let workflow_id = request.params["workflowId"]
            .as_str()
            .ok_or("invalid_request")?;
        let after = request.params["afterCursor"]
            .as_u64()
            .ok_or("invalid_request")?;
        let limit = request.params["limit"].as_u64().ok_or("invalid_request")? as usize;
        let engine = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let snapshot = engine.workflow(workflow_id).map_err(engine_error_code)?;
        let page = engine
            .events(workflow_id, after, limit)
            .map_err(engine_error_code)?;
        let events = page
            .events
            .into_iter()
            .map(|record| project_event(record.cursor, &record.event))
            .collect::<Vec<_>>();
        Ok(
            json!({"events": events, "nextCursor": page.next_cursor, "hasMore": events.len() == limit, "terminal": snapshot.state.is_terminal()}),
        )
    }

    fn workflow_wait(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        let workflow_id = request.params["workflowId"]
            .as_str()
            .ok_or("invalid_request")?;
        // Confirm durable ownership before entering the ephemeral wait set.
        let snapshot = self
            .engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .workflow(workflow_id)
            .map_err(engine_error_code)?;
        self.bridge.register_workflow(workflow_id);
        if snapshot.state.is_terminal() {
            self.bridge
                .mark_workflow_state(workflow_id, state_name(snapshot.state), true);
        }
        self.bridge.wait(
            workflow_id,
            request.params["afterCursor"]
                .as_u64()
                .ok_or("invalid_request")?,
            request.params["limit"].as_u64().ok_or("invalid_request")? as usize,
            Duration::from_millis(
                request.params["timeoutMs"]
                    .as_u64()
                    .ok_or("invalid_request")?,
            ),
        )
    }

    fn workflow_message(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        let workflow_id = request.params["workflowId"]
            .as_str()
            .ok_or("invalid_request")?;
        let handle = request.params["messageArtifactHandle"]
            .as_str()
            .ok_or("invalid_request")?;
        let digest = request.params["messageDigest"]
            .as_str()
            .ok_or("invalid_request")?;
        let bytes = self
            .artifacts
            .read_verified(handle, digest)
            .map_err(|_| "message_artifact_unavailable")?;
        let text = String::from_utf8(bytes).map_err(|_| "message_artifact_invalid")?;
        if text.trim().is_empty() {
            return Err("message_artifact_empty");
        }
        let key = request
            .idempotency_key
            .as_deref()
            .ok_or("invalid_request")?;
        let message_id = format!(
            "message-{:x}",
            Sha256::digest(format!("{workflow_id}:{handle}:{digest}:{key}"))
        );
        let artifact = ArtifactRef {
            opaque_handle: handle.to_owned(),
            digest: digest.to_owned(),
        };
        let native_supported = self
            .bridge
            .active_agent(workflow_id)
            .is_some_and(|agent_id| governed_dispatch::native_steer_supported(&agent_id));
        let interrupt_supported = self
            .bridge
            .active_agent(workflow_id)
            .is_some_and(|agent_id| governed_dispatch::native_interrupt_supported(&agent_id));
        let admission = match self.bridge.reserve_message(
            workflow_id,
            artifact,
            &message_id,
            native_supported,
            interrupt_supported,
        )? {
            local_bridge::MessageReservation::Queued { message_id } => {
                local_bridge::LocalBridge::queued_admission(message_id)
            }
            local_bridge::MessageReservation::Native {
                message_id,
                binding,
            } => {
                let accepted = governed_dispatch::steer_active_turn(&binding, &text);
                self.bridge
                    .resolve_native(workflow_id, &message_id, accepted)?
            }
            local_bridge::MessageReservation::Interrupt {
                message_id,
                binding,
            } => {
                let accepted = governed_dispatch::interrupt_active_turn(&binding);
                self.bridge
                    .resolve_interrupt(workflow_id, &message_id, accepted)?
            }
        };
        Ok(json!({
            "workflowId": workflow_id,
            "messageId": admission.message_id,
            "state": admission.state,
            "deliveryMode": admission.delivery_mode,
        }))
    }

    fn cancel_workflow(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        let workflow_id = request.params["workflowId"]
            .as_str()
            .ok_or("invalid_request")?;
        let key = request
            .idempotency_key
            .as_deref()
            .ok_or("invalid_request")?;
        self.engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .handle(WorkflowCommand::Cancel {
                idempotency_key: format!("engine-cancel-{key}"),
                workflow_id: workflow_id.into(),
            })
            .map_err(engine_error_code)?;
        let status = self.workflow_status(workflow_id)?;
        self.bridge
            .mark_workflow_state(workflow_id, "cancelled", true);
        Ok(status)
    }

    fn approve_workflow(
        &self,
        request: &OrchestratorIpcRequest,
    ) -> std::result::Result<Value, &'static str> {
        if request.params["decision"].as_str() != Some("approved") {
            return Err("approval_rejected");
        }
        let workflow_id = request.params["workflowId"]
            .as_str()
            .ok_or("invalid_request")?;
        let approval_id = request.params["approvalId"]
            .as_str()
            .ok_or("invalid_request")?;
        let step_id = approval_id
            .strip_prefix("approval-")
            .ok_or("invalid_request")?;
        let key = request
            .idempotency_key
            .as_deref()
            .ok_or("invalid_request")?;
        self.engine
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .handle(WorkflowCommand::Approve {
                idempotency_key: format!("engine-approve-{key}"),
                workflow_id: workflow_id.into(),
                step_id: step_id.into(),
            })
            .map_err(engine_error_code)?;
        self.spawn_drive(workflow_id.into());
        self.workflow_status(workflow_id)
    }
}

struct SystemClock;
impl crate::domain::agent_orchestration::Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |duration| duration.as_millis() as u64)
    }
}
struct NoCrash;
impl CrashBoundaryInjector for NoCrash {
    fn should_crash(&self, _: CrashBoundary) -> bool {
        false
    }
}
fn engine_error_code(error: EngineErrorCode) -> &'static str {
    match error {
        EngineErrorCode::NotFound => "workflow_unavailable",
        EngineErrorCode::CapacityExceeded => "capacity_exceeded",
        EngineErrorCode::LeaseHeld => "service_already_running",
        EngineErrorCode::Compile => "policy_schema_invalid",
        EngineErrorCode::TerminalState => "workflow_terminal",
        _ => "orchestrator_state_error",
    }
}

fn state_name(state: WorkflowState) -> &'static str {
    match state {
        WorkflowState::Created => "created",
        WorkflowState::Admitted => "admitted",
        WorkflowState::Running => "running",
        WorkflowState::AwaitingApproval => "awaiting_approval",
        WorkflowState::Validating => "validating",
        WorkflowState::Completed => "completed",
        WorkflowState::Failed => "failed",
        WorkflowState::Cancelled => "cancelled",
        WorkflowState::Unknown => "unknown",
    }
}
fn project_snapshot(snapshot: &WorkflowSnapshot) -> Value {
    let mut result = json!({"workflowId": snapshot.workflow_id, "policyRevisionId": snapshot.policy_revision, "state": state_name(snapshot.state), "adapterDecision": selected_adapter_decision()});
    if snapshot.state == WorkflowState::AwaitingApproval {
        result["approvalId"] = json!(
            snapshot
                .active_step_id
                .as_ref()
                .map(|step| format!("approval-{step}"))
        );
    }
    if snapshot.state.is_terminal() {
        let digest = format!(
            "{:x}",
            Sha256::digest(format!(
                "{}:{}:{}",
                snapshot.workflow_id,
                snapshot.policy_revision,
                state_name(snapshot.state)
            ))
        );
        result["terminalReceipt"] =
            json!({"state": state_name(snapshot.state), "digest": format!("sha256:{digest}")});
    }
    result
}

#[cfg(test)]
mod local_concurrency_tests {
    use super::*;

    #[test]
    fn single_flight_guard_coalesces_a_concurrent_rerun_without_losing_it() {
        let workflows = Arc::new(Mutex::new(HashMap::from([(
            "workflow-1".to_string(),
            false,
        )])));
        let mut guard = ScheduledWorkflowGuard {
            workflows: Arc::clone(&workflows),
            workflow_id: "workflow-1".to_string(),
            registered: true,
        };
        workflows
            .lock()
            .unwrap()
            .insert("workflow-1".to_string(), true);

        assert!(guard.finish_or_rerun());
        assert_eq!(
            workflows.lock().unwrap().get("workflow-1").copied(),
            Some(false)
        );
        assert!(!guard.finish_or_rerun());
        assert!(!workflows.lock().unwrap().contains_key("workflow-1"));
    }

    #[test]
    fn all_mutations_for_one_workflow_share_one_ordering_scope() {
        for method in ["workflow.message", "workflow.cancel", "workflow.approve"] {
            let request = OrchestratorIpcRequest {
                protocol_version: PROTOCOL_VERSION.into(),
                request_id: format!("request-{method}"),
                client_kind: "cli".into(),
                method: method.into(),
                params: json!({"workflowId": "workflow-1"}),
                idempotency_key: Some(format!("idempotency-{method}")),
            };
            assert_eq!(
                mutation_lane_scope(&request),
                Some(("workflow", "workflow-1"))
            );
        }
    }
}
fn project_event(cursor: u64, event: &WorkflowEvent) -> Value {
    let (kind, state) = match event {
        WorkflowEvent::Admitted { .. } => ("workflow.admitted", "admitted"),
        WorkflowEvent::ApprovalRequested { .. } => ("approval.requested", "awaiting_approval"),
        WorkflowEvent::StepApproved { .. } => ("approval.approved", "admitted"),
        WorkflowEvent::ConditionEvaluated { matched: false, .. } => ("step.skipped", "admitted"),
        WorkflowEvent::ConditionEvaluated { .. } => ("condition.matched", "admitted"),
        WorkflowEvent::DispatchStarted { .. } => ("dispatch.started", "running"),
        WorkflowEvent::DispatchProvenSucceeded { .. } => ("dispatch.succeeded", "admitted"),
        WorkflowEvent::StepFailed { .. } => ("step.failed", "failed"),
        WorkflowEvent::StepCancelled { .. } => ("step.cancelled", "cancelled"),
        WorkflowEvent::StepUnknown { .. } => ("step.unknown", "unknown"),
        WorkflowEvent::WorkflowCompleted => ("workflow.completed", "completed"),
        WorkflowEvent::WorkflowFailed { .. } => ("workflow.failed", "failed"),
        WorkflowEvent::WorkflowCancelled { .. } => ("workflow.cancelled", "cancelled"),
        WorkflowEvent::WorkflowUnknown { .. } => ("workflow.unknown", "unknown"),
    };
    json!({"cursor": cursor, "type": kind, "state": state})
}

fn selected_dispatch_port(
    artifacts: Arc<PrivateArtifactStore>,
    bridge: Arc<local_bridge::LocalBridge>,
) -> Arc<dyn DispatchPort> {
    #[cfg(debug_assertions)]
    if let Some(port) = test_support::registered_dispatch_port() {
        return port;
    }
    Arc::new(governed_dispatch::GovernedDispatchPort::new(
        artifacts, bridge,
    ))
}
fn selected_adapter_decision() -> &'static str {
    #[cfg(debug_assertions)]
    if test_support::adapter_decision() != "unavailable" {
        return test_support::adapter_decision();
    }
    "governed"
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Handshake {
    protocol_version: String,
    client_kind: String,
    connection_nonce: String,
    capability_handle: String,
    #[serde(default)]
    acceptance_hold_id: Option<String>,
}

struct AdmissionPermit {
    shared: Arc<ServiceShared>,
    id: String,
}

struct BackgroundPermit(Arc<ServiceShared>);
impl BackgroundPermit {
    fn new(shared: Arc<ServiceShared>) -> Self {
        shared.active.fetch_add(1, Ordering::AcqRel);
        Self(shared)
    }
}
impl Drop for BackgroundPermit {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::AcqRel);
        self.0.wait.1.notify_all();
    }
}
impl AdmissionPermit {
    fn new(shared: Arc<ServiceShared>) -> Self {
        let id = uuid::Uuid::new_v4().simple().to_string();
        shared.active.fetch_add(1, Ordering::AcqRel);
        shared
            .admissions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(id.clone());
        Self { shared, id }
    }
}
impl Drop for AdmissionPermit {
    fn drop(&mut self) {
        self.shared
            .admissions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&self.id);
        self.shared.active.fetch_sub(1, Ordering::AcqRel);
        self.shared.wait.1.notify_all();
    }
}

pub fn run_service(
    options: OrchestratorServiceOptions,
) -> std::result::Result<(), OrchestratorServiceFailure> {
    run_service_inner(options).map_err(|code| OrchestratorServiceFailure { code })
}

#[cfg(unix)]
fn run_service_inner(options: OrchestratorServiceOptions) -> std::result::Result<(), &'static str> {
    file_security::ensure_private_dir(&options.state_root).map_err(|_| "service_unavailable")?;
    let lock_path = options.state_root.join("orchestrator.lock");
    let lock =
        file_security::open_private_lock_file(&lock_path).map_err(|_| "service_unavailable")?;
    lock.try_lock_exclusive()
        .map_err(|_| "service_already_running")?;
    if let Ok(stale) = read_discovery(&options.state_root)
        && let Ok(stale_endpoint) = endpoint_from_discovery(&options.state_root, &stale)
    {
        // The exclusive lifecycle lock proves no healthy service owns this
        // exact generation. Remove only that bounded stale socket leaf.
        let _ = fs::remove_file(stale_endpoint);
    }
    let generation = OrchestratorServiceLifecycle::rotate();
    let service_instance_id = uuid::Uuid::new_v4().simple().to_string();
    let acceptance_mode = cfg!(debug_assertions)
        && (options.ready_file.is_some() || options.acceptance_control_root.is_some());
    let socket_parent = short_runtime_dir();
    ensure_private_runtime_leaf(&socket_parent).map_err(|_| "service_unavailable")?;
    let discovery_record = DiscoveryRecord {
        endpoint_generation: generation.clone(),
        service_instance_id: service_instance_id.clone(),
        endpoint_path: socket_parent
            .join(format!("o-{}.sock", &generation[..12]))
            .to_string_lossy()
            .into_owned(),
        service_pid: std::process::id(),
        acceptance_mode,
    };
    let endpoint = endpoint_from_discovery(&options.state_root, &discovery_record)
        .map_err(|_| "service_unavailable")?;
    let listener = UnixListener::bind(&endpoint).map_err(|_| "service_unavailable")?;
    fs::set_permissions(
        &endpoint,
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    )
    .map_err(|_| "service_unavailable")?;
    listener
        .set_nonblocking(true)
        .map_err(|_| "service_unavailable")?;
    let capabilities = Arc::new(Capabilities::issue());
    let capability_path = capability_bootstrap_path(&options.state_root);
    let discovery = discovery_path(&options.state_root);

    let shared = Arc::new(ServiceShared::default());
    let handler = ServiceHandler::new(
        Arc::clone(&shared),
        service_instance_id,
        generation.clone(),
        &options.state_root,
    )?;
    handler.recover_and_drive()?;
    if !acceptance_mode {
        let bootstrap = PrivateCapabilityBootstrap {
            workflow: capabilities.workflow.clone(),
            status_only: capabilities.status_only.clone(),
            lifecycle: capabilities.lifecycle.clone(),
        };
        let text = serde_json::to_string(&bootstrap).map_err(|_| "service_unavailable")?;
        file_security::atomic_write_private_text_bounded(&capability_path, &text, 1024)
            .map_err(|_| "service_unavailable")?;
    }
    let discovery_text =
        serde_json::to_string(&discovery_record).map_err(|_| "service_unavailable")?;
    file_security::atomic_write_private_text_bounded(
        &discovery,
        &discovery_text,
        DISCOVERY_MAX_BYTES,
    )
    .map_err(|_| "service_unavailable")?;
    if acceptance_mode && let Some(path) = options.ready_file.as_ref() {
        let ready = json!({
            "protocolVersion": PROTOCOL_VERSION, "state": "running", "ownerPrivate": true,
            "admission": "owner-private", "endpointGeneration": generation,
            "endpointPath": endpoint, "discoveryPath": discovery,
            "maxFrameBytes": MAX_FRAME_BYTES,
            "capabilities": { "workflow": capabilities.workflow, "statusOnly": capabilities.status_only, "lifecycle": capabilities.lifecycle }
        });
        write_private_external(path, &ready.to_string()).map_err(|_| "service_unavailable")?;
    }
    let server = Arc::new(OrchestratorIpcServer::new(
        OrchestratorIpcServerConfig::default(),
        handler,
    ));
    let mut workers: Vec<thread::JoinHandle<()>> = Vec::new();
    while !shared.stopped.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((stream, _)) => {
                workers.retain(|worker| !worker.is_finished());
                let connection_permit = match server.try_connection_permit() {
                    Ok(permit) => permit,
                    Err(_) => {
                        record_rejection(&shared, "capacity_exceeded", false);
                        reject_stream(stream, "capacity_exceeded");
                        continue;
                    }
                };
                let shared = Arc::clone(&shared);
                let server = Arc::clone(&server);
                let capabilities = Arc::clone(&capabilities);
                let generation = generation.clone();
                let control = acceptance_mode
                    .then(|| options.acceptance_control_root.clone())
                    .flatten();
                workers.push(thread::spawn(move || {
                    let _connection_permit = connection_permit;
                    serve_connection(
                        stream,
                        shared,
                        server,
                        capabilities,
                        &generation,
                        control.as_deref(),
                    )
                }));
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                workers.retain(|worker| !worker.is_finished());
                thread::sleep(Duration::from_millis(2));
            }
            Err(_) => break,
        }
    }
    for worker in workers {
        let _ = worker.join();
    }
    drop(listener);
    let _ = fs::remove_file(&endpoint);
    if let Ok(Some(text)) =
        file_security::read_private_text_bounded(&discovery, DISCOVERY_MAX_BYTES)
    {
        if serde_json::from_str::<DiscoveryRecord>(&text)
            .ok()
            .is_some_and(|record| record.endpoint_generation == generation)
        {
            let _ = file_security::remove_private_state_marker(&discovery);
        }
    }
    if !acceptance_mode {
        let _ = file_security::remove_private_state_marker(&capability_path);
    }
    drop(lock);
    Ok(())
}

#[cfg(unix)]
fn ensure_private_runtime_leaf(path: &Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};

    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("runtime parent unavailable"))?;
    let parent_metadata =
        fs::metadata(parent).map_err(|_| anyhow!("runtime parent unavailable"))?;
    let effective_uid = nix::unistd::Uid::effective().as_raw();
    let parent_mode = parent_metadata.mode();
    let owner_private_parent = parent_metadata.uid() == effective_uid && parent_mode & 0o077 == 0;
    let sticky_shared_parent = parent_mode & u32::from(nix::libc::S_ISVTX) != 0;
    if !parent_metadata.is_dir() || (!owner_private_parent && !sticky_shared_parent) {
        return Err(anyhow!("runtime parent is not owner-private or sticky"));
    }
    let probe = path.join("o-000000000000.sock");
    if probe.as_os_str().as_encoded_bytes().len() > 100 {
        return Err(anyhow!("runtime endpoint path exceeds platform bound"));
    }
    match fs::symlink_metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let mut builder = fs::DirBuilder::new();
            builder.mode(0o700);
            if let Err(create_error) = builder.create(path)
                && create_error.kind() != io::ErrorKind::AlreadyExists
            {
                return Err(anyhow!("runtime directory unavailable"));
            }
        }
        Err(_) => return Err(anyhow!("runtime directory unavailable")),
    }
    let before =
        fs::symlink_metadata(path).map_err(|_| anyhow!("runtime directory unavailable"))?;
    if before.file_type().is_symlink() || !before.is_dir() || before.uid() != effective_uid {
        return Err(anyhow!("runtime directory ownership is invalid"));
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    let after = fs::symlink_metadata(path).map_err(|_| anyhow!("runtime directory unavailable"))?;
    if after.file_type().is_symlink()
        || !after.is_dir()
        || after.uid() != effective_uid
        || after.mode() & 0o777 != 0o700
        || after.dev() != before.dev()
        || after.ino() != before.ino()
    {
        return Err(anyhow!("runtime directory changed during hardening"));
    }
    Ok(())
}

#[cfg(not(unix))]
fn run_service_inner(
    _options: OrchestratorServiceOptions,
) -> std::result::Result<(), &'static str> {
    Err("service_unavailable")
}

#[cfg(unix)]
fn serve_connection(
    mut stream: UnixStream,
    shared: Arc<ServiceShared>,
    server: Arc<OrchestratorIpcServer>,
    capabilities: Arc<Capabilities>,
    generation: &str,
    control: Option<&Path>,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
    if !owner_peer(&stream) {
        record_rejection(&shared, "peer_rejected", false);
        reject_stream(stream, "peer_rejected");
        return;
    }
    let handshake_frame = match read_bounded_frame(&mut stream) {
        Ok(value) => value,
        Err(code) => {
            record_rejection(&shared, code, code == "transport_closed");
            reject_stream(stream, code);
            return;
        }
    };
    let handshake: Handshake = match serde_json::from_slice(&handshake_frame) {
        Ok(value) => value,
        Err(_) => {
            record_rejection(&shared, "invalid_request", false);
            reject_stream(stream, "invalid_request");
            return;
        }
    };
    if handshake.protocol_version != PROTOCOL_VERSION {
        record_rejection(&shared, "protocol_mismatch", false);
        reject_stream(stream, "protocol_mismatch");
        return;
    }
    if !matches!(
        handshake.client_kind.as_str(),
        "cli" | "desktop" | "codex-mcp"
    ) || handshake.connection_nonce.len() < 32
        || handshake.connection_nonce.len() > 128
    {
        record_rejection(&shared, "invalid_request", false);
        reject_stream(stream, "invalid_request");
        return;
    }
    let operations = match capabilities.operations(&handshake.capability_handle) {
        Some(value) => value,
        None => {
            record_rejection(&shared, "capability_rejected", false);
            reject_stream(stream, "capability_rejected");
            return;
        }
    };
    let request_frame = match read_bounded_frame(&mut stream) {
        Ok(value) => value,
        Err(code) => {
            record_rejection(&shared, code, code == "transport_closed");
            reject_stream(stream, code);
            return;
        }
    };
    if shared.draining.load(Ordering::Acquire) {
        reject_stream(stream, "service_draining");
        return;
    }
    let request: OrchestratorIpcRequest = match serde_json::from_slice(&request_frame) {
        Ok(value) => value,
        Err(_) => {
            record_rejection(&shared, "invalid_request", false);
            reject_stream(stream, "invalid_request");
            return;
        }
    };
    if request.client_kind != handshake.client_kind {
        record_rejection(&shared, "peer_rejected", false);
        reject_stream_for(&mut stream, &request.request_id, "peer_rejected");
        return;
    }
    if !super::orchestrator_ipc::METHODS.contains(&request.method.as_str()) {
        record_rejection(&shared, "unknown_method", false);
        reject_stream_for(&mut stream, &request.request_id, "unknown_method");
        return;
    }
    if super::orchestrator_ipc::decode_request(&request_frame).is_err() {
        record_rejection(&shared, "invalid_request", false);
        reject_stream_for(&mut stream, &request.request_id, "invalid_request");
        return;
    }
    if !operations.contains(&request.method) {
        record_rejection(&shared, "operation_forbidden", false);
        reject_stream_for(&mut stream, &request.request_id, "operation_forbidden");
        return;
    }
    let permit = AdmissionPermit::new(Arc::clone(&shared));
    if let (Some(id), Some(root)) = (handshake.acceptance_hold_id.as_deref(), control) {
        acceptance_hold(root, id, &request, generation, &permit.id);
    }
    let is_stop = request.method == "service.stop";
    if is_stop {
        OrchestratorServiceLifecycle::drain(&shared);
        let deadline = Instant::now() + Duration::from_secs(8);
        let mut guard = shared.wait.0.lock().unwrap_or_else(|e| e.into_inner());
        while shared.active.load(Ordering::Acquire) > 1 && Instant::now() < deadline {
            let wait = shared
                .wait
                .1
                .wait_timeout(guard, Duration::from_millis(20))
                .unwrap_or_else(|e| e.into_inner());
            guard = wait.0;
        }
    }
    let receipt = server.handle_admitted("local-owner", operations, &request_frame);
    let _ = write_frame(
        &mut stream,
        &serde_json::to_vec(&receipt).unwrap_or_default(),
    );
    if let (Some(id), Some(root)) = (handshake.acceptance_hold_id.as_deref(), control) {
        acceptance_completed(root, id, generation, &permit.id);
    }
    drop(permit);
    if is_stop {
        OrchestratorServiceLifecycle::stop(&shared);
    }
}

fn record_rejection(shared: &ServiceShared, code: &'static str, transport_closed: bool) {
    let mut diagnostics = shared.diagnostics.lock().unwrap_or_else(|e| e.into_inner());
    diagnostics.pre_handler_rejected += 1;
    if transport_closed {
        diagnostics.transport_closed += 1;
    }
    diagnostics.last_error_code = Some(code);
}

#[cfg(unix)]
fn read_bounded_frame(stream: &mut UnixStream) -> std::result::Result<Vec<u8>, &'static str> {
    let mut header = [0_u8; 4];
    if let Err(error) = stream.read_exact(&mut header) {
        return Err(if error.kind() == io::ErrorKind::UnexpectedEof {
            "transport_closed"
        } else {
            "transport_closed"
        });
    }
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_BYTES {
        return Err("frame_too_large");
    }
    let mut payload = vec![0_u8; length];
    match stream.read_exact(&mut payload) {
        Ok(()) => Ok(payload),
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Err("frame_truncated"),
        Err(_) => Err("transport_closed"),
    }
}

#[cfg(unix)]
fn reject_stream(mut stream: UnixStream, code: &'static str) {
    reject_stream_for(&mut stream, "rejected", code);
}
fn reject_stream_for(writer: &mut impl std::io::Write, request_id: &str, code: &'static str) {
    let receipt = OrchestratorIpcReceipt {
        protocol_version: PROTOCOL_VERSION.into(),
        request_id: if request_id.is_empty() || request_id.len() > 128 {
            "rejected".into()
        } else {
            request_id.into()
        },
        ok: false,
        result: None,
        error: Some(OrchestratorIpcError { code: code.into() }),
    };
    let _ = write_frame(writer, &serde_json::to_vec(&receipt).unwrap_or_default());
}

#[cfg(unix)]
fn owner_peer(stream: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    #[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
    {
        nix::unistd::getpeereid(stream.as_raw_fd())
            .is_ok_and(|(uid, _)| uid == nix::unistd::Uid::effective())
    }
    #[cfg(target_os = "linux")]
    {
        nix::sys::socket::getsockopt(stream, nix::sys::socket::sockopt::PeerCredentials)
            .is_ok_and(|credential| credential.uid() == nix::unistd::Uid::effective().as_raw())
    }
    #[cfg(not(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "freebsd",
        target_os = "linux"
    )))]
    {
        true
    }
}

fn write_private_external(path: &Path, content: &str) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("private output parent missing"))?;
    file_security::ensure_private_dir(parent)?;
    let mut options = OpenOptions::new();
    options.create(true).truncate(true).write(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(path)
        .map_err(|_| anyhow!("private output unavailable"))?;
    use std::io::Write;
    file.write_all(content.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    Ok(())
}

fn acceptance_hold(
    root: &Path,
    id: &str,
    request: &OrchestratorIpcRequest,
    generation: &str,
    admission_id: &str,
) {
    if !valid_acceptance_id(id) {
        return;
    }
    let _ = file_security::ensure_private_dir(root);
    let digest = format!(
        "{:x}",
        Sha256::digest(serde_json::to_vec(request).unwrap_or_default())
    );
    let marker = json!({"state":"admitted", "requestId":request.request_id, "servicePid":std::process::id(), "endpointGeneration":generation, "source":"orchestrator-service", "admissionId":admission_id, "requestDigest":digest});
    let _ = write_private_external(
        &root.join(format!("{id}.admitted.json")),
        &marker.to_string(),
    );
    let release = root.join(format!("{id}.release.json"));
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline {
        if fs::metadata(&release).is_ok() {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

fn acceptance_completed(root: &Path, id: &str, generation: &str, admission_id: &str) {
    if !valid_acceptance_id(id) {
        return;
    }
    let marker = json!({"state":"completed", "servicePid":std::process::id(), "endpointGeneration":generation, "source":"orchestrator-service", "admissionId":admission_id});
    let _ = write_private_external(
        &root.join(format!("{id}.completed.json")),
        &marker.to_string(),
    );
}
fn valid_acceptance_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
