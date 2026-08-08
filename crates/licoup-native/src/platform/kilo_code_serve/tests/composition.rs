use super::super::{ServeEndpoint, policy};

#[test]
fn facade_preserves_the_private_driver_transport_contract() {
    let endpoint = ServeEndpoint::new(policy::SPEC.default_host, policy::SPEC.default_port);
    assert_eq!(endpoint.host, policy::SPEC.default_host);
    assert_eq!(endpoint.port, policy::SPEC.default_port);
    assert_eq!(endpoint.attach_url, "http://127.0.0.1:4097");
}
