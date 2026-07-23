use super::PACKAGED_RUNTIME_ADAPTER_IDS;
use super::adapter::adapter_for_agent;
use super::model::{
    DriverInventoryDocument, DriverInventoryEntry, ReadinessDocument, ReadinessEntry,
    ReadinessSummary, RuntimeDriverProfile, RuntimeDriverRegistry,
};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

const DRIVER_INVENTORY_SCHEMA_VERSION: &str = "v0.0.1:client-agent-conversation-drivers-1";
const READINESS_SCHEMA_VERSION: &str = "v0.0.1:client-agent-conversation-readiness-1";
const CONVERSATION_PARITY_CONTRACT_VERSION: &str = "CL-06";
const MINIMUM_CONSECUTIVE_PASSES: usize = 3;
pub(super) const DRIVER_INVENTORY_JSON: &str =
    include_str!("../../../resources/agent-conversation-drivers.json");
pub(super) const READINESS_JSON: &str =
    include_str!("../../../resources/agent-conversation-readiness.json");
const CORE_CHECK_IDS: &[&str] = &[
    "P-01", "P-02", "P-03", "P-04", "P-05", "P-06", "P-07", "P-08", "P-09", "P-10",
];
const CONDITIONAL_CHECK_IDS: &[&str] = &["C-01", "C-02", "C-03", "C-04", "C-05", "C-06"];
const REQUIRED_EVIDENCE_BOOLEANS: &[&str] = &[
    "officialNativeLane",
    "conversationGatePassed",
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

static RUNTIME_DRIVER_REGISTRY: OnceLock<Option<RuntimeDriverRegistry>> = OnceLock::new();

pub(crate) fn runtime_driver_profile(target: &str) -> Option<RuntimeDriverProfile> {
    let adapter = adapter_for_agent(target)?;
    runtime_driver_registry()?.profile(adapter.id())
}

pub(super) fn runtime_driver_registry() -> Option<&'static RuntimeDriverRegistry> {
    RUNTIME_DRIVER_REGISTRY
        .get_or_init(|| parse_runtime_driver_registry(DRIVER_INVENTORY_JSON, READINESS_JSON).ok())
        .as_ref()
}

pub(super) fn parse_runtime_driver_registry(
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
            || !entry.conversation_gate_passed
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
    pub(super) fn profile(&self, agent_id: &str) -> Option<RuntimeDriverProfile> {
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

pub(crate) fn inventory_capability_matrix(agent_id: &str) -> Option<Value> {
    let adapter = adapter_for_agent(agent_id)?;
    runtime_driver_registry()?
        .drivers
        .get(adapter.id())
        .and_then(|entry| entry.capability_matrix.clone())
}

/// Build the bounded, client-facing adapter management catalog from the same
/// packaged registry used for runtime dispatch. Installation lifecycle is
/// exposed only for Lico Arc-owned bridges; official native lanes and bundled
/// ACP clients never pretend to require installation into a vendor product.
pub(crate) fn adapter_management_catalog(antigravity_bridge_installed: bool) -> Value {
    let Some(registry) = runtime_driver_registry() else {
        return json!({
            "ok": false,
            "schemaVersion": "lico.adapter-plugin-catalog.v1",
            "adapters": [],
            "error": {"code": "adapter_plugin_catalog_unavailable"},
        });
    };

    let adapters = PACKAGED_RUNTIME_ADAPTER_IDS
        .iter()
        .filter_map(|agent_id| {
            let adapter = adapter_for_agent(agent_id)?;
            let driver = registry.drivers.get(*agent_id)?;
            let readiness = registry.readiness.get(*agent_id)?;
            let lane_family = driver
                .capability_matrix
                .as_ref()
                .and_then(|matrix| matrix.get("laneFamily"))
                .and_then(Value::as_str)
                .unwrap_or("unavailable");
            let managed_bridge = *agent_id == "antigravity";
            let management_kind = if managed_bridge {
                "managed-bridge"
            } else if lane_family == "acp" {
                "bundled-acp"
            } else {
                "native"
            };
            let installation_state = if managed_bridge {
                if antigravity_bridge_installed {
                    "installed"
                } else {
                    "not-installed"
                }
            } else {
                "not-required"
            };
            let lifecycle_actions = if managed_bridge {
                if antigravity_bridge_installed {
                    vec!["uninstall"]
                } else {
                    vec!["install"]
                }
            } else {
                Vec::new()
            };
            Some(json!({
                "agentId": adapter.id(),
                "label": adapter.label(),
                "driverId": driver.driver_id,
                "runtimeProtocol": driver.runtime_protocol,
                "laneFamily": lane_family,
                "managementKind": management_kind,
                "installationState": installation_state,
                "readiness": readiness.status,
                "lifecycleActions": lifecycle_actions,
                "nativePreferred": true,
            }))
        })
        .collect::<Vec<_>>();

    json!({
        "ok": adapters.len() == PACKAGED_RUNTIME_ADAPTER_IDS.len(),
        "schemaVersion": "lico.adapter-plugin-catalog.v1",
        "adapters": adapters,
    })
}
