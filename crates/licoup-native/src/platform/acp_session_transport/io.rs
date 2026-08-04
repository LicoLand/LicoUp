use super::super::process_supervisor::BoundedStdinWriter;
use crate::core::acp;
use serde_json::Value;
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};

pub(in crate::platform) fn write_message(
    stdin: &mut BoundedStdinWriter,
    message: &Value,
) -> io::Result<()> {
    let bytes = acp::encode_json_line(message).map_err(io::Error::other)?;
    stdin
        .enqueue(bytes)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

pub(super) fn write_cancel_notification(
    stdin: &mut BoundedStdinWriter,
    session_id: &str,
) -> io::Result<()> {
    let notification = acp::cancel_notification(session_id).map_err(io::Error::other)?;
    write_message(stdin, &notification)
}

pub(in crate::platform) fn drain_stderr<R: Read>(
    mut stderr: R,
    max_bytes: usize,
    truncated: &AtomicBool,
) {
    let mut buffer = [0u8; 8192];
    let mut total_bytes = 0usize;
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) => return,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
            Ok(read) => {
                total_bytes = total_bytes.saturating_add(read);
                if total_bytes > max_bytes {
                    truncated.store(true, Ordering::Relaxed);
                }
            }
        }
    }
}

pub(in crate::platform) fn read_bounded<R: Read>(
    mut reader: R,
    max_bytes: usize,
) -> (Vec<u8>, bool) {
    let mut kept = Vec::with_capacity(max_bytes.min(8192));
    let mut buffer = [0u8; 8192];
    let mut total = 0usize;
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return (kept, total > max_bytes),
            Ok(read) => {
                let remaining = max_bytes.saturating_sub(kept.len());
                kept.extend_from_slice(&buffer[..read.min(remaining)]);
                total = total.saturating_add(read);
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return (kept, true),
        }
    }
}

pub(in crate::platform) fn drain_bounded<R: Read>(mut reader: R, max_bytes: usize) -> bool {
    let mut buffer = [0u8; 8192];
    let mut total = 0usize;
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return total > max_bytes,
            Ok(read) => total = total.saturating_add(read),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return true,
        }
    }
}
