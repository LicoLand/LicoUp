//! OpenCode headless `serve` lifecycle owned by the native client.
//!
//! Arc auto-starts a localhost serve on an uncommon reserved port, detects
//! collisions with known Arc/LicoLite ports, and persists the attach endpoint
//! so conversation open/send can reuse the running environment.

use crate::platform::file_security::{atomic_write_private_text, harden_private_path};
use crate::platform::paths;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::fs::{self, OpenOptions};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Default OpenCode serve port. Chosen to avoid common Arc/LicoLite and
/// OpenCode example ports (7228, 17328/17329, 8080, 4096, 18789, 58627).
pub const DEFAULT_PORT: u16 = 24173;
const PORT_RANGE_SPAN: u16 = 16;
const HEALTH_PATH: &str = "/global/health";
const SESSION_PROBE_PATH: &str = "/session";
const DEFAULT_HOST: &str = "127.0.0.1";
const STATE_DIR: &str = "opencode-serve";
const DEFAULT_HEALTH_TIMEOUT_MS: u64 = 45_000;
const STATE_SCHEMA_VERSION: &str = "v0.0.1:opencode-serve-1";

/// Ports reserved by Arc / LicoLite / vendor defaults that must not be selected
/// even when currently free. Research-locked exclusions: 4096, 17328, 18789,
/// 58627. Arc default OpenCode serve port 24173 is intentionally not reserved.
const RESERVED_CONFLICT_PORTS: &[u16] = &[
    3000, 4096, 5173, 5494, 7228, 8080, 8443, 17328, 17329, 18765, 18789, 19001, 24189, 58627,
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ServeEndpoint {
    pub host: String,
    pub port: u16,
    pub attach_url: String,
}

impl ServeEndpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        let host = host.into();
        Self {
            attach_url: format!("http://{}:{}", host, port),
            host,
            port,
        }
    }
}

#[derive(Clone, Debug)]
struct ServePaths {
    root: PathBuf,
    state_path: PathBuf,
    pid_path: PathBuf,
    log_path: PathBuf,
}

trait ServeRunner: Send {
    fn spawn_serve(&self, executable: &str, host: &str, port: u16, log_path: &Path) -> Result<u32>;
}

struct DefaultServeRunner;

impl ServeRunner for DefaultServeRunner {
    fn spawn_serve(&self, executable: &str, host: &str, port: u16, log_path: &Path) -> Result<u32> {
        if let Some(parent) = log_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let stdout = OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_path)?;
        let stderr = stdout.try_clone()?;
        let mut command = Command::new(executable);
        command
            .args(["serve", "--hostname", host, "--port", &port.to_string()])
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr));
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt as WindowsCommandExt;
            command.creation_flags(0x0000_0008 | 0x0000_0200 | 0x0800_0000);
        }
        let child = command.spawn().map_err(|error| match error.kind() {
            std::io::ErrorKind::NotFound => {
                anyhow!("opencode executable is not available")
            }
            std::io::ErrorKind::PermissionDenied => {
                anyhow!("opencode executable is not permitted to run")
            }
            _ => anyhow!("opencode serve could not be started"),
        })?;
        Ok(child.id())
    }
}

fn runner_slot() -> &'static Mutex<Option<Box<dyn ServeRunner>>> {
    static SLOT: OnceLock<Mutex<Option<Box<dyn ServeRunner>>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

#[cfg(test)]
fn install_test_runner(runner: Box<dyn ServeRunner>) {
    *runner_slot().lock().expect("opencode serve runner lock") = Some(runner);
}

#[cfg(test)]
fn clear_test_runner() {
    *runner_slot().lock().expect("opencode serve runner lock") = None;
}

fn active_runner() -> Box<dyn ServeRunner> {
    struct Delegating;
    impl ServeRunner for Delegating {
        fn spawn_serve(
            &self,
            executable: &str,
            host: &str,
            port: u16,
            log_path: &Path,
        ) -> Result<u32> {
            let guard = runner_slot().lock().expect("opencode serve runner lock");
            if let Some(runner) = guard.as_ref() {
                return runner.spawn_serve(executable, host, port, log_path);
            }
            drop(guard);
            DefaultServeRunner.spawn_serve(executable, host, port, log_path)
        }
    }
    Box::new(Delegating)
}

pub fn ensure(params: &Value) -> Result<Value> {
    let paths = serve_paths()?;
    fs::create_dir_all(&paths.root)?;
    harden_private_path(&paths.root)?;
    start_with_paths(params, &paths, true)
}

pub fn start(params: &Value) -> Result<Value> {
    let paths = serve_paths()?;
    fs::create_dir_all(&paths.root)?;
    harden_private_path(&paths.root)?;
    start_with_paths(params, &paths, false)
}

pub fn restart(params: &Value) -> Result<Value> {
    let paths = serve_paths()?;
    let _ = stop_process(&paths);
    start(params)
}

pub fn stop(_params: &Value) -> Result<Value> {
    let paths = serve_paths()?;
    let stopped = stop_process(&paths)?;
    let mut state = read_state(&paths.state_path)?;
    state["status"] = json!("stopped");
    state["running"] = json!(false);
    state["updatedAtUnix"] = json!(unix_seconds());
    write_json_private(&paths.state_path, &state)?;
    Ok(json!({
        "ok": true,
        "status": "stopped",
        "attachUrl": state.get("attachUrl").cloned().unwrap_or(json!("")),
        "port": state.get("port").cloned().unwrap_or(json!(DEFAULT_PORT)),
        "stopped": stopped
    }))
}

pub fn status(_params: &Value) -> Result<Value> {
    let paths = serve_paths()?;
    fs::create_dir_all(&paths.root)?;
    let mut state = read_state(&paths.state_path)?;
    let pid = read_pid(&paths.pid_path)?;
    let pid_alive = process_alive(pid);
    let attach_url = state
        .get("attachUrl")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| ServeEndpoint::new(DEFAULT_HOST, DEFAULT_PORT).attach_url);
    // Health is authoritative for attach readiness. A live HTTP serve is reused
    // even when the PID file is missing/stale (adopted endpoint).
    let health = one_health_check(&attach_url).ok();
    let healthy = health_payload_is_ready(health.as_ref());
    let adopted = healthy && !pid_alive;
    let running = pid_alive || healthy;
    if !running
        && state
            .get("running")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        state["status"] = json!("stopped");
        state["running"] = json!(false);
        state["updatedAtUnix"] = json!(unix_seconds());
        write_json_private(&paths.state_path, &state)?;
    } else if adopted {
        state["status"] = json!("running");
        state["running"] = json!(true);
        state["adopted"] = json!(true);
        state["attachUrl"] = json!(attach_url);
        state["updatedAtUnix"] = json!(unix_seconds());
        write_json_private(&paths.state_path, &state)?;
    }
    let status = if running && healthy {
        "running"
    } else if pid_alive {
        "blocked"
    } else if state.get("errorCode").and_then(Value::as_str).is_some() {
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
        "host": state.get("host").cloned().unwrap_or_else(|| json!(DEFAULT_HOST)),
        "port": state.get("port").cloned().unwrap_or_else(|| json!(DEFAULT_PORT)),
        "preferredPort": state.get("preferredPort").cloned().unwrap_or_else(|| json!(DEFAULT_PORT)),
        "portConflict": state.get("portConflict").cloned().unwrap_or(json!(false)),
        "executableAvailable": executable_available(
            state
                .get("executable")
                .and_then(Value::as_str)
                .unwrap_or("opencode")
        ),
        "errorCode": state.get("errorCode").cloned().unwrap_or(Value::Null),
        "health": health.unwrap_or(Value::Null),
        "state": state
    }))
}

/// Ensure a healthy local serve is available for attach-style conversation use.
pub fn ensure_attach_endpoint(executable: &str) -> Result<ServeEndpoint> {
    let result = ensure(&json!({
        "executable": executable,
        "binary": executable,
        "host": DEFAULT_HOST,
        "port": DEFAULT_PORT
    }))?;
    if result.get("ok").and_then(Value::as_bool) != Some(true)
        || result.get("healthy").and_then(Value::as_bool) != Some(true)
    {
        let code = result
            .get("errorCode")
            .and_then(Value::as_str)
            .unwrap_or("opencode_serve_unavailable");
        return Err(anyhow!(code.to_string()));
    }
    let host = result
        .get("host")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_HOST)
        .to_string();
    let port = result
        .get("port")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_PORT as u64) as u16;
    let endpoint = ServeEndpoint::new(host, port);
    // Fail-closed attach: require a fresh health + session probe before use.
    verify_attach_ready(&endpoint.attach_url)?;
    Ok(endpoint)
}

pub fn select_available_port(preferred: u16) -> Result<u16> {
    select_available_port_with(preferred, port_is_bindable)
}

pub fn select_available_port_with<F>(preferred: u16, is_bindable: F) -> Result<u16>
where
    F: Fn(u16) -> bool,
{
    let start = if is_reserved_conflict_port(preferred) {
        next_non_reserved(preferred.saturating_add(1))
    } else {
        preferred
    };
    let end = start.saturating_add(PORT_RANGE_SPAN);
    let mut candidate = start;
    while candidate <= end {
        if !is_reserved_conflict_port(candidate) && is_bindable(candidate) {
            return Ok(candidate);
        }
        candidate = match candidate.checked_add(1) {
            Some(next) => next,
            None => break,
        };
    }
    Err(anyhow!("opencode_serve_port_exhausted"))
}

pub fn is_reserved_conflict_port(port: u16) -> bool {
    RESERVED_CONFLICT_PORTS.contains(&port) || port == 0
}

fn start_with_paths(params: &Value, paths: &ServePaths, reuse_healthy: bool) -> Result<Value> {
    let had_existing_state = paths.state_path.exists();
    let preferred = u16_param(params, &["port", "preferredPort"]).unwrap_or(DEFAULT_PORT);
    let host =
        text_param(params, &["host", "hostname"]).unwrap_or_else(|| DEFAULT_HOST.to_string());
    if host != DEFAULT_HOST && host != "localhost" {
        // Localhost-first; optional remote attach URL is config-only.
        let remote = text_param(params, &["attachUrl", "remoteUrl"]);
        if let Some(attach_url) = remote {
            return status_for_remote(&attach_url);
        }
        return Err(anyhow!(
            "opencode serve auto-start only binds localhost; pass attachUrl for a remote endpoint"
        ));
    }
    let executable = resolve_executable(params)?;
    let preferred_endpoint = ServeEndpoint::new(&host, preferred);

    if reuse_healthy {
        // Prefer live HTTP attach readiness over PID bookkeeping.
        if let Ok(health) = one_health_check(&preferred_endpoint.attach_url)
            && health_payload_is_ready(Some(&health))
        {
            return persist_reused_endpoint(
                paths,
                &preferred_endpoint,
                preferred,
                &executable,
                health,
                false,
            );
        }
        let existing = status(&json!({}))?;
        if had_existing_state && existing.get("healthy").and_then(Value::as_bool) == Some(true) {
            let attach_url = existing
                .get("attachUrl")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            if !attach_url.is_empty()
                && let Ok(health) = one_health_check(&attach_url)
                && health_payload_is_ready(Some(&health))
            {
                let port = existing
                    .get("port")
                    .and_then(Value::as_u64)
                    .unwrap_or(preferred as u64) as u16;
                let endpoint = ServeEndpoint::new(
                    existing
                        .get("host")
                        .and_then(Value::as_str)
                        .unwrap_or(&host),
                    port,
                );
                return persist_reused_endpoint(
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
        // PID alive but unhealthy: recycle before selecting a new port.
        if existing.get("running").and_then(Value::as_bool) == Some(true)
            && existing.get("healthy").and_then(Value::as_bool) != Some(true)
            && existing.get("adopted").and_then(Value::as_bool) != Some(true)
        {
            let _ = stop_process(paths);
        }
    }

    if !executable_available(&executable) {
        // Last chance: adopt an already-healthy preferred endpoint without spawning.
        if let Ok(health) = one_health_check(&preferred_endpoint.attach_url)
            && health_payload_is_ready(Some(&health))
        {
            return persist_reused_endpoint(
                paths,
                &preferred_endpoint,
                preferred,
                &executable,
                health,
                true,
            );
        }
        let state = json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "status": "unavailable",
            "running": false,
            "errorCode": "opencode_executable_missing",
            "preferredPort": preferred,
            "host": host,
            "port": preferred,
            "attachUrl": preferred_endpoint.attach_url,
            "executable": executable,
            "updatedAtUnix": unix_seconds()
        });
        write_json_private(&paths.state_path, &state)?;
        return Ok(json!({
            "ok": false,
            "status": "unavailable",
            "running": false,
            "healthy": false,
            "errorCode": "opencode_executable_missing",
            "host": host,
            "port": preferred,
            "preferredPort": preferred,
            "attachUrl": preferred_endpoint.attach_url,
            "portConflict": false,
            "executableAvailable": false
        }));
    }

    // If preferred is occupied by a non-OpenCode listener, select_available_port
    // will skip it via bind failure. If preferred is reserved, also skip.
    let selected = match select_available_port(preferred) {
        Ok(port) => port,
        Err(_) => {
            // Preferred may be occupied by a healthy OpenCode we can still attach to.
            if let Ok(health) = one_health_check(&preferred_endpoint.attach_url)
                && health_payload_is_ready(Some(&health))
            {
                return persist_reused_endpoint(
                    paths,
                    &preferred_endpoint,
                    preferred,
                    &executable,
                    health,
                    true,
                );
            }
            let state = json!({
                "schemaVersion": STATE_SCHEMA_VERSION,
                "status": "blocked",
                "running": false,
                "errorCode": "opencode_serve_port_exhausted",
                "preferredPort": preferred,
                "host": host,
                "port": preferred,
                "attachUrl": preferred_endpoint.attach_url,
                "portConflict": true,
                "executable": executable,
                "updatedAtUnix": unix_seconds()
            });
            write_json_private(&paths.state_path, &state)?;
            return Ok(json!({
                "ok": false,
                "status": "blocked",
                "running": false,
                "healthy": false,
                "errorCode": "opencode_serve_port_exhausted",
                "host": host,
                "port": preferred,
                "preferredPort": preferred,
                "attachUrl": preferred_endpoint.attach_url,
                "portConflict": true,
                "executableAvailable": true
            }));
        }
    };
    let port_conflict = selected != preferred;
    let endpoint = ServeEndpoint::new(&host, selected);
    let timeout = Duration::from_millis(
        u64_param(params, &["healthTimeoutMs"]).unwrap_or(DEFAULT_HEALTH_TIMEOUT_MS),
    );

    let runner = active_runner();
    let pid = match runner.spawn_serve(&executable, &host, selected, &paths.log_path) {
        Ok(pid) => pid,
        Err(error) => {
            let code = if error.to_string().contains("not available") {
                "opencode_executable_missing"
            } else {
                "opencode_serve_start_failed"
            };
            let state = json!({
                "schemaVersion": STATE_SCHEMA_VERSION,
                "status": "unavailable",
                "running": false,
                "errorCode": code,
                "preferredPort": preferred,
                "host": host,
                "port": selected,
                "attachUrl": endpoint.attach_url,
                "portConflict": port_conflict,
                "executable": executable,
                "updatedAtUnix": unix_seconds()
            });
            write_json_private(&paths.state_path, &state)?;
            return Ok(json!({
                "ok": false,
                "status": "unavailable",
                "running": false,
                "healthy": false,
                "errorCode": code,
                "host": host,
                "port": selected,
                "preferredPort": preferred,
                "attachUrl": endpoint.attach_url,
                "portConflict": port_conflict,
                "executableAvailable": code != "opencode_executable_missing"
            }));
        }
    };
    write_text_private(&paths.pid_path, &format!("{}\n", pid))?;

    match wait_for_health(&endpoint.attach_url, timeout) {
        Ok(health) => {
            let state = json!({
                "schemaVersion": STATE_SCHEMA_VERSION,
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
            write_json_private(&paths.state_path, &state)?;
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
            let _ = stop_process(paths);
            let state = json!({
                "schemaVersion": STATE_SCHEMA_VERSION,
                "status": "blocked",
                "running": false,
                "errorCode": "opencode_serve_health_failed",
                "preferredPort": preferred,
                "host": host,
                "port": selected,
                "attachUrl": endpoint.attach_url,
                "portConflict": port_conflict,
                "executable": executable,
                "updatedAtUnix": unix_seconds()
            });
            write_json_private(&paths.state_path, &state)?;
            Ok(json!({
                "ok": false,
                "status": "blocked",
                "running": false,
                "healthy": false,
                "errorCode": "opencode_serve_health_failed",
                "host": host,
                "port": selected,
                "preferredPort": preferred,
                "attachUrl": endpoint.attach_url,
                "portConflict": port_conflict,
                "executableAvailable": true
            }))
        }
    }
}

fn persist_reused_endpoint(
    paths: &ServePaths,
    endpoint: &ServeEndpoint,
    preferred: u16,
    executable: &str,
    health: Value,
    adopted: bool,
) -> Result<Value> {
    let port_conflict = endpoint.port != preferred;
    let state = json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
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
    write_json_private(&paths.state_path, &state)?;
    Ok(json!({
        "ok": true,
        "status": "running",
        "reused": true,
        "adopted": adopted,
        "running": true,
        "healthy": true,
        "pid": read_pid(&paths.pid_path)?.unwrap_or(0),
        "host": endpoint.host,
        "port": endpoint.port,
        "preferredPort": preferred,
        "attachUrl": endpoint.attach_url,
        "portConflict": port_conflict,
        "executableAvailable": executable_available(executable),
        "health": health
    }))
}

fn status_for_remote(attach_url: &str) -> Result<Value> {
    let trimmed = attach_url.trim().trim_end_matches('/');
    if !(trimmed.starts_with("http://127.0.0.1")
        || trimmed.starts_with("http://localhost")
        || trimmed.starts_with("https://"))
    {
        return Err(anyhow!(
            "remote OpenCode attach URL must use https:// or localhost http"
        ));
    }
    let health = one_health_check(trimmed).ok();
    let healthy = health_payload_is_ready(health.as_ref());
    Ok(json!({
        "ok": healthy,
        "status": if healthy { "running" } else { "blocked" },
        "running": healthy,
        "healthy": healthy,
        "attachUrl": trimmed,
        "remote": true,
        "health": health.unwrap_or(Value::Null),
        "errorCode": if healthy { Value::Null } else { json!("opencode_serve_health_failed") }
    }))
}

fn wait_for_health(attach_url: &str, timeout: Duration) -> Result<Value> {
    let deadline = Instant::now() + timeout;
    let mut last_error = String::from("health endpoint unreachable");
    while Instant::now() < deadline {
        match one_health_check(attach_url) {
            Ok(payload) if health_payload_is_ready(Some(&payload)) => {
                return Ok(payload);
            }
            Ok(_) => last_error = "health endpoint returned unhealthy".to_string(),
            Err(error) => last_error = error.to_string(),
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err(anyhow!(last_error))
}

fn one_health_check(attach_url: &str) -> Result<Value> {
    let url = format!("{}{}", attach_url.trim_end_matches('/'), HEALTH_PATH);
    get_json(&url)
}

fn health_payload_is_ready(payload: Option<&Value>) -> bool {
    payload
        .and_then(|value| value.get("healthy"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn verify_attach_ready(attach_url: &str) -> Result<()> {
    let health = one_health_check(attach_url)?;
    if !health_payload_is_ready(Some(&health)) {
        return Err(anyhow!("opencode_serve_health_failed"));
    }
    // Session list probe confirms HTTP attach surface beyond health alone.
    let sessions_url = format!("{}{}", attach_url.trim_end_matches('/'), SESSION_PROBE_PATH);
    get_json(&sessions_url).map_err(|_| anyhow!("opencode_serve_attach_probe_failed"))?;
    Ok(())
}

pub(super) fn get_json(url: &str) -> Result<Value> {
    let response = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(5))
        .build()
        .get(url)
        .call()
        .map_err(|error| match error {
            ureq::Error::Status(404, _) => anyhow!("opencode_serve_not_found"),
            _ => anyhow!("opencode serve request failed"),
        })?;
    response
        .into_json::<Value>()
        .map_err(|_| anyhow!("opencode serve returned invalid JSON"))
}

pub(super) fn post_json(url: &str, body: &Value) -> Result<Value> {
    let response = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(120))
        .build()
        .post(url)
        .send_json(body)
        .map_err(|error| match error {
            ureq::Error::Status(404, _) => anyhow!("opencode_serve_not_found"),
            _ => anyhow!("opencode serve request failed"),
        })?;
    response
        .into_json::<Value>()
        .map_err(|_| anyhow!("opencode serve returned invalid JSON"))
}

/// Watch OpenCode serve SSE `/event` frames and forward assistant text chunks.
pub(super) fn watch_session_events(
    attach_url: &str,
    session_id: &str,
    stop: &std::sync::atomic::AtomicBool,
    chunks: &std::sync::mpsc::SyncSender<String>,
) {
    let url = format!("{}/event", attach_url.trim_end_matches('/'));
    let Ok(response) = ureq::AgentBuilder::new()
        .timeout_read(Duration::from_secs(1))
        .timeout_connect(Duration::from_secs(2))
        .build()
        .get(&url)
        .call()
    else {
        return;
    };
    let mut reader = std::io::BufReader::new(response.into_reader());
    let mut line = String::new();
    let mut data = String::new();
    while !stop.load(std::sync::atomic::Ordering::Relaxed) {
        line.clear();
        match std::io::BufRead::read_line(&mut reader, &mut line) {
            Ok(0) => break,
            Ok(_) => {
                let trimmed = line.trim_end();
                if trimmed.is_empty() {
                    if !data.is_empty() {
                        if let Some(text) = watch_chunk(session_id, &data) {
                            let _ = chunks.try_send(text);
                        }
                        data.clear();
                    }
                    continue;
                }
                if let Some(payload) = trimmed.strip_prefix("data:") {
                    if !data.is_empty() {
                        data.push('\n');
                    }
                    data.push_str(payload.trim());
                }
            }
            Err(_) => break,
        }
    }
}

fn watch_chunk(session_id: &str, data: &str) -> Option<String> {
    let Ok(event) = serde_json::from_str::<Value>(data) else {
        return None;
    };
    let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
    let props = event.get("properties").cloned().unwrap_or(Value::Null);
    let event_session = props
        .get("sessionID")
        .or_else(|| props.get("sessionId"))
        .and_then(Value::as_str);
    if event_session.is_some_and(|value| value != session_id) {
        return None;
    }
    let text = match event_type {
        "message.part.updated" | "message.part.delta" => props
            .pointer("/part/text")
            .or_else(|| props.get("text"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
        "session.idle" | "session.status" => None,
        _ => props
            .pointer("/part/text")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
    };
    text
}

fn stop_process(paths: &ServePaths) -> Result<Value> {
    let pid = read_pid(&paths.pid_path)?;
    let mut touched = false;
    let mut forced = false;
    if let Some(pid) = pid
        && process_alive(Some(pid))
    {
        touched = true;
        if terminate_pid(pid, false).is_err() {
            forced = true;
            let _ = terminate_pid(pid, true);
        }
        for _ in 0..40 {
            if !process_alive(Some(pid)) {
                break;
            }
            thread::sleep(Duration::from_millis(250));
        }
        if process_alive(Some(pid)) {
            forced = true;
            let _ = terminate_pid(pid, true);
            for _ in 0..20 {
                if !process_alive(Some(pid)) {
                    break;
                }
                thread::sleep(Duration::from_millis(250));
            }
        }
        if process_alive(Some(pid)) {
            return Err(anyhow!("failed to stop opencode serve process"));
        }
    }
    let _ = fs::remove_file(&paths.pid_path);
    Ok(json!({
        "ok": true,
        "status": if touched { "stopped" } else { "not-running" },
        "pid": pid.unwrap_or(0),
        "forced": forced
    }))
}

fn terminate_pid(pid: u32, force: bool) -> Result<()> {
    #[cfg(unix)]
    {
        let signal = if force { "-KILL" } else { "-TERM" };
        let status = Command::new("kill")
            .arg(signal)
            .arg(pid.to_string())
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(anyhow!("kill failed"))
        }
    }
    #[cfg(windows)]
    {
        let mut args = vec!["/PID".to_string(), pid.to_string(), "/T".to_string()];
        if force {
            args.push("/F".to_string());
        }
        let status = Command::new("taskkill")
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?;
        if status.success() {
            Ok(())
        } else {
            Err(anyhow!("taskkill failed"))
        }
    }
}

fn process_alive(pid: Option<u32>) -> bool {
    let Some(pid) = pid else {
        return false;
    };
    if pid == 0 {
        return false;
    }
    #[cfg(unix)]
    {
        Command::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    }
    #[cfg(windows)]
    {
        Command::new("tasklist")
            .args(["/FI", &format!("PID eq {}", pid)])
            .output()
            .map(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains(&pid.to_string())
            })
            .unwrap_or(false)
    }
}

fn port_is_bindable(port: u16) -> bool {
    TcpListener::bind((DEFAULT_HOST, port)).is_ok()
}

fn next_non_reserved(mut port: u16) -> u16 {
    while is_reserved_conflict_port(port) {
        match port.checked_add(1) {
            Some(next) => port = next,
            None => return port,
        }
    }
    port
}

fn serve_paths() -> Result<ServePaths> {
    let root = paths::portable_data_dir()?.join(STATE_DIR);
    Ok(ServePaths {
        state_path: root.join("state.json"),
        pid_path: root.join("serve.pid"),
        log_path: root.join("serve.log"),
        root,
    })
}

fn resolve_executable(params: &Value) -> Result<String> {
    if let Some(value) = text_param(params, &["executable", "binary", "binaryPath"]) {
        return Ok(value);
    }
    if let Ok(value) = std::env::var("OPENCODE_BIN") {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    Ok("opencode".to_string())
}

fn executable_available(executable: &str) -> bool {
    let path = Path::new(executable);
    if path.is_absolute() || executable.contains('/') || executable.contains('\\') {
        return path.is_file();
    }
    which_command(executable)
}

fn which_command(name: &str) -> bool {
    let Ok(path_var) = std::env::var("PATH") else {
        return false;
    };
    for entry in std::env::split_paths(&path_var) {
        let candidate = entry.join(name);
        if candidate.is_file() {
            return true;
        }
        #[cfg(windows)]
        {
            let exe = entry.join(format!("{}.exe", name));
            if exe.is_file() {
                return true;
            }
        }
    }
    false
}

fn read_state(path: &Path) -> Result<Value> {
    if !path.exists() {
        return Ok(json!({}));
    }
    let text = fs::read_to_string(path)?;
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(&text).map_err(|_| anyhow!("opencode serve state is invalid"))
}

fn write_json_private(path: &Path, value: &Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        harden_private_path(parent)?;
    }
    let body = serde_json::to_vec_pretty(value)?;
    atomic_write_private_text(path, &String::from_utf8_lossy(&body))?;
    Ok(())
}

fn write_text_private(path: &Path, body: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
        harden_private_path(parent)?;
    }
    atomic_write_private_text(path, body)?;
    Ok(())
}

fn read_pid(path: &Path) -> Result<Option<u32>> {
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(path)?;
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    Ok(trimmed.parse::<u32>().ok())
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
    })
}

fn u16_param(params: &Value, keys: &[&str]) -> Option<u16> {
    keys.iter().find_map(|key| {
        params
            .get(*key)
            .and_then(|value| {
                value
                    .as_u64()
                    .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
            })
            .and_then(|value| u16::try_from(value).ok())
    })
}

fn u64_param(params: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        })
    })
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct FakeRunner {
        next_pid: AtomicU32,
        fail: bool,
    }

    impl ServeRunner for FakeRunner {
        fn spawn_serve(
            &self,
            _executable: &str,
            _host: &str,
            _port: u16,
            _log_path: &Path,
        ) -> Result<u32> {
            if self.fail {
                return Err(anyhow!("opencode executable is not available"));
            }
            Ok(self.next_pid.fetch_add(1, Ordering::SeqCst))
        }
    }

    #[test]
    fn reserved_ports_are_rejected_even_when_bindable() {
        assert!(is_reserved_conflict_port(7228));
        assert!(is_reserved_conflict_port(17328));
        assert!(is_reserved_conflict_port(8080));
        assert!(is_reserved_conflict_port(4096));
        assert!(is_reserved_conflict_port(18789));
        assert!(is_reserved_conflict_port(58627));
        assert!(!is_reserved_conflict_port(DEFAULT_PORT));
        assert_eq!(DEFAULT_PORT, 24173);
    }

    #[test]
    fn select_port_skips_research_locked_reserved_ports() {
        let selected =
            select_available_port_with(18789, |port| port == 18790 || port == DEFAULT_PORT)
                .unwrap();
        assert_eq!(selected, 18790);
        let selected =
            select_available_port_with(58627, |port| port == 58628 || port == DEFAULT_PORT)
                .unwrap();
        assert_eq!(selected, 58628);
    }

    #[test]
    fn health_payload_requires_explicit_healthy_flag() {
        assert!(!health_payload_is_ready(None));
        assert!(!health_payload_is_ready(Some(&json!({"healthy": false}))));
        assert!(!health_payload_is_ready(Some(&json!({}))));
        assert!(health_payload_is_ready(Some(&json!({"healthy": true}))));
    }

    #[test]
    fn select_port_skips_reserved_and_in_use() {
        let selected =
            select_available_port_with(7228, |port| port == 7229 || port == DEFAULT_PORT).unwrap();
        assert_eq!(selected, 7229);
        let selected = select_available_port_with(DEFAULT_PORT, |port| {
            port != DEFAULT_PORT && port != DEFAULT_PORT + 1
        })
        .unwrap();
        assert_eq!(selected, DEFAULT_PORT + 2);
    }

    #[test]
    fn select_port_fails_closed_when_range_exhausted() {
        let error = select_available_port_with(DEFAULT_PORT, |_| false).unwrap_err();
        assert!(error.to_string().contains("opencode_serve_port_exhausted"));
    }

    #[test]
    fn ensure_fails_closed_when_executable_missing() {
        let dir = std::env::temp_dir().join(format!("lico-oc-serve-missing-{}", unix_seconds()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let previous = paths::set_portable_data_dir_override(Some(dir.clone()));
        clear_test_runner();
        let result = ensure(&json!({
            "executable": dir.join("missing-opencode-binary").to_string_lossy(),
            "port": 24210,
            "healthTimeoutMs": 100
        }))
        .unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["errorCode"], "opencode_executable_missing");
        assert_eq!(result["status"], "unavailable");
        paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn ensure_persists_port_conflict_when_preferred_is_reserved() {
        let dir = std::env::temp_dir().join(format!("lico-oc-serve-conflict-{}", unix_seconds()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let previous = paths::set_portable_data_dir_override(Some(dir.clone()));
        install_test_runner(Box::new(FakeRunner {
            next_pid: AtomicU32::new(4242),
            fail: false,
        }));
        let fake_bin = dir.join("fake-opencode");
        fs::write(&fake_bin, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_bin).unwrap().permissions();
            permissions.set_mode(0o700);
            fs::set_permissions(&fake_bin, permissions).unwrap();
        }
        // Fake runner never opens a listener, so health fails closed after timeout.
        let result = ensure(&json!({
            "executable": fake_bin.to_string_lossy(),
            "port": 8080,
            "healthTimeoutMs": 200
        }))
        .unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["errorCode"], "opencode_serve_health_failed");
        assert_eq!(result["portConflict"], true);
        assert_ne!(result["port"], 8080);
        clear_test_runner();
        paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(dir);
    }
}
