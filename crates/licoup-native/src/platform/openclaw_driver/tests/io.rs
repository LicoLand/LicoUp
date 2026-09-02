use super::*;

#[test]
fn protocol_reader_is_line_bounded_and_leaves_decoding_to_the_parser() {
    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(b"not-json\n"), Some(64), sender);
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::Frame(line) if line == b"not-json"
    ));

    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(Cursor::new(b"{\"id\":1}\n"), Some(4), sender);
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
