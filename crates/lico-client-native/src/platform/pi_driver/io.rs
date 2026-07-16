use super::super::process_supervisor::BoundedStdinWriter;
use serde_json::Value;
use std::io::{self, BufRead, BufReader, Read};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;

#[derive(Debug)]
pub(super) enum TransportEvent {
    Message(Value),
    InvalidJson,
    StdoutLimitExceeded,
    StdoutReadFailed,
    StdoutClosed,
}

pub(super) fn write_message(stdin: &mut BoundedStdinWriter, message: &Value) -> io::Result<()> {
    let mut payload = serde_json::to_vec(message).map_err(io::Error::other)?;
    payload.push(b'\n');
    stdin
        .enqueue(payload)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

pub(super) fn read_protocol_messages<R: Read>(
    mut reader: BufReader<R>,
    max_stdout: usize,
    sender: Sender<TransportEvent>,
) {
    let mut total = 0usize;
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                let _ = sender.send(TransportEvent::StdoutClosed);
                return;
            }
            Ok(read) => {
                total = total.saturating_add(read);
                if total > max_stdout {
                    let _ = sender.send(TransportEvent::StdoutLimitExceeded);
                    return;
                }
                let trimmed = line.trim_end_matches(['\r', '\n']);
                if trimmed.is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(trimmed) {
                    Ok(message) => {
                        if sender.send(TransportEvent::Message(message)).is_err() {
                            return;
                        }
                    }
                    Err(_) => {
                        let _ = sender.send(TransportEvent::InvalidJson);
                        return;
                    }
                }
            }
            Err(_) => {
                let _ = sender.send(TransportEvent::StdoutReadFailed);
                return;
            }
        }
    }
}

pub(super) fn drain_stderr<R: Read>(reader: R, max_bytes: usize, truncated: &Arc<AtomicBool>) {
    let mut reader = reader;
    let mut buffer = [0_u8; 8 * 1024];
    let mut kept = 0usize;
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => return,
            Ok(read) => {
                kept = kept.saturating_add(read);
                if kept > max_bytes {
                    truncated.store(true, Ordering::Relaxed);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => {
                truncated.store(true, Ordering::Relaxed);
                return;
            }
        }
    }
}
