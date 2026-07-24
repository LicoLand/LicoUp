use crate::core::acp;
use serde_json::{Value, json};
use std::io::BufRead;
use std::sync::mpsc::Sender;

#[derive(Debug)]
pub(super) enum TransportEvent {
    Message(Value),
    InvalidJson,
    StdoutLimitExceeded,
    StdoutReadFailed,
    StdoutClosed,
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

pub(super) fn send_protocol_line(line: &[u8], sender: &Sender<TransportEvent>) -> Result<(), ()> {
    match acp::decode_json_line(line) {
        Ok(message) => sender
            .send(TransportEvent::Message(message))
            .map_err(|_| ()),
        Err(acp::AcpError::MessageTooLarge) => sender
            .send(TransportEvent::StdoutLimitExceeded)
            .map_err(|_| ()),
        Err(_) => sender.send(TransportEvent::InvalidJson).map_err(|_| ()),
    }
}

pub(in crate::platform) fn extract_assistant_text(response: &Value) -> String {
    let mut chunks = Vec::new();
    if let Some(parts) = response.get("parts").and_then(Value::as_array) {
        for part in parts {
            if part.get("type").and_then(Value::as_str) == Some("text")
                && let Some(text) = part.get("text").and_then(Value::as_str)
            {
                chunks.push(text.to_string());
            }
        }
    }
    if chunks.is_empty()
        && let Some(parts) = response
            .get("info")
            .and_then(|_| response.get("parts"))
            .and_then(Value::as_array)
    {
        for part in parts {
            if let Some(text) = part.get("text").and_then(Value::as_str) {
                chunks.push(text.to_string());
            }
        }
    }
    // Some OpenCode versions return a list of messages.
    if chunks.is_empty()
        && let Some(items) = response.as_array()
    {
        for item in items {
            if item
                .get("info")
                .and_then(|info| info.get("role"))
                .and_then(Value::as_str)
                == Some("assistant")
            {
                chunks.push(extract_assistant_text(item));
            }
        }
    }
    chunks.join("")
}

pub(in crate::platform) fn project_agent_chunks(chunks: Vec<String>) -> Vec<Value> {
    chunks
        .into_iter()
        .map(|text| {
            json!({
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text}
            })
        })
        .collect()
}
