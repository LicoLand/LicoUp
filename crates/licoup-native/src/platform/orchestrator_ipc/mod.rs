//! Bounded, owner-private control-plane protocol for the local orchestrator.

pub mod client;

pub use client::OrchestratorIpcClient;

use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

pub const PROTOCOL_VERSION: &str = "lico.orchestrator.ipc.v1";
pub const MAX_FRAME_BYTES: usize = 64 * 1024;
pub const MAX_CONNECTIONS: usize = 32;
pub const MAX_QUEUED_REQUESTS: usize = 16;
pub const MAX_REQUESTS_PER_WINDOW: usize = 128;
pub const RATE_WINDOW: Duration = Duration::from_secs(1);
const HANDLER_LANES: usize = 16;

pub const METHODS: [&str; 12] = [
    "service.status",
    "service.stop",
    "policy.register",
    "policy.activate",
    "workflow.submit",
    "workflow.preview",
    "workflow.status",
    "workflow.cancel",
    "workflow.approve",
    "workflow.events",
    "workflow.wait",
    "workflow.message",
];

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrchestratorIpcRequest {
    pub protocol_version: String,
    pub request_id: String,
    pub client_kind: String,
    pub method: String,
    pub params: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrchestratorIpcError {
    pub code: String,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct OrchestratorIpcReceipt {
    pub protocol_version: String,
    pub request_id: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<OrchestratorIpcError>,
}

impl OrchestratorIpcReceipt {
    pub fn success(request_id: impl Into<String>, result: Value) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION.into(),
            request_id: request_id.into(),
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(request_id: impl Into<String>, code: &'static str) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION.into(),
            request_id: bounded_request_id(request_id.into()),
            ok: false,
            result: None,
            error: Some(OrchestratorIpcError { code: code.into() }),
        }
    }

    pub fn error_code(&self) -> Option<&str> {
        self.error.as_ref().map(|error| error.code.as_str())
    }
}

fn bounded_request_id(value: String) -> String {
    if !value.is_empty() && value.len() <= 128 {
        value
    } else {
        "rejected".into()
    }
}

pub trait OrchestratorIpcHandler: Send + Sync + 'static {
    fn handle(&self, request: &OrchestratorIpcRequest) -> OrchestratorIpcReceipt;
    fn mutation_count(&self) -> usize {
        0
    }
}

#[derive(Clone, Copy, Debug)]
pub struct OrchestratorIpcServerConfig {
    pub max_frame_bytes: usize,
    pub max_connections: usize,
    pub max_queued_requests: usize,
    pub max_requests_per_window: usize,
}

impl Default for OrchestratorIpcServerConfig {
    fn default() -> Self {
        Self {
            max_frame_bytes: MAX_FRAME_BYTES,
            max_connections: MAX_CONNECTIONS,
            max_queued_requests: MAX_QUEUED_REQUESTS,
            max_requests_per_window: MAX_REQUESTS_PER_WINDOW,
        }
    }
}

#[derive(Clone)]
pub struct OrchestratorIpcServer {
    inner: Arc<ServerInner>,
}

struct ServerInner {
    config: OrchestratorIpcServerConfig,
    handler: Arc<dyn OrchestratorIpcHandler>,
    draining: AtomicBool,
    active: AtomicUsize,
    connections: AtomicUsize,
    queued_requests: AtomicUsize,
    handler_gates: [Mutex<()>; HANDLER_LANES],
    drain_wait: (Mutex<()>, Condvar),
    rate: Mutex<HashMap<String, VecDeque<Instant>>>,
}

impl OrchestratorIpcServer {
    pub fn new(config: OrchestratorIpcServerConfig, handler: impl OrchestratorIpcHandler) -> Self {
        Self {
            inner: Arc::new(ServerInner {
                config,
                handler: Arc::new(handler),
                draining: AtomicBool::new(false),
                active: AtomicUsize::new(0),
                connections: AtomicUsize::new(0),
                queued_requests: AtomicUsize::new(0),
                handler_gates: std::array::from_fn(|_| Mutex::new(())),
                drain_wait: (Mutex::new(()), Condvar::new()),
                rate: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub fn begin_graceful_drain(&self, _deadline: Duration) {
        self.inner.draining.store(true, Ordering::Release);
    }

    pub fn wait_for_drain(&self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut guard = self
            .inner
            .drain_wait
            .0
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        while self.inner.active.load(Ordering::Acquire) != 0 {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            let waited = self
                .inner
                .drain_wait
                .1
                .wait_timeout(guard, remaining)
                .unwrap_or_else(|e| e.into_inner());
            guard = waited.0;
            if waited.1.timed_out() && self.inner.active.load(Ordering::Acquire) != 0 {
                return false;
            }
        }
        true
    }

    fn exchange(
        &self,
        peer: &PeerAdmission,
        frame: &[u8],
        fault: TestFault,
    ) -> ExchangeObservation {
        let before = self.inner.handler.mutation_count();
        let reject = |code| {
            ExchangeObservation::new(OrchestratorIpcReceipt::failure("rejected", code), before)
        };
        if self.inner.draining.load(Ordering::Acquire) {
            return reject("service_draining");
        }
        if !peer.owner_bound {
            return reject("peer_rejected");
        }
        if peer.protocol_version != PROTOCOL_VERSION {
            return reject("protocol_mismatch");
        }
        match fault {
            TestFault::Truncated => return reject("frame_truncated"),
            TestFault::Broken => return reject("transport_closed"),
            TestFault::ConnectionFull => {
                if self
                    .simulate_saturated_capacity(CapacityKind::Connection)
                    .is_err()
                {
                    return reject("capacity_exceeded");
                }
            }
            TestFault::QueueFull => {
                if self
                    .simulate_saturated_capacity(CapacityKind::RequestQueue)
                    .is_err()
                {
                    return reject("capacity_exceeded");
                }
            }
            TestFault::None => {}
        }
        if frame.len() > self.inner.config.max_frame_bytes {
            return reject("frame_too_large");
        }
        let request: OrchestratorIpcRequest = match serde_json::from_slice(frame) {
            Ok(value) => value,
            Err(_) => return reject("invalid_request"),
        };
        if request.protocol_version != PROTOCOL_VERSION {
            return reject("protocol_mismatch");
        }
        if !valid_id(&request.request_id)
            || !matches!(
                request.client_kind.as_str(),
                "codex-mcp" | "desktop" | "cli"
            )
        {
            return reject("invalid_request");
        }
        if !METHODS.contains(&request.method.as_str()) {
            return reject("unknown_method");
        }
        if !validate_request(&request) {
            return reject("invalid_request");
        }
        if !peer.operations.contains(&request.method) {
            return reject("operation_forbidden");
        }
        if !self.admit_rate(&peer.peer_id) {
            return reject("rate_limited");
        }
        let _permit = ActivePermit::new(&self.inner);
        let receipt = self.inner.handler.handle(&request);
        ExchangeObservation::new(receipt, self.inner.handler.mutation_count())
    }

    fn scheduled_exchange(
        &self,
        peer: &PeerAdmission,
        frame: &[u8],
        fault: TestFault,
    ) -> ExchangeObservation {
        if self.inner.draining.load(Ordering::Acquire) {
            return ExchangeObservation::new(
                OrchestratorIpcReceipt::failure("rejected", "service_draining"),
                self.inner.handler.mutation_count(),
            );
        }
        // A Level-2 wait is a bounded long-poll and must never own a mutation
        // lane; otherwise the message that should wake it could not enter.
        if is_wait_request(frame) {
            return self.exchange(peer, frame, fault);
        }
        let lane = request_lane(frame);
        match self.inner.handler_gates[lane].try_lock() {
            Ok(_gate) => self.exchange(peer, frame, fault),
            Err(std::sync::TryLockError::WouldBlock) => {
                let queued = match self.try_request_queue_permit() {
                    Ok(permit) => permit,
                    Err(code) => {
                        return ExchangeObservation::new(
                            OrchestratorIpcReceipt::failure("rejected", code),
                            self.inner.handler.mutation_count(),
                        );
                    }
                };
                let _gate = self.inner.handler_gates[lane]
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                drop(queued);
                self.exchange(peer, frame, fault)
            }
            Err(std::sync::TryLockError::Poisoned(error)) => {
                let _gate = error.into_inner();
                self.exchange(peer, frame, fault)
            }
        }
    }

    fn admit_rate(&self, peer_id: &str) -> bool {
        let now = Instant::now();
        let mut rates = self.inner.rate.lock().unwrap_or_else(|e| e.into_inner());
        let window = rates.entry(peer_id.to_owned()).or_default();
        while window
            .front()
            .is_some_and(|instant| now.duration_since(*instant) >= RATE_WINDOW)
        {
            window.pop_front();
        }
        if window.len() >= self.inner.config.max_requests_per_window {
            return false;
        }
        window.push_back(now);
        true
    }

    pub fn active_requests(&self) -> usize {
        self.inner.active.load(Ordering::Acquire)
    }

    pub fn wait_for_queued_requests(&self, count: usize, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.inner.queued_requests.load(Ordering::Acquire) >= count {
                return true;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        self.inner.queued_requests.load(Ordering::Acquire) >= count
    }

    pub(crate) fn try_connection_permit(&self) -> Result<IpcCapacityPermit, &'static str> {
        self.try_capacity(CapacityKind::Connection)
    }

    pub(crate) fn try_request_queue_permit(&self) -> Result<IpcCapacityPermit, &'static str> {
        self.try_capacity(CapacityKind::RequestQueue)
    }

    fn try_capacity(&self, kind: CapacityKind) -> Result<IpcCapacityPermit, &'static str> {
        let (counter, limit) = match kind {
            CapacityKind::Connection => {
                (&self.inner.connections, self.inner.config.max_connections)
            }
            CapacityKind::RequestQueue => (
                &self.inner.queued_requests,
                self.inner.config.max_queued_requests,
            ),
        };
        reserve_bounded(counter, limit)?;
        Ok(IpcCapacityPermit {
            inner: Arc::clone(&self.inner),
            kind,
        })
    }

    fn simulate_saturated_capacity(&self, kind: CapacityKind) -> Result<(), &'static str> {
        let (counter, limit) = match kind {
            CapacityKind::Connection => {
                (&self.inner.connections, self.inner.config.max_connections)
            }
            CapacityKind::RequestQueue => (
                &self.inner.queued_requests,
                self.inner.config.max_queued_requests,
            ),
        };
        let previous = counter.swap(limit, Ordering::AcqRel);
        let result = self.try_capacity(kind).map(drop);
        counter.store(previous, Ordering::Release);
        result
    }

    pub fn handle_admitted(
        &self,
        peer_id: &str,
        operations: HashSet<String>,
        frame: &[u8],
    ) -> OrchestratorIpcReceipt {
        self.scheduled_exchange(
            &PeerAdmission {
                peer_id: peer_id.into(),
                owner_bound: true,
                protocol_version: PROTOCOL_VERSION.into(),
                operations,
            },
            frame,
            TestFault::None,
        )
        .receipt
    }
}

fn is_wait_request(frame: &[u8]) -> bool {
    serde_json::from_slice::<Value>(frame)
        .ok()
        .and_then(|value| {
            value
                .get("method")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .as_deref()
        == Some("workflow.wait")
}

fn request_lane(frame: &[u8]) -> usize {
    let Ok(value) = serde_json::from_slice::<Value>(frame) else {
        return 0;
    };
    let scope = value
        .pointer("/params/workflowId")
        .or_else(|| value.pointer("/params/policyRevisionId"))
        .or_else(|| value.pointer("/params/inputArtifactHandle"))
        .or_else(|| value.get("method"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let hash = scope.bytes().fold(0xcbf29ce484222325_u64, |hash, byte| {
        hash.wrapping_mul(0x100000001b3) ^ u64::from(byte)
    });
    hash as usize % HANDLER_LANES
}

#[derive(Clone, Copy)]
enum CapacityKind {
    Connection,
    RequestQueue,
}

pub(crate) struct IpcCapacityPermit {
    inner: Arc<ServerInner>,
    kind: CapacityKind,
}
impl Drop for IpcCapacityPermit {
    fn drop(&mut self) {
        match self.kind {
            CapacityKind::Connection => {
                self.inner.connections.fetch_sub(1, Ordering::AcqRel);
            }
            CapacityKind::RequestQueue => {
                self.inner.queued_requests.fetch_sub(1, Ordering::AcqRel);
            }
        }
    }
}

fn reserve_bounded(counter: &AtomicUsize, limit: usize) -> Result<(), &'static str> {
    if limit == 0 {
        return Err("capacity_exceeded");
    }
    let mut current = counter.load(Ordering::Acquire);
    loop {
        if current >= limit {
            return Err("capacity_exceeded");
        }
        match counter.compare_exchange_weak(
            current,
            current + 1,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => return Ok(()),
            Err(observed) => current = observed,
        }
    }
}

struct ActivePermit<'a> {
    inner: &'a ServerInner,
}
impl<'a> ActivePermit<'a> {
    fn new(inner: &'a ServerInner) -> Self {
        inner.active.fetch_add(1, Ordering::AcqRel);
        Self { inner }
    }
}
impl Drop for ActivePermit<'_> {
    fn drop(&mut self) {
        self.inner.active.fetch_sub(1, Ordering::AcqRel);
        self.inner.drain_wait.1.notify_all();
    }
}

fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128
}

fn exact_keys(value: &Value, required: &[&str]) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    object.len() == required.len() && required.iter().all(|key| object.contains_key(*key))
}

fn validate_request(request: &OrchestratorIpcRequest) -> bool {
    let mutation = matches!(
        request.method.as_str(),
        "service.stop"
            | "policy.register"
            | "policy.activate"
            | "workflow.submit"
            | "workflow.cancel"
            | "workflow.approve"
            | "workflow.message"
    );
    if mutation != request.idempotency_key.as_deref().is_some_and(valid_id) {
        return false;
    }
    match request.method.as_str() {
        "service.status" | "service.stop" => exact_keys(&request.params, &[]),
        "policy.register" => {
            exact_keys(&request.params, &["policy"]) && request.params["policy"].is_object()
        }
        "policy.activate" => {
            exact_keys(&request.params, &["policyRevisionId"])
                && request.params["policyRevisionId"]
                    .as_str()
                    .is_some_and(valid_id)
        }
        "workflow.submit" => {
            (exact_keys(&request.params, &["policyRevisionId", "inputDigest"])
                || exact_keys(
                    &request.params,
                    &["policyRevisionId", "inputArtifactHandle", "inputDigest"],
                ))
                && request.params["policyRevisionId"]
                    .as_str()
                    .is_some_and(valid_id)
                && request
                    .params
                    .get("inputArtifactHandle")
                    .is_none_or(|value| value.as_str().is_some_and(valid_id))
                && request.params["inputDigest"].as_str().is_some_and(|v| {
                    v.len() == 64
                        && v.bytes()
                            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                })
        }
        "workflow.preview" => {
            exact_keys(&request.params, &["policyRevisionId", "inputDigest"])
                && request.params["policyRevisionId"]
                    .as_str()
                    .is_some_and(valid_id)
                && request.params["inputDigest"].as_str().is_some_and(|value| {
                    value.len() == 64
                        && value
                            .bytes()
                            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                })
        }
        "workflow.status" | "workflow.cancel" => {
            exact_keys(&request.params, &["workflowId"])
                && request.params["workflowId"].as_str().is_some_and(valid_id)
        }
        "workflow.approve" => {
            exact_keys(&request.params, &["workflowId", "approvalId", "decision"])
                && request.params["workflowId"].as_str().is_some_and(valid_id)
                && request.params["approvalId"].as_str().is_some_and(valid_id)
                && matches!(
                    request.params["decision"].as_str(),
                    Some("approved" | "rejected")
                )
        }
        "workflow.events" => {
            exact_keys(&request.params, &["workflowId", "afterCursor", "limit"])
                && request.params["workflowId"].as_str().is_some_and(valid_id)
                && request.params["afterCursor"].as_u64().is_some()
                && request.params["limit"]
                    .as_u64()
                    .is_some_and(|v| (1..=256).contains(&v))
        }
        "workflow.wait" => {
            exact_keys(
                &request.params,
                &["workflowId", "afterCursor", "limit", "timeoutMs"],
            ) && request.params["workflowId"].as_str().is_some_and(valid_id)
                && request.params["afterCursor"].as_u64().is_some()
                && request.params["limit"]
                    .as_u64()
                    .is_some_and(|value| (1..=128).contains(&value))
                && request.params["timeoutMs"]
                    .as_u64()
                    .is_some_and(|value| value <= 30_000)
        }
        "workflow.message" => {
            exact_keys(
                &request.params,
                &["workflowId", "messageArtifactHandle", "messageDigest"],
            ) && request.params["workflowId"].as_str().is_some_and(valid_id)
                && request.params["messageArtifactHandle"]
                    .as_str()
                    .is_some_and(valid_id)
                && request.params["messageDigest"]
                    .as_str()
                    .is_some_and(|value| {
                        value.len() == 64
                            && value
                                .bytes()
                                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
                    })
        }
        _ => false,
    }
}

#[derive(Clone)]
struct PeerAdmission {
    peer_id: String,
    owner_bound: bool,
    protocol_version: String,
    operations: HashSet<String>,
}

#[derive(Clone, Copy)]
enum TestFault {
    None,
    Truncated,
    Broken,
    ConnectionFull,
    QueueFull,
}

#[derive(Clone, Debug)]
pub struct ExchangeObservation {
    receipt: OrchestratorIpcReceipt,
    handler_mutations: usize,
}
impl ExchangeObservation {
    fn new(receipt: OrchestratorIpcReceipt, handler_mutations: usize) -> Self {
        Self {
            receipt,
            handler_mutations,
        }
    }
    pub fn error_code(&self) -> Option<&str> {
        self.receipt.error_code()
    }
    pub fn handler_mutations(&self) -> usize {
        self.handler_mutations
    }
    pub fn receipt(&self) -> Value {
        serde_json::to_value(&self.receipt)
            .unwrap_or_else(|_| json!({"ok": false, "error": {"code": "service_unavailable"}}))
    }
    pub fn redacted_json(&self) -> Value {
        self.receipt()
    }
}

pub fn decode_request(frame: &[u8]) -> Result<OrchestratorIpcRequest> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err(anyhow!("frame_too_large"));
    }
    let request: OrchestratorIpcRequest =
        serde_json::from_slice(frame).map_err(|_| anyhow!("invalid_request"))?;
    if !METHODS.contains(&request.method.as_str()) {
        return Err(anyhow!("unknown_method"));
    }
    if !validate_request(&request) {
        return Err(anyhow!("invalid_request"));
    }
    Ok(request)
}

pub mod test_support {
    use super::*;

    #[derive(Clone, Copy)]
    pub struct AcceptanceLimits {
        pub max_frame_bytes: usize,
        pub max_connections: usize,
        pub max_queued_requests: usize,
        pub max_requests_per_window: usize,
    }
    impl OrchestratorIpcServerConfig {
        pub fn synthetic(limits: AcceptanceLimits) -> Self {
            Self {
                max_frame_bytes: limits.max_frame_bytes,
                max_connections: limits.max_connections,
                max_queued_requests: limits.max_queued_requests,
                max_requests_per_window: limits.max_requests_per_window,
            }
        }
    }

    #[derive(Clone, Copy)]
    pub enum AcceptanceFault {
        None,
        TruncatedFrame,
        BrokenTransport,
        ConnectionCapacitySaturated,
        RequestQueueSaturated,
    }
    impl From<AcceptanceFault> for TestFault {
        fn from(value: AcceptanceFault) -> Self {
            match value {
                AcceptanceFault::None => Self::None,
                AcceptanceFault::TruncatedFrame => Self::Truncated,
                AcceptanceFault::BrokenTransport => Self::Broken,
                AcceptanceFault::ConnectionCapacitySaturated => Self::ConnectionFull,
                AcceptanceFault::RequestQueueSaturated => Self::QueueFull,
            }
        }
    }

    #[derive(Clone)]
    pub struct SyntheticPeer(PeerAdmission);
    impl SyntheticPeer {
        pub fn owner_bound<'a>(
            id: &str,
            _kind: &str,
            protocol: &str,
            operations: impl IntoIterator<Item = &'a str>,
        ) -> Self {
            Self(PeerAdmission {
                peer_id: id.into(),
                owner_bound: true,
                protocol_version: protocol.into(),
                operations: operations.into_iter().map(str::to_owned).collect(),
            })
        }
        pub fn foreign<'a>(
            id: &str,
            _kind: &str,
            protocol: &str,
            operations: impl IntoIterator<Item = &'a str>,
        ) -> Self {
            Self(PeerAdmission {
                peer_id: id.into(),
                owner_bound: false,
                protocol_version: protocol.into(),
                operations: operations.into_iter().map(str::to_owned).collect(),
            })
        }
    }

    pub struct TestConnection {
        server: OrchestratorIpcServer,
        peer: SyntheticPeer,
        _permit: IpcCapacityPermit,
    }
    impl std::fmt::Debug for TestConnection {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            formatter
                .debug_struct("TestConnection")
                .finish_non_exhaustive()
        }
    }
    impl TestConnection {
        pub fn exchange(&self, frame: &[u8]) -> ExchangeObservation {
            self.server
                .scheduled_exchange(&self.peer.0, frame, TestFault::None)
        }
    }

    #[derive(Debug)]
    pub struct TestConnectionError {
        code: &'static str,
    }
    impl TestConnectionError {
        pub fn code(&self) -> &'static str {
            self.code
        }
    }

    #[derive(Clone, Default)]
    pub struct FaultInjectingLocalTransport;
    impl FaultInjectingLocalTransport {
        pub fn new() -> Self {
            Self
        }
    }

    #[derive(Clone, Default)]
    pub struct CountingMutationHandler {
        inner: Arc<CountingInner>,
    }
    #[derive(Default)]
    struct CountingInner {
        mutations: AtomicUsize,
        block_next: AtomicBool,
        blocked: (Mutex<bool>, Condvar),
        release: (Mutex<bool>, Condvar),
    }
    impl CountingMutationHandler {
        pub fn new() -> Self {
            Self::default()
        }
        pub fn mutations(&self) -> usize {
            self.inner.mutations.load(Ordering::Acquire)
        }
        pub fn block_next_request(&self) {
            self.inner.block_next.store(true, Ordering::Release);
        }
        pub fn wait_until_blocked(&self, timeout: Duration) -> bool {
            let guard = self
                .inner
                .blocked
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner());
            if *guard {
                return true;
            }
            self.inner
                .blocked
                .1
                .wait_timeout_while(guard, timeout, |v| !*v)
                .map(|v| *v.0)
                .unwrap_or(false)
        }
        pub fn release_blocked_request(&self) {
            *self
                .inner
                .release
                .0
                .lock()
                .unwrap_or_else(|e| e.into_inner()) = true;
            self.inner.release.1.notify_all();
        }
    }
    impl OrchestratorIpcHandler for CountingMutationHandler {
        fn handle(&self, request: &OrchestratorIpcRequest) -> OrchestratorIpcReceipt {
            if self.inner.block_next.swap(false, Ordering::AcqRel) {
                *self
                    .inner
                    .blocked
                    .0
                    .lock()
                    .unwrap_or_else(|e| e.into_inner()) = true;
                self.inner.blocked.1.notify_all();
                let guard = self
                    .inner
                    .release
                    .0
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                drop(
                    self.inner
                        .release
                        .1
                        .wait_while(guard, |released| !*released)
                        .unwrap_or_else(|e| e.into_inner()),
                );
            }
            if matches!(
                request.method.as_str(),
                "service.stop"
                    | "workflow.submit"
                    | "workflow.cancel"
                    | "workflow.approve"
                    | "workflow.message"
            ) {
                self.inner.mutations.fetch_add(1, Ordering::AcqRel);
            }
            OrchestratorIpcReceipt::success(&request.request_id, json!({"state": "running"}))
        }
        fn mutation_count(&self) -> usize {
            self.mutations()
        }
    }

    impl OrchestratorIpcServer {
        pub fn with_fault_transport_for_test(
            config: OrchestratorIpcServerConfig,
            _transport: FaultInjectingLocalTransport,
            handler: impl OrchestratorIpcHandler,
        ) -> Result<Self> {
            Ok(Self::new(config, handler))
        }
        pub fn inject_test_exchange(
            &self,
            peer: SyntheticPeer,
            frame: &[u8],
            fault: AcceptanceFault,
        ) -> ExchangeObservation {
            self.scheduled_exchange(&peer.0, frame, fault.into())
        }
        pub fn open_test_connection(
            &self,
            peer: SyntheticPeer,
        ) -> std::result::Result<TestConnection, TestConnectionError> {
            let permit = self
                .try_connection_permit()
                .map_err(|code| TestConnectionError { code })?;
            Ok(TestConnection {
                server: self.clone(),
                peer,
                _permit: permit,
            })
        }
    }
}
