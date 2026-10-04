//! The client's driver declaration for this Agent.

use super::super::{KILO_CODE_DRIVER, RUNTIME_PROTOCOL, CONTROL_SPEC};
use licoup_agent_kilo::driver::{DRIVER_ID, ERROR_PREFIX};
use licoup_agent_kilo::policy;

#[test]
fn the_driver_declaration_is_read_from_the_package_that_owns_it() {
    assert_eq!(RUNTIME_PROTOCOL, "kilo-code-serve-http-v1");
    assert_eq!(RUNTIME_PROTOCOL, licoup_agent_kilo::driver::RUNTIME_PROTOCOL);
    assert_eq!(KILO_CODE_DRIVER.launch_args, &["serve"]);
    assert_eq!(KILO_CODE_DRIVER.agent_id, "kilo-code-serve");
    assert_eq!(KILO_CODE_DRIVER.agent_id, DRIVER_ID);
    assert_eq!(KILO_CODE_DRIVER.error_prefix, "kilo_code_serve");
    assert_eq!(KILO_CODE_DRIVER.error_prefix, ERROR_PREFIX);
}

#[test]
fn the_launch_shape_starts_a_serve_endpoint_and_never_a_chat_continuation() {
    assert!(KILO_CODE_DRIVER.launch_args.iter().all(|argument| {
        *argument != "acp"
            && !argument.contains("continue")
            && !argument.contains("session")
            && !argument.contains("prompt")
    }));
}

#[test]
fn the_force_stop_descriptor_reads_the_packages_own_endpoint_policy() {
    assert_eq!(CONTROL_SPEC.identity, policy::SPEC.identity);
    assert_eq!(CONTROL_SPEC.state_dir, policy::SPEC.state_dir);
    assert_eq!(
        CONTROL_SPEC.state_schema_version,
        policy::SPEC.state_schema_version
    );
    assert_eq!(CONTROL_SPEC.default_port, policy::SPEC.default_port);
    assert_eq!(CONTROL_SPEC.reserved_ports, policy::SPEC.reserved_ports);
    assert_eq!(
        CONTROL_SPEC.executable_environment,
        policy::SPEC.executable_environment
    );
}
