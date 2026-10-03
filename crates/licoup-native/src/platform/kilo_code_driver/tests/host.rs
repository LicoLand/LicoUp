//! The engine functions the package's ports are answered with.

use super::super::super::kilo_code_host;
use licoup_agent_kilo::policy;

#[test]
fn the_engine_specification_and_the_force_stop_descriptor_are_one_contract() {
    let spec = kilo_code_host::kilo_serve_spec();
    let control = kilo_code_host::CONTROL_SPEC;
    assert_eq!(spec.identity, control.identity);
    assert_eq!(spec.default_port, control.default_port);
    assert_eq!(spec.port_range_span, control.port_range_span);
    assert_eq!(spec.default_host, control.default_host);
    assert_eq!(spec.health_path, control.health_path);
    assert_eq!(spec.session_probe_path, control.session_probe_path);
    assert_eq!(spec.config_path, control.config_path);
    assert_eq!(spec.provider_path, control.provider_path);
    assert_eq!(spec.state_dir, control.state_dir);
    assert_eq!(spec.state_schema_version, control.state_schema_version);
    assert_eq!(
        spec.default_health_timeout_ms,
        control.default_health_timeout_ms
    );
    assert_eq!(spec.reserved_ports, control.reserved_ports);
    assert_eq!(spec.executable_environment, control.executable_environment);
    assert_eq!(spec.default_executable, control.default_executable);
    assert_eq!(spec.errors.executable_missing, control.errors.executable_missing);
    assert_eq!(spec.errors.stop_failed, control.errors.stop_failed);
    // And both are the package's policy, not a second copy of it.
    assert_eq!(spec.identity, policy::SPEC.identity);
}

#[test]
fn the_engine_launch_shape_is_this_agents_own() {
    let mut command = std::process::Command::new("kilo");
    (kilo_code_host::kilo_serve_spec().configure_command)(
        &mut command,
        "127.0.0.1",
        4097,
    );
    let args: Vec<_> = command
        .get_args()
        .map(|argument| argument.to_string_lossy().into_owned())
        .collect();
    assert_eq!(args, ["serve", "--hostname", "127.0.0.1", "--port", "4097"]);
}

#[test]
fn readiness_reads_the_packages_documents_and_crosses_with_its_models() {
    let spec = kilo_code_host::kilo_serve_spec();
    let ready = (spec.parse_readiness)(
        &serde_json::json!({"healthy": true, "version": "1.2.3"}),
        &serde_json::json!([]),
        &serde_json::json!({"model": "kilo-auto/free"}),
        &serde_json::json!({
            "all": [{"id": "kilo", "models": {"kilo-auto/free": {}}}],
            "default": {"kilo": "kilo-auto/free"}
        }),
    )
    .expect("a healthy endpoint with a provider catalogue is ready");
    assert_eq!(ready.version, "1.2.3");
    assert_eq!(ready.catalog.current.selector(), "kilo/kilo-auto/free");
    assert_eq!(ready.catalog.models.len(), 1);

    // A health document without a provider catalogue is not ready, which is the
    // package's own decision rather than the engine's.
    assert!(
        (spec.parse_readiness)(
            &serde_json::json!({"healthy": true, "version": "1.2.3"}),
            &serde_json::json!([]),
            &serde_json::json!({}),
            &serde_json::json!({"all": []}),
        )
        .is_none()
    );
}
