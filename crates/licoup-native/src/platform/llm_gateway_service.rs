//! Managed lifecycle for the loopback LLM gateway sidecar process.
//!
//! The CLI owns a private state directory under the portable data root with
//! the generated provider/routing configuration, the pid record, and the
//! append-only sidecar log. Secrets are never written here. The sidecar starts
//! disconnected and healthy. Explicit authorization only loads credentials
//! into the long-lived native process; an explicit service start applies the
//! loaded session to a newly spawned sidecar.

#[cfg(unix)]
use crate::core::secure_mesh_secret_store::SecretBytes;
#[cfg(unix)]
use crate::domain::llm_api_key_vault::GatewayCredentialHandoff;
use crate::domain::llm_api_key_vault::LlmApiKeyProvider;
use crate::domain::llm_gateway::{
    ClientProtocol, CompiledGateway, CredentialStyle, GatewayConfig, GatewayProvider, ModelRoute,
    UpstreamProtocol,
};
use crate::platform::file_security::{
    atomic_write_private_text, ensure_private_dir, read_private_text_bounded,
    remove_private_state_marker,
};
use crate::platform::paths;
use anyhow::{Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(unix)]
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const DEFAULT_PORT: u16 = 15_722;
pub const REPORT_SCHEMA: &str = "licoup.llm-gateway-service.v1";

const STATE_DIRECTORY: &str = "llm-gateway";
const SIDECAR_BINARY: &str = "lico-llm-gateway";
const MAX_CONFIG_BYTES: usize = 64 * 1024;
const MAX_PID_BYTES: usize = 1024;
const HEALTH_PROBE_BYTES: usize = 4 * 1024;
const HEALTH_PROBE_TIMEOUT: Duration = Duration::from_millis(300);
const START_TIMEOUT: Duration = Duration::from_secs(10);
const STOP_TIMEOUT: Duration = Duration::from_secs(5);
const POLL_INTERVAL: Duration = Duration::from_millis(100);

/// Secret material unlocked by the owner once for the lifetime of the native
/// app process. The cache is never serialized to disk or projected through a
/// command result. A restarted sidecar receives a fresh inherited-pipe copy.
#[cfg(unix)]
static GATEWAY_SESSION_CREDENTIALS: OnceLock<Mutex<Option<SecretBytes>>> = OnceLock::new();

/// Credential IDs currently bound into the in-memory Gateway handoff. Selection
/// is process-local and never persisted.
#[cfg(unix)]
static GATEWAY_ENABLED_CREDENTIAL_IDS: OnceLock<Mutex<BTreeSet<String>>> = OnceLock::new();

#[cfg(unix)]
fn gateway_session_credentials() -> &'static Mutex<Option<SecretBytes>> {
    GATEWAY_SESSION_CREDENTIALS.get_or_init(|| Mutex::new(None))
}

#[cfg(unix)]
fn gateway_enabled_credential_ids() -> &'static Mutex<BTreeSet<String>> {
    GATEWAY_ENABLED_CREDENTIAL_IDS.get_or_init(|| Mutex::new(BTreeSet::new()))
}

fn validate_credential_id(credential_id: &str) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(credential_id).is_ok_and(|value| value.to_string() == credential_id),
        "llm_api_key_credential_id_invalid"
    );
    Ok(())
}

fn authorization_report(
    authorized: bool,
    providers: Vec<String>,
    credential_ids: impl IntoIterator<Item = String>,
    reason_code: Option<&str>,
) -> Value {
    let ids: Vec<String> = credential_ids.into_iter().collect();
    json!({
        "ok": true,
        "schemaVersion": "licoup.llm-gateway-authorization.v1",
        "authorized": authorized,
        "reasonCode": reason_code,
        "providers": providers,
        "authorizedCredentialIds": ids,
    })
}

#[cfg(unix)]
pub(crate) fn replace_gateway_session_credentials(
    handoff: Option<GatewayCredentialHandoff>,
) -> Result<()> {
    let payload = handoff
        .map(|handoff| handoff.to_json())
        .transpose()?
        .map(SecretBytes::try_from_bytes)
        .transpose()
        .map_err(|_| anyhow!("llm_gateway_session_credentials_unavailable"))?;
    *gateway_session_credentials()
        .lock()
        .map_err(|_| anyhow!("llm_gateway_session_credentials_unavailable"))? = payload;
    Ok(())
}

#[derive(Clone, Debug)]
struct ServicePaths {
    config: PathBuf,
    pid: PathBuf,
    log: PathBuf,
    usage: PathBuf,
}

impl ServicePaths {
    fn resolve() -> Result<Self> {
        let root = paths::portable_data_dir()?.join(STATE_DIRECTORY);
        ensure_private_dir(&root)?;
        Ok(Self {
            config: root.join("config.json"),
            pid: root.join("gateway.pid"),
            log: root.join("gateway.log"),
            usage: root.join("usage.json"),
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PidRecord {
    pid: u32,
    port: u16,
    started_at: u64,
    #[serde(default)]
    credentials_loaded: bool,
}

/// Report the sidecar state without spawning anything or prompting.
pub fn service_status(port: u16) -> Result<Value> {
    status_report(port, HEALTH_PROBE_TIMEOUT)
}

/// Return only the private counters produced by requests that traversed the
/// local Gateway. Reading statistics never authorizes credential access.
pub fn service_usage() -> Result<Value> {
    let paths = ServicePaths::resolve()?;
    crate::platform::llm_gateway_usage::read_usage(&paths.usage)
}

/// Start the local service during client initialization without touching the
/// Keychain. Credential authorization remains a separate action.
pub fn service_initialize(port: u16) -> Result<Value> {
    if probe_health(port, HEALTH_PROBE_TIMEOUT) {
        return service_status(port);
    }
    service_start(port)
}

/// Request user presence and load selected system-keyring credentials into
/// the native app process. When `credential_id` is set, only that key is added
/// to the active selection; when omitted, every non-expired key is enabled.
/// This operation performs no network request and does not start, stop, or
/// restart the local Gateway process.
pub fn credentials_authorize(credential_id: Option<&str>) -> Result<Value> {
    #[cfg(unix)]
    {
        if let Some(credential_id) = credential_id {
            validate_credential_id(credential_id)?;
        }
        let vault = crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?;
        let inventory = vault.list()?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| anyhow!("llm_api_key_clock_invalid"))?
            .as_secs();
        let available: BTreeSet<String> = inventory
            .entries
            .iter()
            .filter(|entry| !entry.is_expired(now))
            .map(|entry| entry.credential_id.clone())
            .collect();
        let mut enabled = gateway_enabled_credential_ids()
            .lock()
            .map_err(|_| anyhow!("llm_gateway_session_credentials_unavailable"))?;
        let next_enabled = match credential_id {
            Some(credential_id) => {
                ensure!(
                    available.contains(credential_id),
                    "llm_api_key_credential_unavailable"
                );
                let mut next = enabled.clone();
                next.insert(credential_id.to_owned());
                next
            }
            None => available,
        };
        let ids: Vec<String> = next_enabled.iter().cloned().collect();
        let handoff = if ids.is_empty() {
            None
        } else {
            vault.authorize_gateway_handoff_filtered(Some(&ids))?
        };
        let providers = handoff
            .as_ref()
            .map(|value| {
                value
                    .providers()
                    .map(|provider| provider.as_str().to_owned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let authorized = handoff.is_some();
        replace_gateway_session_credentials(handoff)?;
        *enabled = if authorized {
            next_enabled
        } else {
            BTreeSet::new()
        };
        let ids: Vec<String> = enabled.iter().cloned().collect();
        Ok(authorization_report(
            authorized,
            providers,
            ids,
            if authorized {
                None
            } else {
                Some("no_credentials")
            },
        ))
    }
    #[cfg(not(unix))]
    {
        let _ = credential_id;
        Err(anyhow!("llm_gateway_credential_authorization_unsupported"))
    }
}

/// Drop selected or all in-memory Gateway credentials without deleting vault
/// entries and without starting or stopping the sidecar. When `credential_id`
/// is set, only that key leaves the active selection.
pub fn credentials_clear(credential_id: Option<&str>) -> Result<Value> {
    #[cfg(unix)]
    {
        if let Some(credential_id) = credential_id {
            validate_credential_id(credential_id)?;
        }
        let mut enabled = gateway_enabled_credential_ids()
            .lock()
            .map_err(|_| anyhow!("llm_gateway_session_credentials_unavailable"))?;
        match credential_id {
            None => {
                enabled.clear();
                replace_gateway_session_credentials(None)?;
                return Ok(authorization_report(
                    false,
                    Vec::new(),
                    Vec::<String>::new(),
                    None,
                ));
            }
            Some(credential_id) => {
                enabled.remove(credential_id);
            }
        }
        if enabled.is_empty() {
            replace_gateway_session_credentials(None)?;
            return Ok(authorization_report(
                false,
                Vec::new(),
                Vec::<String>::new(),
                None,
            ));
        }
        let vault = crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()?;
        let ids: Vec<String> = enabled.iter().cloned().collect();
        let handoff = vault.authorize_gateway_handoff_filtered(Some(&ids))?;
        let providers = handoff
            .as_ref()
            .map(|value| {
                value
                    .providers()
                    .map(|provider| provider.as_str().to_owned())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let authorized = handoff.is_some();
        replace_gateway_session_credentials(handoff)?;
        if !authorized {
            enabled.clear();
        }
        let remaining: Vec<String> = enabled.iter().cloned().collect();
        Ok(authorization_report(
            authorized,
            providers,
            remaining,
            if authorized {
                None
            } else {
                Some("no_credentials")
            },
        ))
    }
    #[cfg(not(unix))]
    {
        let _ = credential_id;
        Err(anyhow!("llm_gateway_credential_authorization_unsupported"))
    }
}

/// Start the sidecar detached, generating and validating the default
/// configuration first when it does not exist yet.
pub fn service_start(port: u16) -> Result<Value> {
    if let Some(health) = probe_health_response(port, HEALTH_PROBE_TIMEOUT) {
        let paths = ServicePaths::resolve()?;
        let managed = read_pid_record(&paths.pid)?.filter(|record| pid_alive(record.pid));
        let should_apply_loaded_credentials = managed
            .as_ref()
            .is_some_and(|record| session_credentials_loaded() && !record.credentials_loaded);
        let should_apply_current_protocols =
            !health.contains("openai-chat-completions") || !health.contains("anthropic-messages");
        if !should_apply_loaded_credentials && !should_apply_current_protocols {
            return Ok(report(
                "running",
                managed.is_some(),
                managed.map(|record| record.pid),
                port,
                &paths,
                Some("already_running"),
            ));
        }
        service_stop(port)?;
    }
    let paths = ServicePaths::resolve()?;
    if let Some(record) = read_pid_record(&paths.pid)? {
        if pid_alive(record.pid) {
            return Err(anyhow!("llm_gateway_already_unhealthy"));
        }
        clear_pid_record(&paths.pid)?;
    }
    ensure_default_config(&paths)?;
    let sidecar = sidecar_path()?;
    // Starting the local service never authorizes. If the user already loaded
    // credentials into this app process, a restart reuses that in-memory
    // handoff; otherwise the sidecar starts disconnected but healthy.
    #[cfg(unix)]
    let mut child = spawn_sidecar_with_cached_credentials(&sidecar, &paths, port)?;
    #[cfg(not(unix))]
    let mut child = spawn_sidecar(&sidecar, &paths, port)?;
    let record = PidRecord {
        pid: child.id(),
        port,
        started_at: unix_seconds(),
        credentials_loaded: session_credentials_loaded(),
    };
    write_pid_record(&paths.pid, &record)?;
    let deadline = Instant::now() + START_TIMEOUT;
    loop {
        if child
            .try_wait()
            .map_err(|_| anyhow!("llm_gateway_start_failed"))?
            .is_some()
        {
            let _ = clear_pid_record(&paths.pid);
            return Err(anyhow!("llm_gateway_start_failed"));
        }
        if probe_health(port, HEALTH_PROBE_TIMEOUT) {
            return Ok(report(
                "running",
                true,
                Some(record.pid),
                port,
                &paths,
                None,
            ));
        }
        if Instant::now() >= deadline {
            terminate(record.pid);
            let _ = child.wait();
            let _ = clear_pid_record(&paths.pid);
            return Err(anyhow!("llm_gateway_start_failed"));
        }
        thread::sleep(POLL_INTERVAL);
    }
}

#[cfg(unix)]
fn spawn_sidecar_with_cached_credentials(
    sidecar: &Path,
    paths: &ServicePaths,
    port: u16,
) -> Result<Child> {
    let cached = gateway_session_credentials()
        .lock()
        .map_err(|_| anyhow!("llm_gateway_session_credentials_unavailable"))?;
    match cached.as_ref() {
        Some(payload) => spawn_sidecar_with_handoff(sidecar, paths, port, payload.expose_bytes()),
        None => spawn_sidecar(sidecar, paths, port),
    }
}

/// Stop the managed sidecar. A healthy listener without a valid pid record is
/// never signalled: the CLI only stops processes it started itself.
pub fn service_stop(port: u16) -> Result<Value> {
    let paths = ServicePaths::resolve()?;
    let managed = read_pid_record(&paths.pid)?;
    let managed = match managed {
        Some(record) if pid_alive(record.pid) => Some(record),
        Some(_) => {
            clear_pid_record(&paths.pid)?;
            None
        }
        None => None,
    };
    let Some(record) = managed else {
        if probe_health(port, HEALTH_PROBE_TIMEOUT) {
            return Err(anyhow!("llm_gateway_unmanaged"));
        }
        return Ok(report(
            "stopped",
            false,
            None,
            port,
            &paths,
            Some("not_running"),
        ));
    };
    terminate(record.pid);
    let deadline = Instant::now() + STOP_TIMEOUT;
    loop {
        if !pid_alive(record.pid) && !probe_health(port, HEALTH_PROBE_TIMEOUT) {
            clear_pid_record(&paths.pid)?;
            return Ok(report("stopped", false, None, port, &paths, None));
        }
        if Instant::now() >= deadline {
            return Err(anyhow!("llm_gateway_stop_failed"));
        }
        thread::sleep(POLL_INTERVAL);
    }
}

fn status_report(port: u16, probe_timeout: Duration) -> Result<Value> {
    let paths = ServicePaths::resolve()?;
    let record = read_pid_record(&paths.pid)?;
    let stale = record.is_some();
    let live = record.filter(|record| pid_alive(record.pid));
    if stale && live.is_none() {
        clear_pid_record(&paths.pid)?;
    }
    let healthy = probe_health(port, probe_timeout);
    match (healthy, live) {
        (true, Some(record)) => Ok(report(
            "running",
            true,
            Some(record.pid),
            port,
            &paths,
            None,
        )),
        (true, None) => Ok(report("running", false, None, port, &paths, None)),
        (false, Some(record)) => Ok(report(
            "unhealthy",
            true,
            Some(record.pid),
            port,
            &paths,
            None,
        )),
        (false, None) => Ok(report("stopped", false, None, port, &paths, None)),
    }
}

fn report(
    state: &str,
    managed: bool,
    pid: Option<u32>,
    port: u16,
    paths: &ServicePaths,
    message: Option<&str>,
) -> Value {
    let credentials_loaded = session_credentials_loaded();
    let credentials_applied = pid.is_some_and(|expected_pid| {
        read_pid_record(&paths.pid)
            .ok()
            .flatten()
            .is_some_and(|record| record.pid == expected_pid && record.credentials_loaded)
    });
    let mut value = json!({
        "ok": true,
        "schemaVersion": REPORT_SCHEMA,
        "state": state,
        "managed": managed,
        "pid": pid,
        "processName": if pid.is_some() { Some(SIDECAR_BINARY) } else { None },
        "port": port,
        "credentialsLoaded": credentials_loaded,
        "credentialsApplied": credentials_applied,
        "modelReady": state == "running" && credentials_applied,
        "configPath": paths.config,
        "logPath": paths.log,
    });
    if let Some(message) = message {
        value["message"] = json!(message);
    }
    value
}

#[cfg(unix)]
fn session_credentials_loaded() -> bool {
    gateway_session_credentials()
        .lock()
        .map(|credentials| credentials.is_some())
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn session_credentials_loaded() -> bool {
    false
}

fn default_config(available_providers: &BTreeSet<LlmApiKeyProvider>) -> GatewayConfig {
    let all_providers = [
        GatewayProvider {
            id: "kimi".to_owned(),
            base_url: "https://api.moonshot.cn/v1".to_owned(),
            protocol: UpstreamProtocol::OpenAiChatCompletions,
            credential_provider: LlmApiKeyProvider::Kimi,
            credential_style: CredentialStyle::Bearer,
        },
        GatewayProvider {
            id: "deepseek".to_owned(),
            base_url: "https://api.deepseek.com/v1".to_owned(),
            protocol: UpstreamProtocol::OpenAiChatCompletions,
            credential_provider: LlmApiKeyProvider::DeepSeek,
            credential_style: CredentialStyle::Bearer,
        },
        GatewayProvider {
            id: "kilo".to_owned(),
            base_url: "https://api.kilo.ai/api/gateway".to_owned(),
            protocol: UpstreamProtocol::OpenAiChatCompletions,
            credential_provider: LlmApiKeyProvider::Kilo,
            credential_style: CredentialStyle::Bearer,
        },
    ];
    let providers = all_providers
        .into_iter()
        .filter(|provider| available_providers.contains(&provider.credential_provider))
        .collect::<Vec<_>>();
    let provider_ids = available_providers
        .iter()
        .map(|provider| provider.as_str())
        .collect::<BTreeSet<_>>();
    let mut routes = Vec::new();
    for model in crate::domain::llm_gateway_default_catalog::models_for_provider_ids(&provider_ids)
    {
        for client_protocol in [
            ClientProtocol::OpenAiResponses,
            ClientProtocol::OpenAiChatCompletions,
            ClientProtocol::AnthropicMessages,
        ] {
            routes.push(ModelRoute {
                client_protocol,
                requested_model: model.requested_model.to_owned(),
                provider_id: model.provider_id.to_owned(),
                upstream_model: model.upstream_model.to_owned(),
            });
        }
    }
    GatewayConfig {
        schema_version: 1,
        providers,
        routes,
    }
}

/// Providers that currently have at least one non-expired saved API key.
/// Inventory metadata only; never opens Keychain secrets.
pub(crate) fn providers_with_usable_saved_keys() -> BTreeSet<LlmApiKeyProvider> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    match crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::production()
        .and_then(|vault| vault.list())
    {
        Ok(inventory) => inventory.providers_with_usable_keys(now),
        Err(_) => BTreeSet::new(),
    }
}

/// Materialize the closed product-owned routing configuration for providers
/// that currently have a usable saved API key. Providers without keys are
/// omitted so the Gateway does not advertise their model catalogs. Rewriting
/// this private file ensures a freshly packaged sidecar never inherits a
/// retired route set.
fn ensure_default_config(paths: &ServicePaths) -> Result<()> {
    let config = default_config(&providers_with_usable_saved_keys());
    let body = serde_json::to_string_pretty(&config)?;
    atomic_write_private_text(&paths.config, &body)?;
    validate_config(&paths.config)
}

fn validate_config(path: &Path) -> Result<()> {
    let Some(text) = read_private_text_bounded(path, MAX_CONFIG_BYTES)? else {
        return Err(anyhow!("llm_gateway_config_invalid"));
    };
    let config: GatewayConfig =
        serde_json::from_str(&text).map_err(|_| anyhow!("llm_gateway_config_invalid"))?;
    CompiledGateway::compile(config).map_err(|_| anyhow!("llm_gateway_config_invalid"))?;
    Ok(())
}

fn sidecar_path() -> Result<PathBuf> {
    let current = std::env::current_exe().map_err(|_| anyhow!("llm_gateway_sidecar_missing"))?;
    let sibling = current
        .parent()
        .map(|directory| {
            directory.join(format!(
                "{}{}",
                SIDECAR_BINARY,
                std::env::consts::EXE_SUFFIX
            ))
        })
        .ok_or_else(|| anyhow!("llm_gateway_sidecar_missing"))?;
    let metadata =
        std::fs::symlink_metadata(&sibling).map_err(|_| anyhow!("llm_gateway_sidecar_missing"))?;
    if !metadata.file_type().is_file() {
        return Err(anyhow!("llm_gateway_sidecar_missing"));
    }
    Ok(sibling)
}

fn sidecar_command(sidecar: &Path, paths: &ServicePaths, port: u16) -> Result<Command> {
    let mut options = OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let log = options
        .open(&paths.log)
        .map_err(|_| anyhow!("llm_gateway_start_failed"))?;
    let log_errors = log
        .try_clone()
        .map_err(|_| anyhow!("llm_gateway_start_failed"))?;
    let mut command = Command::new(sidecar);
    command
        .arg("--config")
        .arg(&paths.config)
        .arg("--port")
        .arg(port.to_string())
        .arg("--usage")
        .arg(&paths.usage)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_errors));
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as WindowsCommandExt;
        command.creation_flags(0x0000_0008 | 0x0000_0200 | 0x0800_0000);
    }
    Ok(command)
}

fn spawn_sidecar(sidecar: &Path, paths: &ServicePaths, port: u16) -> Result<Child> {
    sidecar_command(sidecar, paths, port)?
        .spawn()
        .map_err(|_| anyhow!("llm_gateway_start_failed"))
}

/// Spawn the sidecar with the unlocked credentials handed over through an
/// inherited pipe whose read end is fixed at fd 3 in the child. The payload
/// is written only after the spawn succeeds; a failed write means the sidecar
/// can never become healthy and is treated as a start failure.
#[cfg(unix)]
fn spawn_sidecar_with_handoff(
    sidecar: &Path,
    paths: &ServicePaths,
    port: u16,
    payload: &[u8],
) -> Result<Child> {
    use std::os::fd::{FromRawFd, RawFd};
    use std::os::unix::process::CommandExt;

    let mut ends = [0 as RawFd; 2];
    if unsafe { libc::pipe(ends.as_mut_ptr()) } == -1 {
        return Err(anyhow!("llm_gateway_start_failed"));
    }
    let read_fd = ends[0];
    let write_fd = ends[1];
    // Close-on-exec on both ends immediately so nothing inherited past the
    // sidecar can leak them; the child's dup2 target clears CLOEXEC and
    // survives the exec.
    for fd in [read_fd, write_fd] {
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } == -1 {
            unsafe {
                libc::close(read_fd);
                libc::close(write_fd);
            }
            return Err(anyhow!("llm_gateway_start_failed"));
        }
    }
    let mut command = match sidecar_command(sidecar, paths, port) {
        Ok(command) => command,
        Err(error) => {
            unsafe {
                libc::close(read_fd);
                libc::close(write_fd);
            }
            return Err(error);
        }
    };
    command.arg("--credentials-fd").arg("3");
    unsafe {
        command.pre_exec(move || {
            // pre_exec forces the fork+exec path, so this fd fix-up runs in the
            // child after fork and before exec with no ordering races.
            if read_fd != 3 {
                if libc::dup2(read_fd, 3) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
            } else if libc::fcntl(3, libc::F_SETFD, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            unsafe {
                libc::close(read_fd);
                libc::close(write_fd);
            }
            return Err(anyhow!("llm_gateway_start_failed"));
        }
    };
    // Spawn succeeded: the parent keeps no read end. Write the whole payload
    // (write_all retries interrupted writes), then close the write end so the
    // sidecar reads to EOF. The parent's other secret copies zeroize through
    // SecretBytes drop; this payload buffer is dropped with the start flow.
    unsafe { libc::close(read_fd) };
    let write_result = {
        let mut write_end = unsafe { std::fs::File::from_raw_fd(write_fd) };
        let result = write_end.write_all(payload);
        drop(write_end);
        result
    };
    if let Err(error) = write_result {
        // A broken pipe means the sidecar died before reading the handoff;
        // either way the doomed child is reaped instead of left running.
        if error.kind() == std::io::ErrorKind::BrokenPipe {
            terminate(child.id());
            let _ = child.wait();
            let _ = clear_pid_record(&paths.pid);
        }
        return Err(anyhow!("llm_gateway_start_failed"));
    }
    Ok(child)
}

fn probe_health(port: u16, timeout: Duration) -> bool {
    probe_health_response(port, timeout).is_some()
}

fn probe_health_response(port: u16, timeout: Duration) -> Option<String> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, timeout) else {
        return None;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    if stream
        .write_all(b"GET /health HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n")
        .is_err()
    {
        return None;
    }
    let mut received = Vec::with_capacity(HEALTH_PROBE_BYTES);
    let mut chunk = [0u8; 1024];
    while received.len() < HEALTH_PROBE_BYTES {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(count) => received.extend_from_slice(&chunk[..count]),
            Err(_) => break,
        }
    }
    let text = String::from_utf8_lossy(&received);
    (text
        .lines()
        .next()
        .is_some_and(|status| status.contains(" 200"))
        && text.contains("licoup-llm-gateway"))
    .then(|| text.into_owned())
}

fn pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    #[cfg(unix)]
    {
        let signaled = unsafe { libc::kill(pid as i32, 0) } == 0;
        if !signaled && std::io::Error::last_os_error().raw_os_error() != Some(libc::EPERM) {
            return false;
        }
        // A zombie still answers kill(pid, 0); for lifecycle purposes it is
        // already dead and its gateway socket is gone. The long-lived CLI
        // host never reaps detached sidecars, so zombies are a normal state.
        !pid_is_zombie(pid)
    }
    #[cfg(windows)]
    {
        Command::new("tasklist")
            .args(["/FI", &format!("PID eq {}", pid)])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .map(|output| {
                output.status.success()
                    && output.stdout.len() <= 64 * 1024
                    && String::from_utf8_lossy(&output.stdout).contains(&pid.to_string())
            })
            .unwrap_or(false)
    }
}

#[cfg(target_os = "macos")]
fn pid_is_zombie(pid: u32) -> bool {
    // XNU drops zombies from proc_pidinfo's view while they still answer
    // kill(pid, 0), so after a successful kill an ESRCH here means zombie.
    // Other errors (e.g. EPERM for a foreign process) stay conservative.
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    let written = unsafe {
        libc::proc_pidinfo(
            pid as i32,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    written <= 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

#[cfg(target_os = "linux")]
fn pid_is_zombie(pid: u32) -> bool {
    let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return false;
    };
    // comm may contain spaces and parentheses; state follows the last ')'.
    stat.rsplit_once(')')
        .and_then(|(_, rest)| rest.split_whitespace().next())
        == Some("Z")
}

#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
fn pid_is_zombie(_pid: u32) -> bool {
    false
}

fn terminate(pid: u32) {
    #[cfg(unix)]
    unsafe {
        libc::kill(pid as i32, libc::SIGTERM);
    }
    #[cfg(windows)]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &pid.to_string(), "/T"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
}

fn read_pid_record(path: &Path) -> Result<Option<PidRecord>> {
    let Some(text) = read_private_text_bounded(path, MAX_PID_BYTES)? else {
        return Ok(None);
    };
    Ok(serde_json::from_str::<PidRecord>(&text)
        .ok()
        .filter(|record| record.pid != 0))
}

fn write_pid_record(path: &Path, record: &PidRecord) -> Result<()> {
    atomic_write_private_text(path, &serde_json::to_string(record)?)
}

fn clear_pid_record(path: &Path) -> Result<()> {
    remove_private_state_marker(path)?;
    Ok(())
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
    use std::net::TcpListener;

    struct PortableDataDirOverrideGuard {
        previous: Option<PathBuf>,
    }

    impl PortableDataDirOverrideGuard {
        fn set(path: PathBuf) -> Self {
            let previous = paths::set_portable_data_dir_override(Some(path));
            Self { previous }
        }
    }

    impl Drop for PortableDataDirOverrideGuard {
        fn drop(&mut self) {
            paths::set_portable_data_dir_override(self.previous.take());
        }
    }

    fn temp_state_root() -> PathBuf {
        std::env::temp_dir().join(format!(
            "licoup-llm-gateway-service-{}",
            uuid::Uuid::new_v4()
        ))
    }

    fn closed_port() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        port
    }

    #[test]
    fn default_config_compiles_and_covers_both_client_protocols() {
        use crate::domain::llm_gateway_default_catalog::DEFAULT_GATEWAY_MODELS;
        let all_providers = BTreeSet::from(LlmApiKeyProvider::ALL);
        let config = default_config(&all_providers);
        let text = serde_json::to_string_pretty(&config).unwrap();
        let parsed: GatewayConfig = serde_json::from_str(&text).unwrap();
        CompiledGateway::compile(parsed).unwrap();
        assert_eq!(config.routes.len(), DEFAULT_GATEWAY_MODELS.len() * 3);
        for model in DEFAULT_GATEWAY_MODELS {
            for client_protocol in [
                ClientProtocol::OpenAiResponses,
                ClientProtocol::OpenAiChatCompletions,
                ClientProtocol::AnthropicMessages,
            ] {
                assert!(config.routes.iter().any(|route| {
                    route.client_protocol == client_protocol
                        && route.requested_model == model.requested_model
                        && route.provider_id == model.provider_id
                        && route.upstream_model == model.upstream_model
                }));
            }
        }
        assert!(text.contains("\"credentialProvider\": \"kimi\""));
        assert!(text.contains("\"credentialProvider\": \"kilo\""));
        assert!(text.contains("\"requestedModel\": \"deepseek:deepseek-v4-pro\""));
        assert!(text.contains("\"requestedModel\": \"kimi:k3\""));
        assert!(text.contains("\"requestedModel\": \"kilo:kilo-auto/frontier\""));
        assert!(text.contains("\"requestedModel\": \"kilo:anthropic/claude-opus-5\""));
        assert!(text.contains("\"upstreamModel\": \"deepseek-v4-pro\""));
        assert!(text.contains("\"upstreamModel\": \"kimi-k3\""));
        assert!(text.contains("\"upstreamModel\": \"kilo-auto/free\""));
        assert!(!text.contains("\"requestedModel\": \"anthropic/claude-sonnet-4.6\""));
        assert!(!text.contains("kimi-k2-0905-preview"));
        assert!(!text.contains("\"requestedModel\": \"deepseek-chat\""));
        assert!(text.contains("\"baseUrl\": \"https://api.kilo.ai/api/gateway\""));
        assert!(text.contains("\"protocol\": \"open_ai_chat_completions\""));
        assert!(text.contains("\"clientProtocol\": \"anthropic_messages\""));
        assert!(text.contains("\"clientProtocol\": \"open_ai_chat_completions\""));
        assert!(text.contains("\"clientProtocol\": \"open_ai_responses\""));
    }

    #[test]
    fn default_config_omits_providers_without_saved_keys() {
        let only_kimi = BTreeSet::from([LlmApiKeyProvider::Kimi]);
        let config = default_config(&only_kimi);
        CompiledGateway::compile(config.clone()).unwrap();
        assert_eq!(config.providers.len(), 1);
        assert_eq!(
            config.providers[0].credential_provider,
            LlmApiKeyProvider::Kimi
        );
        assert!(
            config
                .routes
                .iter()
                .all(|route| route.provider_id == "kimi")
        );
        assert!(
            config
                .routes
                .iter()
                .any(|route| route.requested_model == "kimi:k3")
        );

        let empty = default_config(&BTreeSet::new());
        CompiledGateway::compile(empty.clone()).unwrap();
        assert!(empty.providers.is_empty());
        assert!(empty.routes.is_empty());
    }

    #[test]
    fn pid_record_round_trip_and_garbage_reads_as_none() {
        let root = temp_state_root();
        let _guard = PortableDataDirOverrideGuard::set(root.clone());
        let paths = ServicePaths::resolve().unwrap();
        assert_eq!(read_pid_record(&paths.pid).unwrap(), None);

        let record = PidRecord {
            pid: 4242,
            port: DEFAULT_PORT,
            started_at: 1_700_000_000,
            credentials_loaded: false,
        };
        write_pid_record(&paths.pid, &record).unwrap();
        assert_eq!(read_pid_record(&paths.pid).unwrap(), Some(record));
        clear_pid_record(&paths.pid).unwrap();
        assert_eq!(read_pid_record(&paths.pid).unwrap(), None);

        atomic_write_private_text(&paths.pid, "not-a-pid-record").unwrap();
        assert_eq!(read_pid_record(&paths.pid).unwrap(), None);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn health_probe_accepts_canned_200_and_rejects_closed_port() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n{\"ok\":true,\"service\":\"licoup-llm-gateway\",\"protocols\":[\"openai-responses\",\"openai-chat-completions\",\"anthropic-messages\"]}",
                )
                .unwrap();
        });
        assert!(probe_health(port, Duration::from_millis(500)));
        server.join().unwrap();

        assert!(!probe_health(closed_port(), Duration::from_millis(50)));
    }

    #[test]
    fn status_on_empty_state_dir_reports_stopped_and_unmanaged() {
        let root = temp_state_root();
        let _guard = PortableDataDirOverrideGuard::set(root.clone());
        let port = closed_port();
        let report = status_report(port, Duration::from_millis(50)).unwrap();
        assert_eq!(report["ok"], json!(true));
        assert_eq!(report["schemaVersion"], json!(REPORT_SCHEMA));
        assert_eq!(report["state"], json!("stopped"));
        assert_eq!(report["managed"], json!(false));
        assert!(report["pid"].is_null());
        assert_eq!(report["port"], json!(port));
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn status_clears_stale_pid_record_for_dead_process() {
        let root = temp_state_root();
        let _guard = PortableDataDirOverrideGuard::set(root.clone());
        let paths = ServicePaths::resolve().unwrap();
        let mut child = Command::new("/usr/bin/true").spawn().unwrap();
        let dead_pid = child.id();
        child.wait().unwrap();
        assert!(!pid_alive(dead_pid));
        write_pid_record(
            &paths.pid,
            &PidRecord {
                pid: dead_pid,
                port: DEFAULT_PORT,
                started_at: unix_seconds(),
                credentials_loaded: false,
            },
        )
        .unwrap();
        let report = status_report(closed_port(), Duration::from_millis(50)).unwrap();
        assert_eq!(report["state"], json!("stopped"));
        assert_eq!(report["managed"], json!(false));
        assert_eq!(read_pid_record(&paths.pid).unwrap(), None);
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn unreaped_zombie_child_is_not_alive() {
        let mut child = Command::new("/usr/bin/true").spawn().unwrap();
        let zombie_pid = child.id();
        // Never wait before the assertion: the exited child stays a zombie
        // and still answers kill(pid, 0), so only the zombie check rejects it.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !pid_is_zombie(zombie_pid) && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(pid_is_zombie(zombie_pid));
        assert!(!pid_alive(zombie_pid));
        child.wait().unwrap();
        assert!(!pid_alive(zombie_pid));
    }

    #[cfg(unix)]
    #[test]
    fn gateway_session_credentials_are_replaceable_without_disk_state() {
        let mut credentials = std::collections::BTreeMap::new();
        credentials.insert(
            LlmApiKeyProvider::Kimi,
            vec![SecretBytes::try_from_string("synthetic-secret".to_owned()).unwrap()],
        );
        let handoff = GatewayCredentialHandoff::new(
            credentials,
            crate::domain::llm_api_key_vault::GatewayCredentialLeaseDays::Seven,
            "11111111-1111-4111-8111-111111111111".to_owned(),
        )
        .unwrap();

        replace_gateway_session_credentials(Some(handoff)).unwrap();

        let cached = gateway_session_credentials().lock().unwrap();
        let parsed = GatewayCredentialHandoff::from_json(
            cached
                .as_ref()
                .expect("session credential payload")
                .expose_bytes(),
        );
        assert!(parsed.is_ok());
        drop(cached);
        replace_gateway_session_credentials(None).unwrap();
    }
}
