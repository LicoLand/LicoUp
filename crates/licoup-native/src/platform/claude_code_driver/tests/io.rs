use super::*;

#[test]
fn protocol_lines_and_probe_output_are_bounded() {
    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(
        BufReader::new(Cursor::new(vec![b'x'; MAX_PROTOCOL_LINE_BYTES + 1])),
        sender,
    );
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::LineLimitExceeded
    ));
    assert!(read_bounded(Cursor::new(vec![b'x'; 2048]), 1024));
}

#[test]
fn stderr_is_drained_without_retaining_or_projecting_bytes() {
    let truncated = Arc::new(AtomicBool::new(false));
    drain_stderr(Cursor::new(vec![b'x'; 2048]), 128, &truncated);
    assert!(truncated.load(Ordering::Relaxed));
}
