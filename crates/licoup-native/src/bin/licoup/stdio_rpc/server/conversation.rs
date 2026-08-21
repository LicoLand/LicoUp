use super::super::*;
use anyhow::anyhow;
use licoup_native::domain::client_conversation::{
    ConversationRuntimeScope, ConversationStore, DispatchState,
};
use licoup_native::ffi::generated::client_error::ClientError;
use licoup_native::platform::runtime_adapters::RuntimeAdapterError;
use std::{
    collections::{HashMap, VecDeque},
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

pub(super) const MAX_CONCURRENT_SENDS: usize = 16;
const SHUTDOWN_POLL_INTERVAL: Duration = Duration::from_millis(5);
const MAX_TRACKED_TURNS: usize = 64;
const DEFAULT_TURN_CACHE_BYTES: usize = 16 * 1024 * 1024;
const REPLAY_PAGE_SIZE: usize = 256;

#[derive(Clone)]
pub(crate) struct PersistentConversationRuntime {
    inner: Arc<PersistentConversationRuntimeInner>,
}

struct PersistentConversationRuntimeInner {
    turns: Mutex<HashMap<String, Arc<PersistentTurn>>>,
    turns_changed: Condvar,
    clients: AtomicUsize,
    store: ConversationStore,
    cache_budget: usize,
}

pub(super) struct PersistentTurn {
    scope: ConversationRuntimeScope,
    agent_id: String,
    session_id: Mutex<String>,
    turn_id: Mutex<String>,
    state: Mutex<PersistentTurnState>,
    changed: Condvar,
    store: ConversationStore,
    cache_budget: usize,
}

#[derive(Default)]
struct PersistentTurnState {
    cache: VecDeque<CachedFrame>,
    cache_bytes: usize,
    high_water: u64,
    terminal: Option<PersistentTerminal>,
}

#[derive(Clone)]
struct CachedFrame {
    cursor: u64,
    encoded_bytes: usize,
    event: Value,
}

#[derive(Clone)]
struct PersistentTerminal {
    ok: bool,
    payload: Value,
}

impl PersistentConversationRuntime {
    pub(crate) fn new(store: ConversationStore) -> Self {
        Self::with_cache_budget(store, DEFAULT_TURN_CACHE_BYTES)
    }

    fn with_cache_budget(store: ConversationStore, cache_budget: usize) -> Self {
        Self {
            inner: Arc::new(PersistentConversationRuntimeInner {
                turns: Mutex::new(HashMap::new()),
                turns_changed: Condvar::new(),
                clients: AtomicUsize::new(0),
                store,
                cache_budget,
            }),
        }
    }

    pub(crate) fn client_connected(&self) {
        self.inner.clients.fetch_add(1, Ordering::AcqRel);
    }

    pub(crate) fn client_disconnected(&self) {
        self.inner.clients.fetch_sub(1, Ordering::AcqRel);
    }

    pub(crate) fn idle(&self) -> bool {
        self.inner.clients.load(Ordering::Acquire) == 0
            && self.inner.turns.lock().is_ok_and(|turns| {
                turns.values().all(|turn| {
                    turn.state
                        .lock()
                        .is_ok_and(|state| state.terminal.is_some())
                })
            })
    }

    fn begin(&self, params: &Value) -> std::result::Result<Arc<PersistentTurn>, ClientError> {
        let agent_id = params
            .get("agent")
            .or_else(|| params.get("agentId"))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let session_id = params
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let text = params
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut turns = self.inner.turns.lock().expect("turn registry lock");
        if turns.len() >= MAX_TRACKED_TURNS {
            let completed = turns
                .iter()
                .find(|(_, turn)| {
                    turn.state
                        .lock()
                        .is_ok_and(|state| state.terminal.is_some())
                })
                .map(|(handle, _)| handle.clone());
            if let Some(completed) = completed {
                turns.remove(&completed);
            } else {
                return Err(stdio_rpc_client_error("conversation_capacity_exhausted"));
            }
        }
        let scope = self
            .inner
            .store
            .prepare_runtime_dispatch(
                agent_id,
                session_id,
                text,
                params.get("conversationId").and_then(Value::as_str),
                params.get("membershipId").and_then(Value::as_str),
                params.get("causationId").and_then(Value::as_str),
                params.get("dispatchId").and_then(Value::as_str),
            )
            .map_err(|_| stdio_rpc_client_error("conversation_persistence_failed"))?;
        let turn = Arc::new(PersistentTurn {
            scope: scope.clone(),
            agent_id: agent_id.to_owned(),
            session_id: Mutex::new(session_id.to_owned()),
            turn_id: Mutex::new(String::new()),
            state: Mutex::new(PersistentTurnState::default()),
            changed: Condvar::new(),
            store: self.inner.store.clone(),
            cache_budget: self.inner.cache_budget,
        });
        turns.insert(scope.dispatch_id.clone(), Arc::clone(&turn));
        self.inner.turns_changed.notify_all();
        Ok(turn)
    }

    fn turn(&self, handle: &str) -> Option<Arc<PersistentTurn>> {
        self.inner.turns.lock().ok()?.get(handle).cloned()
    }

    pub(super) fn scoped_control_params(
        &self,
        params: &Value,
    ) -> std::result::Result<Value, ClientError> {
        let handle = params
            .get("turnHandle")
            .and_then(Value::as_str)
            .filter(|value| valid_turn_handle(value))
            .ok_or_else(|| stdio_rpc_client_error("invalid_turn_handle"))?;
        let conversation_id = params
            .get("conversationId")
            .and_then(Value::as_str)
            .filter(|value| valid_turn_handle(value))
            .ok_or_else(|| stdio_rpc_client_error("invalid_conversation_scope"))?;
        let turn = self
            .turn(handle)
            .ok_or_else(|| stdio_rpc_client_error("turn_not_found"))?;
        if turn.scope.conversation_id != conversation_id {
            return Err(stdio_rpc_client_error("turn_scope_mismatch"));
        }
        if turn
            .state
            .lock()
            .map_err(|_| stdio_rpc_client_error("turn_unavailable"))?
            .terminal
            .is_some()
        {
            return Err(stdio_rpc_client_error("turn_not_active"));
        }
        if params
            .get("agent")
            .or_else(|| params.get("agentId"))
            .and_then(Value::as_str)
            .is_some_and(|agent| agent.trim() != turn.agent_id)
        {
            return Err(stdio_rpc_client_error("turn_scope_mismatch"));
        }
        let mut resolved = params.clone();
        let object = resolved
            .as_object_mut()
            .ok_or_else(|| stdio_rpc_client_error("invalid_params"))?;
        object.insert("agent".to_owned(), Value::String(turn.agent_id.clone()));
        object.insert(
            "sessionId".to_owned(),
            Value::String(turn.session_id.lock().expect("turn session lock").clone()),
        );
        let turn_id = turn.turn_id.lock().expect("turn id lock").clone();
        if !turn_id.is_empty() {
            object.insert("turnId".to_owned(), Value::String(turn_id));
        }
        Ok(resolved)
    }

    /// Open one Membership-scoped dispatch: register the PersistentTurn and
    /// commit its Conversation facts before any native work starts. The
    /// returned handle is the dispatch identity the caller attaches or runs.
    pub(crate) fn open_turn(
        &self,
        params: &Value,
    ) -> std::result::Result<String, RuntimeAdapterError> {
        let turn = self.begin_accepted(params)?;
        Ok(turn.scope.dispatch_id.clone())
    }

    /// Run one previously opened turn to its terminal state. Registration is
    /// never repeated here; an unknown handle fails closed.
    pub(crate) fn run_open_turn(
        &self,
        handle: &str,
        params: &Value,
        portable_data_dir: Option<PathBuf>,
    ) -> std::result::Result<Value, RuntimeAdapterError> {
        let Some(turn) = self.turn(handle) else {
            return Err(RuntimeAdapterError::ConversationDispatchFailed);
        };
        self.run_started_turn(turn, params, portable_data_dir)
    }

    /// Settle one opened turn that will never run. The dispatch completion
    /// authority writes the terminal state with a typed abandonment code so a
    /// registered entry turn can never linger as active.
    pub(crate) fn abandon_turn(&self, handle: &str) {
        let Some(turn) = self.turn(handle) else {
            return;
        };
        let settled = turn
            .state
            .lock()
            .map(|state| state.terminal.is_some())
            .unwrap_or(true);
        if settled {
            return;
        }
        let terminal = PersistentTerminal {
            ok: false,
            payload: json!({
                "ok": false,
                "error": {
                    "code": "conversation_dispatch_failed",
                    "stage": "conversation/dispatch",
                }
            }),
        };
        if Self::finish(&turn, terminal.clone()).is_err() {
            Self::force_terminal(&turn, terminal);
        }
    }

    /// Begin a Membership-scoped PersistentTurn and return immediately so the
    /// caller can attach. Drive continues on a host thread with the same sink
    /// as a blocking open-plus-run turn.
    pub(crate) fn start_background(
        &self,
        params: &Value,
        portable_data_dir: Option<PathBuf>,
    ) -> std::result::Result<Value, RuntimeAdapterError> {
        let handle = self.open_turn(params)?;
        let Some(turn) = self.turn(&handle) else {
            self.abandon_turn(&handle);
            return Err(RuntimeAdapterError::ConversationDispatchFailed);
        };
        let receipt = json!({
            "ok": true,
            "accepted": true,
            "turnHandle": turn.scope.dispatch_id,
            "conversationId": turn.scope.conversation_id,
            "membershipId": turn.scope.membership_id,
        });
        let runtime = self.clone();
        let params = params.clone();
        if std::thread::Builder::new()
            .name("conversation-dispatch".to_owned())
            .spawn(move || {
                let _ = runtime.run_started_turn(turn, &params, portable_data_dir);
            })
            .is_err()
        {
            self.abandon_turn(&handle);
            return Err(RuntimeAdapterError::ConversationDispatchFailed);
        }
        Ok(receipt)
    }

    pub(crate) fn steer_sync(
        &self,
        params: &Value,
    ) -> std::result::Result<Value, RuntimeAdapterError> {
        let params = self
            .scoped_control_params(params)
            .map_err(|_| RuntimeAdapterError::ConversationDispatchFailed)?;
        licoup_native::platform::dispatch_lane_operation("steer", &params)
    }

    fn begin_accepted(
        &self,
        params: &Value,
    ) -> std::result::Result<Arc<PersistentTurn>, RuntimeAdapterError> {
        let turn = self
            .begin(params)
            .map_err(|_| RuntimeAdapterError::ConversationDispatchFailed)?;
        if Self::record_event(
            &turn,
            json!({
                "event": "agent.turn.accepted",
                "sessionId": "",
                "turnId": "",
                "payload": {"status": "accepted"}
            }),
        )
        .is_err()
        {
            persist_runtime_failure(
                &turn,
                &stdio_rpc_client_error("conversation_persistence_failed"),
            );
            return Err(RuntimeAdapterError::ConversationDispatchFailed);
        }
        Ok(turn)
    }

    fn run_started_turn(
        &self,
        turn: Arc<PersistentTurn>,
        params: &Value,
        portable_data_dir: Option<PathBuf>,
    ) -> std::result::Result<Value, RuntimeAdapterError> {
        let persistence_failed = Arc::new(AtomicBool::new(false));
        let sink_failed = Arc::clone(&persistence_failed);
        let sink_turn = Arc::clone(&turn);
        licoup_native::platform::install_stream_sink(Box::new(move |event| {
            if Self::record_event(&sink_turn, event).is_err() {
                sink_failed.store(true, Ordering::Release);
                panic!("conversation frame persistence failed");
            }
        }));
        let stream_guard = licoup_native::platform::StreamSinkGuard;
        let execution = catch_unwind(AssertUnwindSafe(|| {
            let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
            licoup_native::platform::dispatch_lane_operation("send", params)
        }));
        drop(stream_guard);

        match execution {
            Ok(Ok(value)) => {
                if Self::finish(
                    &turn,
                    PersistentTerminal {
                        ok: true,
                        payload: value.clone(),
                    },
                )
                .is_err()
                {
                    persist_runtime_failure(
                        &turn,
                        &stdio_rpc_client_error("conversation_persistence_failed"),
                    );
                    return Err(RuntimeAdapterError::ConversationDispatchFailed);
                }
                Ok(value)
            }
            Ok(Err(error)) => {
                persist_runtime_failure(&turn, &error.client_error());
                Err(error)
            }
            Err(_) => {
                persist_runtime_failure(
                    &turn,
                    &stdio_rpc_client_error(if persistence_failed.load(Ordering::Acquire) {
                        "conversation_persistence_failed"
                    } else {
                        "command_panicked"
                    }),
                );
                Err(RuntimeAdapterError::ConversationDispatchFailed)
            }
        }
    }

    pub(super) fn active(&self, params: &Value) -> Value {
        const MAX_CHANGE_WAIT: Duration = Duration::from_secs(2);

        let agent = params
            .get("agent")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let session = params
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let conversation_id = params
            .get("conversationId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim();
        let wait = Duration::from_millis(
            params
                .get("waitForChangeMs")
                .and_then(Value::as_u64)
                .unwrap_or(0)
                .min(MAX_CHANGE_WAIT.as_millis() as u64),
        );
        let deadline = Instant::now() + wait;
        let mut turns = self.inner.turns.lock().expect("turn registry lock");
        loop {
            let active = turns
                .values()
                .filter_map(|turn| {
                    let state = turn.state.lock().ok()?;
                    if state.terminal.is_some()
                        || (!agent.is_empty() && turn.agent_id != agent)
                        || (!conversation_id.is_empty()
                            && turn.scope.conversation_id != conversation_id)
                    {
                        return None;
                    }
                    let turn_session = turn.session_id.lock().ok()?.clone();
                    if !session.is_empty() && turn_session != session {
                        return None;
                    }
                    Some(json!({
                        "turnHandle": turn.scope.dispatch_id,
                        "conversationId": turn.scope.conversation_id,
                        "membershipId": turn.scope.membership_id,
                        "agent": turn.agent_id,
                        "sessionId": turn_session,
                        "turnId": turn.turn_id.lock().ok()?.clone(),
                        "highWater": state.high_water,
                    }))
                })
                .collect::<Vec<_>>();
            if !active.is_empty() || wait.is_zero() || Instant::now() >= deadline {
                return json!({"turns": active});
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (next, timed_out) = self
                .inner
                .turns_changed
                .wait_timeout(turns, remaining)
                .expect("turn registry lock");
            turns = next;
            if timed_out.timed_out() {
                return json!({"turns": []});
            }
        }
    }

    fn record_event(
        turn: &Arc<PersistentTurn>,
        mut event: Value,
    ) -> licoup_native::domain::client_conversation::StoreResult<Value> {
        if let Some(session_id) = event.get("sessionId").and_then(Value::as_str) {
            if !session_id.trim().is_empty() {
                *turn.session_id.lock().expect("turn session lock") = session_id.trim().to_owned();
            }
        }
        if let Some(turn_id) = event.get("turnId").and_then(Value::as_str) {
            if !turn_id.trim().is_empty() {
                *turn.turn_id.lock().expect("turn id lock") = turn_id.trim().to_owned();
            }
        }
        // Serialize cursor allocation through canonical persistence and the
        // disposable cache update. Computing the cursor under a short lock and
        // releasing it before the store write lets concurrent adapter emitters
        // persist the same cursor before either detects the race.
        let mut state = turn.state.lock().expect("turn state lock");
        let cursor = state.high_water + 1;
        if let Some(object) = event.as_object_mut() {
            object.insert(
                "turnHandle".to_owned(),
                Value::String(turn.scope.dispatch_id.clone()),
            );
            object.insert(
                "conversationId".to_owned(),
                Value::String(turn.scope.conversation_id.clone()),
            );
            object.insert("cursor".to_owned(), Value::from(cursor));
        }
        turn.store
            .append_runtime_frame(&turn.scope, cursor, &event)?;
        let session_id = turn.session_id.lock().expect("turn session lock").clone();
        turn.store
            .bind_runtime_session(&turn.scope, &turn.agent_id, &session_id, None, None)?;
        let encoded_bytes = serde_json::to_vec(&event)?.len();
        state.high_water = cursor;
        state.cache_bytes = state.cache_bytes.saturating_add(encoded_bytes);
        state.cache.push_back(CachedFrame {
            cursor,
            encoded_bytes,
            event: event.clone(),
        });
        while state.cache_bytes > turn.cache_budget {
            let Some(evicted) = state.cache.pop_front() else {
                break;
            };
            state.cache_bytes = state.cache_bytes.saturating_sub(evicted.encoded_bytes);
        }
        turn.changed.notify_all();
        Ok(event)
    }

    fn finish(turn: &Arc<PersistentTurn>, terminal: PersistentTerminal) -> Result<()> {
        let response_ok = terminal
            .payload
            .get("ok")
            .and_then(Value::as_bool)
            .unwrap_or(terminal.ok);
        let turn_status = terminal
            .payload
            .get("turnStatus")
            .or_else(|| {
                terminal
                    .payload
                    .get("error")
                    .and_then(|error| error.get("turnStatus"))
            })
            .and_then(Value::as_str);
        let state = if terminal.ok && response_ok {
            DispatchState::Completed
        } else if turn_status == Some("cancelled") {
            DispatchState::Cancelled
        } else {
            DispatchState::Failed
        };
        let error_code = (state != DispatchState::Completed)
            .then(|| {
                terminal
                    .payload
                    .get("code")
                    .or_else(|| {
                        terminal
                            .payload
                            .get("error")
                            .and_then(|error| error.get("code"))
                    })
                    .and_then(Value::as_str)
            })
            .flatten();
        if let Some(session_id) = terminal
            .payload
            .get("nativeSessionId")
            .or_else(|| terminal.payload.get("sessionId"))
            .and_then(Value::as_str)
        {
            turn.store.bind_runtime_session(
                &turn.scope,
                &turn.agent_id,
                session_id,
                terminal
                    .payload
                    .get("sourcePath")
                    .or_else(|| terminal.payload.get("conversationPath"))
                    .and_then(Value::as_str),
                terminal
                    .payload
                    .get("workingDirectory")
                    .and_then(Value::as_str),
            )?;
        }
        turn.store
            .finish_runtime_dispatch(&turn.scope, &terminal.payload, state, error_code)?;
        let mut state = turn.state.lock().expect("turn state lock");
        state.terminal = Some(terminal);
        turn.changed.notify_all();
        Ok(())
    }

    fn force_terminal(turn: &Arc<PersistentTurn>, terminal: PersistentTerminal) {
        let mut state = turn.state.lock().expect("turn state lock");
        state.terminal = Some(terminal);
        turn.changed.notify_all();
    }
}

pub(super) fn spawn_send<W>(
    writer: Arc<Mutex<W>>,
    request_id: String,
    workflow_id: String,
    params: Value,
    portable_data_dir: Option<PathBuf>,
    runtime: PersistentConversationRuntime,
) -> std::result::Result<std::thread::JoinHandle<()>, ClientError>
where
    W: Write + Send + 'static,
{
    let turn = runtime.begin(&params)?;
    let handle = turn.scope.dispatch_id.clone();
    std::thread::Builder::new()
        .name("conversation-send".to_owned())
        .spawn(move || {
            let _ = execute(
                &writer,
                &request_id,
                &workflow_id,
                "send",
                params,
                portable_data_dir,
                true,
                Some(turn),
            );
        })
        .map_err(|_| {
            runtime.abandon_turn(&handle);
            stdio_rpc_client_error("agent_conversation_dispatch_failed")
        })
}

pub(super) fn spawn_attach<W>(
    writer: Arc<Mutex<W>>,
    request_id: String,
    workflow_id: String,
    params: Value,
    runtime: PersistentConversationRuntime,
) -> std::result::Result<std::thread::JoinHandle<()>, ClientError>
where
    W: Write + Send + 'static,
{
    let handle = params
        .get("turnHandle")
        .and_then(Value::as_str)
        .filter(|value| valid_turn_handle(value))
        .ok_or_else(|| stdio_rpc_client_error("invalid_turn_handle"))?;
    let conversation_id = params
        .get("conversationId")
        .and_then(Value::as_str)
        .filter(|value| valid_turn_handle(value))
        .ok_or_else(|| stdio_rpc_client_error("invalid_conversation_scope"))?;
    let after_cursor = params
        .get("afterCursor")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let turn = runtime
        .turn(handle)
        .ok_or_else(|| stdio_rpc_client_error("turn_not_found"))?;
    if turn.scope.conversation_id != conversation_id {
        return Err(stdio_rpc_client_error("turn_scope_mismatch"));
    }
    let high_water = turn
        .state
        .lock()
        .map_err(|_| stdio_rpc_client_error("turn_unavailable"))?
        .high_water;
    if after_cursor > high_water {
        return Err(stdio_rpc_client_error("cursor_ahead"));
    }
    std::thread::Builder::new()
        .name("conversation-attach".to_owned())
        .spawn(move || {
            let _ = replay_turn(&writer, &request_id, &workflow_id, &turn, after_cursor);
        })
        .map_err(|_| stdio_rpc_client_error("agent_conversation_dispatch_failed"))
}

fn replay_turn<W: Write>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    turn: &Arc<PersistentTurn>,
    mut cursor: u64,
) -> Result<()> {
    let mut request_sequence = 0_u64;
    loop {
        let (captured_high_water, cached, terminal) = {
            let state = turn.state.lock().expect("turn state lock");
            let cache_floor = state
                .cache
                .front()
                .map(|frame| frame.cursor)
                .unwrap_or(state.high_water.saturating_add(1));
            let cached = (cursor.saturating_add(1) >= cache_floor).then(|| {
                state
                    .cache
                    .iter()
                    .filter(|frame| frame.cursor > cursor)
                    .map(|frame| frame.event.clone())
                    .collect::<Vec<_>>()
            });
            (state.high_water, cached, state.terminal.clone())
        };
        while cursor < captured_high_water {
            let frames = if let Some(cached) = cached.as_ref() {
                cached
                    .iter()
                    .filter(|event| event.get("cursor").and_then(Value::as_u64) > Some(cursor))
                    .cloned()
                    .collect::<Vec<_>>()
            } else {
                turn.store.runtime_frames_after(
                    &turn.scope,
                    cursor,
                    captured_high_water,
                    REPLAY_PAGE_SIZE,
                )?
            };
            if frames.is_empty() {
                return Err(anyhow!("canonical_replay_gap"));
            }
            for event in frames {
                let next_cursor = event
                    .get("cursor")
                    .and_then(Value::as_u64)
                    .ok_or_else(|| anyhow!("canonical_replay_cursor_missing"))?;
                if next_cursor != cursor + 1 || next_cursor > captured_high_water {
                    return Err(anyhow!("canonical_replay_cursor_invalid"));
                }
                request_sequence += 1;
                write_stdio_rpc_event(writer, request_id, workflow_id, request_sequence, event)?;
                cursor = next_cursor;
            }
        }
        if let Some(terminal) = terminal {
            request_sequence += 1;
            return write_persistent_terminal(
                writer,
                request_id,
                workflow_id,
                request_sequence,
                &terminal,
            )
            .map_err(Into::into);
        }
        let mut state = turn.state.lock().expect("turn state lock");
        while state.high_water == cursor && state.terminal.is_none() {
            state = turn.changed.wait(state).expect("turn state lock");
        }
    }
}

fn valid_turn_handle(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

pub(super) fn execute<W>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    operation: &str,
    params: Value,
    portable_data_dir: Option<PathBuf>,
    stream_events: bool,
    persistent_turn: Option<Arc<PersistentTurn>>,
) -> Result<()>
where
    W: Write + Send + 'static,
{
    let (initial_sequence, observer_is_connected) = if let Some(turn) = persistent_turn.as_ref() {
        let accepted = match PersistentConversationRuntime::record_event(
            turn,
            json!({
                "event": "agent.turn.accepted",
                "sessionId": "",
                "turnId": "",
                "payload": {"status": "accepted"}
            }),
        ) {
            Ok(accepted) => accepted,
            Err(_) => {
                let error = stdio_rpc_client_error("conversation_persistence_failed");
                let terminal = PersistentTerminal {
                    ok: false,
                    payload: serde_json::to_value(&error)
                        .unwrap_or_else(|_| json!({"code": "conversation_persistence_failed"})),
                };
                if PersistentConversationRuntime::finish(turn, terminal.clone()).is_err() {
                    PersistentConversationRuntime::force_terminal(turn, terminal);
                }
                write_stdio_rpc_terminal_error(writer, request_id, workflow_id, 1, &error)?;
                return Ok(());
            }
        };
        (
            1,
            write_stdio_rpc_event(writer, request_id, workflow_id, 1, accepted).is_ok(),
        )
    } else {
        (0, true)
    };
    let sequence = Arc::new(AtomicU64::new(initial_sequence));
    let observer_connected = Arc::new(AtomicBool::new(observer_is_connected));
    let persistence_failed = Arc::new(AtomicBool::new(false));
    let stream_guard = stream_events.then(|| {
        let writer = Arc::clone(writer);
        let request_id = request_id.to_owned();
        let workflow_id = workflow_id.to_owned();
        let sequence = Arc::clone(&sequence);
        let observer_connected = Arc::clone(&observer_connected);
        let persistence_failed = Arc::clone(&persistence_failed);
        let persistent_turn = persistent_turn.clone();
        licoup_native::platform::install_stream_sink(Box::new(move |event| {
            let event = if let Some(turn) = persistent_turn.as_ref() {
                match PersistentConversationRuntime::record_event(turn, event) {
                    Ok(event) => event,
                    Err(_) => {
                        persistence_failed.store(true, Ordering::Release);
                        panic!("conversation frame persistence failed");
                    }
                }
            } else {
                event
            };
            let next = sequence.load(Ordering::Acquire) + 1;
            if observer_connected.load(Ordering::Acquire)
                && write_stdio_rpc_event(&writer, &request_id, &workflow_id, next, event).is_ok()
            {
                sequence.store(next, Ordering::Release);
            } else {
                observer_connected.store(false, Ordering::Release);
            }
        }));
        licoup_native::platform::StreamSinkGuard
    });
    let execution = catch_unwind(AssertUnwindSafe(|| {
        let _guard = PortableDataDirOverrideGuard::set(portable_data_dir);
        licoup_native::platform::dispatch_lane_operation(operation, &params)
            .map(licoup_native::ffi::commands::CliExecution::Json)
    }));
    drop(stream_guard);
    let terminal_sequence = sequence.fetch_add(1, Ordering::AcqRel) + 1;
    match execution {
        Ok(Ok(licoup_native::ffi::commands::CliExecution::Json(value))) => {
            if let Some(turn) = persistent_turn.as_ref() {
                if PersistentConversationRuntime::finish(
                    turn,
                    PersistentTerminal {
                        ok: true,
                        payload: value.clone(),
                    },
                )
                .is_err()
                {
                    return finish_error(
                        writer,
                        request_id,
                        workflow_id,
                        terminal_sequence,
                        persistent_turn.as_ref(),
                        observer_connected.load(Ordering::Acquire),
                        stdio_rpc_client_error("conversation_persistence_failed"),
                    )
                    .map_err(Into::into);
                }
            }
            if observer_connected.load(Ordering::Acquire) {
                write_stdio_rpc_terminal_success(
                    writer,
                    request_id,
                    workflow_id,
                    terminal_sequence,
                    value,
                )
            } else {
                Ok(())
            }
        }
        Ok(Err(error)) => finish_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            persistent_turn.as_ref(),
            observer_connected.load(Ordering::Acquire),
            error.client_error(),
        ),
        Err(_) => finish_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            persistent_turn.as_ref(),
            observer_connected.load(Ordering::Acquire),
            stdio_rpc_client_error(if persistence_failed.load(Ordering::Acquire) {
                "conversation_persistence_failed"
            } else {
                "command_panicked"
            }),
        ),
        Ok(Ok(_)) => finish_error(
            writer,
            request_id,
            workflow_id,
            terminal_sequence,
            persistent_turn.as_ref(),
            observer_connected.load(Ordering::Acquire),
            stdio_rpc_client_error("command_failed"),
        ),
    }?;
    Ok(())
}

fn finish_error<W: Write>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    sequence: u64,
    turn: Option<&Arc<PersistentTurn>>,
    observer_connected: bool,
    error: ClientError,
) -> io::Result<()> {
    if let Some(turn) = turn {
        let terminal = PersistentTerminal {
            ok: false,
            payload: serde_json::to_value(&error)
                .unwrap_or_else(|_| json!({"code": "command_failed"})),
        };
        if PersistentConversationRuntime::finish(turn, terminal.clone()).is_err() {
            PersistentConversationRuntime::force_terminal(turn, terminal);
        }
    }
    if observer_connected {
        write_stdio_rpc_terminal_error(writer, request_id, workflow_id, sequence, &error)
    } else {
        Ok(())
    }
}

fn persist_runtime_failure(turn: &Arc<PersistentTurn>, error: &ClientError) {
    let terminal = PersistentTerminal {
        ok: false,
        payload: serde_json::to_value(error)
            .unwrap_or_else(|_| json!({"code": "conversation_dispatch_failed"})),
    };
    if PersistentConversationRuntime::finish(turn, terminal.clone()).is_err() {
        PersistentConversationRuntime::force_terminal(turn, terminal);
    }
}

fn write_persistent_terminal<W: Write>(
    writer: &Arc<Mutex<W>>,
    request_id: &str,
    workflow_id: &str,
    sequence: u64,
    terminal: &PersistentTerminal,
) -> io::Result<()> {
    let frame = if terminal.ok {
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": request_id,
            "workflowId": workflow_id,
            "kind": "terminal",
            "sequence": sequence,
            "ok": true,
            "result": terminal.payload,
        })
    } else {
        json!({
            "protocol": STDIO_RPC_PROTOCOL,
            "id": request_id,
            "workflowId": workflow_id,
            "kind": "terminal",
            "sequence": sequence,
            "ok": false,
            "error": terminal.payload,
        })
    };
    let mut writer = writer
        .lock()
        .map_err(|_| io::Error::other("conversation writer lock failed"))?;
    if try_write_stdio_rpc_response(&mut *writer, &frame, STDIO_RPC_MAX_RESPONSE_BYTES)? {
        Ok(())
    } else {
        Err(io::Error::other("conversation terminal exceeds limit"))
    }
}

pub(super) fn has_capacity(workers: &[std::thread::JoinHandle<()>]) -> bool {
    workers.len() < MAX_CONCURRENT_SENDS
}

/// The strategy drive's Conversation-dispatch port, composed once where the
/// persistent host runtime already exists. Open registers a turn, run executes
/// an opened turn, and abandon settles one that will never run; an absent
/// runtime keeps the strategy service fail closed.
pub(super) fn strategy_turn_port(
    runtime: PersistentConversationRuntime,
    portable_data_dir: Option<PathBuf>,
) -> licoup_native::domain::adaptive_flywheel::ActorTurnPort {
    let open_runtime = runtime.clone();
    let run_runtime = runtime.clone();
    let run_dir = portable_data_dir;
    licoup_native::domain::adaptive_flywheel::ActorTurnPort {
        open: Arc::new(move |params| open_runtime.open_turn(params)),
        run: Arc::new(move |handle, params| {
            run_runtime.run_open_turn(handle, params, run_dir.clone())
        }),
        abandon: Arc::new(move |handle| runtime.abandon_turn(handle)),
    }
}

pub(super) fn join_until_completion(workers: &mut Vec<std::thread::JoinHandle<()>>) {
    while !workers.is_empty() {
        reap_finished(workers);
        if !workers.is_empty() {
            std::thread::sleep(SHUTDOWN_POLL_INTERVAL);
        }
    }
}

#[cfg(test)]
fn join_until(workers: &mut Vec<std::thread::JoinHandle<()>>, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        reap_finished(workers);
        if workers.is_empty() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

pub(super) fn reap_finished(workers: &mut Vec<std::thread::JoinHandle<()>>) {
    let mut index = 0;
    while index < workers.len() {
        if workers[index].is_finished() {
            let worker = workers.swap_remove(index);
            let _ = worker.join();
        } else {
            index += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use licoup_native::domain::client_conversation::{ConversationService, EventPartKind};

    fn runtime(cache_budget: usize) -> PersistentConversationRuntime {
        PersistentConversationRuntime::with_cache_budget(
            ConversationStore::open_in_memory().unwrap(),
            cache_budget,
        )
    }

    #[test]
    fn persistent_runtime_replays_after_cursor_in_order() {
        let runtime = runtime(1);
        let turn = runtime
            .begin(&json!({
                "agent": "synthetic",
                "sessionId": "session-1",
                "text": "synthetic prompt"
            }))
            .unwrap();
        for ordinal in 1..=3 {
            PersistentConversationRuntime::record_event(
                &turn,
                json!({
                    "event": "agent.message.chunk",
                    "sessionId": "session-1",
                    "turnId": "native-turn-1",
                    "payload": {"ordinal": ordinal}
                }),
            )
            .unwrap();
        }
        PersistentConversationRuntime::finish(
            &turn,
            PersistentTerminal {
                ok: true,
                payload: json!({
                    "ok": true,
                    "sessionId": "session-1",
                    "output": "final answer"
                }),
            },
        )
        .unwrap();

        let state = turn.state.lock().unwrap();
        assert!(state.cache_bytes <= 1);
        assert!(state.cache.is_empty());
        drop(state);

        let writer = Arc::new(Mutex::new(Vec::<u8>::new()));
        replay_turn(&writer, "request-attach", "workflow-1", &turn, 1).unwrap();
        let output = String::from_utf8(writer.lock().unwrap().clone()).unwrap();
        let frames = output
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(frames.len(), 3);
        assert_eq!(frames[0]["event"]["cursor"], 2);
        assert_eq!(frames[1]["event"]["cursor"], 3);
        assert_eq!(frames[2]["kind"], "terminal");
        assert_eq!(frames[0]["sequence"], 1);
        assert_eq!(frames[2]["sequence"], 3);

        let canonical = turn
            .store
            .page_events(&turn.scope.conversation_id, None, 20)
            .unwrap();
        let assistant = canonical
            .events
            .iter()
            .find(|event| event.id == turn.scope.event_id)
            .unwrap();
        assert!(assistant.finalized);
        assert_eq!(
            assistant.correlation_id.as_deref(),
            Some(turn.scope.dispatch_id.as_str())
        );
        assert!(
            assistant
                .parts
                .iter()
                .any(|part| { part.kind == EventPartKind::Text && part.content == "final answer" })
        );
        assert!(
            assistant
                .parts
                .iter()
                .all(|part| !part.content.contains("turnHandle"))
        );
    }

    #[test]
    fn persistent_runtime_serializes_concurrent_cursor_persistence() {
        const EMITTERS: usize = 8;
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        let turn = runtime
            .begin(&json!({"agent": "synthetic", "text": "synthetic prompt"}))
            .unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(EMITTERS));
        let mut emitters = Vec::with_capacity(EMITTERS);
        for ordinal in 0..EMITTERS {
            let turn = Arc::clone(&turn);
            let barrier = Arc::clone(&barrier);
            emitters.push(std::thread::spawn(move || {
                barrier.wait();
                PersistentConversationRuntime::record_event(
                    &turn,
                    json!({
                        "event": "agent.message.chunk",
                        "payload": {"ordinal": ordinal}
                    }),
                )
                .unwrap();
            }));
        }
        for emitter in emitters {
            emitter.join().unwrap();
        }

        let state = turn.state.lock().unwrap();
        assert_eq!(state.high_water, EMITTERS as u64);
        drop(state);
        let frames = turn
            .store
            .runtime_frames_after(&turn.scope, 0, EMITTERS as u64, EMITTERS)
            .unwrap();
        assert_eq!(frames.len(), EMITTERS);
        assert_eq!(
            frames
                .iter()
                .filter_map(|frame| frame.get("cursor").and_then(Value::as_u64))
                .collect::<Vec<_>>(),
            (1..=EMITTERS as u64).collect::<Vec<_>>()
        );
    }

    #[test]
    fn persistent_runtime_active_discovery_is_scoped_without_content() {
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        let turn = runtime
            .begin(&json!({
                "agent": "synthetic",
                "sessionId": "session-1",
                "text": "synthetic prompt"
            }))
            .unwrap();
        PersistentConversationRuntime::record_event(
            &turn,
            json!({
                "event": "agent.turn.processing",
                "sessionId": "session-1",
                "turnId": "native-turn-1",
                "payload": {"private": "not projected by discovery"}
            }),
        )
        .unwrap();

        let active = runtime.active(&json!({"agent": "synthetic", "sessionId": "session-1"}));
        assert_eq!(active["turns"].as_array().unwrap().len(), 1);
        let encoded = serde_json::to_string(&active).unwrap();
        assert!(!encoded.contains("not projected"));
        assert_eq!(active["turns"][0]["highWater"], 1);
        assert_eq!(
            active["turns"][0]["conversationId"],
            turn.scope.conversation_id
        );
    }

    #[test]
    fn persistent_runtime_active_discovery_waits_for_registration_signal() {
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        let waiter = runtime.clone();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let wait_barrier = Arc::clone(&barrier);
        let waiting = std::thread::spawn(move || {
            wait_barrier.wait();
            waiter.active(&json!({
                "agent": "synthetic",
                "waitForChangeMs": 1000
            }))
        });
        barrier.wait();
        let turn = runtime
            .begin(&json!({"agent": "synthetic", "text": "synthetic prompt"}))
            .unwrap();

        let active = waiting.join().unwrap();
        assert_eq!(active["turns"][0]["turnHandle"], turn.scope.dispatch_id);
    }

    #[test]
    fn persistent_runtime_resolves_controls_only_for_the_canonical_scope() {
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        let turn = runtime
            .begin(&json!({
                "agent": "synthetic",
                "sessionId": "session-1",
                "text": "synthetic prompt"
            }))
            .unwrap();
        PersistentConversationRuntime::record_event(
            &turn,
            json!({
                "event": "agent.turn.processing",
                "sessionId": "session-1",
                "turnId": "native-turn-1",
                "payload": {"status": "processing"}
            }),
        )
        .unwrap();

        let resolved = runtime
            .scoped_control_params(&json!({
                "turnHandle": turn.scope.dispatch_id,
                "conversationId": turn.scope.conversation_id,
                "text": "focus"
            }))
            .unwrap();
        assert_eq!(resolved["agent"], "synthetic");
        assert_eq!(resolved["sessionId"], "session-1");
        assert_eq!(resolved["turnId"], "native-turn-1");
        assert!(
            runtime
                .scoped_control_params(&json!({
                    "turnHandle": turn.scope.dispatch_id,
                    "conversationId": "conversation:other"
                }))
                .is_err()
        );
        assert!(
            runtime
                .scoped_control_params(&json!({"turnHandle": turn.scope.dispatch_id}))
                .is_err()
        );
    }

    #[test]
    fn persistent_runtime_reuses_group_conversation_ownership() {
        let store = ConversationStore::open_in_memory().unwrap();
        let service = ConversationService::from_store(store.clone());
        let group = service
            .execute(json!({
                "action": "conversation.create",
                "title": "Persistent Group",
                "owner": {"id": "human:local", "kind": "human", "displayName": "You"},
                "members": [
                    {"principal": {"id": "agent:synthetic", "kind": "agent", "displayName": "Synthetic", "agentId": "synthetic"}, "access": "member"}
                ]
            }))
            .unwrap();
        let conversation_id = group["id"].as_str().unwrap();
        let membership_id = group["memberships"]
            .as_array()
            .unwrap()
            .iter()
            .find(|membership| membership["principal"]["kind"] == "agent")
            .unwrap()["id"]
            .as_str()
            .unwrap();
        let runtime =
            PersistentConversationRuntime::with_cache_budget(store, DEFAULT_TURN_CACHE_BYTES);
        let turn = runtime
            .begin(&json!({
                "agent": "synthetic",
                "text": "group prompt",
                "conversationId": conversation_id,
                "membershipId": membership_id,
                "causationId": "event:source"
            }))
            .unwrap();

        assert_eq!(turn.scope.conversation_id, conversation_id);
        assert_eq!(turn.scope.membership_id, membership_id);
        assert_eq!(
            runtime.active(&json!({"conversationId": conversation_id}))["turns"][0]["turnHandle"],
            turn.scope.dispatch_id
        );
    }

    #[test]
    fn persistent_runtime_completed_turn_leaves_active_discovery() {
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        let turn = runtime
            .begin(&json!({"agent": "synthetic", "text": "synthetic prompt"}))
            .unwrap();
        PersistentConversationRuntime::finish(
            &turn,
            PersistentTerminal {
                ok: true,
                payload: json!({"ok": true}),
            },
        )
        .unwrap();
        assert!(
            runtime.active(&json!({"agent": "synthetic"}))["turns"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn persistent_runtime_is_not_idle_with_client_or_active_turn() {
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        assert!(runtime.idle());
        runtime.client_connected();
        assert!(!runtime.idle());
        runtime.client_disconnected();
        let turn = runtime
            .begin(&json!({"agent": "synthetic", "text": "synthetic prompt"}))
            .unwrap();
        assert!(!runtime.idle());
        PersistentConversationRuntime::finish(
            &turn,
            PersistentTerminal {
                ok: true,
                payload: json!({"ok": true}),
            },
        )
        .unwrap();
        assert!(runtime.idle());
    }

    #[test]
    fn persistent_runtime_projects_adapter_failure_as_failed_canonical_turn() {
        let runtime = runtime(DEFAULT_TURN_CACHE_BYTES);
        let turn = runtime
            .begin(&json!({"agent": "synthetic", "text": "synthetic prompt"}))
            .unwrap();
        PersistentConversationRuntime::finish(
            &turn,
            PersistentTerminal {
                // The RPC itself completed normally, but the adapter response
                // reports a failed Agent turn.
                ok: true,
                payload: json!({
                    "ok": false,
                    "error": {
                        "code": "synthetic_failure",
                        "stage": "conversation/dispatch"
                    }
                }),
            },
        )
        .unwrap();

        let canonical = turn
            .store
            .page_events(&turn.scope.conversation_id, None, 20)
            .unwrap();
        let assistant = canonical
            .events
            .iter()
            .find(|event| event.id == turn.scope.event_id)
            .unwrap();
        assert!(assistant.finalized);
        assert!(assistant.parts.iter().any(|part| {
            part.kind == EventPartKind::Diagnostic && part.content.contains("synthetic_failure")
        }));
        assert!(
            runtime.active(&json!({"conversationId": turn.scope.conversation_id}))["turns"]
                .as_array()
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn conversation_worker_capacity_is_bounded() {
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let wait = Arc::new(Mutex::new(wait));
        let mut workers = Vec::new();
        for _ in 0..MAX_CONCURRENT_SENDS {
            let wait = Arc::clone(&wait);
            workers.push(std::thread::spawn(move || {
                let _ = wait.lock().unwrap().recv();
            }));
        }

        assert!(!has_capacity(&workers));
        for _ in 0..MAX_CONCURRENT_SENDS {
            release.send(()).unwrap();
        }
        assert!(join_until(&mut workers, Duration::from_secs(1)));
    }

    #[test]
    fn conversation_worker_shutdown_has_a_deadline() {
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let mut workers = vec![std::thread::spawn(move || {
            let _ = wait.recv();
        })];

        assert!(!join_until(&mut workers, Duration::from_millis(20)));
        release.send(()).unwrap();
        assert!(join_until(&mut workers, Duration::from_secs(1)));
    }

    #[test]
    fn detached_conversation_host_waits_for_active_work_to_complete() {
        let (release, wait) = std::sync::mpsc::channel::<()>();
        let (joined, joined_rx) = std::sync::mpsc::channel::<()>();
        let worker = std::thread::spawn(move || {
            let _ = wait.recv();
        });

        let host = std::thread::spawn(move || {
            let mut workers = vec![worker];
            join_until_completion(&mut workers);
            joined.send(()).unwrap();
        });

        assert!(joined_rx.recv_timeout(Duration::from_millis(20)).is_err());
        release.send(()).unwrap();
        joined_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        host.join().unwrap();
    }
}
