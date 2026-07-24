use super::super::policy;
use crate::platform::local_service::serve::{is_reserved_port, select_available_port_with};

#[test]
fn target_policy_owns_ports_identity_and_static_failures() {
    assert_eq!(policy::SPEC.default_port, 4097);
    assert!(!is_reserved_port(policy::SPEC, policy::SPEC.default_port));
    assert!(is_reserved_port(policy::SPEC, 4096));
    assert!(is_reserved_port(policy::SPEC, 24173));
    assert_eq!(policy::SPEC.identity, "kilo_code_serve");
    assert_eq!(
        policy::SPEC.errors.executable_missing,
        "kilo_executable_missing"
    );
    assert_eq!(
        select_available_port_with(policy::SPEC, 24173, |port| port == 24190).unwrap(),
        24190
    );
}
