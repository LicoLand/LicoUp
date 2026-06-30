use crate::client_state::{ActivityLog, ClientStateStore};
use crate::file_security::{atomic_write_private_text, harden_private_path};
use crate::process_identity;
use anyhow::{Result, anyhow};
use base64::{Engine as _, engine::general_purpose};
use rand::RngCore;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::env;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use std::os::windows::process::CommandExt as WindowsCommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const STATE_SCHEMA_VERSION: &str = "v0.0.1:schema:definition-1";
const LOCAL_RUNTIME_DIR: &str = "local-runtime";
const DEFAULT_PORT: u16 = 17328;
const HEALTH_PATH: &str = "/api/healthz";
const MAX_PORT_PROBE_OFFSET: u16 = 10;
const DEFAULT_HEALTH_TIMEOUT_MS: u64 = 30_000;
const CLIENT_RUNTIME_ENTRY: &str = "runtime/start-client-runtime.mjs";
const CLIENT_RUNTIME_BUILD_SCRIPT: &str = "tools/client-runtime/build-client-runtime-package.mjs";
const CLIENT_RUNTIME_BUILD_OUTPUT: &str = "build/client-runtime/client-local-runtime";
const RUNTIME_PLAN_PATH: &str = "runtime-plan/runtime-plan.json";

#[derive(Clone, Debug)]
struct RuntimePaths {
    root: PathBuf,
    install_dir: PathBuf,
    install_source_dir: PathBuf,
    data_dir: PathBuf,
    logs_dir: PathBuf,
    bootstrap_dir: PathBuf,
    runtime_config_path: PathBuf,
    state_path: PathBuf,
    pid_path: PathBuf,
    log_path: PathBuf,
    claim_token_path: PathBuf,
}

#[derive(Clone, Debug)]
struct HealthCheck {
    url: String,
    port: u16,
    payload: Value,
}

pub fn ensure(params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    fs::create_dir_all(&paths.root)?;
    let rebuild = bool_param(params, &["rebuild"]).unwrap_or(false);
    if rebuild && process_alive(read_pid(&paths.pid_path)?) {
        stop_process(&paths)?;
    }
    let install = ensure_installed(params, rebuild)?;
    let start_result = start_with_paths(params, &paths, true)?;
    Ok(json!({
        "ok": true,
        "status": "ready",
        "install": install,
        "runtime": start_result
    }))
}

pub fn build(params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    if process_alive(read_pid(&paths.pid_path)?) {
        stop_process(&paths)?;
    }
    ensure_installed(params, true)
}

pub fn start(params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    if !paths.install_source_dir.join(CLIENT_RUNTIME_ENTRY).exists() {
        ensure_installed(params, false)?;
    }
    start_with_paths(params, &paths, false)
}

pub fn restart(params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    stop_process(&paths)?;
    start(params)
}

pub fn stop(_params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    let stopped = stop_process(&paths)?;
    let mut state = read_state(&paths.state_path)?;
    state["status"] = json!("stopped");
    state["running"] = json!(false);
    state["updatedAtUnix"] = json!(unix_seconds());
    write_json_private(&paths.state_path, &state)?;
    append_activity(
        "local_runtime.stopped",
        json!({
            "target": "local-runtime",
            "pid": stopped.get("pid").cloned().unwrap_or_else(|| json!(0))
        }),
    );
    Ok(json!({
        "ok": true,
        "status": "stopped",
        "dataRoot": display_path(&paths.root),
        "stopped": stopped
    }))
}

pub fn status(_params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    fs::create_dir_all(&paths.root)?;
    let mut state = read_state(&paths.state_path)?;
    let pid = read_pid(&paths.pid_path)?;
    let running = process_alive(pid);
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
    }
    let server_url = state
        .get("serverUrl")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| format!("http://127.0.0.1:{}", DEFAULT_PORT));
    let health = if running {
        one_health_check(&server_url).ok()
    } else {
        None
    };
    let identity = process_identity::status(&json!({ "serverUrl": server_url })).ok();
    let runtime_modules = read_runtime_modules(&paths);
    Ok(json!({
        "ok": true,
        "status": if running { "running" } else { "stopped" },
        "running": running,
        "pid": pid.unwrap_or(0),
        "serverUrl": state.get("serverUrl").cloned().unwrap_or_else(|| json!("")),
        "port": state.get("port").cloned().unwrap_or_else(|| json!(DEFAULT_PORT)),
        "dataRoot": display_path(&paths.root),
        "installSourceDir": display_path(&paths.install_source_dir),
        "runtimeConfigPath": display_path(&paths.runtime_config_path),
        "logPath": display_path(&paths.log_path),
        "health": health.map(|item| item.payload).unwrap_or_else(|| json!(null)),
        "identity": identity.unwrap_or_else(|| json!(null)),
        "runtimeModules": runtime_modules,
        "state": state
    }))
}

pub fn logs(params: &Value) -> Result<Value> {
    let paths = runtime_paths()?;
    let tail = number_param(params, &["tail", "limit"])
        .unwrap_or(200)
        .max(1) as usize;
    let lines = tail_lines(&paths.log_path, tail)?;
    Ok(json!({
        "ok": true,
        "status": "ok",
        "logPath": display_path(&paths.log_path),
        "tail": tail,
        "lines": lines
    }))
}

fn ensure_installed(params: &Value, force_rebuild: bool) -> Result<Value> {
    let paths = runtime_paths()?;
    let already_installed = paths.install_source_dir.join(CLIENT_RUNTIME_ENTRY).exists();
    if already_installed && !force_rebuild {
        return Ok(json!({
            "ok": true,
            "status": "installed",
            "changed": false,
            "installSourceDir": display_path(&paths.install_source_dir)
        }));
    }

    let runtime_source = resolve_client_runtime_source(params, force_rebuild)?;
    if !runtime_source.path.join(CLIENT_RUNTIME_ENTRY).exists() {
        return Err(anyhow!(
            "client-local-runtime entry is missing at {}",
            runtime_source.path.join(CLIENT_RUNTIME_ENTRY).display()
        ));
    }
    install_source_runtime(&runtime_source.path, &paths)?;
    let mut state = read_state(&paths.state_path)?;
    state["schemaVersion"] = json!(STATE_SCHEMA_VERSION);
    state["runtimeKind"] = json!("client-local");
    state["runtimeSourceKind"] = json!(runtime_source.kind);
    state["runtimePackageRoot"] = json!(display_path(&runtime_source.package_root));
    state["runtimeSourceRoot"] = json!(display_path(&runtime_source.path));
    state["installSourceDir"] = json!(display_path(&paths.install_source_dir));
    state["updatedAtUnix"] = json!(unix_seconds());
    write_json_private(&paths.state_path, &state)?;
    append_activity(
        "local_runtime.installed",
        json!({
            "target": "local-runtime",
            "runtimeSourceKind": runtime_source.kind,
            "installSourceDir": display_path(&paths.install_source_dir)
        }),
    );
    Ok(json!({
        "ok": true,
        "status": "installed",
        "changed": true,
        "runtimeSourceKind": runtime_source.kind,
        "runtimePackageRoot": display_path(&runtime_source.package_root),
        "runtimeSourceRoot": display_path(&runtime_source.path),
        "installSourceDir": display_path(&paths.install_source_dir)
    }))
}

fn start_with_paths(params: &Value, paths: &RuntimePaths, allow_claim: bool) -> Result<Value> {
    fs::create_dir_all(&paths.root)?;
    fs::create_dir_all(&paths.data_dir)?;
    fs::create_dir_all(&paths.logs_dir)?;
    fs::create_dir_all(&paths.bootstrap_dir)?;

    let host = text_param(params, &["host"]).unwrap_or_else(|| "127.0.0.1".to_string());
    if !is_loopback_host(&host) {
        return Err(anyhow!("client local runtime must listen on loopback host"));
    }
    let port = port_param(params)?.unwrap_or_else(|| state_port(paths).unwrap_or(DEFAULT_PORT));
    let server_url = format!("http://{}:{}", host, port);
    let runtime_config = write_runtime_config(paths, &host, port, &server_url)?;
    let mut identity_status = process_identity::status(&json!({ "serverUrl": server_url })).ok();
    let mut needs_claim = identity_status.is_none() && allow_claim;

    let pid = read_pid(&paths.pid_path)?;
    if process_alive(pid) {
        let health = wait_for_health(&host, port, Duration::from_secs(2))?;
        if needs_claim {
            stop_process(paths)?;
        } else {
            update_running_state(paths, &server_url, port, pid.unwrap_or(0), &health, false)?;
            let runtime_modules = read_runtime_modules(paths);
            return Ok(json!({
                "ok": true,
                "status": "running",
                "changed": false,
                "pid": pid.unwrap_or(0),
                "serverUrl": health.url,
                "runtimeConfigPath": display_path(&runtime_config),
                "logPath": display_path(&paths.log_path),
                "health": health.payload,
                "identity": identity_status.unwrap_or_else(|| json!(null)),
                "runtimeModules": runtime_modules
            }));
        }
    }

    let claim_token = if needs_claim {
        Some(write_claim_token(&paths.claim_token_path)?)
    } else {
        None
    };
    let pid = spawn_server(paths, &runtime_config, claim_token.as_ref())?;
    let health = wait_for_health(&host, port, health_timeout(params))?;
    if health.url != server_url {
        return Err(anyhow!(
            "local runtime started on {}, expected {}; strict port binding failed",
            health.url,
            server_url
        ));
    }

    let mut claim_result = Value::Null;
    if needs_claim {
        let ids = ensure_identity_ids(paths)?;
        let default_hash = default_identity_hash(params, paths);
        match process_identity::bootstrap_claim(&json!({
            "serverUrl": health.url,
            "claimTokenFile": display_path(&paths.claim_token_path),
            "defaultIdentityHash": default_hash,
            "clientId": ids.0,
            "installationId": ids.1,
            "runtimeInstanceId": ids.2
        })) {
            Ok(result) => {
                claim_result = result.clone();
                if result.get("ok").and_then(Value::as_bool) != Some(true) {
                    let _ = fs::remove_file(&paths.claim_token_path);
                    return Err(anyhow!("process identity claim failed: {}", result));
                }
                identity_status =
                    process_identity::status(&json!({ "serverUrl": health.url })).ok();
            }
            Err(error) => {
                let _ = fs::remove_file(&paths.claim_token_path);
                return Err(error.context("process identity claim failed"));
            }
        }
        needs_claim = false;
    }

    update_running_state(
        paths,
        &health.url,
        port,
        pid,
        &health,
        claim_result != Value::Null,
    )?;
    append_activity(
        "local_runtime.started",
        json!({
            "target": "local-runtime",
            "serverUrl": health.url,
            "pid": pid,
            "claimed": claim_result != Value::Null
        }),
    );
    let runtime_modules = read_runtime_modules(paths);
    Ok(json!({
        "ok": true,
        "status": "running",
        "changed": true,
        "pid": pid,
        "serverUrl": health.url,
        "runtimeConfigPath": display_path(&runtime_config),
        "logPath": display_path(&paths.log_path),
        "health": health.payload,
        "claimed": claim_result != Value::Null,
        "claim": if claim_result != Value::Null { claim_result } else { json!(null) },
        "identity": identity_status.unwrap_or_else(|| json!(null)),
        "needsClaim": needs_claim,
        "runtimeModules": runtime_modules
    }))
}

fn runtime_paths() -> Result<RuntimePaths> {
    let store = ClientStateStore::portable()?;
    let root = store.root().join(LOCAL_RUNTIME_DIR);
    Ok(RuntimePaths {
        install_dir: root.join("runtime"),
        install_source_dir: root.join("runtime").join("source"),
        data_dir: root.join("data"),
        logs_dir: root.join("logs"),
        bootstrap_dir: root.join("bootstrap"),
        runtime_config_path: root.join("runtime-instance.json"),
        state_path: root.join("state.json"),
        pid_path: root.join("runtime.pid"),
        log_path: root.join("logs").join("runtime.log"),
        claim_token_path: root.join("bootstrap").join("claim-token"),
        root,
    })
}

#[derive(Clone, Debug)]
struct ClientRuntimeSource {
    kind: &'static str,
    package_root: PathBuf,
    path: PathBuf,
}

fn resolve_client_runtime_source(
    params: &Value,
    force_rebuild: bool,
) -> Result<ClientRuntimeSource> {
    if !force_rebuild {
        if let Some(source) = bundled_client_runtime_source_candidate() {
            return Ok(source);
        }
    }

    let repo_root = discover_client_repo_root(env::current_dir()?).ok_or_else(|| {
        anyhow!("client runtime package is not bundled and no Lico-Arc repository root was found")
    })?;
    let package_root = repo_root.join(CLIENT_RUNTIME_BUILD_OUTPUT);
    let source = ClientRuntimeSource {
        kind: "source-build-output",
        package_root: package_root.clone(),
        path: package_root.join("source"),
    };
    if force_rebuild || !source.path.join(CLIENT_RUNTIME_ENTRY).exists() {
        run_client_runtime_package_build(params, &repo_root)?;
    }
    Ok(source)
}

fn run_client_runtime_package_build(params: &Value, repo_root: &Path) -> Result<()> {
    let node = text_param(params, &["nodePath", "node-path"])
        .or_else(|| env::var("LICO_NODE_PATH").ok())
        .unwrap_or_else(|| "node".to_string());
    let status = Command::new(node)
        .arg(CLIENT_RUNTIME_BUILD_SCRIPT)
        .current_dir(repo_root)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(anyhow!(
            "client-local-runtime package build exited with {}",
            status
        ))
    }
}

fn install_source_runtime(generated_source: &Path, paths: &RuntimePaths) -> Result<()> {
    if paths.install_source_dir.exists() {
        fs::remove_dir_all(&paths.install_source_dir)?;
    }
    fs::create_dir_all(&paths.install_dir)?;
    copy_dir_recursive(generated_source, &paths.install_source_dir)?;
    Ok(())
}

fn copy_dir_recursive(source: &Path, destination: &Path) -> Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let Some(name_text) = name.to_str() else {
            continue;
        };
        if matches!(name_text, "node_modules" | ".git" | ".dart_tool") {
            continue;
        }
        let target = destination.join(name);
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            copy_dir_recursive(&path, &target)?;
        } else if file_type.is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&path, &target)?;
        }
    }
    Ok(())
}

fn write_runtime_config(
    paths: &RuntimePaths,
    host: &str,
    port: u16,
    server_url: &str,
) -> Result<PathBuf> {
    let feature_profile = paths
        .install_source_dir
        .join("feature-profile")
        .join("feature-profile.json");
    if !feature_profile.exists() {
        return Err(anyhow!(
            "local runtime feature profile is missing at {}",
            feature_profile.display()
        ));
    }
    let config = json!({
        "schemaVersion": STATE_SCHEMA_VERSION,
        "runtimeKind": "client-local",
        "host": host,
        "port": port,
        "strictPort": true,
        "dataDir": display_path(&paths.data_dir),
        "profile": "minimal",
        "edition": "client-local",
        "featureProfile": display_path(&feature_profile),
        "withUi": false,
        "discovery": {
            "mode": "active",
            "serverId": format!("lico-client-local-runtime-{}", port),
            "serverLabel": "LicoLite Client Local Runtime",
            "configVersion": format!("client-local-runtime-{}", unix_seconds()),
            "bootstrapBaseUrl": server_url,
            "activeServiceUrl": server_url,
            "advertisedBaseUrl": server_url
        }
    });
    write_json_private(&paths.runtime_config_path, &config)?;
    Ok(paths.runtime_config_path.clone())
}

fn spawn_server(
    paths: &RuntimePaths,
    runtime_config: &Path,
    claim_token: Option<&String>,
) -> Result<u32> {
    let node = env::var("LICO_NODE_PATH").unwrap_or_else(|_| "node".to_string());
    let stdout = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&paths.log_path)?;
    let stderr = stdout.try_clone()?;
    write_log_preamble(&paths.log_path, runtime_config)?;
    let mut command = Command::new(node);
    command
        .arg(CLIENT_RUNTIME_ENTRY)
        .arg("--runtime-config")
        .arg(runtime_config)
        .arg("--require-runtime-config")
        .arg("--expected-runtime-kind")
        .arg("client-local")
        .arg("--expected-edition")
        .arg("client-local")
        .current_dir(&paths.install_source_dir)
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .stdin(Stdio::null())
        .env("NODE_ENV", "production");
    if claim_token.is_some() {
        command.env(
            "LICO_PROCESS_IDENTITY_CLAIM_TOKEN_FILE",
            &paths.claim_token_path,
        );
    }
    #[cfg(unix)]
    command.process_group(0);
    #[cfg(windows)]
    command.creation_flags(0x0000_0008 | 0x0000_0200 | 0x0800_0000);
    let child = command.spawn()?;
    let pid = child.id();
    write_text_private(&paths.pid_path, &format!("{}\n", pid))?;
    Ok(pid)
}

fn wait_for_health(host: &str, port: u16, timeout: Duration) -> Result<HealthCheck> {
    let deadline = Instant::now() + timeout;
    let mut last_error = String::new();
    while Instant::now() < deadline {
        for candidate in port..=port.saturating_add(MAX_PORT_PROBE_OFFSET) {
            let url = format!("http://{}:{}{}", host, candidate, HEALTH_PATH);
            match get_json(&url) {
                Ok(payload) => {
                    if payload.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                        return Ok(HealthCheck {
                            url: format!("http://{}:{}", host, candidate),
                            port: candidate,
                            payload,
                        });
                    }
                    last_error = format!("{} returned non-ok health payload", url);
                }
                Err(error) => {
                    last_error = error.to_string();
                }
            }
        }
        thread::sleep(Duration::from_millis(250));
    }
    Err(anyhow!("local runtime health check failed: {}", last_error))
}

fn one_health_check(server_url: &str) -> Result<HealthCheck> {
    let url = format!("{}{}", server_url.trim_end_matches('/'), HEALTH_PATH);
    let payload = get_json(&url)?;
    Ok(HealthCheck {
        url: server_url.trim_end_matches('/').to_string(),
        port: parse_url_port(server_url).unwrap_or(DEFAULT_PORT),
        payload,
    })
}

fn get_json(url: &str) -> Result<Value> {
    let response = ureq::AgentBuilder::new()
        .timeout(Duration::from_millis(750))
        .build()
        .get(url)
        .call()?;
    Ok(response.into_json::<Value>()?)
}

fn stop_process(paths: &RuntimePaths) -> Result<Value> {
    let pid = read_pid(&paths.pid_path)?;
    let mut touched_runtime = false;
    let mut forced = false;
    if let Some(pid) = pid {
        if process_alive(Some(pid)) {
            touched_runtime = true;
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
                return Err(anyhow!("failed to stop local runtime process {}", pid));
            }
        }
    }

    #[cfg(not(windows))]
    let fallback_pids = Vec::<u32>::new();
    #[cfg(windows)]
    let fallback_pids = {
        let fallback_pids = terminate_windows_runtime_processes(paths)?;
        if !fallback_pids.is_empty() {
            touched_runtime = true;
            forced = true;
        }
        fallback_pids
    };

    let _ = fs::remove_file(&paths.pid_path);
    Ok(json!({
        "ok": true,
        "status": if touched_runtime { "stopped" } else { "not-running" },
        "pid": pid.unwrap_or(0),
        "forced": forced,
        "fallbackPids": fallback_pids
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
            Err(anyhow!("kill {} {} exited with {}", signal, pid, status))
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
            Err(anyhow!("taskkill {} exited with {}", pid, status))
        }
    }
}

#[cfg(windows)]
fn terminate_windows_runtime_processes(paths: &RuntimePaths) -> Result<Vec<u32>> {
    let runtime_config = display_path(&paths.runtime_config_path);
    let script = r#"
$RuntimeConfig = $env:LICO_RUNTIME_CONFIG_TO_STOP
if (-not [string]::IsNullOrWhiteSpace($RuntimeConfig)) {
  $needle = 'runtime/start-client-runtime.mjs'
  $matches = Get-CimInstance Win32_Process | Where-Object {
    $_.CommandLine -and
    $_.CommandLine.IndexOf($RuntimeConfig, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
    $_.CommandLine.IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
  }
  foreach ($process in $matches) {
    try {
      Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    } catch {}
    [Console]::Out.WriteLine($process.ProcessId)
  }
}
exit 0
"#;
    let encoded_script = general_purpose::STANDARD.encode(
        script
            .encode_utf16()
            .flat_map(|unit| unit.to_le_bytes())
            .collect::<Vec<_>>(),
    );
    let output = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-EncodedCommand",
            &encoded_script,
        ])
        .env("LICO_RUNTIME_CONFIG_TO_STOP", runtime_config)
        .output()?;
    if !output.status.success() {
        return Err(anyhow!(
            "failed to stop Windows local runtime by runtime config: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect())
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

fn write_claim_token(path: &Path) -> Result<String> {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = general_purpose::URL_SAFE_NO_PAD.encode(bytes);
    write_text_private(path, &format!("{}\n", token))?;
    Ok(token)
}

fn ensure_identity_ids(paths: &RuntimePaths) -> Result<(String, String, String)> {
    let mut state = read_state(&paths.state_path)?;
    let client_id = state
        .get("clientId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("client_{}", Uuid::new_v4()));
    let installation_id = state
        .get("installationId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("install_{}", Uuid::new_v4()));
    let runtime_instance_id = state
        .get("runtimeInstanceId")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("runtime_{}", Uuid::new_v4()));
    state["clientId"] = json!(client_id.clone());
    state["installationId"] = json!(installation_id.clone());
    state["runtimeInstanceId"] = json!(runtime_instance_id.clone());
    state["updatedAtUnix"] = json!(unix_seconds());
    write_json_private(&paths.state_path, &state)?;
    Ok((client_id, installation_id, runtime_instance_id))
}

fn update_running_state(
    paths: &RuntimePaths,
    server_url: &str,
    port: u16,
    pid: u32,
    health: &HealthCheck,
    claimed: bool,
) -> Result<()> {
    let mut state = read_state(&paths.state_path)?;
    state["schemaVersion"] = json!(STATE_SCHEMA_VERSION);
    state["runtimeKind"] = json!("client-local");
    state["status"] = json!("running");
    state["running"] = json!(true);
    state["pid"] = json!(pid);
    state["serverUrl"] = json!(server_url);
    state["port"] = json!(port);
    state["actualPort"] = json!(health.port);
    state["dataRoot"] = json!(display_path(&paths.root));
    state["dataDir"] = json!(display_path(&paths.data_dir));
    state["runtimeConfigPath"] = json!(display_path(&paths.runtime_config_path));
    state["installSourceDir"] = json!(display_path(&paths.install_source_dir));
    state["logPath"] = json!(display_path(&paths.log_path));
    state["lastHealth"] = health.payload.clone();
    if claimed {
        state["processIdentityClaimedAtUnix"] = json!(unix_seconds());
    }
    state["updatedAtUnix"] = json!(unix_seconds());
    write_json_private(&paths.state_path, &state)
}

fn read_state(path: &Path) -> Result<Value> {
    if !path.exists() {
        return Ok(json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "runtimeKind": "client-local"
        }));
    }
    let raw = fs::read_to_string(path)?;
    if raw.trim().is_empty() {
        return Ok(json!({
            "schemaVersion": STATE_SCHEMA_VERSION,
            "runtimeKind": "client-local"
        }));
    }
    Ok(serde_json::from_str(&raw)?)
}

fn read_pid(path: &Path) -> Result<Option<u32>> {
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(path)?;
    Ok(raw.trim().parse::<u32>().ok())
}

fn write_json_private(path: &Path, value: &Value) -> Result<()> {
    write_text_private(path, &format!("{}\n", serde_json::to_string_pretty(value)?))
}

fn write_text_private(path: &Path, content: &str) -> Result<()> {
    atomic_write_private_text(path, content)
}

fn write_log_preamble(log_path: &Path, runtime_config: &Path) -> Result<()> {
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    harden_private_path(log_path)?;
    writeln!(
        file,
        "\n[lico-client] starting local runtime at {} with config {}\n",
        unix_seconds(),
        runtime_config.display()
    )?;
    Ok(())
}

fn discover_client_repo_root(start: PathBuf) -> Option<PathBuf> {
    let mut current = Some(start.as_path());
    while let Some(path) = current {
        if path.join("package.json").exists() && path.join(CLIENT_RUNTIME_BUILD_SCRIPT).exists() {
            return fs::canonicalize(path).ok();
        }
        current = path.parent();
    }
    None
}

fn read_json_file(path: &Path) -> Result<Value> {
    Ok(serde_json::from_str(&fs::read_to_string(path)?)?)
}

fn read_optional_json_file(path: &Path) -> Result<Option<Value>> {
    if !path.exists() {
        return Ok(None);
    }
    Ok(Some(read_json_file(path)?))
}

fn read_runtime_modules(paths: &RuntimePaths) -> Value {
    match read_runtime_modules_result(paths) {
        Ok(value) => value,
        Err(error) => json!({
            "ok": false,
            "status": "unavailable",
            "error": error.to_string()
        }),
    }
}

fn read_runtime_modules_result(paths: &RuntimePaths) -> Result<Value> {
    let candidates = runtime_module_metadata_candidates(paths);
    let mut first_missing = None;
    for candidate in candidates {
        let modules = read_runtime_modules_from_candidate(&candidate)?;
        if modules.get("ok").and_then(Value::as_bool).unwrap_or(false) {
            return Ok(modules);
        }
        if first_missing.is_none() {
            first_missing = Some(modules);
        }
    }
    Ok(first_missing.unwrap_or_else(|| {
        json!({
            "ok": false,
            "status": "missing",
            "source": "unavailable",
            "activeFeatureIds": [],
            "activeFeatures": [],
            "disabledFeatureIds": [],
            "disabledFeatures": [],
            "runtimeModules": [],
            "mounts": [],
            "eventTopics": []
        })
    }))
}

#[derive(Clone, Debug)]
struct RuntimeModuleMetadataCandidate {
    source: String,
    root: PathBuf,
}

impl RuntimeModuleMetadataCandidate {
    fn new(source: &str, root: PathBuf) -> Self {
        Self {
            source: source.to_string(),
            root,
        }
    }

    fn feature_profile_path(&self) -> PathBuf {
        self.root
            .join("feature-profile")
            .join("feature-profile.json")
    }

    fn active_features_path(&self) -> PathBuf {
        self.root
            .join("feature-profile")
            .join("active-features.json")
    }

    fn disabled_features_path(&self) -> PathBuf {
        self.root
            .join("feature-profile")
            .join("disabled-features.json")
    }

    fn runtime_plan_path(&self) -> PathBuf {
        self.root.join(RUNTIME_PLAN_PATH)
    }
}

fn runtime_module_metadata_candidates(paths: &RuntimePaths) -> Vec<RuntimeModuleMetadataCandidate> {
    let mut candidates = Vec::new();
    candidates.push(RuntimeModuleMetadataCandidate::new(
        "installed-runtime",
        paths.install_source_dir.clone(),
    ));
    candidates.extend(state_runtime_module_metadata_candidates(paths));
    if let Some(candidate) = bundled_runtime_module_metadata_candidate() {
        candidates.push(candidate);
    }
    if let Some(candidate) = source_build_runtime_module_metadata_candidate() {
        candidates.push(candidate);
    }
    dedupe_runtime_module_metadata_candidates(candidates)
}

fn state_runtime_module_metadata_candidates(
    paths: &RuntimePaths,
) -> Vec<RuntimeModuleMetadataCandidate> {
    let Ok(state) = read_state(&paths.state_path) else {
        return Vec::new();
    };
    let mut candidates = Vec::new();
    if let Some(source_root) = state.get("runtimeSourceRoot").and_then(Value::as_str) {
        if !source_root.trim().is_empty() {
            candidates.push(RuntimeModuleMetadataCandidate::new(
                "state-runtime-source",
                PathBuf::from(source_root),
            ));
        }
    }
    candidates
}

fn bundled_client_runtime_source_candidate() -> Option<ClientRuntimeSource> {
    let root = bundled_client_runtime_root()?;
    if !root.join(CLIENT_RUNTIME_ENTRY).exists() {
        return None;
    }
    Some(ClientRuntimeSource {
        kind: "packaged-client",
        package_root: root.clone(),
        path: root,
    })
}

fn bundled_runtime_module_metadata_candidate() -> Option<RuntimeModuleMetadataCandidate> {
    bundled_client_runtime_root()
        .map(|root| RuntimeModuleMetadataCandidate::new("packaged-client", root))
}

fn bundled_client_runtime_root() -> Option<PathBuf> {
    let executable = env::current_exe().ok()?;
    let executable_dir = executable.parent()?;
    let contents_dir = executable_dir.parent()?;
    let app_dir = contents_dir.parent()?;
    if executable_dir.file_name().and_then(|value| value.to_str()) != Some("MacOS")
        || contents_dir.file_name().and_then(|value| value.to_str()) != Some("Contents")
        || app_dir.extension().and_then(|value| value.to_str()) != Some("app")
    {
        return None;
    }
    Some(
        contents_dir
            .join("Resources")
            .join("lico-runtime")
            .join("client-local-runtime"),
    )
}

fn source_build_runtime_module_metadata_candidate() -> Option<RuntimeModuleMetadataCandidate> {
    let source_root = discover_client_repo_root(env::current_dir().ok()?)?;
    Some(RuntimeModuleMetadataCandidate::new(
        "source-build-output",
        source_root
            .join("build")
            .join("client-runtime")
            .join("client-local-runtime")
            .join("source"),
    ))
}

fn dedupe_runtime_module_metadata_candidates(
    candidates: Vec<RuntimeModuleMetadataCandidate>,
) -> Vec<RuntimeModuleMetadataCandidate> {
    let mut seen = Vec::<PathBuf>::new();
    let mut deduped = Vec::new();
    for candidate in candidates {
        if seen.iter().any(|path| path == &candidate.root) {
            continue;
        }
        seen.push(candidate.root.clone());
        deduped.push(candidate);
    }
    deduped
}

fn read_runtime_modules_from_candidate(
    candidate: &RuntimeModuleMetadataCandidate,
) -> Result<Value> {
    let feature_profile_path = candidate.feature_profile_path();
    let active_features_path = candidate.active_features_path();
    let disabled_features_path = candidate.disabled_features_path();
    let runtime_plan_path = candidate.runtime_plan_path();

    let feature_profile = read_optional_json_file(&feature_profile_path)?.unwrap_or(Value::Null);
    let active_features = read_optional_json_file(&active_features_path)?.unwrap_or(Value::Null);
    let disabled_features =
        read_optional_json_file(&disabled_features_path)?.unwrap_or(Value::Null);
    let runtime_plan = read_optional_json_file(&runtime_plan_path)?.unwrap_or(Value::Null);
    let loaded =
        feature_profile.is_object() || active_features.is_object() || runtime_plan.is_object();

    Ok(json!({
        "ok": loaded,
        "status": if loaded { "loaded" } else { "missing" },
        "source": candidate.source,
        "metadataRoot": display_path(&candidate.root),
        "edition": first_json_text(&[
            active_features.get("edition"),
            feature_profile.get("edition"),
            runtime_plan.pointer("/featureRuntime/edition")
        ]),
        "featureProfilePath": display_path(&feature_profile_path),
        "activeFeaturesPath": display_path(&active_features_path),
        "runtimePlanPath": display_path(&runtime_plan_path),
        "activeFeatureIds": first_json_array(&[
            active_features.get("activeFeatureIds"),
            feature_profile.get("features"),
            runtime_plan.pointer("/featureRuntime/activeFeatureIds")
        ]),
        "activeFeatures": first_json_array(&[
            active_features.get("activeFeatures"),
            runtime_plan.pointer("/featureRuntime/activeFeatures")
        ]),
        "disabledFeatureIds": first_json_array(&[
            disabled_features.get("disabledFeatureIds"),
            runtime_plan.pointer("/featureRuntime/disabledFeatureIds")
        ]),
        "disabledFeatures": first_json_array(&[
            disabled_features.get("disabledFeatures"),
            runtime_plan.pointer("/featureRuntime/disabledFeatures")
        ]),
        "runtimeModules": first_json_array(&[
            runtime_plan.pointer("/packagePlan/runtimeModules")
        ]),
        "mounts": first_json_array(&[
            runtime_plan.pointer("/packagePlan/mounts")
        ]),
        "eventTopics": first_json_array(&[
            runtime_plan.pointer("/packagePlan/eventTopics")
        ])
    }))
}

fn first_json_array(candidates: &[Option<&Value>]) -> Value {
    for candidate in candidates {
        if let Some(Value::Array(items)) = *candidate {
            return Value::Array(items.clone());
        }
    }
    json!([])
}

fn first_json_text(candidates: &[Option<&Value>]) -> String {
    for candidate in candidates {
        if let Some(Value::String(value)) = *candidate {
            if !value.trim().is_empty() {
                return value.trim().to_string();
            }
        }
    }
    String::new()
}

fn state_port(paths: &RuntimePaths) -> Option<u16> {
    read_state(&paths.state_path).ok().and_then(|state| {
        state
            .get("port")
            .and_then(Value::as_u64)
            .map(|value| value as u16)
    })
}

fn port_param(params: &Value) -> Result<Option<u16>> {
    let Some(value) = text_param(params, &["port"]) else {
        return Ok(None);
    };
    let port = value
        .parse::<u16>()
        .map_err(|_| anyhow!("invalid local runtime port: {}", value))?;
    Ok(Some(port))
}

fn health_timeout(params: &Value) -> Duration {
    let millis = number_param(params, &["healthTimeoutMs", "health-timeout-ms"])
        .unwrap_or(DEFAULT_HEALTH_TIMEOUT_MS);
    Duration::from_millis(millis.max(1))
}

fn default_identity_hash(params: &Value, paths: &RuntimePaths) -> String {
    if let Some(value) = text_param(params, &["defaultIdentityHash", "default-identity-hash"]) {
        if !value.trim().is_empty() {
            return value;
        }
    }
    let seed = format!(
        "lico-client-bootstrap-default-identity-v1\0{}",
        paths.root.display()
    );
    format!("sha256:{}", sha256_hex(seed.as_bytes()))
}

fn tail_lines(path: &Path, limit: usize) -> Result<Vec<String>> {
    if !path.exists() {
        return Ok(Vec::new());
    }
    let file = fs::File::open(path)?;
    let mut lines = BufReader::new(file)
        .lines()
        .collect::<std::io::Result<Vec<_>>>()?;
    if lines.len() > limit {
        lines = lines[lines.len() - limit..].to_vec();
    }
    Ok(lines)
}

fn append_activity(event_type: &str, payload: Value) {
    if let Ok(log) = ActivityLog::portable() {
        let _ = log.append(event_type, payload);
    }
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str).map(str::to_string))
}

fn bool_param(params: &Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value.as_bool().or_else(|| {
                value.as_str().map(|text| {
                    matches!(
                        text.trim().to_ascii_lowercase().as_str(),
                        "1" | "true" | "yes"
                    )
                })
            })
        })
    })
}

fn number_param(params: &Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| {
        params.get(*key).and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.parse::<u64>().ok()))
        })
    })
}

fn parse_url_port(server_url: &str) -> Option<u16> {
    server_url
        .trim_end_matches('/')
        .rsplit(':')
        .next()
        .and_then(|value| value.parse::<u16>().ok())
}

fn is_loopback_host(host: &str) -> bool {
    matches!(host.trim(), "127.0.0.1" | "localhost" | "::1")
}

fn sha256_hex(value: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value);
    format!("{:x}", hasher.finalize())
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
fn unix_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::set_portable_data_dir_override;

    #[test]
    fn default_identity_hash_is_stable_for_runtime_root() {
        let temp = env::temp_dir().join(format!("lico-local-runtime-test-{}", unix_nanos()));
        fs::create_dir_all(&temp).unwrap();
        let previous = set_portable_data_dir_override(Some(temp));
        let paths = runtime_paths().unwrap();
        let first = default_identity_hash(&json!({}), &paths);
        let second = default_identity_hash(&json!({}), &paths);
        assert!(first.starts_with("sha256:"));
        assert_eq!(first, second);
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn status_is_safe_before_runtime_exists() {
        let temp = env::temp_dir().join(format!("lico-local-runtime-status-{}", unix_nanos()));
        fs::create_dir_all(&temp).unwrap();
        let previous = set_portable_data_dir_override(Some(temp));
        let result = status(&json!({})).unwrap();
        assert_eq!(result["ok"], true);
        assert_eq!(result["status"], "stopped");
        set_portable_data_dir_override(previous);
    }
}
