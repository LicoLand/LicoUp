//! One-request local IPC client used by every orchestrator control surface.

use super::{MAX_FRAME_BYTES, OrchestratorIpcReceipt, OrchestratorIpcRequest, PROTOCOL_VERSION};
use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

const PRIVATE_BOOTSTRAP_MAX_BYTES: usize = 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Handshake<'a> {
    protocol_version: &'static str,
    client_kind: &'static str,
    connection_nonce: String,
    capability_handle: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    acceptance_hold_id: Option<&'a str>,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DiscoveryRecord {
    pub endpoint_generation: String,
    pub service_instance_id: String,
    pub endpoint_path: String,
    pub service_pid: u32,
    pub acceptance_mode: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PrivateCapabilityBootstrap {
    pub workflow: String,
    pub status_only: String,
    pub lifecycle: String,
}

pub struct OrchestratorIpcClient {
    state_root: PathBuf,
    auto_start: bool,
    client_kind: &'static str,
    timeout: Duration,
    acceptance_capability_override: Option<String>,
    acceptance_hold_id: Option<String>,
}

impl OrchestratorIpcClient {
    pub fn new(state_root: impl Into<PathBuf>) -> Self {
        Self {
            state_root: state_root.into(),
            auto_start: true,
            client_kind: "cli",
            timeout: Duration::from_secs(10),
            acceptance_capability_override: None,
            acceptance_hold_id: None,
        }
    }

    pub fn with_client_kind(mut self, client_kind: &'static str) -> Self {
        self.client_kind = client_kind;
        self
    }

    pub fn with_auto_start(mut self, auto_start: bool) -> Self {
        self.auto_start = auto_start;
        self
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Debug-only fault-control seam. Normal clients always use the private bootstrap.
    pub fn with_acceptance_controls(
        mut self,
        enabled: bool,
        capability: Option<String>,
        hold_id: Option<String>,
    ) -> Self {
        if enabled && cfg!(debug_assertions) {
            self.auto_start = false;
            self.acceptance_capability_override = capability;
            self.acceptance_hold_id = hold_id;
        }
        self
    }

    pub fn execute(&self, request: &OrchestratorIpcRequest) -> OrchestratorIpcReceipt {
        self.execute_abortable(request, Arc::new(AtomicBool::new(false)))
    }

    pub fn execute_abortable(
        &self,
        request: &OrchestratorIpcRequest,
        cancelled: Arc<AtomicBool>,
    ) -> OrchestratorIpcReceipt {
        let mut result = self.execute_inner(request, &cancelled);
        if self.auto_start
            && request.method != "service.stop"
            && !cancelled.load(Ordering::Acquire)
            && matches!(result, Err("transport_closed" | "service_unavailable"))
        {
            // A crashed owner can disappear after discovery/connect but before
            // the framed reply. Every mutating method is idempotency-bound, so
            // one bounded reconnect is safe and closes this narrow race.
            std::thread::sleep(Duration::from_millis(20));
            let _ =
                super::super::orchestrator_service::OrchestratorServiceLifecycle::discover_or_start(
                    &self.state_root,
                );
            result = self.execute_inner(request, &cancelled);
        }
        match result {
            Ok(receipt) => receipt,
            Err(code) => OrchestratorIpcReceipt::failure(&request.request_id, code),
        }
    }

    fn execute_inner(
        &self,
        request: &OrchestratorIpcRequest,
        cancelled: &AtomicBool,
    ) -> std::result::Result<OrchestratorIpcReceipt, &'static str> {
        if !matches!(self.client_kind, "cli" | "desktop" | "codex-mcp") {
            return Err("invalid_request");
        }
        if self.state_root.exists() {
            validate_private_state_root(&self.state_root).map_err(|_| "private_local_state")?;
        }
        let discovery_file = discovery_path(&self.state_root);
        if discovery_file.exists() {
            validate_private_file(&discovery_file).map_err(|_| "private_local_state")?;
        }
        let capability_file = capability_bootstrap_path(&self.state_root);
        if capability_file.exists() {
            validate_private_file(&capability_file).map_err(|_| "private_local_state")?;
        }
        let mut discovery = read_discovery(&self.state_root).ok();
        if discovery.is_none() && self.auto_start {
            super::super::orchestrator_service::OrchestratorServiceLifecycle::discover_or_start(
                &self.state_root,
            )
            .map_err(|_| "service_unavailable")?;
            discovery = read_discovery(&self.state_root).ok();
        }
        let mut discovery = discovery.ok_or("service_unavailable")?;
        if !discovery.acceptance_mode {
            validate_private_file(&capability_file).map_err(|_| "private_local_state")?;
        }
        let mut endpoint = endpoint_from_discovery(&self.state_root, &discovery)
            .map_err(|_| "service_unavailable")?;
        if !endpoint.exists() {
            return Err("service_unavailable");
        }
        validate_private_endpoint(&endpoint).map_err(|_| "private_local_state")?;
        #[cfg(unix)]
        let mut stream = {
            use std::os::unix::net::UnixStream;
            match UnixStream::connect(&endpoint) {
                Ok(stream) => stream,
                Err(_) if self.auto_start => {
                    super::super::orchestrator_service::OrchestratorServiceLifecycle::discover_or_start(&self.state_root).map_err(|_| "service_unavailable")?;
                    discovery =
                        read_discovery(&self.state_root).map_err(|_| "service_unavailable")?;
                    endpoint = endpoint_from_discovery(&self.state_root, &discovery)
                        .map_err(|_| "service_unavailable")?;
                    if !endpoint.exists() {
                        return Err("service_unavailable");
                    }
                    validate_private_endpoint(&endpoint).map_err(|_| "private_local_state")?;
                    UnixStream::connect(&endpoint).map_err(|_| "service_unavailable")?
                }
                Err(_) => return Err("service_unavailable"),
            }
        };
        let automatic_capability;
        let capability = if discovery.acceptance_mode {
            self.acceptance_capability_override
                .as_deref()
                .ok_or("capability_missing")?
        } else {
            automatic_capability = read_private_bootstrap(&self.state_root)
                .map_err(|_| "capability_rejected")?
                .capability_for(&request.method)
                .ok_or("operation_forbidden")?
                .to_owned();
            automatic_capability.as_str()
        };
        #[cfg(unix)]
        {
            let io_poll = self.timeout.min(Duration::from_millis(25));
            let _ = stream.set_read_timeout(Some(io_poll));
            let _ = stream.set_write_timeout(Some(self.timeout));
            let handshake = Handshake {
                protocol_version: PROTOCOL_VERSION,
                client_kind: self.client_kind,
                connection_nonce: uuid::Uuid::new_v4().simple().to_string(),
                capability_handle: capability,
                acceptance_hold_id: discovery
                    .acceptance_mode
                    .then_some(self.acceptance_hold_id.as_deref())
                    .flatten(),
            };
            write_frame(
                &mut stream,
                &serde_json::to_vec(&handshake).map_err(|_| "invalid_request")?,
            )
            .map_err(|_| "transport_closed")?;
            write_frame(
                &mut stream,
                &serde_json::to_vec(request).map_err(|_| "invalid_request")?,
            )
            .map_err(|_| "transport_closed")?;
            let deadline = Instant::now() + self.timeout;
            let frame = match read_frame_abortable(&mut stream, deadline, cancelled) {
                Ok(frame) => frame,
                Err(code) => {
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                    return Err(code);
                }
            };
            serde_json::from_slice(&frame).map_err(|_| "transport_closed")
        }
        #[cfg(not(unix))]
        {
            let _ = (endpoint, capability, discovery);
            Err("service_unavailable")
        }
    }
}

#[cfg(unix)]
fn validate_private_state_root(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        return Err(anyhow!("private local state"));
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_private_state_root(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn validate_private_file(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o777 != 0o600
    {
        return Err(anyhow!("private local state"));
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_private_file(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn validate_private_endpoint(path: &Path) -> Result<()> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
    let metadata = std::fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket()
        || metadata.file_type().is_symlink()
        || metadata.uid() != effective_uid()
        || metadata.permissions().mode() & 0o777 != 0o600
    {
        return Err(anyhow!("private local state"));
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_private_endpoint(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn read_frame_abortable(
    reader: &mut std::os::unix::net::UnixStream,
    deadline: Instant,
    cancelled: &AtomicBool,
) -> std::result::Result<Vec<u8>, &'static str> {
    fn read_exact_polling(
        reader: &mut std::os::unix::net::UnixStream,
        target: &mut [u8],
        deadline: Instant,
        cancelled: &AtomicBool,
    ) -> std::result::Result<(), &'static str> {
        let mut offset = 0;
        while offset < target.len() {
            if cancelled.load(Ordering::Acquire) {
                return Err("request_cancelled");
            }
            if Instant::now() >= deadline {
                return Err("backend_timeout");
            }
            match reader.read(&mut target[offset..]) {
                Ok(0) => return Err("transport_closed"),
                Ok(count) => offset += count,
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => return Err("transport_closed"),
            }
        }
        Ok(())
    }

    let mut header = [0_u8; 4];
    read_exact_polling(reader, &mut header, deadline, cancelled)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_BYTES {
        return Err("transport_closed");
    }
    let mut payload = vec![0_u8; length];
    read_exact_polling(reader, &mut payload, deadline, cancelled)?;
    Ok(payload)
}

impl PrivateCapabilityBootstrap {
    fn capability_for(&self, method: &str) -> Option<&str> {
        if method == "service.stop" {
            Some(&self.lifecycle)
        } else if method == "service.status" {
            Some(&self.status_only)
        } else if method.starts_with("workflow.") || method.starts_with("policy.") {
            Some(&self.workflow)
        } else {
            None
        }
    }
}

pub(crate) fn discovery_path(state_root: &Path) -> PathBuf {
    state_root.join("orchestrator.discovery.json")
}
pub(crate) fn capability_bootstrap_path(state_root: &Path) -> PathBuf {
    state_root.join("orchestrator.capability")
}

pub(crate) fn read_discovery(state_root: &Path) -> Result<DiscoveryRecord> {
    let content =
        super::super::file_security::read_private_text_bounded(&discovery_path(state_root), 512)?
            .ok_or_else(|| anyhow!("service unavailable"))?;
    let record: DiscoveryRecord =
        serde_json::from_str(&content).map_err(|_| anyhow!("service unavailable"))?;
    if record.endpoint_generation.len() != 32
        || !record
            .endpoint_generation
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
        || record.service_instance_id.len() != 32
        || !record
            .service_instance_id
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
        || record.service_pid == 0
    {
        return Err(anyhow!("service unavailable"));
    }
    let endpoint = PathBuf::from(&record.endpoint_path);
    let expected =
        short_runtime_dir().join(format!("o-{}.sock", &record.endpoint_generation[..12]));
    if !endpoint.is_absolute() || endpoint != expected || record.endpoint_path.len() > 100 {
        return Err(anyhow!("service unavailable"));
    }
    Ok(record)
}

pub(crate) fn endpoint_from_discovery(
    state_root: &Path,
    record: &DiscoveryRecord,
) -> Result<PathBuf> {
    let _ = state_root;
    Ok(PathBuf::from(&record.endpoint_path))
}

pub(crate) fn short_runtime_dir() -> PathBuf {
    #[cfg(unix)]
    {
        PathBuf::from("/tmp").join(format!("licoup-orchestrator-{}", effective_uid()))
    }
    #[cfg(not(unix))]
    {
        std::env::temp_dir().join("licoup-orchestrator")
    }
}

#[cfg(unix)]
fn effective_uid() -> u32 {
    nix::unistd::Uid::effective().as_raw()
}

fn read_private_bootstrap(state_root: &Path) -> Result<PrivateCapabilityBootstrap> {
    let content = super::super::file_security::read_private_text_bounded(
        &capability_bootstrap_path(state_root),
        PRIVATE_BOOTSTRAP_MAX_BYTES,
    )?
    .ok_or_else(|| anyhow!("private bootstrap unavailable"))?;
    serde_json::from_str(&content).map_err(|_| anyhow!("private bootstrap unavailable"))
}

pub(crate) fn write_frame(writer: &mut impl Write, payload: &[u8]) -> Result<()> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(anyhow!("frame too large"));
    }
    let length = u32::try_from(payload.len()).map_err(|_| anyhow!("frame too large"))?;
    writer.write_all(&length.to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()?;
    Ok(())
}

pub(crate) fn read_frame(reader: &mut impl Read) -> Result<Vec<u8>> {
    let mut header = [0_u8; 4];
    reader.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length > MAX_FRAME_BYTES {
        return Err(anyhow!("frame too large"));
    }
    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload)?;
    Ok(payload)
}
