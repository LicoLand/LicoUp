use serde_json::Value;
use std::io::{BufRead, Read};
use std::sync::mpsc::Sender;

pub(super) const MAX_PROTOCOL_LINE_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug)]
pub(super) enum TransportEvent {
    Message { message: Value, bytes: usize },
    InvalidJson,
    LineLimitExceeded,
    StdoutReadFailed,
    StdoutClosed,
}

pub(super) fn read_protocol_messages<R: BufRead>(mut reader: R, sender: Sender<TransportEvent>) {
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
            .map_or(available.len(), |index| index + 1);
        if line.len().saturating_add(consumed) > MAX_PROTOCOL_LINE_BYTES {
            let _ = sender.send(TransportEvent::LineLimitExceeded);
            return;
        }
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
        if line.last() == Some(&b'\n') {
            if send_protocol_line(&line, &sender).is_err() {
                return;
            }
            line.clear();
        }
    }
}

fn send_protocol_line(line: &[u8], sender: &Sender<TransportEvent>) -> Result<(), ()> {
    let trimmed = line
        .iter()
        .copied()
        .skip_while(|byte| byte.is_ascii_whitespace())
        .collect::<Vec<_>>();
    if trimmed.iter().all(|byte| byte.is_ascii_whitespace()) {
        return Ok(());
    }
    let message = serde_json::from_slice(&trimmed).map_err(|_| {
        let _ = sender.send(TransportEvent::InvalidJson);
    })?;
    sender
        .send(TransportEvent::Message {
            message,
            bytes: line.len(),
        })
        .map_err(|_| ())
}

pub(super) fn drain_stderr(mut reader: impl Read, max_stderr: usize, truncated: &mut bool) {
    let mut buffer = [0_u8; 4096];
    let mut collected = 0usize;
    loop {
        let read = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(_) => break,
        };
        if collected >= max_stderr {
            *truncated = true;
            break;
        }
        collected = collected.saturating_add(read.min(max_stderr.saturating_sub(collected)));
    }
}
