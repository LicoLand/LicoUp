use super::super::process_supervisor::BoundedStdinWriter;
use crate::core::acp;
use crate::platform::raw_execution::{RawExecutionDirection, RawExecutionObserver};
use serde_json::Value;
use std::io::{self, Read};
use std::sync::atomic::{AtomicBool, Ordering};

pub(super) fn write_message(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let bytes = acp::encode_json_line(message).map_err(io::Error::other)?;
    if let Some(observer) = RawExecutionObserver::current() {
        observer.record_bytes("acp", RawExecutionDirection::Sent, &bytes);
    }
    stdin
        .enqueue(bytes)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

pub(super) fn drain_stderr<R: Read>(mut stderr: R, max_bytes: usize, truncated: &AtomicBool) {
    let raw_observer = RawExecutionObserver::current();
    let mut total = 0usize;
    let mut buffer = [0u8; 8192];
    loop {
        match stderr.read(&mut buffer) {
            Ok(0) => return,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => return,
            Ok(count) => {
                if let Some(observer) = raw_observer.as_ref() {
                    observer.record_bytes("acp", RawExecutionDirection::Stderr, &buffer[..count]);
                }
                total = total.saturating_add(count);
                if total > max_bytes {
                    truncated.store(true, Ordering::Relaxed);
                }
            }
        }
    }
}
