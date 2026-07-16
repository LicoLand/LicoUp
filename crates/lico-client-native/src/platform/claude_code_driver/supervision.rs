use super::command::LaunchIdentity;
use super::control::{ControlDisposition, ControlRequest};
use super::errors::{ProtocolFailure, supervisor_failure};
use super::params::DriverConfig;
use super::transport::PersistentTransport;
use std::collections::HashMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

pub(super) const CONTROL_ACK_TIMEOUT: Duration = Duration::from_secs(1);
pub(super) const CONTROL_QUEUE_CAPACITY: usize = 4;
pub(super) const MAX_POOLED_TRANSPORTS: usize = 8;
pub(super) const MAX_TRACKED_SESSIONS: usize = 1024;

static NEXT_TRANSPORT_ID: AtomicU64 = AtomicU64::new(1);
static TRANSPORT_POOL: OnceLock<Mutex<HashMap<u64, Arc<ManagedTransport>>>> = OnceLock::new();
static SESSION_TRANSPORTS: OnceLock<Mutex<HashMap<String, Weak<ManagedTransport>>>> =
    OnceLock::new();

#[derive(Debug)]
pub(super) struct ManagedTransport {
    pub(super) id: u64,
    pub(super) identity: LaunchIdentity,
    pub(super) transport: Mutex<PersistentTransport>,
    pub(super) control_sender: SyncSender<ControlRequest>,
    pub(super) native_session_id: Mutex<Option<String>>,
    pub(super) active_session: Mutex<Option<String>>,
}

pub(super) fn spawn_transport(
    executable: &str,
    config: &DriverConfig,
    cwd: Option<&Path>,
    max_stderr: usize,
) -> Result<Arc<ManagedTransport>, ProtocolFailure> {
    let mut pool = transport_pool().lock().map_err(|_| supervisor_failure())?;
    pool.retain(|_, transport| Arc::strong_count(transport) > 0);
    if pool.len() >= MAX_POOLED_TRANSPORTS {
        return Err(ProtocolFailure::new(
            "claude_code_transport_capacity",
            "Claude Code reached the bounded persistent transport capacity.",
            "process/supervisor",
        ));
    }
    let identity = LaunchIdentity::new(executable, config, cwd);
    let (control_sender, control_receiver) = mpsc::sync_channel(CONTROL_QUEUE_CAPACITY);
    let transport = PersistentTransport::spawn(&identity, control_receiver, max_stderr)?;
    let id = NEXT_TRANSPORT_ID.fetch_add(1, Ordering::Relaxed);
    let managed = Arc::new(ManagedTransport {
        id,
        identity,
        transport: Mutex::new(transport),
        control_sender,
        native_session_id: Mutex::new(None),
        active_session: Mutex::new(None),
    });
    pool.insert(id, Arc::clone(&managed));
    Ok(managed)
}

pub(super) fn bind_session(managed: &Arc<ManagedTransport>, session_id: &str) {
    if session_id.is_empty() {
        return;
    }
    if let Ok(mut native) = managed.native_session_id.lock() {
        if native
            .as_deref()
            .is_some_and(|existing| existing != session_id)
        {
            return;
        }
        *native = Some(session_id.to_string());
    }
    if let Ok(mut sessions) = session_transports().lock() {
        sessions.retain(|_, transport| transport.strong_count() > 0);
        if sessions.len() >= MAX_TRACKED_SESSIONS
            && !sessions.contains_key(session_id)
            && let Some(key) = sessions.keys().next().cloned()
        {
            sessions.remove(&key);
        }
        sessions.insert(session_id.to_string(), Arc::downgrade(managed));
    }
}

fn transport_pool() -> &'static Mutex<HashMap<u64, Arc<ManagedTransport>>> {
    TRANSPORT_POOL.get_or_init(|| Mutex::new(HashMap::new()))
}

fn session_transports() -> &'static Mutex<HashMap<String, Weak<ManagedTransport>>> {
    SESSION_TRANSPORTS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(super) fn lookup_session_transport(session_id: &str) -> Option<Arc<ManagedTransport>> {
    if session_id.trim().is_empty() {
        return None;
    }
    session_transports()
        .lock()
        .ok()?
        .get(session_id)
        .and_then(Weak::upgrade)
}

pub(in crate::platform) fn has_live_session(session_id: &str) -> bool {
    lookup_session_transport(session_id).is_some()
}

pub(super) fn remove_transport(managed: &Arc<ManagedTransport>, cleanup: bool) {
    if let Ok(mut pool) = transport_pool().lock() {
        pool.remove(&managed.id);
    }
    if let Ok(mut sessions) = session_transports().lock() {
        sessions.retain(|_, weak| {
            weak.upgrade()
                .is_some_and(|current| !Arc::ptr_eq(&current, managed))
        });
    }
    if cleanup && let Ok(mut transport) = managed.transport.lock() {
        let _ = transport.shutdown();
    }
}

pub(super) fn set_active_session(managed: &ManagedTransport, session_id: Option<String>) {
    if let Ok(mut active) = managed.active_session.lock() {
        *active = session_id;
    }
}

pub(in crate::platform) fn cancel(session_id: &str) -> ControlDisposition {
    let Some(managed) = lookup_session_transport(session_id) else {
        return ControlDisposition::SessionUnavailable;
    };
    let active = managed
        .active_session
        .lock()
        .ok()
        .and_then(|value| value.clone());
    if active.as_deref() != Some(session_id) {
        return ControlDisposition::NoActiveTurn;
    }
    let (acknowledged, receiver) = mpsc::sync_channel(1);
    if managed
        .control_sender
        .try_send(ControlRequest::Cancel {
            session_id: session_id.to_string(),
            acknowledged,
        })
        .is_err()
    {
        return ControlDisposition::TransportUnavailable;
    }
    match receiver.recv_timeout(CONTROL_ACK_TIMEOUT) {
        Ok(true) => ControlDisposition::Accepted,
        Ok(false) => ControlDisposition::NoActiveTurn,
        Err(_) => ControlDisposition::TransportUnavailable,
    }
}

pub(in crate::platform) fn cleanup_session(session_id: &str) -> ControlDisposition {
    let Some(managed) = lookup_session_transport(session_id) else {
        return ControlDisposition::SessionUnavailable;
    };
    let active = managed
        .active_session
        .lock()
        .ok()
        .is_some_and(|value| value.is_some());
    if active {
        let (acknowledged, receiver) = mpsc::sync_channel(1);
        if managed
            .control_sender
            .try_send(ControlRequest::Cleanup { acknowledged })
            .is_err()
            || receiver.recv_timeout(CONTROL_ACK_TIMEOUT) != Ok(true)
        {
            return ControlDisposition::TransportUnavailable;
        }
    }
    remove_transport(&managed, true);
    ControlDisposition::Accepted
}
