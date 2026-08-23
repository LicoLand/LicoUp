use crate::platform::native_agent_parser::adapters::antigravity::valid_session_id;
use crate::platform::native_agent_parser::adapters::driver_registry::{
    registry_get, registry_insert, registry_remove,
};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ControlDisposition {
    Accepted,
    NotPersisted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

const REGISTRY_NAMESPACE: &str = "antigravity-active-turn";
const MAX_ACTIVE_TURNS: usize = 128;

pub(in crate::platform) fn register_active_turn(session_id: &str, pid: u32) {
    if !valid_session_id(session_id) {
        return;
    }
    let _ = registry_insert(REGISTRY_NAMESPACE, session_id, pid, MAX_ACTIVE_TURNS);
}

pub(in crate::platform) fn clear_active_turn(session_id: &str) {
    let _ = registry_remove::<u32>(REGISTRY_NAMESPACE, session_id);
}

pub(in crate::platform) fn cancel(session_id: &str) -> ControlDisposition {
    if !valid_session_id(session_id) {
        return ControlDisposition::SessionUnavailable;
    }
    let pid = registry_get::<u32>(REGISTRY_NAMESPACE, session_id);
    let Some(pid) = pid else {
        return ControlDisposition::NoActiveTurn;
    };
    #[cfg(unix)]
    {
        use nix::sys::signal::{Signal, kill};
        use nix::unistd::Pid;
        if kill(Pid::from_raw(pid as i32), Signal::SIGTERM).is_ok() {
            clear_active_turn(session_id);
            return ControlDisposition::Accepted;
        }
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
    }
    ControlDisposition::TransportUnavailable
}

pub(in crate::platform) fn cleanup_session(session_id: &str) -> ControlDisposition {
    if !valid_session_id(session_id) {
        return ControlDisposition::SessionUnavailable;
    }
    match remove_antigravity_brain(session_id) {
        Ok(true) => ControlDisposition::Accepted,
        Ok(false) => ControlDisposition::NotPersisted,
        Err(_) => ControlDisposition::TransportUnavailable,
    }
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn remove_antigravity_brain(session_id: &str) -> Result<bool, ()> {
    let Some(home) = home_dir() else {
        return Err(());
    };
    let brain = home
        .join(".gemini")
        .join("antigravity-cli")
        .join("brain")
        .join(session_id);
    if !is_safe_brain_dir(&home, &brain, session_id) {
        return Err(());
    }
    if !brain.exists() {
        return Ok(false);
    }
    trash::delete(&brain).map_err(|_| ())?;
    Ok(true)
}

fn is_safe_brain_dir(home: &Path, brain: &Path, session_id: &str) -> bool {
    if !valid_session_id(session_id) {
        return false;
    }
    let root = home.join(".gemini").join("antigravity-cli").join("brain");
    brain.starts_with(&root) && brain.ends_with(session_id)
}
