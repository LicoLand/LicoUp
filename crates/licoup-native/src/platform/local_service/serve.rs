use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::process::Command;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::SyncSender;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use super::bounds::{MAX_PROJECTED_EVENT_TEXT_BYTES, PROCESS_POLL_INTERVAL};
use super::endpoint::ServeEndpoint;
use super::executable;
use super::http::{self, HttpFailure};
use super::params;
use super::port;
use super::process::{self, CommandServeRunner, ServeRunner, SpawnFailure};
use super::state::{self, OperationLock, ServicePaths};

#[derive(Clone, Copy)]
pub(in crate::platform) struct ServeErrorCodes {
    pub(in crate::platform) executable_missing: &'static str,
    pub(in crate::platform) port_exhausted: &'static str,
    pub(in crate::platform) start_failed: &'static str,
    pub(in crate::platform) health_failed: &'static str,
    pub(in crate::platform) attach_probe_failed: &'static str,
    pub(in crate::platform) not_found: &'static str,
    pub(in crate::platform) request_failed: &'static str,
    pub(in crate::platform) invalid_json: &'static str,
    pub(in crate::platform) invalid_state: &'static str,
    pub(in crate::platform) stop_failed: &'static str,
}

#[derive(Clone, Copy)]
pub(in crate::platform) struct ServeSpec {
    pub(in crate::platform) identity: &'static str,
    pub(in crate::platform) default_port: u16,
    pub(in crate::platform) port_range_span: u16,
    pub(in crate::platform) default_host: &'static str,
    pub(in crate::platform) health_path: &'static str,
    pub(in crate::platform) session_probe_path: &'static str,
    pub(in crate::platform) state_dir: &'static str,
    pub(in crate::platform) state_schema_version: &'static str,
    pub(in crate::platform) default_health_timeout_ms: u64,
    pub(in crate::platform) reserved_ports: &'static [u16],
    pub(in crate::platform) executable_environment: &'static [&'static str],
    pub(in crate::platform) default_executable: &'static str,
    pub(in crate::platform) configure_command: fn(&mut Command, &str, u16),
    pub(in crate::platform) errors: ServeErrorCodes,
}

pub(in crate::platform) fn ensure(spec: ServeSpec, params: &Value) -> Result<Value> {
    operate(spec, |paths| {
        start_with_paths(spec, params, paths, true, &CommandServeRunner)
    })
}

pub(in crate::platform) fn start(spec: ServeSpec, params: &Value) -> Result<Value> {
    operate(spec, |paths| {
        start_with_paths(spec, params, paths, false, &CommandServeRunner)
    })
}

pub(in crate::platform) fn restart(spec: ServeSpec, params: &Value) -> Result<Value> {
    operate(spec, |paths| {
        process::stop(paths, spec.errors.stop_failed)?;
        start_with_paths(spec, params, paths, false, &CommandServeRunner)
    })
}

pub(in crate::platform) fn stop(spec: ServeSpec) -> Result<Value> {
    operate(spec, |paths| {
        let stopped = process::stop(paths, spec.errors.stop_failed)?;
        let mut service_state = state::read_json(&paths.state_path, spec.errors.invalid_state)?;
        service_state["status"] = json!("stopped");
        service_state["running"] = json!(false);
        service_state["updatedAtUnix"] = json!(unix_seconds());
        state::write_json(&paths.state_path, &service_state)?;
        Ok(json!({
            "ok": true,
            "status": "stopped",
            "attachUrl": service_state.get("attachUrl").cloned().unwrap_or(json!("")),
            "port": service_state.get("port").cloned().unwrap_or(json!(spec.default_port)),
            "stopped": stopped
        }))
    })
}

pub(in crate::platform) fn status(spec: ServeSpec) -> Result<Value> {
    operate(spec, |paths| status_with_paths(spec, paths))
}

pub(in crate::platform) fn ensure_attach_endpoint(
    spec: ServeSpec,
    executable: &str,
) -> Result<ServeEndpoint> {
    let result = ensure(
        spec,
        &json!({
            "executable": executable,
            "binary": executable,
            "host": spec.default_host,
            "port": spec.default_port
        }),
    )?;
    if result.get("ok").and_then(Value::as_bool) != Some(true)
        || result.get("healthy").and_then(Value::as_bool) != Some(true)
    {
        return Err(anyhow!(
            result
                .get("errorCode")
                .and_then(Value::as_str)
                .unwrap_or(spec.errors.health_failed)
                .to_string()
        ));
    }
    let host = result
        .get("host")
        .and_then(Value::as_str)
        .unwrap_or(spec.default_host)
        .to_string();
    let port = result
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|value| u16::try_from(value).ok())
        .unwrap_or(spec.default_port);
    let endpoint = ServeEndpoint::new(host, port);
    verify_attach_ready(spec, &endpoint.attach_url)?;
    Ok(endpoint)
}

pub(in crate::platform) fn select_available_port(spec: ServeSpec, preferred: u16) -> Result<u16> {
    port::select(
        preferred,
        spec.port_range_span,
        spec.reserved_ports,
        spec.errors.port_exhausted,
    )
}

pub(in crate::platform) fn select_available_port_with<F>(
    spec: ServeSpec,
    preferred: u16,
    is_bindable: F,
) -> Result<u16>
where
    F: Fn(u16) -> bool,
{
    port::select_with(
        preferred,
        spec.port_range_span,
        spec.reserved_ports,
        spec.errors.port_exhausted,
        is_bindable,
    )
}

pub(in crate::platform) fn is_reserved_port(spec: ServeSpec, candidate: u16) -> bool {
    port::is_reserved(candidate, spec.reserved_ports)
}

pub(in crate::platform) fn get_json(spec: ServeSpec, url: &str) -> Result<Value> {
    http::get_json(url, Duration::from_secs(5)).map_err(|failure| http_error(spec, failure))
}

pub(in crate::platform) fn post_json(spec: ServeSpec, url: &str, body: &Value) -> Result<Value> {
    http::post_json(url, body, Duration::from_secs(120))
        .map_err(|failure| http_error(spec, failure))
}

pub(in crate::platform) fn watch_session_events(
    spec: ServeSpec,
    attach_url: &str,
    session_id: &str,
    stop: &AtomicBool,
    chunks: &SyncSender<String>,
) {
    let url = format!("{}/event", attach_url.trim_end_matches('/'));
    let _ = super::sse::watch_data(&url, stop, |data| {
        if let Some(text) = project_session_text(session_id, data) {
            let _ = chunks.try_send(text);
        }
        true
    });
    let _ = spec;
}

pub(in crate::platform) fn project_session_text(session_id: &str, data: &str) -> Option<String> {
    let event = serde_json::from_str::<Value>(data).ok()?;
    let event_type = event.get("type").and_then(Value::as_str)?;
    if !matches!(event_type, "message.part.updated" | "message.part.delta") {
        return None;
    }
    let properties = event.get("properties")?;
    let event_session = properties
        .get("sessionID")
        .or_else(|| properties.get("sessionId"))
        .and_then(Value::as_str)?;
    if event_session != session_id {
        return None;
    }
    properties
        .pointer("/part/text")
        .or_else(|| properties.get("text"))
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty() && text.len() <= MAX_PROJECTED_EVENT_TEXT_BYTES)
        .map(str::to_string)
}

fn operate<F>(spec: ServeSpec, operation: F) -> Result<Value>
where
    F: FnOnce(&ServicePaths) -> Result<Value>,
{
    let paths = ServicePaths::resolve(spec.state_dir, "serve.pid")?;
    let _lock = OperationLock::acquire(&paths.lock_path)?;
    operation(&paths)
}

fn status_with_paths(spec: ServeSpec, paths: &ServicePaths) -> Result<Value> {
    let mut service_state = state::read_json(&paths.state_path, spec.errors.invalid_state)?;
    let pid = state::read_pid(&paths.pid_path)?;
    let pid_alive = process::alive(pid);
    let attach_url = service_state
        .get("attachUrl")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| ServeEndpoint::new(spec.default_host, spec.default_port).attach_url);
    let health = one_health_check(spec, &attach_url).ok();
    let healthy = health_is_ready(health.as_ref());
    let adopted = healthy && !pid_alive;
    let running = pid_alive || healthy;
    if !running
        && service_state
            .get("running")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        service_state["status"] = json!("stopped");
        service_state["running"] = json!(false);
        service_state["updatedAtUnix"] = json!(unix_seconds());
        state::write_json(&paths.state_path, &service_state)?;
    } else if adopted {
        service_state["status"] = json!("running");
        service_state["running"] = json!(true);
        service_state["adopted"] = json!(true);
        service_state["attachUrl"] = json!(attach_url);
        service_state["updatedAtUnix"] = json!(unix_seconds());
        state::write_json(&paths.state_path, &service_state)?;
    }
    let status = if running && healthy {
        "running"
    } else if pid_alive {
        "blocked"
    } else if service_state
        .get("errorCode")
        .and_then(Value::as_str)
        .is_some()
    {
        "unavailable"
    } else {
        "stopped"
    };
    Ok(json!({
        "ok": true,
        "status": status,
        "running": running,
        "healthy": healthy,
        "adopted": adopted,
        "pid": pid.unwrap_or(0),
        "attachUrl": attach_url,
        "host": service_state.get("host").cloned().unwrap_or_else(|| json!(spec.default_host)),
        "port": service_state.get("port").cloned().unwrap_or_else(|| json!(spec.default_port)),
        "preferredPort": service_state.get("preferredPort").cloned().unwrap_or_else(|| json!(spec.default_port)),
        "portConflict": service_state.get("portConflict").cloned().unwrap_or(json!(false)),
        "executableAvailable": executable::available(
            service_state
                .get("executable")
                .and_then(Value::as_str)
                .unwrap_or(spec.default_executable)
        ),
        "errorCode": service_state.get("errorCode").cloned().unwrap_or(Value::Null),
        "health": health.unwrap_or_else(|| json!({"healthy": false}))
    }))
}

fn start_with_paths(
    spec: ServeSpec,
    params_value: &Value,
    paths: &ServicePaths,
    reuse_healthy: bool,
    runner: &dyn ServeRunner,
) -> Result<Value> {
    let had_existing_state = paths.state_path.exists();
    let preferred =
        params::u16_value(params_value, &["port", "preferredPort"]).unwrap_or(spec.default_port);
    let host = params::text(params_value, &["host", "hostname"])
        .unwrap_or_else(|| spec.default_host.to_string());
    if !matches!(host.as_str(), "127.0.0.1" | "localhost" | "::1") {
        if let Some(attach_url) = params::text(params_value, &["attachUrl", "remoteUrl"]) {
            return status_for_remote(spec, &attach_url);
        }
        return Err(anyhow!(format!("{}_remote_attach_required", spec.identity)));
    }
    let executable = executable::resolve(
        params_value,
        spec.executable_environment,
        spec.default_executable,
    );
    let preferred_endpoint = ServeEndpoint::new(&host, preferred);

    if reuse_healthy {
        if let Ok(health) =
            probe_ready(spec, &preferred_endpoint.attach_url, Duration::from_secs(5))
        {
            return persist_reused_endpoint(
                spec,
                paths,
                &preferred_endpoint,
                preferred,
                &executable,
                health,
                false,
            );
        }
        let existing = status_with_paths(spec, paths)?;
        if had_existing_state && existing.get("healthy").and_then(Value::as_bool) == Some(true) {
            let attach_url = existing
                .get("attachUrl")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if !attach_url.is_empty()
                && let Ok(health) = probe_ready(spec, attach_url, Duration::from_secs(5))
            {
                let port = existing
                    .get("port")
                    .and_then(Value::as_u64)
                    .and_then(|value| u16::try_from(value).ok())
                    .unwrap_or(preferred);
                let endpoint = ServeEndpoint::new(
                    existing
                        .get("host")
                        .and_then(Value::as_str)
                        .unwrap_or(&host),
                    port,
                );
                return persist_reused_endpoint(
                    spec,
                    paths,
                    &endpoint,
                    preferred,
                    &executable,
                    health,
                    existing
                        .get("adopted")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                );
            }
        }
        if existing.get("running").and_then(Value::as_bool) == Some(true)
            && existing.get("healthy").and_then(Value::as_bool) != Some(true)
            && existing.get("adopted").and_then(Value::as_bool) != Some(true)
        {
            process::stop(paths, spec.errors.stop_failed)?;
        }
    }

    if !executable::available(&executable) {
        if let Ok(health) =
            probe_ready(spec, &preferred_endpoint.attach_url, Duration::from_secs(5))
        {
            return persist_reused_endpoint(
                spec,
                paths,
                &preferred_endpoint,
                preferred,
                &executable,
                health,
                true,
            );
        }
        return persist_failure(
            spec,
            paths,
            &host,
            preferred,
            preferred,
            &preferred_endpoint,
            &executable,
            "unavailable",
            spec.errors.executable_missing,
            false,
            false,
        );
    }

    let selected = match select_available_port(spec, preferred) {
        Ok(port) => port,
        Err(_) => {
            if let Ok(health) =
                probe_ready(spec, &preferred_endpoint.attach_url, Duration::from_secs(5))
            {
                return persist_reused_endpoint(
                    spec,
                    paths,
                    &preferred_endpoint,
                    preferred,
                    &executable,
                    health,
                    true,
                );
            }
            return persist_failure(
                spec,
                paths,
                &host,
                preferred,
                preferred,
                &preferred_endpoint,
                &executable,
                "blocked",
                spec.errors.port_exhausted,
                true,
                true,
            );
        }
    };
    let endpoint = ServeEndpoint::new(&host, selected);
    let port_conflict = selected != preferred;
    let timeout = Duration::from_millis(
        params::u64_value(params_value, &["healthTimeoutMs"])
            .unwrap_or(spec.default_health_timeout_ms),
    );
    let pid = match runner.spawn(&executable, &host, selected, spec.configure_command) {
        Ok(pid) => pid,
        Err(failure) => {
            let missing = failure == SpawnFailure::Missing;
            let code = if missing {
                spec.errors.executable_missing
            } else {
                spec.errors.start_failed
            };
            return persist_failure(
                spec,
                paths,
                &host,
                preferred,
                selected,
                &endpoint,
                &executable,
                "unavailable",
                code,
                port_conflict,
                !missing,
            );
        }
    };
    if state::write_pid(&paths.pid_path, pid).is_err() {
        process::terminate_owned(pid);
        return Err(anyhow!(spec.errors.start_failed));
    }

    match wait_for_ready(spec, &endpoint.attach_url, timeout) {
        Ok(health) => {
            let service_state = json!({
                "schemaVersion": spec.state_schema_version,
                "status": "running",
                "running": true,
                "preferredPort": preferred,
                "host": host,
                "port": selected,
                "attachUrl": endpoint.attach_url,
                "portConflict": port_conflict,
                "pid": pid,
                "executable": executable,
                "updatedAtUnix": unix_seconds()
            });
            if state::write_json(&paths.state_path, &service_state).is_err() {
                let _ = process::stop(paths, spec.errors.stop_failed);
                return Err(anyhow!(spec.errors.start_failed));
            }
            Ok(json!({
                "ok": true,
                "status": "running",
                "reused": false,
                "running": true,
                "healthy": true,
                "pid": pid,
                "host": host,
                "port": selected,
                "preferredPort": preferred,
                "attachUrl": endpoint.attach_url,
                "portConflict": port_conflict,
                "executableAvailable": true,
                "health": health
            }))
        }
        Err(_) => {
            let _ = process::stop(paths, spec.errors.stop_failed);
            persist_failure(
                spec,
                paths,
                &host,
                preferred,
                selected,
                &endpoint,
                &executable,
                "blocked",
                spec.errors.health_failed,
                port_conflict,
                true,
            )
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn persist_failure(
    spec: ServeSpec,
    paths: &ServicePaths,
    host: &str,
    preferred: u16,
    selected: u16,
    endpoint: &ServeEndpoint,
    executable: &str,
    status: &'static str,
    error_code: &'static str,
    port_conflict: bool,
    executable_available: bool,
) -> Result<Value> {
    let service_state = json!({
        "schemaVersion": spec.state_schema_version,
        "status": status,
        "running": false,
        "errorCode": error_code,
        "preferredPort": preferred,
        "host": host,
        "port": selected,
        "attachUrl": endpoint.attach_url,
        "portConflict": port_conflict,
        "executable": executable,
        "updatedAtUnix": unix_seconds()
    });
    state::write_json(&paths.state_path, &service_state)?;
    Ok(json!({
        "ok": false,
        "status": status,
        "running": false,
        "healthy": false,
        "errorCode": error_code,
        "host": host,
        "port": selected,
        "preferredPort": preferred,
        "attachUrl": endpoint.attach_url,
        "portConflict": port_conflict,
        "executableAvailable": executable_available
    }))
}

fn persist_reused_endpoint(
    spec: ServeSpec,
    paths: &ServicePaths,
    endpoint: &ServeEndpoint,
    preferred: u16,
    executable: &str,
    health: Value,
    adopted: bool,
) -> Result<Value> {
    let port_conflict = endpoint.port != preferred;
    let service_state = json!({
        "schemaVersion": spec.state_schema_version,
        "status": "running",
        "running": true,
        "preferredPort": preferred,
        "host": endpoint.host,
        "port": endpoint.port,
        "attachUrl": endpoint.attach_url,
        "portConflict": port_conflict,
        "adopted": adopted,
        "executable": executable,
        "updatedAtUnix": unix_seconds()
    });
    state::write_json(&paths.state_path, &service_state)?;
    Ok(json!({
        "ok": true,
        "status": "running",
        "reused": true,
        "adopted": adopted,
        "running": true,
        "healthy": true,
        "pid": state::read_pid(&paths.pid_path)?.unwrap_or(0),
        "host": endpoint.host,
        "port": endpoint.port,
        "preferredPort": preferred,
        "attachUrl": endpoint.attach_url,
        "portConflict": port_conflict,
        "executableAvailable": executable::available(executable),
        "health": health
    }))
}

fn status_for_remote(spec: ServeSpec, attach_url: &str) -> Result<Value> {
    let trimmed = attach_url.trim().trim_end_matches('/');
    let health = probe_ready(spec, trimmed, Duration::from_secs(5)).ok();
    let healthy = health_is_ready(health.as_ref());
    Ok(json!({
        "ok": healthy,
        "status": if healthy { "running" } else { "blocked" },
        "running": healthy,
        "healthy": healthy,
        "attachUrl": trimmed,
        "remote": true,
        "health": health.unwrap_or_else(|| json!({"healthy": false})),
        "errorCode": if healthy { Value::Null } else { json!(spec.errors.health_failed) }
    }))
}

fn wait_for_ready(spec: ServeSpec, attach_url: &str, timeout: Duration) -> Result<Value> {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if let Ok(health) = probe_ready(spec, attach_url, remaining.min(Duration::from_secs(5))) {
            return Ok(health);
        }
        thread::sleep(PROCESS_POLL_INTERVAL.min(remaining));
    }
    Err(anyhow!(spec.errors.health_failed))
}

fn probe_ready(spec: ServeSpec, attach_url: &str, timeout: Duration) -> Result<Value> {
    let deadline = Instant::now() + timeout;
    let health = one_health_check_with_timeout(spec, attach_url, timeout)?;
    if !health_is_ready(Some(&health)) {
        return Err(anyhow!(spec.errors.health_failed));
    }
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(anyhow!(spec.errors.attach_probe_failed));
    }
    let sessions_url = format!(
        "{}{}",
        attach_url.trim_end_matches('/'),
        spec.session_probe_path
    );
    http::get_json(&sessions_url, remaining)
        .map_err(|_| anyhow!(spec.errors.attach_probe_failed))?;
    Ok(health)
}

fn one_health_check(spec: ServeSpec, attach_url: &str) -> Result<Value> {
    one_health_check_with_timeout(spec, attach_url, Duration::from_secs(5))
}

fn one_health_check_with_timeout(
    spec: ServeSpec,
    attach_url: &str,
    timeout: Duration,
) -> Result<Value> {
    let url = format!("{}{}", attach_url.trim_end_matches('/'), spec.health_path);
    let payload = http::get_json(&url, timeout).map_err(|failure| http_error(spec, failure))?;
    Ok(json!({
        "healthy": payload
            .get("healthy")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    }))
}

fn health_is_ready(payload: Option<&Value>) -> bool {
    payload
        .and_then(|value| value.get("healthy"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn verify_attach_ready(spec: ServeSpec, attach_url: &str) -> Result<()> {
    probe_ready(spec, attach_url, Duration::from_secs(5)).map(|_| ())
}

fn http_error(spec: ServeSpec, failure: HttpFailure) -> anyhow::Error {
    let code = match failure {
        HttpFailure::NotFound => spec.errors.not_found,
        HttpFailure::InvalidJson => spec.errors.invalid_json,
        _ => spec.errors.request_failed,
    };
    anyhow!(code)
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
