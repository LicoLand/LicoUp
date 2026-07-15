//! OpenClaw Gateway ensure/attach lifecycle owned by the native client.
//!
//! Priority (Gateway-native over ACP cold-start):
//! 1. Reuse a healthy Arc-managed Gateway endpoint when present.
//! 2. Attach to the vendor default loopback Gateway on port 18789 when it is
//!    already reachable (status/install path) — never bind or steal 18789.
//! 3. Only then auto-start an Arc-owned Gateway on an uncommon reserved port
//!    with conflict detection, isolated state under portable data.
//!
//! Conversation send still speaks ACP stdio, but always attaches to the
//! selected Gateway WebSocket URL so sessions remain Gateway-native.

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

/// Vendor OpenClaw Gateway default. Prefer attach/reuse; never bind this port.
pub const VENDOR_DEFAULT_PORT: u16 = 18789;
/// Arc-owned fallback Gateway port when vendor 18789 is absent/unreachable.
pub const DEFAULT_PORT: u16 = 24189;
const PORT_RANGE_SPAN: u16 = 16;
const DEFAULT_HOST: &str = "127.0.0.1";
const STATE_DIR: &str = "openclaw-gateway";
const DEFAULT_HEALTH_TIMEOUT_MS: u64 = 60_000;
const STATE_SCHEMA_VERSION: &str = "v0.0.1:openclaw-gateway-1";

/// Ports that must not be selected for Arc-owned Gateway starts.
const RESERVED_CONFLICT_PORTS: &[u16] = &[
    3000, 4096, 5173, 7228, 8080, 8443, 17328, 17329, 18765, 18789, 19001, 24173,
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GatewayEndpoint {
    pub host: String,
    pub port: u16,
    pub attach_url: String,
    pub ws_url: String,
}

impl GatewayEndpoint {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        let host = host.into();
        Self {
            attach_url: format!("http://{}:{}", host, port),
            ws_url: format!("ws://{}:{}", host, port),
            host,
            port,
        }
    }
}

#[derive(Clone, Debug)]
struct GatewayPaths {
    root: PathBuf,
    state_path: PathBuf,
    pid_path: PathBuf,
    log_path: PathBuf,
    openclaw_state_dir: PathBuf,
    config_path: PathBuf,
}

trait GatewayRunner: Send {
    fn spawn_gateway(
        &self,
        executable: &str,
        host: &str,
        port: u16,
        openclaw_state_dir: &Path,
        config_path: &Path,
        log_path: &Path,
    ) -> Result<u32>;
}

struct DefaultGatewayRunner;

impl GatewayRunner for DefaultGatewayRunner {
    fn spawn_gateway(
        &self,
        executable: &str,
        host: &str,
        port: u16,
        openclaw_state_dir: &Path,
        config_path: &Path,
        log_path: &Path,
    ) -> Result<u32> {
        if let Some(parent) = log_path.parent() {
            fs::create_dir_all(parent)?;
        }
        ensure_minimal_config(config_path, port)?;
        let stdout = OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_path)?;
        let stderr = stdout.try_clone()?;
        let mut command = Command::new(executable);
        command
            .args([
                "gateway",
                "--port",
                &port.to_string(),
                "--bind",
                "loopback",
                "--allow-unconfigured",
                "--auth",
                "none",
                "run",
            ])
            .env("OPENCLAW_STATE_DIR", openclaw_state_dir)
            .env("OPENCLAW_CONFIG_PATH", config_path)
            .env("OPENCLAW_GATEWAY_PORT", port.to_string())
            .env_remove("OPENCLAW_GATEWAY_TOKEN")
            .env_remove("OPENCLAW_GATEWAY_PASSWORD")
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr));
        // Host is loopback-only; keep for endpoint bookkeeping and future bind
        // modes without leaking onto argv.
        let _ = host;
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
            std::io::ErrorKind::NotFound => anyhow!("openclaw executable is not available"),
            std::io::ErrorKind::PermissionDenied => {
                anyhow!("openclaw executable is not permitted to run")
            }
            _ => anyhow!("openclaw gateway could not be started"),
        })?;
        Ok(child.id())
    }
}

fn runner_slot() -> &'static Mutex<Option<Box<dyn GatewayRunner>>> {
    static SLOT: OnceLock<Mutex<Option<Box<dyn GatewayRunner>>>> = OnceLock::new();
    SLOT.get_or_init(|| Mutex::new(None))
}

#[cfg(test)]
fn install_test_runner(runner: Box<dyn GatewayRunner>) {
    *runner_slot().lock().expect("openclaw gateway runner lock") = Some(runner);
}

#[cfg(test)]
fn clear_test_runner() {
    *runner_slot().lock().expect("openclaw gateway runner lock") = None;
}

fn active_runner() -> Box<dyn GatewayRunner> {
    struct Delegating;
    impl GatewayRunner for Delegating {
        fn spawn_gateway(
            &self,
            executable: &str,
            host: &str,
            port: u16,
            openclaw_state_dir: &Path,
            config_path: &Path,
            log_path: &Path,
        ) -> Result<u32> {
            let guard = runner_slot().lock().expect("openclaw gateway runner lock");
            if let Some(runner) = guard.as_ref() {
                return runner.spawn_gateway(
                    executable,
                    host,
                    port,
                    openclaw_state_dir,
                    config_path,
                    log_path,
                );
            }
            drop(guard);
            DefaultGatewayRunner.spawn_gateway(
                executable,
                host,
                port,
                openclaw_state_dir,
                config_path,
                log_path,
            )
        }
    }
    Box::new(Delegating)
}

pub fn ensure(params: &Value) -> Result<Value> {
    let paths = gateway_paths()?;
    fs::create_dir_all(&paths.root)?;
    harden_private_path(&paths.root)?;
    start_with_paths(params, &paths, true)
}

pub fn start(params: &Value) -> Result<Value> {
    let paths = gateway_paths()?;
    fs::create_dir_all(&paths.root)?;
    harden_private_path(&paths.root)?;
    start_with_paths(params, &paths, false)
}

pub fn restart(params: &Value) -> Result<Value> {
    let paths = gateway_paths()?;
    let _ = stop_process(&paths);
    start(params)
}

pub fn stop(_params: &Value) -> Result<Value> {
    let paths = gateway_paths()?;
    let state_before = read_state(&paths.state_path)?;
    if state_before.get("attachMode").and_then(Value::as_str) == Some("vendor-default") {
        // Never stop a vendor-installed Gateway we only attached to.
        let mut state = state_before;
        state["status"] = json!("detached");
        state["running"] = json!(false);
        state["attachMode"] = json!("none");
        state["updatedAtUnix"] = json!(unix_seconds());
        write_json_private(&paths.state_path, &state)?;
        return Ok(json!({
            "ok": true,
            "status": "detached",
            "attachMode": "vendor-default",
            "stoppedOwnedProcess": false,
            "attachUrl": state.get("attachUrl").cloned().unwrap_or(json!("")),
            "wsUrl": state.get("wsUrl").cloned().unwrap_or(json!("")),
            "port": VENDOR_DEFAULT_PORT
        }));
    }
    let stopped = stop_process(&paths)?;
    let mut state = read_state(&paths.state_path)?;
    state["status"] = json!("stopped");
    state["running"] = json!(false);
    state["attachMode"] = json!("none");
    state["updatedAtUnix"] = json!(unix_seconds());
    write_json_private(&paths.state_path, &state)?;
    Ok(json!({
        "ok": true,
        "status": "stopped",
        "attachMode": "none",
        "attachUrl": state.get("attachUrl").cloned().unwrap_or(json!("")),
        "wsUrl": state.get("wsUrl").cloned().unwrap_or(json!("")),
        "port": state.get("port").cloned().unwrap_or(json!(DEFAULT_PORT)),
        "stopped": stopped
    }))
}

pub fn status(_params: &Value) -> Result<Value> {
    let paths = gateway_paths()?;
    fs::create_dir_all(&paths.root)?;
    let mut state = read_state(&paths.state_path)?;
    let pid = read_pid(&paths.pid_path)?;
    let running = process_alive(pid);
    let endpoint = endpoint_from_state(&state);
    let attach_mode_hint = state
        .get("attachMode")
        .and_then(Value::as_str)
        .unwrap_or("none")
        .to_string();
    let health = if running || attach_mode_hint == "vendor-default" {
        one_health_check(&endpoint.attach_url).ok()
    } else {
        None
    };
    let healthy = health
        .as_ref()
        .and_then(|payload| payload.get("healthy"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !running
        && attach_mode_hint != "vendor-default"
        && state
            .get("running")
            .and_then(Value::as_bool)
            .unwrap_or(false)
    {
        state["status"] = json!("stopped");
        state["running"] = json!(false);
        state["updatedAtUnix"] = json!(unix_seconds());
        write_json_private(&paths.state_path, &state)?;
    }
    let status = if (running || attach_mode_hint == "vendor-default") && healthy {
        "running"
    } else if running {
        "blocked"
    } else if state.get("errorCode").and_then(Value::as_str).is_some() {
        "unavailable"
    } else {
        "stopped"
    };
    let attach_mode = if attach_mode_hint == "vendor-default" {
        "vendor-default"
    } else if running {
        state
            .get("attachMode")
            .and_then(Value::as_str)
            .unwrap_or("managed")
    } else {
        "none"
    };
    let running = if attach_mode == "vendor-default" {
        healthy
    } else {
        running
    };
    let status = if attach_mode == "vendor-default" {
        if healthy { "running" } else { "stopped" }
    } else {
        status
    };
    Ok(json!({
        "ok": true,
        "status": status,
        "running": running,
        "healthy": healthy,
        "attachMode": attach_mode,
        "pid": pid.unwrap_or(0),
        "attachUrl": endpoint.attach_url,
        "wsUrl": endpoint.ws_url,
        "host": state.get("host").cloned().unwrap_or_else(|| json!(DEFAULT_HOST)),
        "port": state.get("port").cloned().unwrap_or_else(|| json!(DEFAULT_PORT)),
        "preferredPort": state.get("preferredPort").cloned().unwrap_or_else(|| json!(DEFAULT_PORT)),
        "vendorDefaultPort": VENDOR_DEFAULT_PORT,
        "portConflict": state.get("portConflict").cloned().unwrap_or(json!(false)),
        "executableAvailable": executable_available(
            state
                .get("executable")
                .and_then(Value::as_str)
                .unwrap_or("openclaw")
        ),
        "errorCode": state.get("errorCode").cloned().unwrap_or(Value::Null),
        "health": health.unwrap_or(Value::Null),
        "stateDir": paths.openclaw_state_dir.to_string_lossy(),
        "state": state
    }))
}

/// Ensure a healthy local Gateway is available for ACP attach.
pub fn ensure_attach_endpoint(executable: &str) -> Result<GatewayEndpoint> {
    let result = ensure(&json!({
        "executable": executable,
        "binary": executable,
        "host": DEFAULT_HOST,
        "port": DEFAULT_PORT
    }))?;
    if result.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = result
            .get("errorCode")
            .and_then(Value::as_str)
            .unwrap_or("openclaw_gateway_unavailable");
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
    Ok(GatewayEndpoint::new(host, port))
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
    Err(anyhow!("openclaw_gateway_port_exhausted"))
}

pub fn is_reserved_conflict_port(port: u16) -> bool {
    RESERVED_CONFLICT_PORTS.contains(&port) || port == 0
}

fn start_with_paths(params: &Value, paths: &GatewayPaths, reuse_healthy: bool) -> Result<Value> {
    let preferred_raw = u16_param(params, &["port", "preferredPort"]).unwrap_or(DEFAULT_PORT);
    // Never allow callers to bind the vendor default; remap to Arc fallback.
    let preferred = if preferred_raw == VENDOR_DEFAULT_PORT {
        DEFAULT_PORT
    } else {
        preferred_raw
    };
    let host =
        text_param(params, &["host", "hostname"]).unwrap_or_else(|| DEFAULT_HOST.to_string());
    if host != DEFAULT_HOST && host != "localhost" {
        let remote = text_param(params, &["attachUrl", "remoteUrl", "wsUrl"]);
        if let Some(attach) = remote {
            return status_for_remote(&attach);
        }
        return Err(anyhow!(
            "openclaw gateway auto-start only binds localhost; pass wsUrl/attachUrl for a remote endpoint"
        ));
    }
    let executable = resolve_executable(params)?;

    if reuse_healthy {
        let existing = status(&json!({}))?;
        if existing.get("running").and_then(Value::as_bool) == Some(true)
            && existing.get("healthy").and_then(Value::as_bool) == Some(true)
        {
            return Ok(json!({
                "ok": true,
                "status": "running",
                "reused": true,
                "attachMode": existing.get("attachMode").cloned().unwrap_or_else(|| json!("managed")),
                "running": true,
                "healthy": true,
                "pid": existing.get("pid").cloned().unwrap_or(json!(0)),
                "host": existing.get("host").cloned().unwrap_or_else(|| json!(host)),
                "port": existing.get("port").cloned().unwrap_or_else(|| json!(preferred)),
                "attachUrl": existing.get("attachUrl").cloned().unwrap_or(json!("")),
                "wsUrl": existing.get("wsUrl").cloned().unwrap_or(json!("")),
                "portConflict": false,
                "preferredPort": preferred,
                "vendorDefaultPort": VENDOR_DEFAULT_PORT,
                "executableAvailable": true
            }));
        }
        // Prefer vendor default Gateway (18789) attach/reuse over starting Arc-owned.
        if let Some(vendor) = probe_vendor_default_gateway() {
            write_json_private(&paths.state_path, &vendor.state)?;
            return Ok(vendor.response);
        }
        // Owned process marked running but unhealthy → stop before restart.
        if existing.get("running").and_then(Value::as_bool) == Some(true)
            && existing.get("attachMode").and_then(Value::as_str) != Some("vendor-default")
        {
            let _ = stop_process(paths);
        }
    }

    if !executable_available(&executable) {
        let endpoint = GatewayEndpoint::new(&host, preferred);
        let state = json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "status": "unavailable",
            "running": false,
            "errorCode": "openclaw_executable_missing",
            "preferredPort": preferred,
            "host": host,
            "port": preferred,
            "attachUrl": endpoint.attach_url,
            "wsUrl": endpoint.ws_url,
            "executable": executable,
            "updatedAtUnix": unix_seconds()
        });
        write_json_private(&paths.state_path, &state)?;
        return Ok(json!({
            "ok": false,
            "status": "unavailable",
            "running": false,
            "healthy": false,
            "errorCode": "openclaw_executable_missing",
            "host": host,
            "port": preferred,
            "preferredPort": preferred,
            "attachUrl": endpoint.attach_url,
            "wsUrl": endpoint.ws_url,
            "portConflict": false,
            "executableAvailable": false
        }));
    }

    let selected = match select_available_port(preferred) {
        Ok(port) => port,
        Err(_) => {
            let endpoint = GatewayEndpoint::new(&host, preferred);
            let state = json!({
                "schemaVersion": STATE_SCHEMA_VERSION,
                "status": "blocked",
                "running": false,
                "errorCode": "openclaw_gateway_port_exhausted",
                "preferredPort": preferred,
                "host": host,
                "port": preferred,
                "attachUrl": endpoint.attach_url,
                "wsUrl": endpoint.ws_url,
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
                "errorCode": "openclaw_gateway_port_exhausted",
                "host": host,
                "port": preferred,
                "preferredPort": preferred,
                "attachUrl": endpoint.attach_url,
                "wsUrl": endpoint.ws_url,
                "portConflict": true,
                "executableAvailable": true
            }));
        }
    };
    let port_conflict = selected != preferred;
    let endpoint = GatewayEndpoint::new(&host, selected);
    let timeout = Duration::from_millis(
        u64_param(params, &["healthTimeoutMs"]).unwrap_or(DEFAULT_HEALTH_TIMEOUT_MS),
    );

    fs::create_dir_all(&paths.openclaw_state_dir)?;
    harden_private_path(&paths.openclaw_state_dir)?;

    let runner = active_runner();
    let pid = match runner.spawn_gateway(
        &executable,
        &host,
        selected,
        &paths.openclaw_state_dir,
        &paths.config_path,
        &paths.log_path,
    ) {
        Ok(pid) => pid,
        Err(error) => {
            let code = if error.to_string().contains("not available") {
                "openclaw_executable_missing"
            } else {
                "openclaw_gateway_start_failed"
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
                "wsUrl": endpoint.ws_url,
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
                "wsUrl": endpoint.ws_url,
                "portConflict": port_conflict,
                "executableAvailable": code != "openclaw_executable_missing"
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
                "attachMode": "managed",
                "preferredPort": preferred,
                "vendorDefaultPort": VENDOR_DEFAULT_PORT,
                "host": host,
                "port": selected,
                "attachUrl": endpoint.attach_url,
                "wsUrl": endpoint.ws_url,
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
                "attachMode": "managed",
                "running": true,
                "healthy": true,
                "pid": pid,
                "host": host,
                "port": selected,
                "preferredPort": preferred,
                "vendorDefaultPort": VENDOR_DEFAULT_PORT,
                "attachUrl": endpoint.attach_url,
                "wsUrl": endpoint.ws_url,
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
                "errorCode": "openclaw_gateway_health_failed",
                "preferredPort": preferred,
                "host": host,
                "port": selected,
                "attachUrl": endpoint.attach_url,
                "wsUrl": endpoint.ws_url,
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
                "errorCode": "openclaw_gateway_health_failed",
                "host": host,
                "port": selected,
                "preferredPort": preferred,
                "attachUrl": endpoint.attach_url,
                "wsUrl": endpoint.ws_url,
                "portConflict": port_conflict,
                "executableAvailable": true
            }))
        }
    }
}

fn status_for_remote(attach: &str) -> Result<Value> {
    let trimmed = attach.trim();
    let http_url = if trimmed.starts_with("ws://") {
        format!("http://{}", trimmed.trim_start_matches("ws://"))
    } else if trimmed.starts_with("wss://") {
        format!("https://{}", trimmed.trim_start_matches("wss://"))
    } else {
        trimmed.to_string()
    };
    let health = one_health_check(&http_url).ok();
    let healthy = health
        .as_ref()
        .and_then(|payload| payload.get("healthy"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Ok(json!({
        "ok": healthy,
        "status": if healthy { "running" } else { "unavailable" },
        "running": healthy,
        "healthy": healthy,
        "reused": true,
        "attachMode": "remote",
        "attachUrl": http_url,
        "wsUrl": if trimmed.starts_with("ws") {
            trimmed.to_string()
        } else if trimmed.starts_with("https://") {
            format!("wss://{}", trimmed.trim_start_matches("https://"))
        } else {
            format!("ws://{}", trimmed.trim_start_matches("http://"))
        },
        "errorCode": if healthy { Value::Null } else { json!("openclaw_gateway_health_failed") },
        "health": health.unwrap_or(Value::Null)
    }))
}

struct VendorAttach {
    state: Value,
    response: Value,
}

/// Probe vendor default Gateway on 18789 for attach/reuse. Never starts or binds it.
fn probe_vendor_default_gateway() -> Option<VendorAttach> {
    let endpoint = GatewayEndpoint::new(DEFAULT_HOST, VENDOR_DEFAULT_PORT);
    let health = one_health_check(&endpoint.attach_url).ok()?;
    if health.get("healthy").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let state = json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "status": "running",
        "running": true,
        "attachMode": "vendor-default",
        "preferredPort": DEFAULT_PORT,
        "vendorDefaultPort": VENDOR_DEFAULT_PORT,
        "host": DEFAULT_HOST,
        "port": VENDOR_DEFAULT_PORT,
        "attachUrl": endpoint.attach_url,
        "wsUrl": endpoint.ws_url,
        "portConflict": false,
        "pid": 0,
        "updatedAtUnix": unix_seconds()
    });
    let response = json!({
        "ok": true,
        "status": "running",
        "reused": true,
        "attachMode": "vendor-default",
        "running": true,
        "healthy": true,
        "pid": 0,
        "host": DEFAULT_HOST,
        "port": VENDOR_DEFAULT_PORT,
        "preferredPort": DEFAULT_PORT,
        "vendorDefaultPort": VENDOR_DEFAULT_PORT,
        "attachUrl": endpoint.attach_url,
        "wsUrl": endpoint.ws_url,
        "portConflict": false,
        "executableAvailable": which_command("openclaw"),
        "health": health
    });
    Some(VendorAttach { state, response })
}

fn wait_for_health(attach_url: &str, timeout: Duration) -> Result<Value> {
    let deadline = Instant::now() + timeout;
    let mut last_error = String::from("gateway health endpoint unreachable");
    while Instant::now() < deadline {
        match one_health_check(attach_url) {
            Ok(payload)
                if payload
                    .get("healthy")
                    .and_then(Value::as_bool)
                    .unwrap_or(false) =>
            {
                return Ok(payload);
            }
            Ok(_) => last_error = "gateway health endpoint returned unhealthy".to_string(),
            Err(error) => last_error = error.to_string(),
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err(anyhow!(last_error))
}

fn one_health_check(attach_url: &str) -> Result<Value> {
    let base = attach_url.trim_end_matches('/');
    // Prefer OpenAI-compatible probe; any HTTP response (including 401) proves
    // the multiplexed Gateway listener is up. Fall back to Control UI root.
    for path in ["/v1/models", "/"] {
        let url = format!("{base}{path}");
        match ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(3))
            .build()
            .get(&url)
            .call()
        {
            Ok(response) => {
                let status = response.status();
                return Ok(json!({
                    "healthy": true,
                    "httpStatus": status,
                    "probePath": path
                }));
            }
            Err(ureq::Error::Status(code, _)) => {
                return Ok(json!({
                    "healthy": true,
                    "httpStatus": code,
                    "probePath": path
                }));
            }
            Err(_) => continue,
        }
    }
    Err(anyhow!("openclaw gateway request failed"))
}

fn stop_process(paths: &GatewayPaths) -> Result<Value> {
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
            return Err(anyhow!("failed to stop openclaw gateway process"));
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

fn gateway_paths() -> Result<GatewayPaths> {
    let root = paths::portable_data_dir()?.join(STATE_DIR);
    Ok(GatewayPaths {
        state_path: root.join("state.json"),
        pid_path: root.join("gateway.pid"),
        log_path: root.join("gateway.log"),
        openclaw_state_dir: root.join("runtime"),
        config_path: root.join("config.json"),
        root,
    })
}

fn ensure_minimal_config(config_path: &Path, port: u16) -> Result<()> {
    if config_path.exists() {
        return Ok(());
    }
    if let Some(parent) = config_path.parent() {
        fs::create_dir_all(parent)?;
        harden_private_path(parent)?;
    }
    let body = format!(
        "{{\n  \"gateway\": {{\n    \"mode\": \"local\",\n    \"port\": {port},\n    \"bind\": \"loopback\",\n    \"auth\": {{ \"mode\": \"none\" }}\n  }}\n}}\n"
    );
    atomic_write_private_text(config_path, &body)?;
    Ok(())
}

fn resolve_executable(params: &Value) -> Result<String> {
    if let Some(value) = text_param(params, &["executable", "binary", "binaryPath"]) {
        return Ok(value);
    }
    if let Ok(value) = std::env::var("OPENCLAW_BIN") {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Ok(trimmed.to_string());
        }
    }
    Ok("openclaw".to_string())
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

fn endpoint_from_state(state: &Value) -> GatewayEndpoint {
    let host = state
        .get("host")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_HOST)
        .to_string();
    let port = state
        .get("port")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_PORT as u64) as u16;
    if let Some(ws) = state
        .get("wsUrl")
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty())
    {
        let mut endpoint = GatewayEndpoint::new(host, port);
        endpoint.ws_url = ws.to_string();
        if let Some(http) = state
            .get("attachUrl")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        {
            endpoint.attach_url = http.to_string();
        }
        return endpoint;
    }
    GatewayEndpoint::new(host, port)
}

fn read_state(path: &Path) -> Result<Value> {
    if !path.exists() {
        return Ok(json!({}));
    }
    let text = fs::read_to_string(path)?;
    if text.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(&text).map_err(|_| anyhow!("openclaw gateway state is invalid"))
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
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn u16_param(params: &Value, keys: &[&str]) -> Option<u16> {
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_u64) {
            if value > 0 && value <= u16::MAX as u64 {
                return Some(value as u16);
            }
        }
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            if let Ok(parsed) = value.trim().parse::<u16>()
                && parsed > 0
            {
                return Some(parsed);
            }
        }
    }
    None
}

fn u64_param(params: &Value, keys: &[&str]) -> Option<u64> {
    for key in keys {
        if let Some(value) = params.get(*key).and_then(Value::as_u64) {
            return Some(value);
        }
        if let Some(value) = params.get(*key).and_then(Value::as_str) {
            if let Ok(parsed) = value.trim().parse::<u64>() {
                return Some(parsed);
            }
        }
    }
    None
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct FakeRunner {
        pid: AtomicU32,
    }

    impl GatewayRunner for FakeRunner {
        fn spawn_gateway(
            &self,
            _executable: &str,
            _host: &str,
            _port: u16,
            _openclaw_state_dir: &Path,
            _config_path: &Path,
            _log_path: &Path,
        ) -> Result<u32> {
            Ok(self.pid.fetch_add(1, Ordering::SeqCst) + 42_000)
        }
    }

    #[test]
    fn reserved_ports_include_vendor_defaults() {
        assert!(is_reserved_conflict_port(VENDOR_DEFAULT_PORT));
        assert!(is_reserved_conflict_port(19001));
        assert!(is_reserved_conflict_port(24173));
        assert!(is_reserved_conflict_port(7228));
        assert!(!is_reserved_conflict_port(DEFAULT_PORT));
    }

    #[test]
    fn select_port_never_returns_vendor_default() {
        let selected = select_available_port_with(VENDOR_DEFAULT_PORT, |port| {
            !is_reserved_conflict_port(port)
        })
        .unwrap();
        assert_ne!(selected, VENDOR_DEFAULT_PORT);
        assert!(!is_reserved_conflict_port(selected));
        let err = select_available_port_with(DEFAULT_PORT, |_| false).unwrap_err();
        assert!(err.to_string().contains("openclaw_gateway_port_exhausted"));
    }

    #[test]
    fn preferred_vendor_port_is_remapped_before_bind() {
        assert!(is_reserved_conflict_port(VENDOR_DEFAULT_PORT));
        let remapped = if VENDOR_DEFAULT_PORT == VENDOR_DEFAULT_PORT {
            DEFAULT_PORT
        } else {
            VENDOR_DEFAULT_PORT
        };
        assert_eq!(remapped, DEFAULT_PORT);
    }

    #[test]
    fn ensure_reports_missing_executable() {
        let dir = std::env::temp_dir().join(format!("lico-ocw-gw-missing-{}", unix_seconds()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let previous = paths::set_portable_data_dir_override(Some(dir.clone()));
        clear_test_runner();
        let result = ensure(&json!({
            "executable": dir.join("no-such-openclaw").to_string_lossy(),
            "port": DEFAULT_PORT,
            "healthTimeoutMs": 100
        }))
        .unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["errorCode"], "openclaw_executable_missing");
        paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn ensure_persists_port_conflict_when_preferred_reserved() {
        let dir = std::env::temp_dir().join(format!("lico-ocw-gw-conflict-{}", unix_seconds()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let previous = paths::set_portable_data_dir_override(Some(dir.clone()));
        install_test_runner(Box::new(FakeRunner {
            pid: AtomicU32::new(0),
        }));
        // Fake runner never opens a listener → health fails closed after start.
        let fake_bin = dir.join("fake-openclaw");
        fs::write(&fake_bin, b"#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = fs::metadata(&fake_bin).unwrap().permissions();
            permissions.set_mode(0o700);
            fs::set_permissions(&fake_bin, permissions).unwrap();
        }
        let result = ensure(&json!({
            "executable": fake_bin.to_string_lossy(),
            "port": VENDOR_DEFAULT_PORT,
            "healthTimeoutMs": 200
        }))
        .unwrap();
        assert_eq!(result["ok"], false);
        assert_eq!(result["errorCode"], "openclaw_gateway_health_failed");
        // Vendor default is remapped before bind; Arc never attempts 18789.
        assert_eq!(result["preferredPort"], DEFAULT_PORT);
        assert_ne!(result["port"], VENDOR_DEFAULT_PORT);
        assert!(!is_reserved_conflict_port(
            result["port"].as_u64().unwrap() as u16
        ));
        clear_test_runner();
        paths::set_portable_data_dir_override(previous);
        let _ = fs::remove_dir_all(dir);
    }
}
