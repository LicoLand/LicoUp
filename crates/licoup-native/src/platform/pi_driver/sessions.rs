use super::errors::ProtocolFailure;
use serde_json::Value;
use std::env;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

pub(super) const MAX_SESSION_SCAN_FILES: usize = 4_096;

pub(super) fn resolve_session_path(session_id: &str) -> Result<PathBuf, ProtocolFailure> {
    resolve_session_path_in_roots(session_id, &session_roots())
}

pub(super) fn resolve_session_path_in_roots(
    session_id: &str,
    roots: &[PathBuf],
) -> Result<PathBuf, ProtocolFailure> {
    let trimmed = session_id.trim();
    if trimmed.is_empty() {
        return Err(ProtocolFailure::new(
            "pi_session_id_missing",
            "Pi Agent resume requires a native session identifier.",
            "session/resume",
        ));
    }
    let mut scanned = 0usize;
    let mut matches = Vec::new();
    for root in roots {
        find_session_files(root, trimmed, &mut scanned, &mut matches);
        if scanned >= MAX_SESSION_SCAN_FILES || matches.len() > 1 {
            break;
        }
    }
    if matches.len() > 1 {
        return Err(ProtocolFailure::new(
            "pi_session_identity_ambiguous",
            "Pi Agent found more than one session with the requested identity.",
            "session/resume",
        )
        .with_session(Some(trimmed)));
    }
    if let Some(path) = matches.pop() {
        return Ok(path);
    }
    Err(ProtocolFailure::new(
        "pi_session_not_found",
        "Pi Agent could not resolve the requested session without placing identity on argv.",
        "session/resume",
    )
    .with_session(Some(trimmed)))
}

pub(super) fn session_roots() -> Vec<PathBuf> {
    let session_dir = env::var("PI_CODING_AGENT_SESSION_DIR").ok();
    let agent_dir = env::var("PI_CODING_AGENT_DIR").ok();
    let home = env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from);
    session_roots_from_sources(session_dir.as_deref(), agent_dir.as_deref(), home)
}

pub(super) fn session_roots_from_sources(
    session_dir: Option<&str>,
    agent_dir: Option<&str>,
    home: Option<PathBuf>,
) -> Vec<PathBuf> {
    if let Some(dir) = session_dir {
        let path = PathBuf::from(dir.trim());
        if !path.as_os_str().is_empty() {
            return vec![path];
        }
    }
    if let Some(dir) = agent_dir {
        let path = PathBuf::from(dir.trim()).join("sessions");
        if !dir.trim().is_empty() {
            return vec![path];
        }
    }
    if let Some(home) = home.filter(|path| !path.as_os_str().is_empty()) {
        return vec![home.join(".pi").join("agent").join("sessions")];
    }
    Vec::new()
}

pub(super) fn find_session_files(
    root: &Path,
    session_id: &str,
    scanned: &mut usize,
    matches: &mut Vec<PathBuf>,
) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        if matches.len() > 1 {
            return;
        }
        let Ok(entries) = fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if *scanned >= MAX_SESSION_SCAN_FILES {
                return;
            }
            *scanned += 1;
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
                continue;
            };
            if !name.ends_with(".jsonl") {
                continue;
            }
            if session_header_matches(&path, session_id) {
                matches.push(path);
                if matches.len() > 1 {
                    return;
                }
            }
        }
    }
}

pub(super) fn session_header_matches(path: &Path, session_id: &str) -> bool {
    const MAX_HEADER_BYTES: u64 = 64 * 1024;
    let Ok(file) = fs::File::open(path) else {
        return false;
    };
    let mut bytes = Vec::with_capacity(MAX_HEADER_BYTES as usize);
    if file.take(MAX_HEADER_BYTES).read_to_end(&mut bytes).is_err() {
        return false;
    }
    let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') else {
        return false;
    };
    let Ok(line) = std::str::from_utf8(&bytes[..newline]) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<Value>(line.trim_end_matches('\r')) else {
        return false;
    };
    value.get("type").and_then(Value::as_str) == Some("session")
        && value.get("id").and_then(Value::as_str) == Some(session_id)
}
