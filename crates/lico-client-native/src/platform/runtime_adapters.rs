use anyhow::{Result, anyhow};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs::{self, File, Metadata};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use super::{
    antigravity_driver, claude_code_driver, codex_app_server, copilot_driver, cursor_driver,
    hermes_driver, kilo_code_driver, kimi_code_driver, openclaw_driver, opencode_driver, pi_driver,
};

const RUNTIME_SCHEMA_VERSION: u32 = 3;
const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MIN_TIMEOUT_MS: u64 = 1_000;
const MAX_TIMEOUT_MS: u64 = 30 * 60 * 1_000;
const DEFAULT_MAX_STDOUT_BYTES: usize = 2 * 1024 * 1024;
const DEFAULT_MAX_STDERR_BYTES: usize = 512 * 1024;
const MAX_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
const DRIVER_INVENTORY_SCHEMA_VERSION: &str = "v0.0.1:client-agent-conversation-drivers-1";
const READINESS_SCHEMA_VERSION: &str = "v0.0.1:client-agent-conversation-readiness-1";
const CONVERSATION_PARITY_CONTRACT_VERSION: &str = "CL-06";
const MINIMUM_CONSECUTIVE_PASSES: usize = 3;
const DRIVER_INVENTORY_JSON: &str = include_str!("../../resources/agent-conversation-drivers.json");
const READINESS_JSON: &str = include_str!("../../resources/agent-conversation-readiness.json");
const CORE_CHECK_IDS: &[&str] = &[
    "P-01", "P-02", "P-03", "P-04", "P-05", "P-06", "P-07", "P-08", "P-09", "P-10",
];
const CONDITIONAL_CHECK_IDS: &[&str] = &["C-01", "C-02", "C-03", "C-04", "C-05", "C-06"];
const REQUIRED_EVIDENCE_BOOLEANS: &[&str] = &[
    "officialNativeLane",
    "releaseUiPassed",
    "cleanupPassed",
    "privacyPassed",
];
const REQUIRED_EVIDENCE_COUNTS: &[&str] = &["consecutivePasses"];
const REQUIRED_EVIDENCE_DIGESTS: &[&str] = &[
    "runtimeVersionDigest",
    "capabilitySnapshotDigest",
    "adapterManifestDigest",
    "releaseArtifactDigest",
    "releaseSidecarDigest",
    "productContinuityBindingDigest",
    "registryDigest",
    "driverInventoryDigest",
    "evidenceDigest",
];
const REQUIRED_EVIDENCE_BINDINGS: &[&str] = &[
    "agentId",
    "driverId",
    "runtimeProtocol",
    "harnessVersion",
    "runtimeVersionClass",
    "runtimeSourceClass",
];

/// Dispatch implementations must stay in one-to-one correspondence with the
/// canonical target-adapters packaging registry. This is implementation
/// dispatch, not a readiness claim; release readiness is reduced separately.
pub(crate) const PACKAGED_RUNTIME_ADAPTER_IDS: &[&str] = &[
    "openclaw",
    "claude-code",
    "codex",
    "antigravity",
    "opencode",
    "copilot",
    "kilo-code",
    "cursor",
    "hermes",
    "kimi-code",
    "pi",
];

#[derive(Clone, Debug)]
pub(crate) struct RuntimeDriverProfile {
    pub(crate) driver_status: String,
    pub(crate) readiness: String,
    pub(crate) protocol: String,
    pub(crate) blocker: Option<String>,
    pub(crate) runtime_version_digest: Option<String>,
    pub(crate) capability_matrix: Option<Value>,
    pub(crate) summary_codes: Vec<String>,
    pub(crate) consecutive_passes: usize,
    pub(crate) evidence_age_class: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DriverInventoryDocument {
    schema_version: String,
    contract_version: String,
    evidence_contract: DriverEvidenceContract,
    drivers: Vec<DriverInventoryEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DriverEvidenceContract {
    minimum_consecutive_passes: usize,
    core_checks: Vec<String>,
    conditional_checks: Vec<String>,
    required_booleans: Vec<String>,
    required_counts: Vec<String>,
    required_digests: Vec<String>,
    required_bindings: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DriverInventoryEntry {
    agent_id: String,
    driver_id: String,
    runtime_protocol: String,
    official_native_lane_kind: String,
    history_readable: bool,
    driver_mode: String,
    blocker_codes: Vec<String>,
    #[serde(default)]
    capability_matrix: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReadinessDocument {
    schema_version: String,
    contract_version: String,
    minimum_consecutive_passes: usize,
    summary: ReadinessSummary,
    adapters: Vec<ReadinessEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReadinessSummary {
    total: usize,
    ready: usize,
    partial: usize,
    failed: usize,
    blocked: usize,
    unverified: usize,
    history_only: usize,
    send_enabled: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReadinessEntry {
    agent_id: String,
    status: String,
    send_enabled: bool,
    official_native_lane_proven: bool,
    release_ui_passed: bool,
    cleanup_passed: bool,
    privacy_passed: bool,
    consecutive_passes: usize,
    core_checks: CoreReadinessCounts,
    conditional_checks: ConditionalReadinessCounts,
    evidence_binding: Option<ReadinessEvidenceBinding>,
    summary_codes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReadinessEvidenceBinding {
    agent_id: String,
    driver_id: String,
    runtime_protocol: String,
    harness_version: String,
    runtime_version_class: String,
    runtime_version_digest: String,
    capability_snapshot_digest: String,
    adapter_manifest_digest: String,
    release_artifact_digest: String,
    release_sidecar_digest: String,
    product_continuity_binding_digest: String,
    runtime_source_class: String,
    registry_digest: String,
    driver_inventory_digest: String,
    evidence_digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CoreReadinessCounts {
    required: usize,
    passed: usize,
    failed: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ConditionalReadinessCounts {
    total: usize,
    native_supported: usize,
    passed: usize,
    gaps: usize,
    failed: usize,
}

#[derive(Debug)]
struct RuntimeDriverRegistry {
    drivers: BTreeMap<String, DriverInventoryEntry>,
    readiness: BTreeMap<String, ReadinessEntry>,
}

static RUNTIME_DRIVER_REGISTRY: OnceLock<Option<RuntimeDriverRegistry>> = OnceLock::new();

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RuntimeAdapter {
    Antigravity,
    ClaudeCode,
    Codex,
    Copilot,
    Cursor,
    Hermes,
    KiloCode,
    KimiCode,
    OpenClaw,
    OpenCode,
    Pi,
}

#[derive(Clone, Debug, Default)]
struct NormalizedEffectiveSettings {
    cwd: Option<String>,
    model: Option<String>,
    reasoning_effort: Option<String>,
    permission_mode: Option<String>,
    mode: Option<String>,
    runtime_agent: Option<String>,
    allow_all: Option<bool>,
    sandbox: Option<Value>,
    approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
struct NormalizedFailure {
    code: String,
    message: String,
    stage: String,
    user_interaction_required: bool,
    request_method: Option<String>,
    session_id: Option<String>,
    thread_id: Option<String>,
    turn_id: Option<String>,
    turn_status: Option<String>,
}

#[derive(Debug)]
struct NormalizedExecution {
    ok: bool,
    output: String,
    events: Vec<Value>,
    capabilities: Value,
    error: Option<NormalizedFailure>,
    session_id: String,
    thread_id: String,
    turn_id: String,
    turn_status: String,
    effective: NormalizedEffectiveSettings,
    status_code: Option<i32>,
    stdout_truncated: bool,
    stderr_truncated: bool,
    started_at: String,
    runtime_protocol: &'static str,
    driver_id: &'static str,
}

pub fn send_message(params: &Value) -> Result<Value> {
    let agent_id = text_param(params, &["agent", "agentId", "target"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("agent message request requires an agent identifier"))?;
    let text = message_param(params, &["text", "message", "prompt"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("agent message request requires message text"))?;
    if text.len() > MAX_MESSAGE_BYTES {
        return Err(anyhow!("agent message request exceeds the input limit"));
    }
    let adapter = adapter_for_agent(&agent_id)
        .ok_or_else(|| anyhow!("unsupported runtime adapter: {}", agent_id))?;
    let session_id = text_param(params, &["sessionId", "nativeSessionId"]).unwrap_or_default();
    let cwd = text_param(params, &["cwd", "workingDirectory"])
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .or_else(|| env::current_dir().ok());
    let timeout_ms =
        u64_param(params, "timeoutMs", DEFAULT_TIMEOUT_MS).clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    let max_stdout = bounded_output_param(params, "maxStdoutBytes", DEFAULT_MAX_STDOUT_BYTES);
    let max_stderr = bounded_output_param(params, "maxStderrBytes", DEFAULT_MAX_STDERR_BYTES);
    let requested_executable = if adapter == RuntimeAdapter::Codex {
        codex_binary_param(params)
    } else {
        binary_param(params, adapter.default_binary())
    };
    let executable = verified_runtime_executable(adapter, &requested_executable)?;

    let execution = match adapter {
        RuntimeAdapter::Antigravity => normalize_antigravity(antigravity_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::ClaudeCode => normalize_claude(claude_code_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::Codex => normalize_codex(codex_app_server::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::Copilot => normalize_acp(
            adapter,
            copilot_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::Cursor => normalize_acp(
            adapter,
            cursor_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::KiloCode => normalize_acp(
            adapter,
            kilo_code_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::KimiCode => normalize_acp(
            adapter,
            kimi_code_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::Hermes => normalize_hermes(hermes_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::OpenClaw => normalize_openclaw(openclaw_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
        RuntimeAdapter::OpenCode => normalize_acp(
            adapter,
            opencode_driver::execute(
                &executable,
                params,
                &text,
                &session_id,
                cwd.as_deref(),
                timeout_ms,
                max_stdout,
                max_stderr,
            ),
        ),
        RuntimeAdapter::Pi => normalize_pi(pi_driver::execute(
            &executable,
            params,
            &text,
            &session_id,
            cwd.as_deref(),
            timeout_ms,
            max_stdout,
            max_stderr,
        )),
    };

    Ok(execution_response(adapter, execution))
}

pub(crate) fn runtime_driver_profile(target: &str) -> Option<RuntimeDriverProfile> {
    let adapter = adapter_for_agent(target)?;
    runtime_driver_registry()?.profile(adapter.id())
}

pub(crate) fn runtime_artifact_digest(executable: &Path) -> Option<String> {
    let mut file = File::open(executable).ok()?;
    let opened_before = file.metadata().ok()?;
    if !opened_before.is_file() {
        return None;
    }
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = loop {
            match file.read(&mut buffer) {
                Ok(read) => break read,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => return None,
            }
        };
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    let opened_after = file.metadata().ok()?;
    let current = File::open(executable).ok()?;
    let current_metadata = current.metadata().ok()?;
    if !same_runtime_artifact(&opened_before, &opened_after)
        || !same_runtime_artifact(&opened_after, &current_metadata)
    {
        return None;
    }
    Some(format!("sha256:{:x}", hasher.finalize()))
}

pub(crate) fn runtime_evidence_matches(target: &str, executable: &Path) -> bool {
    let Some(expected) = runtime_driver_profile(target)
        .filter(|profile| profile.readiness == "ready")
        .and_then(|profile| profile.runtime_version_digest)
    else {
        return false;
    };
    runtime_artifact_digest(executable).is_some_and(|actual| actual == expected)
}

fn verified_runtime_executable(adapter: RuntimeAdapter, requested: &str) -> Result<String> {
    let Some(profile) = runtime_driver_profile(adapter.id()) else {
        return Err(anyhow!("native agent runtime profile is unavailable"));
    };
    // Unverified drivers remain callable only by the explicit local acceptance
    // harness. Product surfaces fail closed before reaching this function. Once
    // an adapter is promoted, every launch must use the exact evidence-bound
    // artifact; PATH lookup and relative paths are no longer accepted.
    if profile.readiness != "ready" {
        return Ok(requested.to_string());
    }
    let requested_path = Path::new(requested);
    if !requested_path.is_absolute() {
        return Err(anyhow!(
            "native agent runtime evidence binding is unavailable"
        ));
    }
    let canonical = fs::canonicalize(requested_path)
        .map_err(|_| anyhow!("native agent runtime evidence binding is unavailable"))?;
    if !runtime_evidence_matches(adapter.id(), &canonical) {
        return Err(anyhow!(
            "native agent runtime evidence binding is unavailable"
        ));
    }
    canonical
        .to_str()
        .map(str::to_string)
        .ok_or_else(|| anyhow!("native agent runtime evidence binding is unavailable"))
}

#[cfg(unix)]
fn same_runtime_artifact(left: &Metadata, right: &Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.len() == right.len()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
}

#[cfg(not(unix))]
fn same_runtime_artifact(left: &Metadata, right: &Metadata) -> bool {
    left.len() == right.len()
        && left.modified().ok() == right.modified().ok()
        && left.permissions().readonly() == right.permissions().readonly()
}

fn runtime_driver_registry() -> Option<&'static RuntimeDriverRegistry> {
    RUNTIME_DRIVER_REGISTRY
        .get_or_init(|| parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, READINESS_JSON).ok())
        .as_ref()
}

fn parse_runtime_driver_registry(
    inventory_json: &str,
    readiness_json: &str,
) -> std::result::Result<RuntimeDriverRegistry, &'static str> {
    let inventory: DriverInventoryDocument =
        serde_json::from_str(inventory_json).map_err(|_| "driver_inventory_parse_failed")?;
    let readiness: ReadinessDocument =
        serde_json::from_str(readiness_json).map_err(|_| "readiness_parse_failed")?;

    validate_driver_contract(&inventory)?;
    validate_readiness_document(&readiness)?;

    let expected_ids = PACKAGED_RUNTIME_ADAPTER_IDS
        .iter()
        .map(|id| (*id).to_string())
        .collect::<BTreeSet<_>>();
    let mut drivers = BTreeMap::new();
    for driver in inventory.drivers {
        validate_driver_entry(&driver)?;
        let agent_id = driver.agent_id.clone();
        if drivers.insert(agent_id, driver).is_some() {
            return Err("driver_inventory_duplicate_agent");
        }
    }
    let mut readiness_by_agent = BTreeMap::new();
    for entry in readiness.adapters {
        validate_readiness_entry(&entry)?;
        let agent_id = entry.agent_id.clone();
        if readiness_by_agent.insert(agent_id, entry).is_some() {
            return Err("readiness_duplicate_agent");
        }
    }

    let driver_ids = drivers.keys().cloned().collect::<BTreeSet<_>>();
    let readiness_ids = readiness_by_agent.keys().cloned().collect::<BTreeSet<_>>();
    if driver_ids != expected_ids || readiness_ids != expected_ids || driver_ids != readiness_ids {
        return Err("runtime_driver_registry_set_drift");
    }

    for agent_id in &expected_ids {
        let driver = drivers
            .get(agent_id)
            .ok_or("runtime_driver_registry_set_drift")?;
        let state = readiness_by_agent
            .get(agent_id)
            .ok_or("runtime_driver_registry_set_drift")?;
        match driver.driver_mode.as_str() {
            "blocked" if state.status != "blocked" => {
                return Err("runtime_driver_registry_state_drift");
            }
            "history-only" if state.status != "history-only" => {
                return Err("runtime_driver_registry_state_drift");
            }
            "conversation" if state.status == "history-only" => {
                return Err("runtime_driver_registry_state_drift");
            }
            _ => {}
        }
        if driver.driver_mode == "blocked"
            && !driver
                .blocker_codes
                .iter()
                .any(|code| state.summary_codes.contains(code))
        {
            return Err("runtime_driver_registry_blocker_drift");
        }
        if let Some(binding) = state.evidence_binding.as_ref()
            && (binding.agent_id != driver.agent_id
                || binding.driver_id != driver.driver_id
                || binding.runtime_protocol != driver.runtime_protocol)
        {
            return Err("runtime_driver_registry_evidence_binding_drift");
        }
    }

    validate_readiness_summary(&readiness.summary, &readiness_by_agent)?;
    Ok(RuntimeDriverRegistry {
        drivers,
        readiness: readiness_by_agent,
    })
}

fn validate_driver_contract(
    inventory: &DriverInventoryDocument,
) -> std::result::Result<(), &'static str> {
    let contract = &inventory.evidence_contract;
    if inventory.schema_version != DRIVER_INVENTORY_SCHEMA_VERSION
        || inventory.contract_version != CONVERSATION_PARITY_CONTRACT_VERSION
        || contract.minimum_consecutive_passes != MINIMUM_CONSECUTIVE_PASSES
        || !strings_match(&contract.core_checks, CORE_CHECK_IDS)
        || !strings_match(&contract.conditional_checks, CONDITIONAL_CHECK_IDS)
        || !strings_match(&contract.required_booleans, REQUIRED_EVIDENCE_BOOLEANS)
        || !strings_match(&contract.required_counts, REQUIRED_EVIDENCE_COUNTS)
        || !strings_match(&contract.required_digests, REQUIRED_EVIDENCE_DIGESTS)
        || !strings_match(&contract.required_bindings, REQUIRED_EVIDENCE_BINDINGS)
    {
        return Err("driver_inventory_contract_invalid");
    }
    Ok(())
}

fn validate_driver_entry(driver: &DriverInventoryEntry) -> std::result::Result<(), &'static str> {
    let Some(adapter) = adapter_for_agent(&driver.agent_id) else {
        return Err("driver_inventory_unknown_agent");
    };
    let mode_valid = matches!(
        driver.driver_mode.as_str(),
        "conversation" | "blocked" | "history-only"
    );
    let blockers_valid = driver
        .blocker_codes
        .iter()
        .all(|code| is_sanitized_code(code));
    if adapter.id() != driver.agent_id
        || adapter.driver_id() != driver.driver_id
        || driver.runtime_protocol != adapter.runtime_protocol()
        || !is_sanitized_code(&driver.driver_id)
        || !is_sanitized_code(&driver.runtime_protocol)
        || !is_sanitized_code(&driver.official_native_lane_kind)
        || !mode_valid
        || !blockers_valid
        || (driver.driver_mode == "blocked" && driver.blocker_codes.is_empty())
        || (driver.driver_mode != "blocked" && !driver.blocker_codes.is_empty())
        || (driver.driver_mode != "blocked" && driver.official_native_lane_kind == "unavailable")
        || (driver.driver_mode == "history-only" && !driver.history_readable)
    {
        return Err("driver_inventory_entry_invalid");
    }
    Ok(())
}

fn validate_readiness_document(
    readiness: &ReadinessDocument,
) -> std::result::Result<(), &'static str> {
    if readiness.schema_version != READINESS_SCHEMA_VERSION
        || readiness.contract_version != CONVERSATION_PARITY_CONTRACT_VERSION
        || readiness.minimum_consecutive_passes != MINIMUM_CONSECUTIVE_PASSES
    {
        return Err("readiness_contract_invalid");
    }
    Ok(())
}

fn validate_readiness_entry(entry: &ReadinessEntry) -> std::result::Result<(), &'static str> {
    let status_valid = matches!(
        entry.status.as_str(),
        "ready" | "partial" | "failed" | "blocked" | "unverified" | "history-only"
    );
    let core = &entry.core_checks;
    let conditional = &entry.conditional_checks;
    let counts_valid = core.required == CORE_CHECK_IDS.len()
        && core.passed <= core.required
        && core.failed <= core.required
        && core.passed + core.failed <= core.required
        && conditional.total == CONDITIONAL_CHECK_IDS.len()
        && conditional.native_supported <= conditional.total
        && conditional.passed <= conditional.native_supported
        && conditional.gaps <= conditional.native_supported
        && conditional.failed <= conditional.native_supported
        && conditional.passed + conditional.gaps + conditional.failed
            <= conditional.native_supported;
    if !status_valid
        || entry.send_enabled != (entry.status == "ready")
        || entry.summary_codes.is_empty()
        || !entry
            .summary_codes
            .iter()
            .all(|code| is_sanitized_code(code))
        || !counts_valid
    {
        return Err("readiness_entry_invalid");
    }
    if entry.status == "ready"
        && (!entry.official_native_lane_proven
            || !entry.release_ui_passed
            || !entry.cleanup_passed
            || !entry.privacy_passed
            || entry.consecutive_passes < MINIMUM_CONSECUTIVE_PASSES
            || core.passed != core.required
            || core.failed != 0
            || conditional.passed != conditional.native_supported
            || conditional.gaps != 0
            || conditional.failed != 0
            || !entry
                .summary_codes
                .iter()
                .any(|code| code == "all_required_evidence_passed"))
    {
        return Err("readiness_ready_evidence_invalid");
    }
    if let Some(binding) = entry.evidence_binding.as_ref() {
        if !is_sanitized_code(&binding.driver_id)
            || !is_sanitized_code(&binding.runtime_protocol)
            || !is_sanitized_code(&binding.harness_version)
            || !is_sanitized_code(&binding.runtime_version_class)
            || !is_sanitized_code(&binding.runtime_source_class)
            || !is_sha256_digest(&binding.runtime_version_digest)
            || !is_sha256_digest(&binding.capability_snapshot_digest)
            || !is_sha256_digest(&binding.adapter_manifest_digest)
            || !is_sha256_digest(&binding.release_artifact_digest)
            || !is_sha256_digest(&binding.release_sidecar_digest)
            || !is_sha256_digest(&binding.product_continuity_binding_digest)
            || !is_sha256_digest(&binding.registry_digest)
            || !is_sha256_digest(&binding.driver_inventory_digest)
            || !is_sha256_digest(&binding.evidence_digest)
        {
            return Err("readiness_evidence_binding_invalid");
        }
    } else if entry.status == "ready" {
        return Err("readiness_ready_binding_missing");
    }
    Ok(())
}

fn validate_readiness_summary(
    summary: &ReadinessSummary,
    entries: &BTreeMap<String, ReadinessEntry>,
) -> std::result::Result<(), &'static str> {
    let count = |status: &str| {
        entries
            .values()
            .filter(|entry| entry.status == status)
            .count()
    };
    if summary.total != entries.len()
        || summary.ready != count("ready")
        || summary.partial != count("partial")
        || summary.failed != count("failed")
        || summary.blocked != count("blocked")
        || summary.unverified != count("unverified")
        || summary.history_only != count("history-only")
        || summary.send_enabled != entries.values().filter(|entry| entry.send_enabled).count()
    {
        return Err("readiness_summary_invalid");
    }
    Ok(())
}

fn strings_match(actual: &[String], expected: &[&str]) -> bool {
    actual
        .iter()
        .map(String::as_str)
        .eq(expected.iter().copied())
}

fn is_sanitized_code(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || b"._:+-".contains(&byte)
        })
}

fn is_sha256_digest(value: &str) -> bool {
    value.len() == 71
        && value.starts_with("sha256:")
        && value[7..]
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn driver_status_for_mode(mode: &str) -> Option<&'static str> {
    match mode {
        "conversation" => Some("implemented"),
        "blocked" => Some("blocked"),
        "history-only" => Some("history-only"),
        _ => None,
    }
}

impl RuntimeDriverRegistry {
    fn profile(&self, agent_id: &str) -> Option<RuntimeDriverProfile> {
        let driver = self.drivers.get(agent_id)?;
        let readiness = self.readiness.get(agent_id)?;
        let blocker = if driver.driver_mode == "blocked" {
            driver.blocker_codes.first().cloned()
        } else {
            None
        };
        let evidence_age_class = if readiness.evidence_binding.is_some() {
            "current".to_string()
        } else if readiness
            .summary_codes
            .iter()
            .any(|code| code == "evidence_stale_or_incomplete")
        {
            "stale".to_string()
        } else if readiness
            .summary_codes
            .iter()
            .any(|code| code == "evidence_missing" || code == "evidence_incomplete")
        {
            "missing".to_string()
        } else {
            "absent".to_string()
        };
        Some(RuntimeDriverProfile {
            driver_status: driver_status_for_mode(&driver.driver_mode)?.to_string(),
            readiness: readiness.status.clone(),
            protocol: driver.runtime_protocol.clone(),
            blocker,
            runtime_version_digest: readiness
                .evidence_binding
                .as_ref()
                .map(|binding| binding.runtime_version_digest.clone()),
            capability_matrix: driver.capability_matrix.clone(),
            summary_codes: readiness.summary_codes.clone(),
            consecutive_passes: readiness.consecutive_passes,
            evidence_age_class,
        })
    }
}

/// Probes only the official fixed-argument entrypoint and emits redacted
/// booleans. No command output, paths, account data, or runtime content escapes.
pub(crate) fn probe_runtime_driver(target: &str, executable: &Path, cwd: &Path) -> Value {
    let executable = executable.to_string_lossy();
    let Some(adapter) = adapter_for_agent(target) else {
        return json!({"available": false, "supported": false, "errorCode": "unknown_adapter"});
    };
    match adapter {
        RuntimeAdapter::Antigravity => {
            let probe = antigravity_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "stdinPrompt": probe.stdin_prompt,
                "structuredStream": probe.structured_stream,
                "newSession": probe.new_session,
                "resumeSession": probe.resume_session,
                "interactiveApprovalEvents": probe.interactive_approval_events,
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::ClaudeCode => {
            let probe = claude_code_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.available,
                "stdinPrompt": probe.stdin_prompt,
                "structuredStream": probe.structured_stream,
                "newSession": probe.new_session,
                "resumeSession": probe.resume_session,
                "model": probe.model,
                "reasoningEffort": probe.reasoning_effort,
                "permissionMode": probe.permission_mode,
                "interactiveApprovalEvents": probe.interactive_approval_events
            })
        }
        RuntimeAdapter::Codex => json!({
            "available": executable.as_ref() != "",
            "supported": true,
            "stdinPrompt": true,
            "structuredStream": true,
            "newSession": true,
            "resumeSession": true,
            "interactiveApprovalEvents": false
        }),
        RuntimeAdapter::Copilot => probe_acp_runtime(copilot_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            64 * 1024,
            16 * 1024,
        )),
        RuntimeAdapter::Cursor => probe_acp_runtime(cursor_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            64 * 1024,
            16 * 1024,
        )),
        RuntimeAdapter::Hermes => {
            let probe = hermes_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supports_streaming,
                "tools": probe.supports_tools,
                "approvals": probe.supports_approvals,
                "modelOverride": probe.supports_model_override,
                "reasoningOverride": probe.supports_reasoning_override,
                "versionDetected": probe.version.is_some(),
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::KiloCode => probe_acp_runtime(kilo_code_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            64 * 1024,
            16 * 1024,
        )),
        RuntimeAdapter::KimiCode => probe_acp_runtime(kimi_code_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            64 * 1024,
            16 * 1024,
        )),
        RuntimeAdapter::OpenClaw => {
            let probe = openclaw_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supports_streaming,
                "tools": probe.supports_tools,
                "approvals": probe.supports_approvals,
                "reasoning": probe.supports_reasoning,
                "modelOverride": probe.supports_model_override,
                "versionDetected": probe.version.is_some(),
                "errorCode": probe.error_code
            })
        }
        RuntimeAdapter::OpenCode => probe_acp_runtime(opencode_driver::capability_probe(
            &executable,
            cwd,
            2_000,
            64 * 1024,
            16 * 1024,
        )),
        RuntimeAdapter::Pi => {
            let probe = pi_driver::probe(&executable, 2_000, 64 * 1024);
            json!({
                "available": probe.available,
                "supported": probe.supported,
                "newSession": probe.supported,
                "resumeSession": probe.supported,
                "structuredStream": probe.supported,
                "versionCommandOk": probe.version_command_ok,
                "helpCommandOk": probe.help_command_ok,
                "errorCode": probe.error_code
            })
        }
    }
}

fn probe_acp_runtime(
    result: std::result::Result<opencode_driver::CapabilityProbe, opencode_driver::ProtocolFailure>,
) -> Value {
    match result {
        Ok(probe) => json!({
            "available": true,
            "supported": probe.protocol_version == Some(1),
            "protocolVersion": probe.protocol_version,
            "loadSession": probe.load_session,
            "resumeSession": probe.resume_session,
            "closeSession": probe.close_session,
            "listSessions": probe.list_sessions,
            "deleteSession": probe.delete_session,
            "imagePrompts": probe.image_prompts,
            "audioPrompts": probe.audio_prompts,
            "embeddedContext": probe.embedded_context
        }),
        Err(failure) => json!({
            "available": false,
            "supported": false,
            "errorCode": failure.code
        }),
    }
}

fn execution_response(adapter: RuntimeAdapter, execution: NormalizedExecution) -> Value {
    debug_assert_eq!(execution.driver_id, adapter.driver_id());
    let native_session_id = if adapter == RuntimeAdapter::Codex {
        execution.thread_id.clone()
    } else {
        execution.session_id.clone()
    };
    let error = execution.error.as_ref().map(|failure| {
        json!({
            "code": failure.code,
            "message": failure.message,
            "stage": failure.stage,
            "userInteractionRequired": failure.user_interaction_required,
            "requestMethod": failure.request_method,
            "sessionId": failure.session_id,
            "threadId": failure.thread_id,
            "turnId": failure.turn_id,
            "turnStatus": failure.turn_status
        })
    });
    let stderr = execution
        .error
        .as_ref()
        .map(|failure| failure.message.clone())
        .unwrap_or_default();
    let effective = json!({
        "cwd": execution.effective.cwd,
        "model": execution.effective.model,
        "reasoningEffort": execution.effective.reasoning_effort,
        "permissionMode": execution.effective.permission_mode,
        "mode": execution.effective.mode,
        "runtimeAgent": execution.effective.runtime_agent,
        "allowAll": execution.effective.allow_all,
        "sandbox": execution.effective.sandbox,
        "approvalPolicy": execution.effective.approval_policy
    });
    json!({
        "ok": execution.ok,
        "schemaVersion": RUNTIME_SCHEMA_VERSION,
        "mode": "runtime-adapter",
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "driverId": adapter.driver_id(),
        "runtimeProtocol": execution.runtime_protocol,
        "agentId": adapter.id(),
        "nativeSessionId": native_session_id,
        "sessionId": native_session_id,
        "threadId": execution.thread_id,
        "turnId": execution.turn_id,
        "turnStatus": execution.turn_status,
        "statusCode": execution.status_code,
        "output": execution.output,
        // Child stderr is never returned. This field preserves the old client
        // contract while containing only the driver's fixed sanitized message.
        "stderr": stderr,
        "error": error,
        "events": execution.events,
        "capabilities": execution.capabilities,
        "stdoutTruncated": execution.stdout_truncated,
        "stderrTruncated": execution.stderr_truncated,
        "startedAt": execution.started_at,
        "completedAt": timestamp(),
        "cwd": effective["cwd"],
        "workingDirectory": effective["cwd"],
        "model": effective["model"],
        "reasoningEffort": effective["reasoningEffort"],
        "permissionMode": effective["permissionMode"],
        "sandbox": effective["sandbox"],
        "approvalPolicy": effective["approvalPolicy"],
        "effective": effective,
        "planner": false,
        "clientOwnedToolLoop": false,
        "approvalOwner": "user"
    })
}

fn normalize_codex(execution: codex_app_server::RunResult) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: execution.events,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false
        }),
        error: execution.error.map(|failure| NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id: failure.thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: codex_app_server::RUNTIME_PROTOCOL,
        driver_id: "codex-app-server",
    }
}

fn normalize_antigravity(execution: antigravity_driver::RunResult) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: Vec::new(),
        capabilities: json!({
            "newSession": false,
            "resumeSession": false,
            "structuredEvents": false,
            "interactiveApprovalBridge": false,
            "messageSend": false,
            "blocker": "antigravity_cli_structured_transport_unavailable"
        }),
        error: execution.error.map(|failure| NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id: failure.thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: antigravity_driver::RUNTIME_PROTOCOL,
        driver_id: "antigravity-cli",
    }
}

fn normalize_claude(execution: claude_code_driver::RunResult) -> NormalizedExecution {
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: execution.events,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "interactiveApprovalBridge": false,
            "processLocalContinuation": true
        }),
        error: execution.error.map(|failure| NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id: failure.thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: claude_code_driver::RUNTIME_PROTOCOL,
        driver_id: "claude-code-stream-json",
    }
}

fn normalize_acp(
    adapter: RuntimeAdapter,
    execution: opencode_driver::RunResult,
) -> NormalizedExecution {
    debug_assert_eq!(execution.driver_id, adapter.driver_id());
    let capabilities = json!({
        "protocolVersion": execution.capabilities.protocol_version,
        "loadSession": execution.capabilities.load_session,
        "resumeSession": execution.capabilities.resume_session,
        "closeSession": execution.capabilities.close_session,
        "listSessions": execution.capabilities.list_sessions,
        "deleteSession": execution.capabilities.delete_session,
        "imagePrompts": execution.capabilities.image_prompts,
        "audioPrompts": execution.capabilities.audio_prompts,
        "embeddedContext": execution.capabilities.embedded_context
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: execution.events,
        capabilities,
        error: execution.error.map(|failure| NormalizedFailure {
            code: failure.code,
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id: failure.thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }),
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            mode: execution.effective.mode,
            runtime_agent: execution.effective.runtime_agent,
            allow_all: execution.effective.allow_all,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: execution.runtime_protocol,
        // The shared ACP engine reports the canonical driver identity from the
        // inventory. Keep the public response bound to that same identity,
        // which is deliberately distinct from the packaged agent id.
        driver_id: adapter.driver_id(),
    }
}

fn normalize_openclaw(execution: openclaw_driver::RunResult) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: execution.events,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "reasoning": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": false
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: openclaw_driver::RUNTIME_PROTOCOL,
        driver_id: "openclaw-acp",
    }
}

fn normalize_hermes(execution: hermes_driver::RunResult) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: execution.events,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": true,
            "reasoningOverride": false
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: hermes_driver::RUNTIME_PROTOCOL,
        driver_id: "hermes-acp",
    }
}

fn normalize_pi(execution: pi_driver::RunResult) -> NormalizedExecution {
    let error = execution.error.map(|failure| {
        let thread_id = failure.session_id.clone();
        NormalizedFailure {
            code: failure.code.to_string(),
            message: failure.message.to_string(),
            stage: failure.stage.to_string(),
            user_interaction_required: failure.user_interaction_required,
            request_method: failure.request_method,
            session_id: failure.session_id,
            thread_id,
            turn_id: failure.turn_id,
            turn_status: failure.turn_status,
        }
    });
    NormalizedExecution {
        ok: execution.ok,
        output: execution.output,
        events: execution.events,
        capabilities: json!({
            "newSession": true,
            "resumeSession": true,
            "structuredEvents": true,
            "tools": true,
            "interactiveApprovalBridge": false,
            "modelOverride": true,
            "reasoningOverride": true
        }),
        error,
        session_id: execution.session_id,
        thread_id: execution.thread_id,
        turn_id: execution.turn_id,
        turn_status: execution.turn_status,
        effective: NormalizedEffectiveSettings {
            cwd: execution.effective.cwd,
            model: execution.effective.model,
            reasoning_effort: execution.effective.reasoning_effort,
            permission_mode: execution.effective.permission_mode,
            sandbox: execution.effective.sandbox,
            approval_policy: execution.effective.approval_policy,
            ..NormalizedEffectiveSettings::default()
        },
        status_code: execution.status_code,
        stdout_truncated: execution.stdout_truncated,
        stderr_truncated: execution.stderr_truncated,
        started_at: execution.started_at,
        runtime_protocol: pi_driver::RUNTIME_PROTOCOL,
        driver_id: "pi-rpc",
    }
}

pub(crate) fn inventory_capability_matrix(agent_id: &str) -> Option<Value> {
    let adapter = adapter_for_agent(agent_id)?;
    runtime_driver_registry()?
        .drivers
        .get(adapter.id())
        .and_then(|entry| entry.capability_matrix.clone())
}

pub(crate) fn adapter_for_agent_public(agent_id: &str) -> Option<RuntimeAdapter> {
    adapter_for_agent(agent_id)
}

pub(crate) fn text_param_public(params: &Value, keys: &[&str]) -> Option<String> {
    text_param(params, keys)
}

fn adapter_for_agent(agent_id: &str) -> Option<RuntimeAdapter> {
    match agent_id {
        "antigravity" => Some(RuntimeAdapter::Antigravity),
        "claude" | "claude-code" => Some(RuntimeAdapter::ClaudeCode),
        "codex" => Some(RuntimeAdapter::Codex),
        "copilot" | "github-copilot" => Some(RuntimeAdapter::Copilot),
        "cursor" | "cursor-agent" => Some(RuntimeAdapter::Cursor),
        "hermes" | "hermes-agent" => Some(RuntimeAdapter::Hermes),
        "kilo" | "kilocode" | "kilo-code" => Some(RuntimeAdapter::KiloCode),
        "kimi-code" | "kimicode" => Some(RuntimeAdapter::KimiCode),
        "openclaw" => Some(RuntimeAdapter::OpenClaw),
        "opencode" => Some(RuntimeAdapter::OpenCode),
        "pi" | "pi-agent" | "pi-coding-agent" => Some(RuntimeAdapter::Pi),
        _ => None,
    }
}

impl RuntimeAdapter {
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity",
            Self::ClaudeCode => "claude-code",
            Self::Codex => "codex",
            Self::Copilot => "copilot",
            Self::Cursor => "cursor",
            Self::Hermes => "hermes",
            Self::KiloCode => "kilo-code",
            Self::KimiCode => "kimi-code",
            Self::OpenClaw => "openclaw",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Antigravity => "Antigravity - CLI",
            Self::ClaudeCode => "Claude Code - CLI",
            Self::Codex => "ChatGPT - Desktop",
            Self::Copilot => "GitHub Copilot - CLI",
            Self::Cursor => "Cursor - IDE",
            Self::Hermes => "Hermes Agent - CLI",
            Self::KiloCode => "Kilo Code - CLI",
            Self::KimiCode => "Kimi Code - CLI",
            Self::OpenClaw => "OpenClaw - CLI",
            Self::OpenCode => "OpenCode - CLI",
            Self::Pi => "Pi Agent - CLI",
        }
    }

    pub(crate) fn driver_id(self) -> &'static str {
        match self {
            Self::Antigravity => "antigravity-cli",
            Self::ClaudeCode => "claude-code-stream-json",
            Self::Codex => "codex-app-server",
            Self::Copilot => "copilot-acp",
            Self::Cursor => "cursor-acp",
            Self::Hermes => "hermes-acp",
            Self::KiloCode => "kilo-code-serve",
            Self::KimiCode => "kimi-code-acp",
            Self::OpenClaw => "openclaw-acp",
            Self::OpenCode => "opencode-serve",
            Self::Pi => "pi-rpc",
        }
    }

    pub(crate) fn runtime_protocol(self) -> &'static str {
        match self {
            Self::Antigravity => antigravity_driver::RUNTIME_PROTOCOL,
            Self::ClaudeCode => claude_code_driver::RUNTIME_PROTOCOL,
            Self::Codex => codex_app_server::RUNTIME_PROTOCOL,
            Self::Copilot => copilot_driver::RUNTIME_PROTOCOL,
            Self::Cursor => cursor_driver::RUNTIME_PROTOCOL,
            Self::Hermes => hermes_driver::RUNTIME_PROTOCOL,
            Self::KiloCode => kilo_code_driver::RUNTIME_PROTOCOL,
            Self::KimiCode => kimi_code_driver::RUNTIME_PROTOCOL,
            Self::OpenClaw => openclaw_driver::RUNTIME_PROTOCOL,
            Self::OpenCode => opencode_driver::RUNTIME_PROTOCOL,
            Self::Pi => pi_driver::RUNTIME_PROTOCOL,
        }
    }

    fn default_binary(self) -> &'static str {
        match self {
            Self::Antigravity => "agy",
            Self::ClaudeCode => "claude",
            Self::Codex => "codex",
            Self::Copilot => "copilot",
            Self::Cursor => "cursor-agent",
            Self::Hermes => "hermes",
            Self::KiloCode => "kilo",
            Self::KimiCode => "kimi",
            Self::OpenClaw => "openclaw",
            Self::OpenCode => "opencode",
            Self::Pi => "pi",
        }
    }
}

fn binary_param(params: &Value, fallback: &str) -> String {
    text_param(params, &["binary", "binaryPath", "executable"])
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| fallback.to_string())
}

fn codex_binary_param(params: &Value) -> String {
    if let Some(binary) = text_param(params, &["binary", "binaryPath", "executable"])
        .filter(|value| !value.is_empty())
    {
        return binary;
    }
    if let Ok(binary) = env::var("CODEX_CLI_PATH")
        && !binary.trim().is_empty()
    {
        return binary;
    }
    if cfg!(windows)
        && let Ok(profile) = env::var("USERPROFILE")
    {
        let candidate = Path::new(&profile)
            .join(".codex")
            .join(".sandbox-bin")
            .join("codex.exe");
        if candidate.is_file() {
            return candidate.to_string_lossy().to_string();
        }
    }
    "codex".to_string()
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

fn message_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(str::to_string)
}

fn u64_param(params: &Value, key: &str, fallback: u64) -> u64 {
    params
        .get(key)
        .and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|text| text.trim().parse().ok()))
        })
        .unwrap_or(fallback)
}

fn bounded_output_param(params: &Value, key: &str, fallback: usize) -> usize {
    usize::try_from(u64_param(params, key, fallback as u64))
        .unwrap_or(MAX_OUTPUT_BYTES)
        .clamp(1, MAX_OUTPUT_BYTES)
}

fn timestamp() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    millis.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packaged_dispatch_ids_are_unique_and_complete() {
        let unique = PACKAGED_RUNTIME_ADAPTER_IDS
            .iter()
            .copied()
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(unique.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());
        for id in PACKAGED_RUNTIME_ADAPTER_IDS {
            assert_eq!(adapter_for_agent(id).map(RuntimeAdapter::id), Some(*id));
            assert!(runtime_driver_profile(id).is_some());
        }
    }

    #[test]
    fn canonical_resources_are_the_only_runtime_profile_source() {
        let registry =
            parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, READINESS_JSON).unwrap();
        assert_eq!(registry.drivers.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());
        assert_eq!(registry.readiness.len(), PACKAGED_RUNTIME_ADAPTER_IDS.len());

        let opencode = registry.profile("opencode").unwrap();
        assert_eq!(opencode.driver_status, "implemented");
        assert_eq!(opencode.readiness, "unverified");
        assert_eq!(opencode.protocol, opencode_driver::RUNTIME_PROTOCOL);
        assert_eq!(opencode.blocker, None);
        assert_eq!(opencode.evidence_age_class, "missing");
        assert!(
            opencode
                .summary_codes
                .contains(&"evidence_missing".to_string())
        );
        assert_eq!(
            opencode
                .capability_matrix
                .as_ref()
                .and_then(|matrix| matrix.get("laneFamily"))
                .and_then(Value::as_str),
            Some("serve-http")
        );

        let antigravity = registry.profile("antigravity").unwrap();
        assert_eq!(antigravity.driver_status, "blocked");
        assert_eq!(antigravity.readiness, "blocked");
        assert_eq!(
            antigravity.blocker.as_deref(),
            Some("antigravity_cli_structured_transport_unavailable")
        );
        assert_eq!(
            antigravity
                .capability_matrix
                .as_ref()
                .and_then(|matrix| matrix.get("laneFamily"))
                .and_then(Value::as_str),
            Some("unavailable")
        );
        assert!(registry.readiness.values().all(|entry| !entry.send_enabled));

        let cursor = registry.profile("cursor").unwrap();
        assert_eq!(cursor.driver_status, "blocked");
        assert_eq!(cursor.blocker.as_deref(), Some("safe_cleanup_unavailable"));
    }

    #[test]
    fn malformed_or_set_drifted_resources_fail_closed() {
        assert!(parse_runtime_driver_registry("{}", READINESS_JSON).is_err());
        assert!(parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, "{}").is_err());

        let mut inventory = serde_json::from_str::<Value>(DRIVER_INVENTORY_JSON).unwrap();
        inventory["drivers"].as_array_mut().unwrap().pop();
        let drifted_inventory = serde_json::to_string(&inventory).unwrap();
        assert!(parse_runtime_driver_registry(&drifted_inventory, READINESS_JSON).is_err());

        let mut readiness = serde_json::from_str::<Value>(READINESS_JSON).unwrap();
        readiness["adapters"].as_array_mut().unwrap().pop();
        let drifted_readiness = serde_json::to_string(&readiness).unwrap();
        assert!(parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, &drifted_readiness).is_err());
    }

    #[test]
    fn protocol_drift_and_incomplete_ready_claims_fail_closed() {
        let mut inventory = serde_json::from_str::<Value>(DRIVER_INVENTORY_JSON).unwrap();
        inventory["drivers"][0]["runtimeProtocol"] = json!("drifted-protocol");
        let drifted_inventory = serde_json::to_string(&inventory).unwrap();
        assert!(parse_runtime_driver_registry(&drifted_inventory, READINESS_JSON).is_err());

        let mut readiness = serde_json::from_str::<Value>(READINESS_JSON).unwrap();
        let codex = readiness["adapters"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|entry| entry["agentId"] == "codex")
            .unwrap();
        codex["status"] = json!("ready");
        codex["sendEnabled"] = json!(true);
        let invalid_ready = serde_json::to_string(&readiness).unwrap();
        let profile = parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, &invalid_ready)
            .ok()
            .and_then(|registry| registry.profile("codex"));
        assert!(profile.is_none());
    }

    #[test]
    fn adapter_aliases_resolve_to_canonical_ids() {
        assert_eq!(
            adapter_for_agent("claude").map(RuntimeAdapter::id),
            Some("claude-code")
        );
        assert_eq!(
            adapter_for_agent("github-copilot").map(RuntimeAdapter::id),
            Some("copilot")
        );
        assert_eq!(
            adapter_for_agent("kilocode").map(RuntimeAdapter::id),
            Some("kilo-code")
        );
        assert_eq!(
            adapter_for_agent("cursor-agent").map(RuntimeAdapter::id),
            Some("cursor")
        );
    }

    #[test]
    fn message_body_is_not_normalized() {
        let body = "\n  indented code  \n";
        assert_eq!(
            message_param(&json!({"text": body}), &["text"]),
            Some(body.to_string())
        );
    }

    #[test]
    fn oversized_message_is_rejected_before_runtime_launch() {
        let oversized = "x".repeat(MAX_MESSAGE_BYTES + 1);
        let error = send_message(&json!({
            "agent": "codex",
            "text": oversized,
            "binaryPath": "/runtime/must-not-launch"
        }))
        .unwrap_err();

        assert_eq!(
            error.to_string(),
            "agent message request exceeds the input limit"
        );
    }

    #[test]
    fn runtime_artifact_digest_tracks_the_opened_file_identity_and_content() {
        let root = std::env::temp_dir().join(format!(
            "lico-runtime-artifact-{}-{}",
            std::process::id(),
            timestamp()
        ));
        fs::create_dir_all(&root).unwrap();
        let executable = root.join("runtime-canary");
        fs::write(&executable, b"accepted-runtime").unwrap();
        let first = runtime_artifact_digest(&executable).unwrap();
        fs::write(&executable, b"different-runtime").unwrap();
        let second = runtime_artifact_digest(&executable).unwrap();
        let _ = fs::remove_dir_all(root);

        assert!(first.starts_with("sha256:"));
        assert_ne!(first, second);
    }

    #[test]
    fn codex_response_uses_the_canonical_shape() {
        let response = execution_response(
            RuntimeAdapter::Codex,
            normalize_codex(codex_app_server::RunResult {
                ok: true,
                output: "answer".to_string(),
                events: Vec::new(),
                error: None,
                session_id: "session-1".to_string(),
                thread_id: "thread-1".to_string(),
                turn_id: "turn-1".to_string(),
                turn_status: "completed".to_string(),
                effective: codex_app_server::EffectiveSettings {
                    cwd: Some("/workspace/project".to_string()),
                    model: Some("model-1".to_string()),
                    reasoning_effort: Some("high".to_string()),
                    sandbox: Some(json!({"type": "workspaceWrite"})),
                    approval_policy: Some(json!("on-request")),
                },
                status_code: None,
                stdout_truncated: false,
                stderr_truncated: false,
                started_at: "1".to_string(),
            }),
        );

        assert_eq!(response["schemaVersion"], RUNTIME_SCHEMA_VERSION);
        assert_eq!(response["driverId"], "codex-app-server");
        assert_eq!(
            response["runtimeProtocol"],
            codex_app_server::RUNTIME_PROTOCOL
        );
        assert_eq!(response["threadId"], "thread-1");
        assert_eq!(response["nativeSessionId"], "thread-1");
        assert_eq!(response["sessionId"], "thread-1");
        assert_eq!(response["effective"]["model"], "model-1");
        assert_eq!(response["approvalOwner"], "user");
    }

    #[test]
    fn non_codex_response_uses_session_id_as_native_continuity_id() {
        let response = execution_response(
            RuntimeAdapter::OpenCode,
            NormalizedExecution {
                ok: true,
                output: "answer".to_string(),
                events: Vec::new(),
                capabilities: json!({}),
                error: None,
                session_id: "native-session-1".to_string(),
                thread_id: "diagnostic-thread-1".to_string(),
                turn_id: "turn-1".to_string(),
                turn_status: "completed".to_string(),
                effective: NormalizedEffectiveSettings::default(),
                status_code: None,
                stdout_truncated: false,
                stderr_truncated: false,
                started_at: "1".to_string(),
                runtime_protocol: opencode_driver::RUNTIME_PROTOCOL,
                driver_id: "opencode-serve",
            },
        );

        assert_eq!(response["nativeSessionId"], "native-session-1");
        assert_eq!(response["driverId"], "opencode-serve");
        assert_eq!(response["sessionId"], "native-session-1");
        assert_eq!(response["threadId"], "diagnostic-thread-1");
    }

    #[test]
    fn configured_command_fallback_has_been_removed() {
        let response = send_message(&json!({
            "agent": "claude-code",
            "text": "private prompt",
            "binary": "/definitely/not/a/claude-binary",
            "command": "/bin/echo",
            "args": ["{prompt}"]
        }))
        .unwrap();

        assert_eq!(response["ok"], false);
        assert_eq!(
            response["runtimeProtocol"],
            claude_code_driver::RUNTIME_PROTOCOL
        );
        assert_ne!(response["runtimeProtocol"], "configured-command");
    }

    #[test]
    fn unknown_runtime_adapter_is_rejected() {
        let error = send_message(&json!({"agent": "unknown", "text": "hello"})).unwrap_err();
        assert!(error.to_string().contains("unsupported runtime adapter"));
    }
}
