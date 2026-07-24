use super::*;

#[test]
fn protocol_reader_is_line_bounded_and_rejects_invalid_json() {
    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(b"not-json\n"), 64, sender);
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::InvalidJson
    ));

    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(b"{\"id\":1}\n"), 4, sender);
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::StdoutLimitExceeded
    ));
}

#[test]
fn stderr_is_fully_drained_without_retaining_bytes() {
    let truncated = Arc::new(AtomicBool::new(false));
    drain_stderr(Cursor::new(vec![b'x'; 128]), 16, &truncated);
    assert!(truncated.load(std::sync::atomic::Ordering::Relaxed));
}
