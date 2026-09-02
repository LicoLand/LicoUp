use super::*;

#[test]
fn foundation_exposes_http_sse_and_lifecycle_without_jsonl_ownership() {
    let endpoint = ServeEndpoint::new("127.0.0.1", 24173);
    assert_eq!(endpoint.attach_url, "http://127.0.0.1:24173");
    assert_eq!(crate::core::acp::MAX_JSON_LINE_BYTES, 1024 * 1024 + 2);
}
