use super::*;
use std::io::{Cursor, Read};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc;

struct CountingReader {
    inner: Cursor<Vec<u8>>,
    consumed: Arc<AtomicUsize>,
}

impl Read for CountingReader {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let read = self.inner.read(buffer)?;
        self.consumed.fetch_add(read, Ordering::Relaxed);
        Ok(read)
    }
}

#[test]
fn stderr_is_fully_drained_after_the_truncation_bit_is_set() {
    let payload = vec![b'x'; 24 * 1024];
    let consumed = Arc::new(AtomicUsize::new(0));
    let truncated = Arc::new(AtomicBool::new(false));
    drain_stderr(
        CountingReader {
            inner: Cursor::new(payload.clone()),
            consumed: Arc::clone(&consumed),
        },
        16,
        &truncated,
    );
    assert!(truncated.load(Ordering::Relaxed));
    assert_eq!(consumed.load(Ordering::Relaxed), payload.len());
}

#[test]
fn stdout_jsonl_reader_enforces_the_aggregate_capacity() {
    let (sender, receiver) = mpsc::channel();
    read_protocol_messages(
        std::io::BufReader::new(Cursor::new(b"{\"type\":\"event\"}\n")),
        4,
        sender,
    );
    assert!(matches!(
        receiver.recv().unwrap(),
        TransportEvent::StdoutLimitExceeded
    ));
}
