//! LicoUp-owned subordinate handoff records.
//!
//! The main agent only requests work. LicoUp accepts, runs the subordinate,
//! detects completion, and resumes the original main conversation.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub const HANDOFF_SCHEMA_VERSION: &str = "licoup.subagent.handoff.v2";
pub const RECEIPT_SCHEMA_VERSION: &str = "licoup.subagent.receipt.v2";
pub const DELIVERY_CONTROL_SCHEMA_VERSION: &str = "licoup.delivery-control.v1";
const MAX_PRIVATE_PATH_BYTES: usize = 4096;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryRunnerState {
    #[default]
    Pending,
    Running,
    Ready,
    InDoubt,
    Blocked,
    Completed,
    Cancelled,
}

impl DeliveryRunnerState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Ready => "ready",
            Self::InDoubt => "in_doubt",
            Self::Blocked => "blocked",
            Self::Completed => "completed",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeliveryFailureRecord {
    pub code: String,
    pub stage: String,
    pub component: String,
    pub retryable: bool,
    pub recovery: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeliveryControlRecord {
    pub schema_version: String,
    pub generation: u64,
    pub workflow_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_code: Option<String>,
    pub plan_revision: u64,
    /// Private storage binding. This field is never included in the public
    /// status projection or the numeric workflow ledger report.
    pub ledger_state_root: String,
    pub runner_state: DeliveryRunnerState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<DeliveryFailureRecord>,
    pub updated_at_unix_ms: u64,
}

impl DeliveryControlRecord {
    pub fn new(workflow_id: impl Into<String>, ledger_state_root: impl Into<String>) -> Self {
        Self {
            schema_version: DELIVERY_CONTROL_SCHEMA_VERSION.to_owned(),
            generation: 1,
            workflow_id: workflow_id.into(),
            plan_code: None,
            plan_revision: 0,
            ledger_state_root: ledger_state_root.into(),
            runner_state: DeliveryRunnerState::Pending,
            failure: None,
            updated_at_unix_ms: unix_ms_now(),
        }
    }

    pub fn public_projection(&self) -> Value {
        serde_json::json!({
            "state": self.runner_state.as_str(),
            "failure": self.failure,
            "updatedAtUnixMs": self.updated_at_unix_ms,
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum HandoffState {
    Accepted,
    Running,
    Completed,
    Failed,
    CancelRequested,
}

/// Numeric Token settlement lifecycle attached to the one current handoff
/// generation.  `InDoubt` is deliberately distinct from a failed agent state:
/// the native conversation must be reconciled before a retry is admitted.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum UsageSettlementState {
    #[default]
    Pending,
    Ready,
    Settled,
    InDoubt,
    Reconciled,
}

impl UsageSettlementState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Ready => "ready",
            Self::Settled => "settled",
            Self::InDoubt => "in-doubt",
            Self::Reconciled => "reconciled",
        }
    }
}

impl HandoffState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Accepted => "accepted",
            Self::Running => "running",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::CancelRequested => "cancel-requested",
        }
    }
}

/// Whether LicoUp should open a fresh subordinate session or resume one.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SessionMode {
    #[default]
    New,
    Resume,
}

impl SessionMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::New => "new",
            Self::Resume => "resume",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "new" => Some(Self::New),
            "resume" => Some(Self::Resume),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HandoffRecord {
    pub schema_version: String,
    /// Monotonically increasing current-generation marker.  A dispatch file
    /// contains one record only; older generations are never read as a
    /// compatibility format.
    pub generation: u64,
    pub plan_code: String,
    pub plan_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    pub dispatch_id: String,
    pub operation: String,
    pub manager_agent_id: String,
    pub agent_id: String,
    pub role: String,
    pub attempt: u64,
    pub state: HandoffState,
    pub session_mode: SessionMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub main_conversation_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation_path: Option<String>,
    /// Opaque identity handles used by the Token ledger.  Native paths remain
    /// in the private execution fields above and are never projected into
    /// workflow reports.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manager_conversation_binding: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub child_conversation_binding: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lineage_scope: Option<String>,
    pub usage_settlement: UsageSettlementState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    pub updated_at_unix_ms: u64,
}

impl HandoffRecord {
    pub fn new(
        dispatch_id: impl Into<String>,
        operation: impl Into<String>,
        manager_agent_id: impl Into<String>,
        agent_id: impl Into<String>,
        session_mode: SessionMode,
        main_conversation_path: Option<String>,
    ) -> Self {
        Self {
            schema_version: HANDOFF_SCHEMA_VERSION.to_owned(),
            generation: 1,
            plan_code: String::new(),
            plan_revision: 0,
            task_code: None,
            phase: None,
            dispatch_id: dispatch_id.into(),
            operation: operation.into(),
            manager_agent_id: manager_agent_id.into(),
            agent_id: agent_id.into(),
            role: "worker".to_owned(),
            attempt: 1,
            state: HandoffState::Accepted,
            session_mode,
            main_conversation_path,
            conversation_path: None,
            manager_conversation_binding: None,
            child_conversation_binding: None,
            lineage_scope: None,
            usage_settlement: UsageSettlementState::Pending,
            error_code: None,
            updated_at_unix_ms: unix_ms_now(),
        }
    }

    /// Construct a current-generation delivery handoff without exposing a
    /// native location to the ledger report.  The path arguments are retained
    /// only for the execution adapter's private binding.
    #[allow(clippy::too_many_arguments)]
    pub fn new_delivery(
        dispatch_id: impl Into<String>,
        operation: impl Into<String>,
        plan_code: impl Into<String>,
        plan_revision: u64,
        task_code: Option<String>,
        phase: Option<String>,
        manager_agent_id: impl Into<String>,
        agent_id: impl Into<String>,
        role: impl Into<String>,
        attempt: u64,
        session_mode: SessionMode,
        manager_conversation_binding: Option<String>,
        child_conversation_binding: Option<String>,
        lineage_scope: Option<String>,
        main_conversation_path: Option<String>,
    ) -> Self {
        let mut record = Self::new(
            dispatch_id,
            operation,
            manager_agent_id,
            agent_id,
            session_mode,
            main_conversation_path,
        );
        record.plan_code = plan_code.into();
        record.plan_revision = plan_revision;
        record.task_code = task_code;
        record.phase = phase;
        record.role = role.into();
        record.attempt = attempt.max(1);
        record.manager_conversation_binding = manager_conversation_binding;
        record.child_conversation_binding = child_conversation_binding;
        record.lineage_scope = lineage_scope;
        record
    }

    pub fn ack_receipt(&self) -> Value {
        serde_json::json!({
            "schemaVersion": RECEIPT_SCHEMA_VERSION,
            "operation": self.operation,
            "agentId": self.agent_id,
            "state": self.state.as_str(),
            "dispatchId": self.dispatch_id,
            "sessionMode": self.session_mode.as_str(),
            "generation": self.generation,
            "planCode": self.plan_code,
            "planRevision": self.plan_revision,
            "role": self.role,
            "attempt": self.attempt,
            "usageSettlement": self.usage_settlement.as_str(),
            "accepted": true,
        })
    }
}

pub fn handoff_root(portable_data: &Path) -> PathBuf {
    portable_data.join("client-state").join("subagent-handoffs")
}

pub fn handoff_path(portable_data: &Path, dispatch_id: &str) -> PathBuf {
    handoff_root(portable_data).join(format!("{dispatch_id}.json"))
}

pub fn delivery_control_root(portable_data: &Path) -> PathBuf {
    handoff_root(portable_data).join("delivery-controls")
}

pub fn delivery_control_path(portable_data: &Path, workflow_id: &str) -> PathBuf {
    delivery_control_root(portable_data).join(format!("{workflow_id}.json"))
}

pub fn persist_delivery_control(
    portable_data: &Path,
    record: &DeliveryControlRecord,
) -> Result<(), String> {
    validate_delivery_control(record)?;
    let root = delivery_control_root(portable_data);
    fs::create_dir_all(&root).map_err(|_| "delivery_control_store_unavailable".to_owned())?;
    let root_metadata =
        fs::symlink_metadata(&root).map_err(|_| "delivery_control_store_unavailable".to_owned())?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err("delivery_control_store_invalid".to_owned());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
            .map_err(|_| "delivery_control_store_unavailable".to_owned())?;
    }
    let path = delivery_control_path(portable_data, &record.workflow_id);
    if path.exists()
        && fs::symlink_metadata(&path)
            .map_err(|_| "delivery_control_store_unavailable".to_owned())?
            .file_type()
            .is_symlink()
    {
        return Err("delivery_control_store_invalid".to_owned());
    }
    let body = serde_json::to_vec_pretty(record)
        .map_err(|_| "delivery_control_encode_failed".to_owned())?;
    let tmp = root.join(format!(".{}.{}.tmp", record.workflow_id, unix_ms_now()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&tmp)
        .map_err(|_| "delivery_control_write_failed".to_owned())?;
    file.write_all(&body)
        .and_then(|_| file.write_all(b"\n"))
        .and_then(|_| file.sync_all())
        .map_err(|_| "delivery_control_write_failed".to_owned())?;
    drop(file);
    fs::rename(&tmp, &path).map_err(|_| "delivery_control_write_failed".to_owned())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|_| "delivery_control_write_failed".to_owned())?;
    }
    Ok(())
}

pub fn load_delivery_control(
    portable_data: &Path,
    workflow_id: &str,
) -> Result<Option<DeliveryControlRecord>, String> {
    if !valid_dispatch_id(workflow_id) {
        return Err("delivery_control_workflow_id_invalid".to_owned());
    }
    let path = delivery_control_path(portable_data, workflow_id);
    if !path
        .try_exists()
        .map_err(|_| "delivery_control_store_unavailable".to_owned())?
    {
        return Ok(None);
    }
    let metadata =
        fs::symlink_metadata(&path).map_err(|_| "delivery_control_store_unavailable".to_owned())?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("delivery_control_store_invalid".to_owned());
    }
    let raw =
        fs::read_to_string(&path).map_err(|_| "delivery_control_store_unavailable".to_owned())?;
    let record = serde_json::from_str::<DeliveryControlRecord>(&raw)
        .map_err(|_| "delivery_control_decode_failed".to_owned())?;
    validate_delivery_control(&record)?;
    if record.workflow_id != workflow_id {
        return Err("delivery_control_identity_mismatch".to_owned());
    }
    Ok(Some(record))
}

pub fn persist_handoff(portable_data: &Path, record: &HandoffRecord) -> Result<(), String> {
    if !valid_dispatch_id(&record.dispatch_id) {
        return Err("handoff_dispatch_id_invalid".to_owned());
    }
    let root = handoff_root(portable_data);
    fs::create_dir_all(&root).map_err(|_| "handoff_store_unavailable".to_owned())?;
    let root_metadata =
        fs::symlink_metadata(&root).map_err(|_| "handoff_store_unavailable".to_owned())?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err("handoff_store_invalid".to_owned());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
            .map_err(|_| "handoff_store_unavailable".to_owned())?;
    }
    let path = handoff_path(portable_data, &record.dispatch_id);
    if path.exists()
        && fs::symlink_metadata(&path)
            .map_err(|_| "handoff_store_unavailable".to_owned())?
            .file_type()
            .is_symlink()
    {
        return Err("handoff_store_invalid".to_owned());
    }
    let body = serde_json::to_vec_pretty(record).map_err(|_| "handoff_encode_failed".to_owned())?;
    let tmp = root.join(format!(".{}.{}.tmp", record.dispatch_id, unix_ms_now()));
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&tmp)
        .map_err(|_| "handoff_write_failed".to_owned())?;
    file.write_all(&body)
        .and_then(|_| file.write_all(b"\n"))
        .and_then(|_| file.sync_all())
        .map_err(|_| "handoff_write_failed".to_owned())?;
    drop(file);
    fs::rename(&tmp, &path).map_err(|_| "handoff_write_failed".to_owned())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|_| "handoff_write_failed".to_owned())?;
    }
    Ok(())
}

pub fn load_handoff(portable_data: &Path, dispatch_id: &str) -> Result<HandoffRecord, String> {
    if !valid_dispatch_id(dispatch_id) {
        return Err("handoff_dispatch_id_invalid".to_owned());
    }
    let path = handoff_path(portable_data, dispatch_id);
    let metadata = fs::symlink_metadata(&path).map_err(|_| "handoff_not_found".to_owned())?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err("handoff_store_invalid".to_owned());
    }
    let raw = fs::read_to_string(&path).map_err(|_| "handoff_not_found".to_owned())?;
    let record: HandoffRecord =
        serde_json::from_str(&raw).map_err(|_| "handoff_decode_failed".to_owned())?;
    if record.schema_version != HANDOFF_SCHEMA_VERSION {
        return Err("handoff_unsupported_generation".to_owned());
    }
    Ok(record)
}

pub fn list_handoffs(portable_data: &Path) -> Result<Vec<HandoffRecord>, String> {
    let root = handoff_root(portable_data);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let mut records = Vec::new();
    let entries = fs::read_dir(&root).map_err(|_| "handoff_store_unavailable".to_owned())?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let metadata =
            fs::symlink_metadata(&path).map_err(|_| "handoff_store_unavailable".to_owned())?;
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err("handoff_store_invalid".to_owned());
        }
        let raw = fs::read_to_string(&path).map_err(|_| "handoff_store_unavailable".to_owned())?;
        let record = serde_json::from_str::<HandoffRecord>(&raw)
            .map_err(|_| "handoff_decode_failed".to_owned())?;
        if record.schema_version != HANDOFF_SCHEMA_VERSION
            || !valid_dispatch_id(&record.dispatch_id)
        {
            return Err("handoff_unsupported_generation".to_owned());
        }
        records.push(record);
    }
    records.sort_by_key(|record| std::cmp::Reverse(record.updated_at_unix_ms));
    Ok(records)
}

pub fn new_dispatch_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_nanos())
        .unwrap_or(0);
    format!("handoff-{nanos}")
}

pub fn unix_ms_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0)
}

fn valid_dispatch_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value != "."
        && value != ".."
        && value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':' | b'@' | b'+')
        })
}

fn validate_delivery_control(record: &DeliveryControlRecord) -> Result<(), String> {
    if record.schema_version != DELIVERY_CONTROL_SCHEMA_VERSION || record.generation != 1 {
        return Err("delivery_control_unsupported_generation".to_owned());
    }
    if !valid_dispatch_id(&record.workflow_id) {
        return Err("delivery_control_workflow_id_invalid".to_owned());
    }
    if record
        .plan_code
        .as_deref()
        .is_some_and(|value| !valid_dispatch_id(value))
    {
        return Err("delivery_control_plan_code_invalid".to_owned());
    }
    let root = Path::new(&record.ledger_state_root);
    if record.ledger_state_root.is_empty()
        || record.ledger_state_root.len() > MAX_PRIVATE_PATH_BYTES
        || record.ledger_state_root.contains('\0')
        || !root.is_absolute()
    {
        return Err("delivery_control_state_root_invalid".to_owned());
    }
    if let Some(failure) = &record.failure
        && (!valid_control_token(&failure.code)
            || !valid_control_token(&failure.stage)
            || !valid_control_token(&failure.component)
            || !valid_control_token(&failure.recovery))
    {
        return Err("delivery_control_failure_invalid".to_owned());
    }
    Ok(())
}

fn valid_control_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn persist_and_load_round_trip() {
        let dir = std::env::temp_dir().join(format!(
            "licoup-handoff-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_nanos())
                .unwrap_or(0)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let main_conversation_path = std::env::temp_dir()
            .join("licoup-handoff-main.jsonl")
            .to_string_lossy()
            .into_owned();
        let record = HandoffRecord::new(
            "handoff-1",
            "subagent.delegate",
            "codex",
            "claude",
            SessionMode::Resume,
            Some(main_conversation_path.clone()),
        );
        persist_handoff(&dir, &record).unwrap();
        let loaded = load_handoff(&dir, "handoff-1").unwrap();
        assert_eq!(loaded.dispatch_id, "handoff-1");
        assert_eq!(loaded.state, HandoffState::Accepted);
        assert_eq!(loaded.session_mode, SessionMode::Resume);
        assert_eq!(
            loaded.main_conversation_path.as_deref(),
            Some(main_conversation_path.as_str())
        );
        let ack = loaded.ack_receipt();
        assert_eq!(ack["accepted"], true);
        assert_eq!(ack["state"], "accepted");
        assert_eq!(ack["sessionMode"], "resume");
        assert_eq!(ack["dispatchId"], "handoff-1");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn handoff_store_rejects_path_traversal_and_unknown_generations() {
        let dir = std::env::temp_dir().join(format!("licoup-handoff-invalid-{}", unix_ms_now()));
        fs::create_dir_all(&dir).unwrap();
        let record = HandoffRecord::new(
            "../escape",
            "subagent.delegate",
            "codex",
            "claude",
            SessionMode::New,
            None,
        );
        assert_eq!(
            persist_handoff(&dir, &record).unwrap_err(),
            "handoff_dispatch_id_invalid"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn delivery_control_persists_typed_failure_but_projects_no_state_root() {
        let dir = std::env::temp_dir().join(format!("licoup-delivery-control-{}", unix_ms_now()));
        let state_root = dir.join("custom-state");
        fs::create_dir_all(&state_root).unwrap();
        let mut record = DeliveryControlRecord::new(
            "workflow-control",
            state_root.to_string_lossy().into_owned(),
        );
        record.runner_state = DeliveryRunnerState::InDoubt;
        record.failure = Some(DeliveryFailureRecord {
            code: "native_effect_in_doubt".to_owned(),
            stage: "native-dispatch".to_owned(),
            component: "native-lane".to_owned(),
            retryable: true,
            recovery: "reconcile_exact_conversation_before_retry".to_owned(),
        });
        persist_delivery_control(&dir, &record).unwrap();

        // A fresh load is the restart seam.
        let loaded = load_delivery_control(&dir, "workflow-control")
            .unwrap()
            .unwrap();
        assert_eq!(loaded.runner_state, DeliveryRunnerState::InDoubt);
        assert_eq!(
            loaded
                .failure
                .as_ref()
                .map(|failure| failure.stage.as_str()),
            Some("native-dispatch")
        );
        let public = loaded.public_projection();
        assert_eq!(public["state"], "in_doubt");
        assert_eq!(public["failure"]["retryable"], true);
        assert!(!public.to_string().contains(&record.ledger_state_root));
        assert!(public.get("ledgerStateRoot").is_none());
        let _ = fs::remove_dir_all(&dir);
    }
}
