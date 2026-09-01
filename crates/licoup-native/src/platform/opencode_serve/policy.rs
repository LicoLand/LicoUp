use std::process::Command;

use super::super::local_service::{ServeErrorCodes, ServeSpec};

pub(super) const DEFAULT_PORT: u16 = 24173;
const RESERVED_PORTS: &[u16] = &[
    3000, 4096, 5173, 5494, 7228, 8080, 8443, 17328, 17329, 18765, 18789, 19001, 24189, 58627,
];

pub(super) const SPEC: ServeSpec = ServeSpec {
    identity: "opencode_serve",
    default_port: DEFAULT_PORT,
    port_range_span: 16,
    default_host: "127.0.0.1",
    health_path: "/global/health",
    session_probe_path: "/session",
    config_path: "/config",
    provider_path: "/provider",
    state_dir: "opencode-serve",
    state_schema_version: "v0.0.1:opencode-serve-2",
    default_health_timeout_ms: 45_000,
    reserved_ports: RESERVED_PORTS,
    executable_environment: &["OPENCODE_BIN"],
    default_executable: "opencode",
    configure_command,
    parse_readiness: crate::platform::native_agent_parser::adapters::opencode::readiness,
    errors: ServeErrorCodes {
        executable_missing: "opencode_executable_missing",
        port_exhausted: "opencode_serve_port_exhausted",
        start_failed: "opencode_serve_start_failed",
        health_failed: "opencode_serve_health_failed",
        attach_probe_failed: "opencode_serve_attach_probe_failed",
        not_found: "opencode_serve_not_found",
        request_failed: "opencode_serve_request_failed",
        invalid_json: "opencode_serve_invalid_json",
        invalid_state: "opencode_serve_state_invalid",
        stop_failed: "opencode_serve_stop_failed",
    },
};

fn configure_command(command: &mut Command, host: &str, port: u16) {
    command.args(["serve", "--hostname", host, "--port", &port.to_string()]);
}
