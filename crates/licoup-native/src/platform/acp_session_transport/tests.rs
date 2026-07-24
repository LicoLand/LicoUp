use super::capabilities::AcpSessionDriverSpec;
use super::continuity::{SessionKey, TransportKey};
use std::path::Path;

#[test]
fn transport_and_session_keys_are_scoped_by_driver_identity() {
    let first = AcpSessionDriverSpec::new("first-acp", &["acp"]);
    let second = AcpSessionDriverSpec::new("second-acp", &["acp"]);
    let cwd = Path::new("/workspace");

    assert_ne!(
        TransportKey::new(first, "agent", cwd),
        TransportKey::new(second, "agent", cwd)
    );
    assert_ne!(
        SessionKey::new(first, "native-session"),
        SessionKey::new(second, "native-session")
    );
}

#[test]
fn launch_arguments_are_immutable_adapter_metadata() {
    let driver = AcpSessionDriverSpec::new("vendor-acp", &["acp"]);
    assert_eq!(driver.driver_id, "vendor-acp");
    assert_eq!(driver.launch_args, &["acp"]);
}
