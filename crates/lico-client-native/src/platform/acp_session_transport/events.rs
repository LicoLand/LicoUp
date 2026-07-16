use crate::core::acp;
use serde_json::Value;
use std::io::BufRead;
use std::sync::mpsc::Sender;

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
            .map(|index| index + 1)
            .unwrap_or(available.len());
        if line.len().saturating_add(consumed) > acp::MAX_JSON_LINE_BYTES {
            let _ = sender.send(TransportEvent::LineLimitExceeded);
            return;
        }
        let completed_line = available.get(consumed.saturating_sub(1)) == Some(&b'\n');
        line.extend_from_slice(&available[..consumed]);
        reader.consume(consumed);
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

pub(super) fn send_protocol_line(line: &[u8], sender: &Sender<TransportEvent>) -> Result<(), ()> {
    match acp::decode_json_line(line) {
        Ok(message) => sender
            .send(TransportEvent::Message {
                message,
                bytes: line.len(),
            })
            .map_err(|_| ()),
        Err(acp::AcpError::MessageTooLarge) => sender
            .send(TransportEvent::LineLimitExceeded)
            .map_err(|_| ()),
        Err(_) => sender.send(TransportEvent::InvalidJson).map_err(|_| ()),
    }
}

pub(super) fn response_is_error(message: &Value) -> bool {
    message.get("error").is_some()
}

pub(super) fn request_id_matches(message: &Value, expected: i64) -> bool {
    message.get("id").is_some_and(|id| {
        id.as_i64() == Some(expected)
            || id
                .as_str()
                .is_some_and(|value| value == expected.to_string())
    })
}
