use super::super::sse::{SseFailure, parse_stream};
use std::io::Cursor;
use std::sync::atomic::AtomicBool;

#[test]
fn parser_combines_data_lines_and_ignores_non_data_fields() {
    let input = b"event: update\ndata: {\"a\":\ndata: 1}\n\n";
    let stop = AtomicBool::new(false);
    let mut events = Vec::new();
    parse_stream(Cursor::new(input), &stop, |data| {
        events.push(data.to_string());
        true
    })
    .unwrap();
    assert_eq!(events, vec!["{\"a\":\n1}"]);
}

#[test]
fn parser_rejects_an_unbounded_line_before_allocating_a_frame() {
    let input = vec![b'x'; super::super::bounds::MAX_SSE_LINE_BYTES + 1];
    let stop = AtomicBool::new(false);
    let failure = parse_stream(Cursor::new(input), &stop, |_| true).unwrap_err();
    assert_eq!(failure, SseFailure::LineTooLarge);
}
