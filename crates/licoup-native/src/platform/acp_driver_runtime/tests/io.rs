use super::*;
use std::io::Cursor;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;

#[test]
fn stderr_is_drained_to_a_truncation_bit_without_content_projection() {
    let truncated = AtomicBool::new(false);
    drain_stderr(Cursor::new(b"private-stderr-canary"), 4, &truncated);
    assert!(truncated.load(Ordering::Relaxed));
}

#[test]
fn stdout_reader_enforces_the_configured_aggregate_limit() {
    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(b"{\"id\":1}\n{\"id\":2}\n"), Some(8), sender);
    assert!(matches!(
        receiver.recv().unwrap(),
        super::super::events::TransportEvent::StdoutLimitExceeded
    ));
}
