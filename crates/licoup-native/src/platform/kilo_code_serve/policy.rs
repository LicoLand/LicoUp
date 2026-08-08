use std::process::Command;

use super::super::local_service::{ServeErrorCodes, ServeSpec};

pub(super) const DEFAULT_PORT: u16 = 4097;
const RESERVED_PORTS: &[u16] = &[
    3000, 4096, 5173, 7228, 8080, 8443, 17328, 17329, 18765, 18789, 19001, 24173, 24174, 24175,
    24176, 24177, 24178, 24179, 24180, 24181, 24182, 24183, 24184, 24185, 24186, 24187, 24188,
    24189, 58627,
];

pub(super) const SPEC: ServeSpec = ServeSpec {
    identity: "kilo_code_serve",
    default_port: DEFAULT_PORT,
    port_range_span: 19,
    default_host: "127.0.0.1",
    health_path: "/global/health",
    session_probe_path: "/session",
    state_dir: "kilo-code-serve",
    state_schema_version: "v0.0.1:kilo-code-serve-2",
    default_health_timeout_ms: 45_000,
    reserved_ports: RESERVED_PORTS,
    executable_environment: &["KILO_BIN", "KILO_PATH", "KILOCODE_PATH"],
    default_executable: "kilo",
    configure_command,
    errors: ServeErrorCodes {
        executable_missing: "kilo_executable_missing",
        port_exhausted: "kilo_code_serve_port_exhausted",
        start_failed: "kilo_code_serve_start_failed",
        health_failed: "kilo_code_serve_health_failed",
        attach_probe_failed: "kilo_code_serve_attach_probe_failed",
        not_found: "kilo_code_serve_not_found",
        request_failed: "kilo_code_serve_request_failed",
        invalid_json: "kilo_code_serve_invalid_json",
        invalid_state: "kilo_code_serve_state_invalid",
        stop_failed: "kilo_code_serve_stop_failed",
    },
};

fn configure_command(command: &mut Command, host: &str, port: u16) {
    command.args(["serve", "--hostname", host, "--port", &port.to_string()]);
}
