use super::model::{MAX_SESSION_ID_LEN, MIN_SESSION_ID_LEN};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(in crate::platform) enum ControlDisposition {
    Accepted,
    NoActiveTurn,
    SessionUnavailable,
    TransportUnavailable,
}

static ACTIVE_TURNS: OnceLock<Mutex<HashMap<String, u32>>> = OnceLock::new();

fn active_turns() -> &'static Mutex<HashMap<String, u32>> {
    ACTIVE_TURNS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(in crate::platform) fn register_active_turn(session_id: &str, pid: u32) {
    if !safe_session_id(session_id) {
        return;
    }
    if let Ok(mut registry) = active_turns().lock() {
        registry.insert(session_id.to_string(), pid);
    }
}

pub(in crate::platform) fn clear_active_turn(session_id: &str) {
    if let Ok(mut registry) = active_turns().lock() {
        registry.remove(session_id);
    }
}

pub(in crate::platform) fn cancel(session_id: &str) -> ControlDisposition {
    if !safe_session_id(session_id) {
        return ControlDisposition::SessionUnavailable;
    }
    let pid = active_turns()
        .lock()
        .ok()
        .and_then(|registry| registry.get(session_id).copied());
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
    if !safe_session_id(session_id) {
        return ControlDisposition::SessionUnavailable;
    }
    let removed = remove_cursor_chat_storage(session_id);
    match removed {
        Ok(true) | Ok(false) => ControlDisposition::Accepted,
        Err(_) => ControlDisposition::TransportUnavailable,
    }
}

pub(in crate::platform) fn safe_session_id(session_id: &str) -> bool {
    let len = session_id.len();
    len >= MIN_SESSION_ID_LEN
        && len <= MAX_SESSION_ID_LEN
        && session_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-'))
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn remove_cursor_chat_storage(session_id: &str) -> Result<bool, ()> {
    let Some(home) = home_dir() else {
        return Err(());
    };
    let mut removed_any = false;
    let chats_root = home.join(".cursor").join("chats");
    if chats_root.is_dir() {
        removed_any |= remove_matching_chat_leaves(&chats_root, session_id)?;
    }
    let projects_root = home.join(".cursor").join("projects");
    if projects_root.is_dir() {
        removed_any |= remove_matching_transcript_dirs(&projects_root, session_id, 8)?;
    }
    Ok(removed_any)
}

fn remove_matching_chat_leaves(chats_root: &Path, session_id: &str) -> Result<bool, ()> {
    let mut removed = false;
    let entries = fs::read_dir(chats_root).map_err(|_| ())?;
    for entry in entries {
        let entry = entry.map_err(|_| ())?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let leaf = path.join(session_id);
        if is_safe_chat_leaf(&home_dir().unwrap_or_default(), &leaf, session_id) && leaf.is_dir() {
            fs::remove_dir_all(&leaf).map_err(|_| ())?;
            removed = true;
        }
    }
    Ok(removed)
}

fn remove_matching_transcript_dirs(
    root: &Path,
    session_id: &str,
    max_depth: usize,
) -> Result<bool, ()> {
    let mut removed = false;
    remove_transcript_dirs_recursive(root, session_id, max_depth, &mut removed)?;
    Ok(removed)
}

fn remove_transcript_dirs_recursive(
    current: &Path,
    session_id: &str,
    remaining_depth: usize,
    removed: &mut bool,
) -> Result<(), ()> {
    if remaining_depth == 0 {
        return Ok(());
    }
    let entries = fs::read_dir(current).map_err(|_| ())?;
    for entry in entries {
        let entry = entry.map_err(|_| ())?;
        let path = entry.path();
        if path.file_name().and_then(|name| name.to_str()) == Some("agent-transcripts")
            && path.is_dir()
        {
            let target = path.join(session_id);
            if target.is_dir()
                && is_safe_transcript_dir(&home_dir().unwrap_or_default(), &target, session_id)
            {
                fs::remove_dir_all(&target).map_err(|_| ())?;
                *removed = true;
            }
            continue;
        }
        if path.is_dir() {
            remove_transcript_dirs_recursive(&path, session_id, remaining_depth - 1, removed)?;
        }
    }
    Ok(())
}

fn is_safe_chat_leaf(home: &Path, leaf: &Path, session_id: &str) -> bool {
    if !safe_session_id(session_id) {
        return false;
    }
    let chats_root = home.join(".cursor").join("chats");
    if !leaf.starts_with(&chats_root) {
        return false;
    }
    let Ok(relative) = leaf.strip_prefix(&chats_root) else {
        return false;
    };
    let mut parts = relative.components();
    matches!(
        (parts.next(), parts.next(), parts.next()),
        (Some(_), Some(_), None)
    ) && leaf.ends_with(session_id)
}

fn is_safe_transcript_dir(home: &Path, target: &Path, session_id: &str) -> bool {
    if !safe_session_id(session_id) {
        return false;
    }
    let projects_root = home.join(".cursor").join("projects");
    target.starts_with(&projects_root)
        && target.ends_with(session_id)
        && target
            .parent()
            .and_then(|parent| parent.file_name())
            .and_then(|name| name.to_str())
            == Some("agent-transcripts")
}
