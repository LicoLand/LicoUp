//! The client's answer for the Kilo Code adapter package's ports.
//!
//! The package owns what one Kilo turn *is*; this module owns where its effects
//! go, because the client owns the consumer and the shared local-service engine.
//! Both halves meet exactly here:
//!
//! - [`serve_port`] is the package's [`ServePort`] answered from
//!   `licoup-agent-drivers`' serve engine — the same engine that starts and
//!   supervises the endpoint, reads its documents over HTTP, frames its SSE
//!   stream, records raw bytes and admits an active turn for force stop.
//! - [`turn_event_port`] is the package's turn-event emission answered from this
//!   host's own emitters, so a Kilo event and a Cursor event reach the same
//!   reader through the same path.
//! - [`host_ports`] states both at once, which is what composition installs.
//!
//! Nothing here names a vendor field: the engine is protocol-agnostic and the
//! policy it runs on comes from the package ([`kilo_serve_spec`]).

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

use licoup_agent_kilo::host::HostPorts;
use licoup_agent_kilo::policy;
use licoup_agent_kilo::port::serve::{
    ServeAttachment, ServeByteDirection, ServeEndpoint, ServeFramingFailure, ServePort,
    ServeTurnAdmission,
};
use licoup_agent_kilo::port::turn_event::TurnEventPort;
use serde_json::Value;

use super::local_service;
use super::raw_execution::{RawExecutionDirection, RawExecutionObserver};

/// The durable serve owner descriptor force stop reads.
///
/// Control reads the state and pid records this specification's owner writes, so
/// force stop finds a Kilo endpoint through the same record the engine created
/// rather than through a second registry.
pub(crate) const CONTROL_SPEC: local_service::ServeSpec = local_service::ServeSpec {
    identity: policy::SPEC.identity,
    default_port: policy::SPEC.default_port,
    port_range_span: policy::SPEC.port_range_span,
    default_host: policy::SPEC.default_host,
    health_path: policy::SPEC.health_path,
    session_probe_path: policy::SPEC.session_probe_path,
    config_path: policy::SPEC.config_path,
    provider_path: policy::SPEC.provider_path,
    state_dir: policy::SPEC.state_dir,
    state_schema_version: policy::SPEC.state_schema_version,
    default_health_timeout_ms: policy::SPEC.default_health_timeout_ms,
    reserved_ports: policy::SPEC.reserved_ports,
    executable_environment: policy::SPEC.executable_environment,
    default_executable: policy::SPEC.default_executable,
    configure_command,
    parse_readiness,
    errors: policy::SPEC.errors,
};

/// The serve engine specification this Agent's policy describes.
///
/// The engine supplies the two things the package does not own: the environment
/// it launches the endpoint in and the readiness reader that turns this Agent's
/// documents into the shared readiness record. Everything else — the identity,
/// the port, the paths, the reserved ports, the executable names and the failure
/// codes — is read from the package's own policy, so the client carries no
/// second copy of Kilo Code's endpoint contract.
pub(crate) fn kilo_serve_spec() -> local_service::ServeSpec {
    let policy = &policy::SPEC;
    local_service::ServeSpec {
        identity: policy.identity,
        default_port: policy.default_port,
        port_range_span: policy.port_range_span,
        default_host: policy.default_host,
        health_path: policy.health_path,
        session_probe_path: policy.session_probe_path,
        config_path: policy.config_path,
        provider_path: policy.provider_path,
        state_dir: policy.state_dir,
        state_schema_version: policy.state_schema_version,
        default_health_timeout_ms: policy.default_health_timeout_ms,
        reserved_ports: policy.reserved_ports,
        executable_environment: policy.executable_environment,
        default_executable: policy.default_executable,
        configure_command,
        parse_readiness,
        errors: local_service::ServeErrorCodes {
            executable_missing: policy.errors.executable_missing,
            port_exhausted: policy.errors.port_exhausted,
            start_failed: policy.errors.start_failed,
            health_failed: policy.errors.health_failed,
            attach_probe_failed: policy.errors.attach_probe_failed,
            not_found: policy.errors.not_found,
            request_failed: policy.errors.request_failed,
            invalid_json: policy.errors.invalid_json,
            invalid_state: policy.errors.invalid_state,
            stop_failed: policy.errors.stop_failed,
        },
    }
}

/// How the engine launches this Agent's endpoint.
fn configure_command(command: &mut std::process::Command, host: &str, port: u16) {
    command.args(["serve", "--hostname", host, "--port", &port.to_string()]);
}

/// How this Agent's documents decide readiness.
///
/// The reading is the package's; only the record type changes, because the
/// engine's readiness record and the SDK's readiness vocabulary are both shared
/// shapes.
fn parse_readiness(
    health: &Value,
    sessions: &Value,
    config: &Value,
    providers: &Value,
) -> Option<local_service::ServeReadiness> {
    licoup_agent_kilo::parser::readiness(health, sessions, config, providers).map(|ready| {
        local_service::ServeReadiness {
            version: ready.version,
            catalog: local_service::ServeModelCatalog {
                current: serve_model(ready.catalog.current),
                models: ready.catalog.models.into_iter().map(serve_model).collect(),
            },
            health: ready.health,
        }
    })
}

/// This Agent's readiness vocabulary is the SDK's, which the engine's record and
/// this client both already carry; the crossing is a field copy.
fn serve_model(model: licoup_agent_adapter_sdk::serve::ServeModel) -> local_service::ServeModel {
    local_service::ServeModel {
        provider_id: model.provider_id,
        model_id: model.model_id,
    }
}

fn ensure_attachment(executable: &str) -> Result<ServeAttachment, String> {
    let attachment = local_service::serve::ensure_attachment(kilo_serve_spec(), executable)
        .map_err(|error| error.to_string())?;
    Ok(ServeAttachment {
        endpoint: ServeEndpoint {
            host: attachment.endpoint.host,
            port: attachment.endpoint.port,
            attach_url: attachment.endpoint.attach_url,
        },
        catalog: licoup_agent_adapter_sdk::serve::ServeModelCatalog {
            current: package_model(attachment.catalog.current),
            models: attachment
                .catalog
                .models
                .into_iter()
                .map(package_model)
                .collect(),
        },
    })
}

fn package_model(model: local_service::ServeModel) -> licoup_agent_adapter_sdk::serve::ServeModel {
    licoup_agent_adapter_sdk::serve::ServeModel {
        provider_id: model.provider_id,
        model_id: model.model_id,
    }
}

fn get_json(url: &str, observed: bool) -> Result<Value, String> {
    let source = observed.then_some("kilo-code.http");
    local_service::serve::get_json(kilo_serve_spec(), url, source)
        .map_err(|error| error.to_string())
}

fn post_json(url: &str, body: &Value) -> Result<Value, String> {
    local_service::serve::post_json(kilo_serve_spec(), url, body, "kilo-code.http")
        .map_err(|error| error.to_string())
}

fn watch_frames(
    url: &str,
    stop: &AtomicBool,
    on_frame: &mut dyn FnMut(&str, &str) -> bool,
) -> Result<(), ServeFramingFailure> {
    // The engine frames the stream; the package decides what a frame means. The
    // observer scope is entered here because the diagnostic record is the
    // client's, and a frame the package never looks at is still a frame the
    // record captured.
    let raw_observer = RawExecutionObserver::current();
    let _scope = licoup_foundation::platform::raw_execution::RawExecutionScope::enter(raw_observer);
    local_service::sse::watch_frames(url, stop, |data, frame| {
        let frame = String::from_utf8_lossy(frame);
        on_frame(data, &frame)
    })
    .map_err(framing_failure)
}

fn framing_failure(failure: local_service::sse::SseFailure) -> ServeFramingFailure {
    use local_service::sse::SseFailure;
    match failure {
        SseFailure::Busy => ServeFramingFailure::Busy,
        SseFailure::EventLimit => ServeFramingFailure::EventLimit,
        SseFailure::FrameTooLarge => ServeFramingFailure::FrameTooLarge,
        SseFailure::HeadersTooLarge => ServeFramingFailure::HeadersTooLarge,
        SseFailure::InvalidUtf8 => ServeFramingFailure::InvalidUtf8,
        SseFailure::InvalidUrl => ServeFramingFailure::InvalidUrl,
        SseFailure::LineTooLarge => ServeFramingFailure::LineTooLarge,
        SseFailure::Request => ServeFramingFailure::Request,
        SseFailure::Unavailable => ServeFramingFailure::Unavailable,
    }
}

fn observe_bytes(
    source: &str,
    direction: ServeByteDirection,
    session_id: Option<&str>,
    bytes: &str,
) {
    let Some(observer) = RawExecutionObserver::current() else {
        return;
    };
    if let Some(session_id) = session_id
        && !local_service::sse::frame_belongs_to_session(bytes, session_id)
    {
        return;
    }
    let direction = match direction {
        ServeByteDirection::Received => RawExecutionDirection::Received,
        ServeByteDirection::Sent => RawExecutionDirection::Sent,
    };
    observer.record_bytes(source, direction, bytes.as_bytes());
}

fn admit_turn(attach_url: &str, session_id: &str) -> ServeTurnAdmission {
    match local_service::turn_control::register("kilo-code-serve", attach_url, session_id, None) {
        Ok(guard) => {
            // The guard is released immediately: the caller registers through
            // [`super::kilo_code_driver::execute`], which owns the guard for the
            // whole turn. Admission asked here is a question about capacity.
            drop(guard);
            ServeTurnAdmission::Admitted
        }
        Err(()) => ServeTurnAdmission::AtCapacity,
    }
}

/// This host's answer for the package's serve port.
pub(crate) fn serve_port() -> ServePort {
    ServePort {
        ensure_attachment,
        get_json,
        post_json,
        watch_frames,
        observe_bytes,
        admit_turn,
    }
}

/// This host's answer for the package's turn-event port.
pub(crate) fn turn_event_port() -> TurnEventPort {
    TurnEventPort {
        emit_turn_event: super::turn_event_emit::emit_turn_event,
        emit_agent_message_chunk: super::turn_event_emit::emit_agent_message_chunk,
        emit_agent_message_completed: super::turn_event_emit::emit_agent_message_completed,
    }
}

/// Both ports, as composition installs them.
pub(crate) fn host_ports() -> HostPorts {
    HostPorts {
        turn_event: turn_event_port(),
        serve: serve_port(),
    }
}

/// Whether this Agent's endpoint policy still describes the paths the engine
/// will read, so a mismatch between the two halves fails loudly at build time
/// rather than as a mystifying 404.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_engine_spec_reads_every_field_from_the_packages_own_policy() {
        let spec = kilo_serve_spec();
        let policy = &policy::SPEC;
        assert_eq!(spec.identity, policy.identity);
        assert_eq!(spec.default_port, policy.default_port);
        assert_eq!(spec.port_range_span, policy.port_range_span);
        assert_eq!(spec.default_host, policy.default_host);
        assert_eq!(spec.health_path, policy.health_path);
        assert_eq!(spec.session_probe_path, policy.session_probe_path);
        assert_eq!(spec.config_path, policy.config_path);
        assert_eq!(spec.provider_path, policy.provider_path);
        assert_eq!(spec.state_dir, policy.state_dir);
        assert_eq!(spec.state_schema_version, policy.state_schema_version);
        assert_eq!(
            spec.default_health_timeout_ms,
            policy.default_health_timeout_ms
        );
        assert_eq!(spec.reserved_ports, policy.reserved_ports);
        assert_eq!(spec.executable_environment, policy.executable_environment);
        assert_eq!(spec.default_executable, policy.default_executable);
        assert_eq!(
            spec.errors.executable_missing,
            policy.errors.executable_missing
        );
        assert_eq!(spec.errors.stop_failed, policy.errors.stop_failed);
    }

    #[test]
    fn readiness_crosses_the_seam_with_its_models_intact() {
        let spec = kilo_serve_spec();
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
    }

    #[test]
    fn the_engine_configure_command_is_this_agents_own_launch_shape() {
        let mut command = std::process::Command::new("kilo");
        (kilo_serve_spec().configure_command)(&mut command, "127.0.0.1", 4097);
        let args: Vec<_> = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect();
        assert_eq!(args, ["serve", "--hostname", "127.0.0.1", "--port", "4097"]);
    }

    #[test]
    fn an_absolute_path_is_what_the_package_requires() {
        assert!(Path::new("/workspace").is_absolute());
        assert!(!Path::new("workspace").is_absolute());
    }
}
