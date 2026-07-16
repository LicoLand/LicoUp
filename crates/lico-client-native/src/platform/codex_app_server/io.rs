use super::super::process_supervisor::BoundedStdinWriter;
use serde_json::Value;
use std::io::{self, BufRead, Read};
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
    let mut bytes = serde_json::to_vec(message).map_err(io::Error::other)?;
    bytes.push(b'\n');
    stdin
        .enqueue(bytes)
        .map_err(|_| io::Error::other("native agent protocol write failed"))
}

pub(super) fn read_protocol_messages<R: BufRead>(
    mut reader: R,
    max_bytes: usize,
    sender: Sender<TransportEvent>,
) {
    let mut total_bytes = 0usize;
    let mut line = Vec::new();
    loop {
        let available = match reader.fill_buf() {
            Ok(bytes) => bytes,
            Err(_) => {
                let _ = sender.send(TransportEvent::StdoutReadFailed);
                return;
            }
        };
        if available.is_empty() {
            if !line.is_empty() && send_protocol_line(&line, &sender).is_err() {
                return;
            }
            let _ = sender.send(TransportEvent::StdoutClosed);
            return;
        }

        let consumed = available
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|index| index + 1)
            .unwrap_or(available.len());
        if total_bytes.saturating_add(consumed) > max_bytes {
            let _ = sender.send(TransportEvent::StdoutLimitExceeded);
            return;
        }
        let completed_line = available.get(consumed.saturating_sub(1)) == Some(&b'\n');
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        total_bytes += consumed;

        if completed_line {
            while matches!(line.last(), Some(b'\n' | b'\r')) {
                line.pop();
            }
            if !line.is_empty() && send_protocol_line(&line, &sender).is_err() {
                return;
            }
            line.clear();
        }
    }
}

fn send_protocol_line(line: &[u8], sender: &Sender<TransportEvent>) -> Result<(), ()> {
    match serde_json::from_slice::<Value>(line) {
        Ok(message) => sender
            .send(TransportEvent::Message(message))
            .map_err(|_| ()),
        Err(_) => sender.send(TransportEvent::InvalidJson).map_err(|_| ()),
    }
}

/// Drain child stderr without retaining or forwarding its potentially private
/// contents. Only a bounded truncation fact crosses the adapter boundary.
pub(super) fn drain_stderr<R: Read>(mut stderr: R, max_bytes: usize, truncated: &AtomicBool) {
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
