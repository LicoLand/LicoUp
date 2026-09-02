use super::super::endpoint::ServeEndpoint;

#[test]
fn endpoint_constructs_only_the_supplied_loopback_identity() {
    let endpoint = ServeEndpoint::new("127.0.0.1", 4097);
    assert_eq!(endpoint.host, "127.0.0.1");
    assert_eq!(endpoint.port, 4097);
    assert_eq!(endpoint.attach_url, "http://127.0.0.1:4097");
}
