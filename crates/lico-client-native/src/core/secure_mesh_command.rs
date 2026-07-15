use anyhow::{Context, Result, anyhow, bail, ensure};
use base64::{Engine as _, engine::general_purpose};
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    error::Error as StdError,
    fmt, fs,
    path::{Path, PathBuf},
};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::core::secure_mesh::{
    ALLOWED_COMMANDS, DENIED_PREFIXES, SECURE_MESH_COMMAND_PROTOCOL_VERSION,
};
use crate::core::secure_mesh_response::{SecureMeshErrorPayload, SecureMeshResultPayload};
use crate::core::secure_mesh_trust::DeviceTrustState;

pub const SECURE_MESH_COMMAND_SECURITY_STATUS: &str = "local_schema_risk_replay_idempotency_sqlite_ledger_execution_adapter_runtime_binding_available";

const MAX_COMMAND_ID_BYTES: usize = 255;
const MAX_COMMAND_KIND_BYTES: usize = 255;
const MAX_ENDPOINT_ID_BYTES: usize = 255;
const MAX_FINGERPRINT_BYTES: usize = 255;
const MAX_BINDING_ID_BYTES: usize = 255;
const MAX_IDEMPOTENCY_KEY_BYTES: usize = 255;
const MAX_COMMAND_BODY_BYTES: usize = 1024 * 1024;
const MAX_CLOCK_SKEW_SECONDS: i64 = 300;
pub const SECURE_MESH_COMMAND_LEDGER_MAX_ENTRIES: usize = 4096;
const SECURE_MESH_COMMAND_LEDGER_PATH: &str = "lico-client/secure-mesh/command-replay.sqlite";
const LOCAL_EXECUTION_FAILED_REMOTE_DETAIL: &str =
    "local command execution failed; details are not exposed over secure mesh";
const SECURE_AGENT_MESSAGE_TIMEOUT_MS: u64 = 90_000;
const AGENT_MESSAGE_SEND_PAYLOAD_FIELDS: &[&str] = &[
    "agent",
    "agentId",
    "target",
    "text",
    "message",
    "prompt",
    "model",
    "modelId",
    "reasoningEffort",
    "reasoning_effort",
    "sessionId",
    "nativeSessionId",
];
const PROVIDER_CHAT_SEND_PAYLOAD_FIELDS: &[&str] = &[
    "provider",
    "providerId",
    "profile",
    "profileId",
    "modelProfile",
    "text",
    "message",
    "prompt",
    "input",
    "model",
    "modelId",
    "reasoningEffort",
    "reasoning_effort",
    "messages",
];
const PROVIDER_CREDENTIAL_EXPORT_PAYLOAD_FIELDS: &[&str] = &[
    "provider",
    "providerId",
    "profile",
    "profileId",
    "modelProfile",
];
const AGENT_SESSIONS_LIST_PAYLOAD_FIELDS: &[&str] =
    &["agent", "agentId", "target", "limit", "offset"];
const AGENT_SESSIONS_DESCRIBE_PAYLOAD_FIELDS: &[&str] =
    &["agent", "agentId", "target", "sessionId", "nativeSessionId"];
const CLIENT_ACTIVITY_SYNC_PAYLOAD_FIELDS: &[&str] = &["type", "target", "limit"];
const CLIENT_SNAPSHOT_REQUEST_PAYLOAD_FIELDS: &[&str] = &["target", "limit"];
const COMMAND_BODY_DENIED_LOCAL_RUNTIME_FIELDS: &[&str] = &[
    "command",
    "args",
    "stdin",
    "executable",
    "binaryPath",
    "commandPath",
    "cwd",
    "workingDirectory",
    "root",
    "historyRoot",
    "env",
    "environment",
    "shell",
    "timeoutMs",
    "maxStdoutBytes",
    "maxStderrBytes",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SecureCommandRiskClass {
    ReadOnly,
    SafeWrite,
    LocalEffect,
    HighRisk,
}

impl SecureCommandRiskClass {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::ReadOnly => "read_only",
            Self::SafeWrite => "safe_write",
            Self::LocalEffect => "local_effect",
            Self::HighRisk => "high_risk",
        }
    }

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "read_only" => Ok(Self::ReadOnly),
            "safe_write" => Ok(Self::SafeWrite),
            "local_effect" => Ok(Self::LocalEffect),
            "high_risk" => Ok(Self::HighRisk),
            _ => bail!("secure mesh command riskClass is unsupported"),
        }
    }

    fn rank(&self) -> u8 {
        match self {
            Self::ReadOnly => 0,
            Self::SafeWrite => 1,
            Self::LocalEffect => 2,
            Self::HighRisk => 3,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureCommandSenderIdentity {
    pub endpoint_id: String,
    pub identity_fingerprint: String,
    pub trust_state: DeviceTrustState,
    pub endpoint_kind: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureCommandTargetBinding {
    pub target_endpoint_id: String,
    pub target_agent_id: Option<String>,
    pub workspace_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureCommandPayload {
    pub command_id: String,
    pub command_kind: String,
    pub sender_identity: SecureCommandSenderIdentity,
    pub target_binding: SecureCommandTargetBinding,
    pub risk_class: SecureCommandRiskClass,
    pub requires_user_confirmation: bool,
    pub idempotency_key: String,
    pub created_at: String,
    pub expires_at: String,
    created_at_time: OffsetDateTime,
    expires_at_time: OffsetDateTime,
    body: Value,
}

impl SecureCommandPayload {
    pub fn from_value(value: &Value) -> Result<Self> {
        let object = value
            .as_object()
            .ok_or_else(|| anyhow!("secure mesh command payload must be a JSON object"))?;
        ensure_allowed_keys(
            "secure mesh command payload",
            object.keys().map(String::as_str),
            &[
                "schema",
                "commandId",
                "commandKind",
                "senderIdentity",
                "targetBinding",
                "riskClass",
                "requiresUserConfirmation",
                "idempotencyKey",
                "createdAt",
                "expiresAt",
                "body",
            ],
        )?;
        let schema = read_required_string(value, "schema", 255)?;
        ensure!(
            schema == SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "secure mesh command schema is unsupported"
        );
        let command_id = read_required_string(value, "commandId", MAX_COMMAND_ID_BYTES)?;
        let command_kind = read_required_string(value, "commandKind", MAX_COMMAND_KIND_BYTES)?;
        let sender_identity = read_sender_identity(
            value
                .get("senderIdentity")
                .context("secure mesh command senderIdentity is required")?,
        )?;
        let target_binding = read_target_binding(
            value
                .get("targetBinding")
                .context("secure mesh command targetBinding is required")?,
        )?;
        let risk_class =
            SecureCommandRiskClass::from_str(&read_required_string(value, "riskClass", 64)?)?;
        let requires_user_confirmation = value
            .get("requiresUserConfirmation")
            .and_then(Value::as_bool)
            .context("secure mesh command requiresUserConfirmation is required")?;
        let idempotency_key =
            read_required_string(value, "idempotencyKey", MAX_IDEMPOTENCY_KEY_BYTES)?;
        let created_at = read_required_string(value, "createdAt", 64)?;
        let expires_at = read_required_string(value, "expiresAt", 64)?;
        let created_at_time = parse_timestamp("createdAt", &created_at)?;
        let expires_at_time = parse_timestamp("expiresAt", &expires_at)?;
        ensure!(
            expires_at_time > created_at_time,
            "secure mesh command expiresAt must be after createdAt"
        );
        let body = value
            .get("body")
            .cloned()
            .context("secure mesh command body is required")?;
        ensure!(
            serde_json::to_vec(&body)?.len() <= MAX_COMMAND_BODY_BYTES,
            "secure mesh command body is too large"
        );
        Ok(Self {
            command_id,
            command_kind,
            sender_identity,
            target_binding,
            risk_class,
            requires_user_confirmation,
            idempotency_key,
            created_at,
            expires_at,
            created_at_time,
            expires_at_time,
            body,
        })
    }

    fn idempotency_fingerprint(&self) -> Result<String> {
        let canonical = json!({
            "schema": SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandKind": self.command_kind,
            "senderIdentity": {
                "endpointId": self.sender_identity.endpoint_id,
                "identityFingerprint": self.sender_identity.identity_fingerprint,
            },
            "targetBinding": {
                "targetEndpointId": self.target_binding.target_endpoint_id,
                "targetAgentId": self.target_binding.target_agent_id,
                "workspaceId": self.target_binding.workspace_id,
            },
            "riskClass": self.risk_class.as_str(),
            "requiresUserConfirmation": self.requires_user_confirmation,
            "body": self.body,
        });
        Ok(hex_digest(&serde_json::to_vec(&canonical)?))
    }

    pub fn body(&self) -> &Value {
        &self.body
    }
}

#[derive(Clone, Debug)]
pub struct SecureCommandEvaluationContext {
    pub local_endpoint_id: String,
    pub sender_endpoint_id: String,
    pub sender_identity_fingerprint: String,
    pub sender_trust_state: DeviceTrustState,
    pub sender_endpoint_kind: String,
    pub sender_roster_active: bool,
    pub target_roster_active: bool,
    pub session_or_epoch_valid: bool,
    pub user_confirmed: bool,
    pub allowed_workspace_ids: BTreeSet<String>,
    pub allowed_agent_ids: BTreeSet<String>,
    pub now: OffsetDateTime,
}

impl SecureCommandEvaluationContext {
    pub fn from_value(value: &Value) -> Result<Self> {
        let object = value
            .as_object()
            .ok_or_else(|| anyhow!("secure mesh command context must be a JSON object"))?;
        ensure_allowed_keys(
            "secure mesh command context",
            object.keys().map(String::as_str),
            &[
                "localEndpointId",
                "senderEndpointId",
                "senderIdentityFingerprint",
                "senderTrustState",
                "senderEndpointKind",
                "senderRosterActive",
                "targetRosterActive",
                "sessionOrEpochValid",
                "userConfirmed",
                "allowedWorkspaceIds",
                "allowedAgentIds",
                "now",
            ],
        )?;
        let now = value
            .get("now")
            .and_then(Value::as_str)
            .map(|raw| parse_timestamp("now", raw))
            .transpose()?
            .unwrap_or_else(OffsetDateTime::now_utc);
        Ok(Self {
            local_endpoint_id: read_required_string(
                value,
                "localEndpointId",
                MAX_ENDPOINT_ID_BYTES,
            )?,
            sender_endpoint_id: read_required_string(
                value,
                "senderEndpointId",
                MAX_ENDPOINT_ID_BYTES,
            )?,
            sender_identity_fingerprint: read_required_string(
                value,
                "senderIdentityFingerprint",
                MAX_FINGERPRINT_BYTES,
            )?,
            sender_trust_state: trust_state_from_str(&read_required_string(
                value,
                "senderTrustState",
                64,
            )?)?,
            sender_endpoint_kind: read_required_string(
                value,
                "senderEndpointKind",
                MAX_ENDPOINT_ID_BYTES,
            )?,
            sender_roster_active: read_required_bool(value, "senderRosterActive")?,
            target_roster_active: read_required_bool(value, "targetRosterActive")?,
            session_or_epoch_valid: read_required_bool(value, "sessionOrEpochValid")?,
            user_confirmed: read_required_bool(value, "userConfirmed")?,
            allowed_workspace_ids: read_string_set(value, "allowedWorkspaceIds")?,
            allowed_agent_ids: read_string_set(value, "allowedAgentIds")?,
            now,
        })
    }
}

#[derive(Default)]
pub struct SecureCommandReplayLedger {
    command_ids: BTreeMap<String, String>,
    idempotency_fingerprints: BTreeMap<String, String>,
    insertion_order: VecDeque<String>,
    max_entries: usize,
}

impl SecureCommandReplayLedger {
    pub fn with_max_entries(max_entries: usize) -> Result<Self> {
        ensure!(
            max_entries > 0,
            "secure mesh command replay ledger max entries must be positive"
        );
        Ok(Self {
            command_ids: BTreeMap::new(),
            idempotency_fingerprints: BTreeMap::new(),
            insertion_order: VecDeque::new(),
            max_entries,
        })
    }

    fn effective_max_entries(&self) -> usize {
        if self.max_entries == 0 {
            SECURE_MESH_COMMAND_LEDGER_MAX_ENTRIES
        } else {
            self.max_entries
        }
    }

    fn prune_to_limit(&mut self) {
        while self.command_ids.len() > self.effective_max_entries() {
            let Some(old_command_id) = self.insertion_order.pop_front() else {
                break;
            };
            if let Some(old_idempotency_key) = self.command_ids.remove(&old_command_id) {
                self.idempotency_fingerprints.remove(&old_idempotency_key);
            }
        }
    }
}

impl SecureCommandReplayStore for SecureCommandReplayLedger {
    fn has_command_id(&self, command_id: &str) -> Result<bool> {
        Ok(self.command_ids.contains_key(command_id))
    }

    fn record_execution(
        &mut self,
        payload: &SecureCommandPayload,
        _now: OffsetDateTime,
    ) -> Result<SecureCommandReplayRecordStatus> {
        if self.command_ids.contains_key(&payload.command_id) {
            return Ok(SecureCommandReplayRecordStatus::CommandReplay);
        }
        let fingerprint = payload.idempotency_fingerprint()?;
        if let Some(existing) = self.idempotency_fingerprints.get(&payload.idempotency_key) {
            if existing == &fingerprint {
                return Ok(SecureCommandReplayRecordStatus::IdempotentReplay);
            }
            return Ok(SecureCommandReplayRecordStatus::IdempotencyConflict);
        }
        self.command_ids
            .insert(payload.command_id.clone(), payload.idempotency_key.clone());
        self.idempotency_fingerprints
            .insert(payload.idempotency_key.clone(), fingerprint);
        self.insertion_order.push_back(payload.command_id.clone());
        self.prune_to_limit();
        Ok(SecureCommandReplayRecordStatus::Fresh)
    }

    fn entry_count(&self) -> Result<usize> {
        Ok(self.command_ids.len())
    }
}

pub struct SecureCommandSqliteReplayLedger {
    connection: Connection,
    max_entries: usize,
}

impl SecureCommandSqliteReplayLedger {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_max_entries(path, SECURE_MESH_COMMAND_LEDGER_MAX_ENTRIES)
    }

    pub fn open_with_max_entries(path: impl AsRef<Path>, max_entries: usize) -> Result<Self> {
        ensure!(
            max_entries > 0,
            "secure mesh command sqlite replay ledger max entries must be positive"
        );
        let connection = Connection::open(path.as_ref())
            .with_context(|| "secure mesh command sqlite replay ledger open failed")?;
        let ledger = Self {
            connection,
            max_entries,
        };
        ledger.initialize()?;
        Ok(ledger)
    }

    fn initialize(&self) -> Result<()> {
        self.connection.execute_batch(
            r#"
            CREATE TABLE IF NOT EXISTS secure_mesh_command_replay (
                command_id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                fingerprint TEXT NOT NULL,
                recorded_at_unix INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_command_replay_recorded_at_idx
                ON secure_mesh_command_replay(recorded_at_unix, command_id);
            "#,
        )?;
        Ok(())
    }

    fn prune_to_limit(&self) -> Result<()> {
        let count = self.entry_count()?;
        if count <= self.max_entries {
            return Ok(());
        }
        let excess = count - self.max_entries;
        self.connection.execute(
            r#"
            DELETE FROM secure_mesh_command_replay
            WHERE command_id IN (
                SELECT command_id
                FROM secure_mesh_command_replay
                ORDER BY recorded_at_unix ASC, command_id ASC
                LIMIT ?1
            )
            "#,
            params![excess as i64],
        )?;
        Ok(())
    }
}

impl SecureCommandReplayStore for SecureCommandSqliteReplayLedger {
    fn has_command_id(&self, command_id: &str) -> Result<bool> {
        let seen = self
            .connection
            .query_row(
                "SELECT 1 FROM secure_mesh_command_replay WHERE command_id = ?1 LIMIT 1",
                params![command_id],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        Ok(seen)
    }

    fn record_execution(
        &mut self,
        payload: &SecureCommandPayload,
        now: OffsetDateTime,
    ) -> Result<SecureCommandReplayRecordStatus> {
        if self.has_command_id(&payload.command_id)? {
            return Ok(SecureCommandReplayRecordStatus::CommandReplay);
        }
        let fingerprint = payload.idempotency_fingerprint()?;
        let existing = self
            .connection
            .query_row(
                "SELECT fingerprint FROM secure_mesh_command_replay WHERE idempotency_key = ?1",
                params![payload.idempotency_key],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if let Some(existing) = existing {
            if existing == fingerprint {
                return Ok(SecureCommandReplayRecordStatus::IdempotentReplay);
            }
            return Ok(SecureCommandReplayRecordStatus::IdempotencyConflict);
        }
        self.connection.execute(
            r#"
            INSERT INTO secure_mesh_command_replay (
                command_id,
                idempotency_key,
                fingerprint,
                recorded_at_unix
            ) VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                payload.command_id,
                payload.idempotency_key,
                fingerprint,
                now.unix_timestamp()
            ],
        )?;
        self.prune_to_limit()?;
        Ok(SecureCommandReplayRecordStatus::Fresh)
    }

    fn entry_count(&self) -> Result<usize> {
        let count = self.connection.query_row(
            "SELECT COUNT(*) FROM secure_mesh_command_replay",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        Ok(count as usize)
    }
}

pub trait SecureCommandReplayStore {
    fn has_command_id(&self, command_id: &str) -> Result<bool>;
    fn record_execution(
        &mut self,
        payload: &SecureCommandPayload,
        now: OffsetDateTime,
    ) -> Result<SecureCommandReplayRecordStatus>;
    fn entry_count(&self) -> Result<usize>;
}

pub enum SecureCommandReplayRecordStatus {
    Fresh,
    CommandReplay,
    IdempotentReplay,
    IdempotencyConflict,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureCommandEvaluation {
    pub accepted: bool,
    pub should_execute: bool,
    pub replayed: bool,
    pub code: String,
    pub reason: String,
    pub command_id: String,
    pub command_kind: String,
    pub risk_class: String,
    pub requires_user_confirmation: bool,
}

impl SecureCommandEvaluation {
    pub fn to_json(&self) -> Value {
        json!({
            "ok": true,
            "protocolVersion": SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "accepted": self.accepted,
            "shouldExecute": self.should_execute,
            "replayed": self.replayed,
            "code": self.code,
            "reason": self.reason,
            "commandId": self.command_id,
            "commandKind": self.command_kind,
            "riskClass": self.risk_class,
            "requiresUserConfirmation": self.requires_user_confirmation,
            "bodyRedacted": true,
        })
    }
}

pub trait SecureCommandLocalExecutor {
    fn execute_secure_command(&mut self, payload: &SecureCommandPayload) -> Result<Value>;
}

#[derive(Default)]
pub struct SecureCommandRuntimeExecutor;

#[derive(Debug)]
struct SecureAgentDispatchFailure {
    code: &'static str,
    retryable: bool,
}

impl SecureAgentDispatchFailure {
    const fn new(code: &'static str, retryable: bool) -> Self {
        Self { code, retryable }
    }

    fn from_adapter_code(code: &str) -> Self {
        let code = code.to_ascii_lowercase();
        if code.contains("timeout") {
            Self::new("native_agent_timeout", true)
        } else if code.contains("cancel") || code.contains("interrupt") {
            Self::new("native_agent_cancelled", true)
        } else if code.contains("approval")
            || code.contains("permission")
            || code.contains("interaction")
        {
            Self::new("native_agent_user_interaction_required", true)
        } else if code.contains("login") || code.contains("auth") || code.contains("credential") {
            Self::new("native_agent_authentication_required", true)
        } else if code.contains("session") || code.contains("resume") || code.contains("thread") {
            Self::new("native_agent_session_rejected", false)
        } else if code.contains("model") || code.contains("setting") || code.contains("effort") {
            Self::new("native_agent_configuration_rejected", false)
        } else if code.contains("output_limit") || code.contains("stdout_limit") {
            Self::new("native_agent_output_limit", false)
        } else if code.contains("process")
            || code.contains("executable")
            || code.contains("unavailable")
        {
            Self::new("native_agent_runtime_unavailable", true)
        } else {
            Self::new("native_agent_dispatch_failed", false)
        }
    }
}

impl fmt::Display for SecureAgentDispatchFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.code)
    }
}

impl StdError for SecureAgentDispatchFailure {}

impl SecureCommandLocalExecutor for SecureCommandRuntimeExecutor {
    fn execute_secure_command(&mut self, payload: &SecureCommandPayload) -> Result<Value> {
        match payload.command_kind.as_str() {
            "agent.sessions.list" => crate::domain::conversations::conversation_list(
                &agent_sessions_list_params(payload)?,
            ),
            "agent.sessions.describe" => crate::domain::conversations::conversation_list(
                &agent_sessions_describe_params(payload)?,
            ),
            "agent.message.send" => {
                let mut params = agent_message_send_params(payload)?;
                let agent = text_from_any(&params, &["agent", "agentId", "target"])
                    .ok_or_else(|| anyhow!("agent message target is unavailable"))?;
                if !crate::platform::runtime_adapters::runtime_driver_profile(&agent)
                    .is_some_and(|profile| profile.readiness == "ready")
                {
                    return Err(anyhow::Error::new(SecureAgentDispatchFailure::new(
                        "native_agent_parity_not_ready",
                        false,
                    )));
                }
                let executable = crate::domain::targets::ready_runtime_executable(&agent)
                    .ok_or_else(|| {
                        anyhow::Error::new(SecureAgentDispatchFailure::new(
                            "native_agent_runtime_binding_unavailable",
                            false,
                        ))
                    })?;
                params["binaryPath"] = json!(executable.to_string_lossy());
                dispatch_ready_agent_message(&params, crate::platform::dispatch_lane_operation)
            }
            "provider.chat.send" => {
                crate::domain::forwarding::provider_chat(&provider_chat_send_params(payload)?)
            }
            "provider.credential.export" => crate::domain::forwarding::export_provider_credential(
                &provider_credential_export_params(payload)?,
            ),
            "client.activity.sync" => crate::platform::client_state::activity_list(&filtered_body(
                payload.body(),
                CLIENT_ACTIVITY_SYNC_PAYLOAD_FIELDS,
            )?),
            "client.snapshot.request" => crate::platform::client_state::snapshots_list(
                &filtered_body(payload.body(), CLIENT_SNAPSHOT_REQUEST_PAYLOAD_FIELDS)?,
            ),
            "secure_mesh.device.verify" => Err(anyhow!(
                "secure mesh command runtime binding requires an interactive endpoint UI for {}",
                payload.command_kind
            )),
            _ => Err(anyhow!(
                "secure mesh command runtime binding does not implement {}",
                payload.command_kind
            )),
        }
    }
}

fn dispatch_ready_agent_message<F>(params: &Value, dispatch_lane: F) -> Result<Value>
where
    F: FnOnce(&str, &Value) -> Result<Value>,
{
    successful_agent_dispatch(dispatch_lane("send", params))
}

fn successful_agent_dispatch(result: Result<Value>) -> Result<Value> {
    let result = result?;
    if result.get("ok").and_then(Value::as_bool) != Some(true) {
        let code = result
            .get("error")
            .and_then(|error| error.get("code"))
            .and_then(Value::as_str)
            .or_else(|| result.get("code").and_then(Value::as_str))
            .unwrap_or_default();
        return Err(anyhow::Error::new(
            SecureAgentDispatchFailure::from_adapter_code(code),
        ));
    }
    Ok(result)
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SecureCommandExecutionOutcome {
    Result(SecureMeshResultPayload),
    Error(SecureMeshErrorPayload),
}

impl SecureCommandExecutionOutcome {
    pub fn result(self) -> Option<SecureMeshResultPayload> {
        match self {
            Self::Result(result) => Some(result),
            Self::Error(_) => None,
        }
    }

    pub fn error(self) -> Option<SecureMeshErrorPayload> {
        match self {
            Self::Result(_) => None,
            Self::Error(error) => Some(error),
        }
    }
}

pub fn evaluate_secure_command(
    payload: &SecureCommandPayload,
    context: &SecureCommandEvaluationContext,
    ledger: &mut impl SecureCommandReplayStore,
) -> Result<SecureCommandEvaluation> {
    if payload.sender_identity.endpoint_id != context.sender_endpoint_id {
        return Ok(reject(payload, "sender_identity_mismatch"));
    }
    if payload.sender_identity.identity_fingerprint != context.sender_identity_fingerprint {
        return Ok(reject(payload, "sender_fingerprint_mismatch"));
    }
    if payload.sender_identity.endpoint_kind != context.sender_endpoint_kind {
        return Ok(reject(payload, "sender_endpoint_kind_mismatch"));
    }
    if payload.sender_identity.trust_state != context.sender_trust_state {
        return Ok(reject(payload, "sender_trust_state_mismatch"));
    }
    if matches!(
        context.sender_trust_state,
        DeviceTrustState::KeyChanged | DeviceTrustState::Revoked
    ) {
        return Ok(reject(payload, "sender_device_trust_rejected"));
    }
    if !context.sender_roster_active || !context.target_roster_active {
        return Ok(reject(payload, "roster_inactive"));
    }
    if !context.session_or_epoch_valid {
        return Ok(reject(payload, "session_or_epoch_invalid"));
    }
    if ledger.has_command_id(&payload.command_id)? {
        return Ok(no_execute(payload, "command_replay_rejected", true));
    }
    if payload.created_at_time > context.now + time::Duration::seconds(MAX_CLOCK_SKEW_SECONDS) {
        return Ok(reject(payload, "created_at_clock_skew_rejected"));
    }
    if payload.expires_at_time <= context.now {
        return Ok(reject(payload, "command_expired"));
    }
    if denied_prefix(&payload.command_kind).is_some()
        || !ALLOWED_COMMANDS.contains(&payload.command_kind.as_str())
    {
        return Ok(reject(payload, "command_not_allowlisted"));
    }
    if let Some(minimum_risk) = minimum_risk_class(&payload.command_kind) {
        if payload.risk_class.rank() < minimum_risk.rank() {
            return Ok(reject(payload, "risk_class_understated"));
        }
    }
    if payload.target_binding.target_endpoint_id != context.local_endpoint_id {
        return Ok(reject(payload, "target_endpoint_mismatch"));
    }
    if !binding_allowed(
        payload.target_binding.workspace_id.as_deref(),
        &context.allowed_workspace_ids,
    ) {
        return Ok(reject(payload, "workspace_binding_rejected"));
    }
    if !binding_allowed(
        payload.target_binding.target_agent_id.as_deref(),
        &context.allowed_agent_ids,
    ) {
        return Ok(reject(payload, "agent_binding_rejected"));
    }
    if matches!(payload.risk_class, SecureCommandRiskClass::HighRisk)
        && (!trusted_for_high_risk(&context.sender_trust_state)
            || context.sender_endpoint_kind == "web_limited")
    {
        return Ok(reject(payload, "high_risk_sender_rejected"));
    }
    if confirmation_required(payload) && !context.user_confirmed {
        return Ok(no_execute(payload, "user_confirmation_required", false));
    }
    match ledger.record_execution(payload, context.now)? {
        SecureCommandReplayRecordStatus::Fresh => Ok(SecureCommandEvaluation {
            accepted: true,
            should_execute: true,
            replayed: false,
            code: "execute".to_string(),
            reason: "secure mesh command passed local receive gates".to_string(),
            command_id: payload.command_id.clone(),
            command_kind: payload.command_kind.clone(),
            risk_class: payload.risk_class.as_str().to_string(),
            requires_user_confirmation: payload.requires_user_confirmation,
        }),
        SecureCommandReplayRecordStatus::CommandReplay => {
            Ok(no_execute(payload, "command_replay_rejected", true))
        }
        SecureCommandReplayRecordStatus::IdempotentReplay => {
            Ok(no_execute(payload, "idempotent_replay", true))
        }
        SecureCommandReplayRecordStatus::IdempotencyConflict => {
            Ok(reject(payload, "idempotency_conflict"))
        }
    }
}

pub fn execute_evaluated_secure_command(
    payload: &SecureCommandPayload,
    evaluation: &SecureCommandEvaluation,
    executor: &mut impl SecureCommandLocalExecutor,
    completed_at: impl Into<String>,
) -> Result<SecureCommandExecutionOutcome> {
    let completed_at = completed_at.into();
    ensure!(
        !completed_at.trim().is_empty(),
        "secure mesh command execution completedAt is required"
    );
    ensure!(
        evaluation.command_id == payload.command_id
            && evaluation.command_kind == payload.command_kind
            && evaluation.risk_class == payload.risk_class.as_str(),
        "secure mesh command execution evaluation does not match payload"
    );
    if !evaluation.should_execute {
        return Ok(SecureCommandExecutionOutcome::Error(command_error_payload(
            payload,
            &evaluation.code,
            evaluation.accepted && !evaluation.replayed,
            &completed_at,
            &evaluation.reason,
        )));
    }
    let output = match executor.execute_secure_command(payload) {
        Ok(output) => output,
        Err(error) => {
            let classified = error.downcast_ref::<SecureAgentDispatchFailure>();
            return Ok(SecureCommandExecutionOutcome::Error(command_error_payload(
                payload,
                classified
                    .map(|failure| failure.code)
                    .unwrap_or("local_execution_failed"),
                classified.map(|failure| failure.retryable).unwrap_or(true),
                &completed_at,
                LOCAL_EXECUTION_FAILED_REMOTE_DETAIL,
            )));
        }
    };
    Ok(SecureCommandExecutionOutcome::Result(
        SecureMeshResultPayload {
            command_id: payload.command_id.clone(),
            idempotency_key: payload.idempotency_key.clone(),
            output_content_type: "application/json".to_string(),
            completed_at,
            output: serde_json::to_vec(&json!({
                "ok": true,
                "commandKind": payload.command_kind,
                "output": output,
            }))?,
        },
    ))
}

pub fn evaluate_secure_command_json(
    payload: &Value,
    context: &Value,
    ledger: &mut SecureCommandReplayLedger,
) -> Result<Value> {
    let payload = SecureCommandPayload::from_value(payload)?;
    let context = SecureCommandEvaluationContext::from_value(context)?;
    Ok(evaluate_secure_command(&payload, &context, ledger)?.to_json())
}

pub fn execute_secure_command_json(
    payload: &Value,
    context: &Value,
    ledger: &mut impl SecureCommandReplayStore,
    executor: &mut impl SecureCommandLocalExecutor,
    completed_at: impl Into<String>,
) -> Result<Value> {
    let payload = SecureCommandPayload::from_value(payload)?;
    let context = SecureCommandEvaluationContext::from_value(context)?;
    let evaluation = evaluate_secure_command(&payload, &context, ledger)?;
    let outcome =
        execute_evaluated_secure_command(&payload, &evaluation, executor, completed_at.into())?;
    Ok(json!({
        "ok": true,
        "protocolVersion": SECURE_MESH_COMMAND_PROTOCOL_VERSION,
        "evaluation": evaluation.to_json(),
        "execution": command_execution_outcome_json(outcome),
        "bodyRedacted": true,
    }))
}

pub fn default_secure_command_ledger_path() -> Result<PathBuf> {
    let path = crate::platform::paths::portable_data_dir()?.join(SECURE_MESH_COMMAND_LEDGER_PATH);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    Ok(path)
}

fn command_execution_outcome_json(outcome: SecureCommandExecutionOutcome) -> Value {
    match outcome {
        SecureCommandExecutionOutcome::Result(result) => json!({
            "outcome": "result",
            "commandId": result.command_id,
            "idempotencyKey": result.idempotency_key,
            "outputContentType": result.output_content_type,
            "completedAt": result.completed_at,
            "output": response_output_json(&result.output),
        }),
        SecureCommandExecutionOutcome::Error(error) => json!({
            "outcome": "error",
            "commandId": error.command_id,
            "idempotencyKey": error.idempotency_key,
            "errorCode": error.error_code,
            "retryable": error.retryable,
            "occurredAt": error.occurred_at,
            "errorDetail": error.error_detail,
        }),
    }
}

fn response_output_json(output: &[u8]) -> Value {
    serde_json::from_slice(output).unwrap_or_else(|_| {
        json!({
            "base64": general_purpose::URL_SAFE_NO_PAD.encode(output),
        })
    })
}

fn agent_sessions_list_params(payload: &SecureCommandPayload) -> Result<Value> {
    let body = filtered_body(payload.body(), AGENT_SESSIONS_LIST_PAYLOAD_FIELDS)?;
    let agent = text_from_any(&body, &["agent", "agentId", "target"])
        .ok_or_else(|| anyhow!("secure mesh command agent.sessions.list requires agent id"))?;
    let mut params = Map::new();
    params.insert("agent".to_string(), json!(agent));
    if let Some(limit) = body.get("limit").and_then(Value::as_u64) {
        params.insert("limit".to_string(), json!(limit.min(100)));
    }
    if let Some(offset) = body.get("offset").and_then(Value::as_u64) {
        params.insert("offset".to_string(), json!(offset));
    }
    Ok(Value::Object(params))
}

fn agent_sessions_describe_params(payload: &SecureCommandPayload) -> Result<Value> {
    let body = filtered_body(payload.body(), AGENT_SESSIONS_DESCRIBE_PAYLOAD_FIELDS)?;
    let agent = text_from_any(&body, &["agent", "agentId", "target"])
        .ok_or_else(|| anyhow!("secure mesh command agent.sessions.describe requires agent id"))?;
    let session_id = text_from_any(&body, &["sessionId", "nativeSessionId"]).ok_or_else(|| {
        anyhow!("secure mesh command agent.sessions.describe requires session id")
    })?;
    Ok(json!({
        "agent": agent,
        "sessionId": session_id,
        "limit": 1,
        "offset": 0,
    }))
}

fn agent_message_send_params(payload: &SecureCommandPayload) -> Result<Value> {
    let mut body = filtered_body(payload.body(), AGENT_MESSAGE_SEND_PAYLOAD_FIELDS)?;
    ensure!(
        text_from_any(&body, &["agent", "agentId", "target"]).is_some(),
        "secure mesh command agent.message.send requires agent id"
    );
    ensure!(
        text_from_any(&body, &["text", "message", "prompt"]).is_some(),
        "secure mesh command agent.message.send requires message text"
    );
    body["timeoutMs"] = json!(SECURE_AGENT_MESSAGE_TIMEOUT_MS);
    Ok(body)
}

fn provider_chat_send_params(payload: &SecureCommandPayload) -> Result<Value> {
    let body = filtered_body(payload.body(), PROVIDER_CHAT_SEND_PAYLOAD_FIELDS)?;
    ensure!(
        text_from_any(
            &body,
            &[
                "provider",
                "providerId",
                "profile",
                "profileId",
                "modelProfile"
            ]
        )
        .is_some(),
        "secure mesh command provider.chat.send requires provider id"
    );
    ensure!(
        text_from_any(&body, &["text", "message", "prompt", "input"]).is_some()
            || body.get("messages").and_then(Value::as_array).is_some(),
        "secure mesh command provider.chat.send requires message text"
    );
    Ok(body)
}

fn provider_credential_export_params(payload: &SecureCommandPayload) -> Result<Value> {
    let body = filtered_body(payload.body(), PROVIDER_CREDENTIAL_EXPORT_PAYLOAD_FIELDS)?;
    ensure!(
        text_from_any(
            &body,
            &[
                "provider",
                "providerId",
                "profile",
                "profileId",
                "modelProfile"
            ]
        )
        .is_some(),
        "secure mesh command provider.credential.export requires provider id"
    );
    Ok(body)
}

fn filtered_body(body: &Value, allowed_fields: &[&str]) -> Result<Value> {
    let object = body
        .as_object()
        .ok_or_else(|| anyhow!("secure mesh command body must be a JSON object"))?;
    let mut out = Map::new();
    for (key, value) in object {
        if COMMAND_BODY_DENIED_LOCAL_RUNTIME_FIELDS.contains(&key.as_str()) {
            bail!(
                "secure mesh command body cannot carry local runtime execution field: {}",
                key
            );
        }
        ensure!(
            allowed_fields.contains(&key.as_str()),
            "secure mesh command body field is not enabled for local execution: {}",
            key
        );
        out.insert(key.clone(), value.clone());
    }
    Ok(Value::Object(out))
}

fn text_from_any(value: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .filter_map(|key| value.get(*key).and_then(Value::as_str))
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(ToString::to_string)
}

fn command_error_payload(
    payload: &SecureCommandPayload,
    error_code: &str,
    retryable: bool,
    occurred_at: &str,
    error_detail: &str,
) -> SecureMeshErrorPayload {
    SecureMeshErrorPayload {
        command_id: payload.command_id.clone(),
        idempotency_key: payload.idempotency_key.clone(),
        error_code: error_code.to_string(),
        retryable,
        occurred_at: occurred_at.to_string(),
        error_detail: error_detail.to_string(),
    }
}

fn read_sender_identity(value: &Value) -> Result<SecureCommandSenderIdentity> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure mesh command senderIdentity must be a JSON object"))?;
    ensure_allowed_keys(
        "secure mesh command senderIdentity",
        object.keys().map(String::as_str),
        &[
            "endpointId",
            "identityFingerprint",
            "trustState",
            "endpointKind",
        ],
    )?;
    Ok(SecureCommandSenderIdentity {
        endpoint_id: read_required_string(value, "endpointId", MAX_ENDPOINT_ID_BYTES)?,
        identity_fingerprint: read_required_string(
            value,
            "identityFingerprint",
            MAX_FINGERPRINT_BYTES,
        )?,
        trust_state: trust_state_from_str(&read_required_string(value, "trustState", 64)?)?,
        endpoint_kind: read_required_string(value, "endpointKind", MAX_ENDPOINT_ID_BYTES)?,
    })
}

fn read_target_binding(value: &Value) -> Result<SecureCommandTargetBinding> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure mesh command targetBinding must be a JSON object"))?;
    ensure_allowed_keys(
        "secure mesh command targetBinding",
        object.keys().map(String::as_str),
        &["targetEndpointId", "targetAgentId", "workspaceId"],
    )?;
    Ok(SecureCommandTargetBinding {
        target_endpoint_id: read_required_string(value, "targetEndpointId", MAX_ENDPOINT_ID_BYTES)?,
        target_agent_id: read_optional_string(value, "targetAgentId", MAX_BINDING_ID_BYTES)?,
        workspace_id: read_optional_string(value, "workspaceId", MAX_BINDING_ID_BYTES)?,
    })
}

fn ensure_allowed_keys<'a>(
    context: &str,
    keys: impl Iterator<Item = &'a str>,
    allowed: &[&str],
) -> Result<()> {
    for key in keys {
        ensure!(
            allowed.contains(&key),
            "{} contains unsupported field {}",
            context,
            key
        );
    }
    Ok(())
}

fn read_required_string(value: &Value, key: &str, max_bytes: usize) -> Result<String> {
    let raw = value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure mesh command {} is required", key))?
        .trim();
    ensure!(
        !raw.is_empty(),
        "secure mesh command {} must not be empty",
        key
    );
    ensure!(
        raw.len() <= max_bytes,
        "secure mesh command {} is too large",
        key
    );
    Ok(raw.to_string())
}

fn read_optional_string(value: &Value, key: &str, max_bytes: usize) -> Result<Option<String>> {
    match value.get(key) {
        Some(Value::String(raw)) => {
            let trimmed = raw.trim();
            ensure!(
                !trimmed.is_empty(),
                "secure mesh command {} must not be empty",
                key
            );
            ensure!(
                trimmed.len() <= max_bytes,
                "secure mesh command {} is too large",
                key
            );
            Ok(Some(trimmed.to_string()))
        }
        Some(Value::Null) | None => Ok(None),
        _ => bail!("secure mesh command {} must be a string", key),
    }
}

fn read_required_bool(value: &Value, key: &str) -> Result<bool> {
    value
        .get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| anyhow!("secure mesh command {} is required", key))
}

fn read_string_set(value: &Value, key: &str) -> Result<BTreeSet<String>> {
    let mut out = BTreeSet::new();
    let Some(raw) = value.get(key) else {
        return Ok(out);
    };
    let values = raw
        .as_array()
        .ok_or_else(|| anyhow!("secure mesh command {} must be an array", key))?;
    for value in values {
        let item = value
            .as_str()
            .ok_or_else(|| anyhow!("secure mesh command {} entries must be strings", key))?
            .trim();
        ensure!(
            !item.is_empty(),
            "secure mesh command {} entries must not be empty",
            key
        );
        ensure!(
            item.len() <= MAX_BINDING_ID_BYTES,
            "secure mesh command {} entry is too large",
            key
        );
        out.insert(item.to_string());
    }
    Ok(out)
}

fn parse_timestamp(key: &str, value: &str) -> Result<OffsetDateTime> {
    OffsetDateTime::parse(value, &Rfc3339)
        .map_err(|error| anyhow!("secure mesh command {} is not RFC3339: {error}", key))
}

fn trust_state_from_str(value: &str) -> Result<DeviceTrustState> {
    match value {
        "unverified" => Ok(DeviceTrustState::Unverified),
        "verified" => Ok(DeviceTrustState::Verified),
        "cross_signed" => Ok(DeviceTrustState::CrossSigned),
        "changed" | "key_changed" => Ok(DeviceTrustState::KeyChanged),
        "revoked" => Ok(DeviceTrustState::Revoked),
        _ => bail!("secure mesh command sender trust state is unsupported"),
    }
}

fn denied_prefix(command_kind: &str) -> Option<&'static str> {
    DENIED_PREFIXES
        .iter()
        .find(|prefix| command_kind.starts_with(**prefix))
        .copied()
}

fn binding_allowed(value: Option<&str>, allowed_values: &BTreeSet<String>) -> bool {
    match value {
        // An empty set means no bound value is authorized; it is never a
        // wildcard. Unbound commands remain valid only when no binding policy
        // was supplied for that dimension.
        None => allowed_values.is_empty(),
        Some(_) if allowed_values.is_empty() => false,
        Some(candidate) => allowed_values.contains(candidate),
    }
}

fn trusted_for_high_risk(trust_state: &DeviceTrustState) -> bool {
    matches!(
        trust_state,
        DeviceTrustState::Verified | DeviceTrustState::CrossSigned
    )
}

fn minimum_risk_class(command_kind: &str) -> Option<SecureCommandRiskClass> {
    match command_kind {
        "agent.sessions.list"
        | "agent.sessions.describe"
        | "client.activity.sync"
        | "client.snapshot.request" => Some(SecureCommandRiskClass::ReadOnly),
        "agent.message.send" | "provider.chat.send" => Some(SecureCommandRiskClass::SafeWrite),
        "provider.credential.export" => Some(SecureCommandRiskClass::HighRisk),
        "secure_mesh.device.verify" => Some(SecureCommandRiskClass::LocalEffect),
        _ => None,
    }
}

fn confirmation_required(payload: &SecureCommandPayload) -> bool {
    payload.requires_user_confirmation
        || matches!(
            payload.risk_class,
            SecureCommandRiskClass::LocalEffect | SecureCommandRiskClass::HighRisk
        )
}

fn reject(payload: &SecureCommandPayload, code: &str) -> SecureCommandEvaluation {
    SecureCommandEvaluation {
        accepted: false,
        should_execute: false,
        replayed: false,
        code: code.to_string(),
        reason: format!("secure mesh command rejected by {}", code),
        command_id: payload.command_id.clone(),
        command_kind: payload.command_kind.clone(),
        risk_class: payload.risk_class.as_str().to_string(),
        requires_user_confirmation: payload.requires_user_confirmation,
    }
}

fn no_execute(
    payload: &SecureCommandPayload,
    code: &str,
    replayed: bool,
) -> SecureCommandEvaluation {
    SecureCommandEvaluation {
        accepted: true,
        should_execute: false,
        replayed,
        code: code.to_string(),
        reason: format!("secure mesh command accepted without execution by {}", code),
        command_id: payload.command_id.clone(),
        command_kind: payload.command_kind.clone(),
        risk_class: payload.risk_class.as_str().to_string(),
        requires_user_confirmation: payload.requires_user_confirmation,
    }
}

fn hex_digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_crypto::{ContentKey, SecureMeshContentContext};
    use crate::core::secure_mesh_response::{open_command_result, seal_command_result};
    use serde_json::json;

    #[test]
    fn secure_mesh_command_gate_accepts_allowlisted_bound_command() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(evaluation.accepted);
        assert!(evaluation.should_execute);
        assert!(!evaluation.replayed);
        assert_eq!(evaluation.code, "execute");
        assert_eq!(evaluation.to_json()["bodyRedacted"], true);
        assert!(evaluation.to_json().get("body").is_none());
    }

    #[test]
    fn agent_sessions_list_params_forward_offset_and_limit() {
        let mut raw = command_fixture();
        raw["commandKind"] = json!("agent.sessions.list");
        raw["riskClass"] = json!("read_only");
        raw["body"] = json!({
            "agentId": "codex",
            "limit": 20,
            "offset": 40,
        });
        let payload = SecureCommandPayload::from_value(&raw).unwrap();
        let params = agent_sessions_list_params(&payload).unwrap();
        assert_eq!(params["agent"], "codex");
        assert_eq!(params["limit"], 20);
        assert_eq!(params["offset"], 40);
    }

    #[test]
    fn agent_sessions_describe_params_require_session_identity() {
        let mut raw = command_fixture();
        raw["commandKind"] = json!("agent.sessions.describe");
        raw["riskClass"] = json!("read_only");
        raw["body"] = json!({
            "agentId": "codex",
            "nativeSessionId": "codex-native-exact",
        });
        let payload = SecureCommandPayload::from_value(&raw).unwrap();
        let params = agent_sessions_describe_params(&payload).unwrap();
        assert_eq!(params["agent"], "codex");
        assert_eq!(params["sessionId"], "codex-native-exact");
        assert_eq!(params["limit"], 1);
        assert_eq!(params["offset"], 0);

        raw["body"] = json!({"agentId": "codex"});
        let missing = SecureCommandPayload::from_value(&raw).unwrap();
        assert!(agent_sessions_describe_params(&missing).is_err());
    }

    #[test]
    fn secure_mesh_command_gate_accepts_sessions_describe_as_read_only() {
        let mut raw = command_fixture();
        raw["commandKind"] = json!("agent.sessions.describe");
        raw["riskClass"] = json!("read_only");
        raw["targetBinding"]["targetAgentId"] = json!("codex");
        raw["body"] = json!({
            "agentId": "codex",
            "sessionId": "codex-native-exact",
        });
        let payload = SecureCommandPayload::from_value(&raw).unwrap();
        let mut context = context_fixture();
        context["allowedAgentIds"] = json!(["codex"]);
        let context = SecureCommandEvaluationContext::from_value(&context).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(evaluation.accepted);
        assert!(evaluation.should_execute);
        assert_eq!(evaluation.risk_class, "read_only");
    }

    #[test]
    fn secure_mesh_command_gate_rejects_web_limited_high_risk() {
        let mut raw = command_fixture();
        raw["riskClass"] = json!("high_risk");
        raw["senderIdentity"]["endpointKind"] = json!("web_limited");
        let mut context = context_fixture();
        context["senderEndpointKind"] = json!("web_limited");
        let payload = SecureCommandPayload::from_value(&raw).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(!evaluation.accepted);
        assert!(!evaluation.should_execute);
        assert_eq!(evaluation.code, "high_risk_sender_rejected");
    }

    #[test]
    fn secure_mesh_command_gate_rejects_understated_command_risk() {
        let mut raw = command_fixture();
        raw["riskClass"] = json!("read_only");
        let payload = SecureCommandPayload::from_value(&raw).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();

        assert!(!evaluation.accepted);
        assert!(!evaluation.should_execute);
        assert_eq!(evaluation.code, "risk_class_understated");
    }

    #[test]
    fn secure_mesh_command_gate_requires_user_confirmation_for_protected_local_effects() {
        for (command_kind, risk_class, body) in [
            ("secure_mesh.device.verify", "local_effect", json!({})),
            (
                "provider.credential.export",
                "high_risk",
                json!({"provider": "deepseek"}),
            ),
        ] {
            let mut raw = command_fixture();
            raw["commandKind"] = json!(command_kind);
            raw["riskClass"] = json!(risk_class);
            raw["targetBinding"]["targetAgentId"] = Value::Null;
            raw["body"] = body;
            let payload = SecureCommandPayload::from_value(&raw).unwrap();
            let mut context = context_fixture();
            context["allowedAgentIds"] = json!([]);
            let context = SecureCommandEvaluationContext::from_value(&context).unwrap();
            let mut ledger = SecureCommandReplayLedger::default();
            let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();

            assert!(
                evaluation.accepted,
                "{command_kind} should pass identity gates"
            );
            assert!(
                !evaluation.should_execute,
                "{command_kind} must not execute without local user confirmation"
            );
            assert_eq!(evaluation.code, "user_confirmation_required");
        }
    }

    #[test]
    fn secure_mesh_command_gate_rejects_target_mismatch() {
        let mut raw = command_fixture();
        raw["targetBinding"]["targetEndpointId"] = json!("pc-c");
        let payload = SecureCommandPayload::from_value(&raw).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(!evaluation.accepted);
        assert_eq!(evaluation.code, "target_endpoint_mismatch");
    }

    #[test]
    fn secure_mesh_command_idempotency_prevents_duplicate_execution() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let first = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(first.should_execute);

        let mut retry_raw = command_fixture();
        retry_raw["commandId"] = json!("cmd-b");
        let retry = SecureCommandPayload::from_value(&retry_raw).unwrap();
        let second = evaluate_secure_command(&retry, &context, &mut ledger).unwrap();
        assert!(second.accepted);
        assert!(!second.should_execute);
        assert!(second.replayed);
        assert_eq!(second.code, "idempotent_replay");
    }

    #[test]
    fn secure_mesh_command_idempotency_conflict_rejected() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let first = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(first.should_execute);

        let mut conflicting_raw = command_fixture();
        conflicting_raw["commandId"] = json!("cmd-c");
        conflicting_raw["body"] = json!({"message": "changed"});
        let conflicting = SecureCommandPayload::from_value(&conflicting_raw).unwrap();
        let second = evaluate_secure_command(&conflicting, &context, &mut ledger).unwrap();
        assert!(!second.accepted);
        assert!(!second.should_execute);
        assert_eq!(second.code, "idempotency_conflict");
    }

    #[test]
    fn secure_mesh_command_replay_command_id_does_not_execute() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let first = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(first.should_execute);

        let mut replay_raw = command_fixture();
        replay_raw["idempotencyKey"] = json!("idem-b");
        let replay = SecureCommandPayload::from_value(&replay_raw).unwrap();
        let second = evaluate_secure_command(&replay, &context, &mut ledger).unwrap();
        assert!(second.accepted);
        assert!(!second.should_execute);
        assert!(second.replayed);
        assert_eq!(second.code, "command_replay_rejected");
    }

    #[test]
    fn secure_mesh_command_schema_rejects_extra_fields() {
        let mut raw = command_fixture();
        raw["plaintext"] = json!("not allowed");
        let error = SecureCommandPayload::from_value(&raw).unwrap_err();
        assert!(error.to_string().contains("unsupported field plaintext"));
    }

    #[test]
    fn secure_mesh_command_sqlite_ledger_survives_reopen_and_bounds_entries() {
        let path = std::env::temp_dir().join(format!(
            "lico-secure-mesh-command-ledger-{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();

        {
            let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
            let mut ledger =
                SecureCommandSqliteReplayLedger::open_with_max_entries(&path, 2).unwrap();
            let first = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
            assert!(first.should_execute);
            assert_eq!(ledger.entry_count().unwrap(), 1);
        }

        {
            let mut ledger =
                SecureCommandSqliteReplayLedger::open_with_max_entries(&path, 2).unwrap();
            let retry = SecureCommandPayload::from_value(&command_fixture_with(
                "cmd-b",
                "idem-a",
                json!({"message": "hello"}),
            ))
            .unwrap();
            let replay = evaluate_secure_command(&retry, &context, &mut ledger).unwrap();
            assert!(replay.accepted);
            assert!(!replay.should_execute);
            assert!(replay.replayed);
            assert_eq!(replay.code, "idempotent_replay");

            for index in 0..3 {
                let payload = SecureCommandPayload::from_value(&command_fixture_with(
                    &format!("cmd-extra-{index}"),
                    &format!("idem-extra-{index}"),
                    json!({"message": format!("extra-{index}")}),
                ))
                .unwrap();
                let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
                assert!(evaluation.should_execute);
            }
            assert!(ledger.entry_count().unwrap() <= 2);
        }

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn secure_mesh_command_execution_wraps_result_payload_after_gate() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(evaluation.should_execute);

        let mut executor = FixtureExecutor::default();
        let outcome = execute_evaluated_secure_command(
            &payload,
            &evaluation,
            &mut executor,
            "2026-01-01T00:02:00Z",
        )
        .unwrap();
        assert_eq!(executor.calls, 1);
        let result = outcome.result().unwrap();
        assert_eq!(result.command_id, "cmd-a");
        assert_eq!(result.idempotency_key, "idem-a");
        assert!(!String::from_utf8_lossy(&result.output).contains("requiresUserConfirmation"));

        let key = ContentKey::from_bytes([31; 32]);
        let encrypted = seal_command_result(&key, &response_context_fixture(), &result).unwrap();
        let opened = open_command_result(&key, &response_context_fixture(), &encrypted).unwrap();
        assert_eq!(opened, result);
    }

    #[test]
    fn secure_mesh_command_execution_does_not_call_executor_for_rejected_gate() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let mut context = context_fixture();
        context["senderRosterActive"] = json!(false);
        let context = SecureCommandEvaluationContext::from_value(&context).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(!evaluation.accepted);
        assert!(!evaluation.should_execute);

        let mut executor = FixtureExecutor::default();
        let outcome = execute_evaluated_secure_command(
            &payload,
            &evaluation,
            &mut executor,
            "2026-01-01T00:02:00Z",
        )
        .unwrap();
        assert_eq!(executor.calls, 0);
        let error = outcome.error().unwrap();
        assert_eq!(error.error_code, "roster_inactive");
        assert!(!error.retryable);
    }

    #[test]
    fn secure_mesh_command_execution_redacts_executor_error_detail() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        let mut executor = FixtureExecutor {
            fail: true,
            failure_detail: "fixture execution failed at <user-home>/private with token=local-secret-canary",
            ..FixtureExecutor::default()
        };
        let outcome = execute_evaluated_secure_command(
            &payload,
            &evaluation,
            &mut executor,
            "2026-01-01T00:02:00Z",
        )
        .unwrap();
        assert_eq!(executor.calls, 1);
        let error = outcome.error().unwrap();
        assert_eq!(error.error_code, "local_execution_failed");
        assert!(error.retryable);
        assert_eq!(error.error_detail, LOCAL_EXECUTION_FAILED_REMOTE_DETAIL);
        assert!(!error.error_detail.contains("<user-home>/private"));
        assert!(!error.error_detail.contains("local-secret-canary"));
    }

    #[test]
    fn secure_mesh_command_denies_local_runtime_fields_before_runtime_dispatch() {
        let payload = SecureCommandPayload::from_value(&command_fixture_with(
            "cmd-denied-local-runtime-fields",
            "idem-denied-local-runtime-fields",
            json!({
                "agentId": "agent-a",
                "text": "hello",
                "command": "open",
                "args": ["/tmp/not-allowed"],
                "cwd": "/tmp/not-allowed",
                "env": {"LOCAL_SECRET_CANARY": "must-not-leak"},
                "shell": true
            }),
        ))
        .unwrap();
        let context = SecureCommandEvaluationContext::from_value(&context_fixture()).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();
        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();
        assert!(evaluation.should_execute);

        let mut executor = FilteringExecutor::default();
        let outcome = execute_evaluated_secure_command(
            &payload,
            &evaluation,
            &mut executor,
            "2026-01-01T00:02:00Z",
        )
        .unwrap();
        assert_eq!(executor.runtime_calls, 0);
        let error = outcome.error().unwrap();
        assert_eq!(error.error_code, "local_execution_failed");
        assert_eq!(error.error_detail, LOCAL_EXECUTION_FAILED_REMOTE_DETAIL);
        let serialized = format!("{error:?}");
        assert!(!serialized.contains("/tmp/not-allowed"));
        assert!(!serialized.contains("LOCAL_SECRET_CANARY"));
    }

    #[test]
    fn empty_agent_allowlist_never_authorizes_a_bound_agent() {
        let payload = SecureCommandPayload::from_value(&command_fixture()).unwrap();
        let mut context = context_fixture();
        context["allowedAgentIds"] = json!([]);
        let context = SecureCommandEvaluationContext::from_value(&context).unwrap();
        let mut ledger = SecureCommandReplayLedger::default();

        let evaluation = evaluate_secure_command(&payload, &context, &mut ledger).unwrap();

        assert!(!evaluation.accepted);
        assert!(!evaluation.should_execute);
        assert_eq!(evaluation.code, "agent_binding_rejected");
    }

    #[test]
    fn runtime_executor_rejects_an_agent_without_ready_parity() {
        let payload = SecureCommandPayload::from_value(&command_fixture_with(
            "cmd-unready-agent",
            "idem-unready-agent",
            json!({
                "agentId": "unsupported-fixture-agent",
                "text": "fixture message"
            }),
        ))
        .unwrap();
        let mut executor = SecureCommandRuntimeExecutor;

        let error = executor.execute_secure_command(&payload).unwrap_err();

        assert_eq!(error.to_string(), "native_agent_parity_not_ready");
    }

    #[test]
    fn ready_agent_dispatch_uses_the_shared_conversation_lane() {
        let params = json!({
            "agent": "fixture-ready-agent",
            "text": "fixture message",
            "binaryPath": "/fixture/agent"
        });
        let mut observed_operation = String::new();
        let mut observed_agent = String::new();

        let result = dispatch_ready_agent_message(&params, |operation, dispatched| {
            observed_operation = operation.to_string();
            observed_agent = dispatched["agent"].as_str().unwrap_or_default().to_string();
            Ok(json!({"ok": true, "status": "fixture"}))
        })
        .unwrap();

        assert_eq!(observed_operation, "send");
        assert_eq!(observed_agent, "fixture-ready-agent");
        assert_eq!(result["ok"], true);
    }

    #[test]
    fn nested_runtime_failure_is_not_wrapped_as_secure_mesh_success() {
        let error = successful_agent_dispatch(Ok(json!({
            "ok": false,
            "error": {"code": "fixture_failure"}
        })))
        .unwrap_err();

        assert_eq!(error.to_string(), "native_agent_dispatch_failed");
    }

    #[test]
    fn secure_agent_deadline_is_receiver_owned_and_bounded() {
        let payload = SecureCommandPayload::from_value(&command_fixture_with(
            "cmd-receiver-deadline",
            "idem-receiver-deadline",
            json!({
                "agentId": "codex",
                "text": "fixture message",
                "model": "model-canary",
                "reasoningEffort": "high"
            }),
        ))
        .unwrap();

        let params = agent_message_send_params(&payload).unwrap();

        assert_eq!(params["timeoutMs"], SECURE_AGENT_MESSAGE_TIMEOUT_MS);
        assert_eq!(params["model"], "model-canary");
        assert_eq!(params["reasoningEffort"], "high");
    }

    #[test]
    fn adapter_failure_categories_survive_secure_mesh_redaction() {
        for (adapter_code, expected, retryable) in [
            (
                "acp_session_rejected",
                "native_agent_session_rejected",
                false,
            ),
            ("acp_protocol_timeout", "native_agent_timeout", true),
            (
                "acp_user_interaction_required",
                "native_agent_user_interaction_required",
                true,
            ),
        ] {
            let error = successful_agent_dispatch(Ok(json!({
                "ok": false,
                "error": {"code": adapter_code}
            })))
            .unwrap_err();
            let failure = error.downcast_ref::<SecureAgentDispatchFailure>().unwrap();
            assert_eq!(failure.code, expected);
            assert_eq!(failure.retryable, retryable);
        }
    }

    #[derive(Default)]
    struct FixtureExecutor {
        calls: usize,
        fail: bool,
        failure_detail: &'static str,
    }

    #[derive(Default)]
    struct FilteringExecutor {
        runtime_calls: usize,
    }

    impl SecureCommandLocalExecutor for FixtureExecutor {
        fn execute_secure_command(&mut self, payload: &SecureCommandPayload) -> Result<Value> {
            self.calls += 1;
            if self.fail {
                return Err(anyhow!(self.failure_detail));
            }
            assert_eq!(payload.command_kind, "agent.message.send");
            Ok(json!({
                "accepted": true,
                "message": payload.body().get("message").and_then(Value::as_str).unwrap_or_default(),
            }))
        }
    }

    impl SecureCommandLocalExecutor for FilteringExecutor {
        fn execute_secure_command(&mut self, payload: &SecureCommandPayload) -> Result<Value> {
            let _params = agent_message_send_params(payload)?;
            self.runtime_calls += 1;
            Ok(json!({"ok": true}))
        }
    }

    fn command_fixture_with(command_id: &str, idempotency_key: &str, body: Value) -> Value {
        let mut raw = command_fixture();
        raw["commandId"] = json!(command_id);
        raw["idempotencyKey"] = json!(idempotency_key);
        raw["body"] = body;
        raw
    }

    fn command_fixture() -> Value {
        json!({
            "schema": SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": "cmd-a",
            "commandKind": "agent.message.send",
            "senderIdentity": {
                "endpointId": "pc-a",
                "identityFingerprint": "fingerprint-a",
                "trustState": "verified",
                "endpointKind": "desktop_sidecar"
            },
            "targetBinding": {
                "targetEndpointId": "pc-b",
                "targetAgentId": "agent-a",
                "workspaceId": "workspace-a"
            },
            "riskClass": "safe_write",
            "requiresUserConfirmation": false,
            "idempotencyKey": "idem-a",
            "createdAt": "2026-01-01T00:00:00Z",
            "expiresAt": "2026-01-01T00:10:00Z",
            "body": {"message": "hello"}
        })
    }

    fn context_fixture() -> Value {
        json!({
            "localEndpointId": "pc-b",
            "senderEndpointId": "pc-a",
            "senderIdentityFingerprint": "fingerprint-a",
            "senderTrustState": "verified",
            "senderEndpointKind": "desktop_sidecar",
            "senderRosterActive": true,
            "targetRosterActive": true,
            "sessionOrEpochValid": true,
            "userConfirmed": false,
            "allowedWorkspaceIds": ["workspace-a"],
            "allowedAgentIds": ["agent-a"],
            "now": "2026-01-01T00:01:00Z"
        })
    }

    fn response_context_fixture() -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            "env_result",
            "msg_result",
            "mailbox_command",
            "pc-b",
            "pc-a",
            "command_session_test",
            "2026-01-01T00:02:00Z",
            "2026-01-01T00:10:00Z",
        )
    }
}
