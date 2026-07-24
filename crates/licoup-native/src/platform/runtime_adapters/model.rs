use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

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
pub(super) struct DriverInventoryDocument {
    pub(super) schema_version: String,
    pub(super) contract_version: String,
    pub(super) evidence_contract: DriverEvidenceContract,
    pub(super) drivers: Vec<DriverInventoryEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct DriverEvidenceContract {
    pub(super) minimum_consecutive_passes: usize,
    pub(super) core_checks: Vec<String>,
    pub(super) conditional_checks: Vec<String>,
    pub(super) required_booleans: Vec<String>,
    pub(super) required_counts: Vec<String>,
    pub(super) required_digests: Vec<String>,
    pub(super) required_bindings: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct DriverInventoryEntry {
    pub(super) agent_id: String,
    pub(super) driver_id: String,
    pub(super) runtime_protocol: String,
    pub(super) official_native_lane_kind: String,
    pub(super) history_readable: bool,
    pub(super) driver_mode: String,
    pub(super) blocker_codes: Vec<String>,
    #[serde(default)]
    pub(super) capability_matrix: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReadinessDocument {
    pub(super) schema_version: String,
    pub(super) contract_version: String,
    pub(super) minimum_consecutive_passes: usize,
    pub(super) summary: ReadinessSummary,
    pub(super) adapters: Vec<ReadinessEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReadinessSummary {
    pub(super) total: usize,
    pub(super) ready: usize,
    pub(super) partial: usize,
    pub(super) failed: usize,
    pub(super) blocked: usize,
    pub(super) unverified: usize,
    pub(super) history_only: usize,
    pub(super) send_enabled: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReadinessEntry {
    pub(super) agent_id: String,
    pub(super) status: String,
    pub(super) send_enabled: bool,
    pub(super) official_native_lane_proven: bool,
    pub(super) conversation_gate_passed: bool,
    pub(super) cleanup_passed: bool,
    pub(super) privacy_passed: bool,
    pub(super) consecutive_passes: usize,
    pub(super) core_checks: CoreReadinessCounts,
    pub(super) conditional_checks: ConditionalReadinessCounts,
    pub(super) evidence_binding: Option<ReadinessEvidenceBinding>,
    pub(super) summary_codes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ReadinessEvidenceBinding {
    pub(super) agent_id: String,
    pub(super) driver_id: String,
    pub(super) runtime_protocol: String,
    pub(super) harness_version: String,
    pub(super) runtime_version_class: String,
    pub(super) runtime_version_digest: String,
    pub(super) capability_snapshot_digest: String,
    pub(super) adapter_manifest_digest: String,
    pub(super) release_artifact_digest: String,
    pub(super) release_sidecar_digest: String,
    pub(super) product_continuity_binding_digest: String,
    pub(super) runtime_source_class: String,
    pub(super) registry_digest: String,
    pub(super) driver_inventory_digest: String,
    pub(super) evidence_digest: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct CoreReadinessCounts {
    pub(super) required: usize,
    pub(super) passed: usize,
    pub(super) failed: usize,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ConditionalReadinessCounts {
    pub(super) total: usize,
    pub(super) native_supported: usize,
    pub(super) passed: usize,
    pub(super) gaps: usize,
    pub(super) failed: usize,
}

#[derive(Debug)]
pub(super) struct RuntimeDriverRegistry {
    pub(super) drivers: BTreeMap<String, DriverInventoryEntry>,
    pub(super) readiness: BTreeMap<String, ReadinessEntry>,
}

#[derive(Clone, Debug, Default)]
pub(super) struct NormalizedEffectiveSettings {
    pub(super) cwd: Option<String>,
    pub(super) model: Option<String>,
    pub(super) reasoning_effort: Option<String>,
    pub(super) permission_mode: Option<String>,
    pub(super) mode: Option<String>,
    pub(super) runtime_agent: Option<String>,
    pub(super) allow_all: Option<bool>,
    pub(super) sandbox: Option<Value>,
    pub(super) approval_policy: Option<Value>,
}

#[derive(Clone, Debug)]
pub(super) struct NormalizedFailure {
    pub(super) code: String,
    pub(super) message: String,
    pub(super) stage: String,
    pub(super) user_interaction_required: bool,
    pub(super) request_method: Option<String>,
    pub(super) session_id: Option<String>,
    pub(super) thread_id: Option<String>,
    pub(super) turn_id: Option<String>,
    pub(super) turn_status: Option<String>,
}

#[derive(Debug)]
pub(super) struct NormalizedExecution {
    pub(super) ok: bool,
    pub(super) output: String,
    pub(super) events: Vec<Value>,
    pub(super) capabilities: Value,
    pub(super) error: Option<NormalizedFailure>,
    pub(super) session_id: String,
    pub(super) thread_id: String,
    pub(super) turn_id: String,
    pub(super) turn_status: String,
    pub(super) effective: NormalizedEffectiveSettings,
    pub(super) status_code: Option<i32>,
    pub(super) stdout_truncated: bool,
    pub(super) stderr_truncated: bool,
    pub(super) started_at: String,
    pub(super) runtime_protocol: &'static str,
    pub(super) driver_id: &'static str,
}
