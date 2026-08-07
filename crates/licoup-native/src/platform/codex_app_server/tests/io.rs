use crate::platform::codex_app_server::io::{TransportEvent, drain_stderr, read_protocol_messages};
use std::io::Cursor;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;

#[test]
fn stdout_reader_is_line_framed_and_enforces_total_limit() {
    let input = b"{\"id\":1,\"result\":{}}\n{\"method\":\"initialized\"}\n";
    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(input), Some(input.len()), sender);
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::Message(_)
    ));
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::Message(_)
    ));
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::StdoutClosed
    ));

    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(input), Some(input.len() - 1), sender);
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::Message(_)
    ));
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::StdoutLimitExceeded
    ));
}

#[test]
fn stderr_drain_retains_no_content_and_marks_truncation() {
    let truncated = AtomicBool::new(false);
    drain_stderr(Cursor::new(vec![b'x'; 64 * 1024]), 1024, &truncated);
    assert!(truncated.load(Ordering::Relaxed));
}
