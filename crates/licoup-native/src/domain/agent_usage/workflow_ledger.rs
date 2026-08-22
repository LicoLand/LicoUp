//! Local, numeric-only usage accounting for Adaptive Flywheel Graph runs.
//!
//! The ledger owns only opaque run, command, state and Membership identities
//! plus checked integer counters. It never reads or stores a transcript,
//! prompt, reply, tool payload, credential, native path or runtime endpoint.

use super::persistence::client_state_store;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::fmt::{Display, Formatter};
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
#[cfg(test)]
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

pub const WORKFLOW_LEDGER_SCHEMA_VERSION: i64 = 2;
pub const WORKFLOW_LEDGER_FILE_NAME: &str = "graph-usage-ledger-v2.sqlite3";
pub const WORKFLOW_LEDGER_REPORT_SCHEMA: &str = "licoup.graph-usage-report.v2";
pub const WORKFLOW_LEDGER_RESULT_KIND: &str = "graph-run-usage";
pub const WORKFLOW_LEDGER_MAX_RUNS: usize = 256;

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LedgerError {
    pub code: String,
    pub stage: String,
    pub retryable: bool,
    pub recovery: String,
}

impl LedgerError {
    fn storage() -> Self {
        Self {
            code: "usage_ledger_store_unavailable".into(),
            stage: "graph-usage-ledger".into(),
            retryable: true,
            recovery: "retry_after_store_recovers".into(),
        }
    }

    fn invalid(code: &'static str) -> Self {
        Self {
            code: code.into(),
            stage: "graph-usage-ledger".into(),
            retryable: false,
            recovery: "correct_request_and_retry".into(),
        }
    }
}

impl Display for LedgerError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.code)
    }
}

impl std::error::Error for LedgerError {}

pub type LedgerResult<T> = std::result::Result<T, LedgerError>;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct CheckedUsage {
    prompt: u64,
    cached: u64,
    completion: u64,
    total: u64,
    accuracy: UsageAccuracy,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum UsageAccuracy {
    Exact,
    Estimated,
    #[default]
    Unknown,
}

impl UsageAccuracy {
    fn parse(value: Option<&str>, has_usage: bool) -> LedgerResult<Self> {
        match value.map(str::trim).filter(|value| !value.is_empty()) {
            Some("exact") => Ok(Self::Exact),
            Some("estimated") => Ok(Self::Estimated),
            Some("unknown") | None if !has_usage => Ok(Self::Unknown),
            Some("unknown") | None => Ok(Self::Exact),
            _ => Err(LedgerError::invalid("usage_ledger_accuracy_invalid")),
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Exact => "exact",
            Self::Estimated => "estimated",
            Self::Unknown => "unknown",
        }
    }
}

impl CheckedUsage {
    fn from_value(value: Option<&Value>) -> LedgerResult<Self> {
        let Some(object) = value.and_then(Value::as_object) else {
            return Ok(Self::default());
        };
        let prompt = numeric_field(
            object,
            &[
                "promptTokens",
                "prompt_tokens",
                "inputTokens",
                "input_tokens",
            ],
        )
        .unwrap_or(0);
        let cached = numeric_field(
            object,
            &[
                "cachedInputTokens",
                "cached_input_tokens",
                "cacheReadInputTokens",
                "cache_read_input_tokens",
            ],
        )
        .unwrap_or(0);
        let completion = numeric_field(
            object,
            &[
                "completionTokens",
                "completion_tokens",
                "outputTokens",
                "output_tokens",
            ],
        )
        .unwrap_or(0);
        let total = prompt
            .checked_add(completion)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        if cached > prompt || total > i64::MAX as u64 {
            return Err(LedgerError::invalid("usage_ledger_counter_invalid"));
        }
        if let Some(submitted_total) = numeric_field(object, &["totalTokens", "total_tokens"])
            && submitted_total != total
        {
            return Err(LedgerError::invalid("usage_ledger_total_mismatch"));
        }
        let has_usage = prompt > 0 || cached > 0 || completion > 0;
        let accuracy = UsageAccuracy::parse(
            object
                .get("accuracy")
                .or_else(|| object.get("usageAccuracy"))
                .and_then(Value::as_str),
            has_usage,
        )?;
        Ok(Self {
            prompt,
            cached,
            completion,
            total,
            accuracy,
        })
    }

    fn to_value(self) -> Value {
        json!({
            "promptTokens": self.prompt,
            "cachedInputTokens": self.cached,
            "completionTokens": self.completion,
            "totalTokens": self.total,
        })
    }

    fn to_value_with_counts(self, exact_count: u64, estimated_count: u64) -> Value {
        json!({
            "promptTokens": self.prompt,
            "cachedInputTokens": self.cached,
            "completionTokens": self.completion,
            "totalTokens": self.total,
            "exactCount": exact_count,
            "estimatedCount": estimated_count,
        })
    }

    fn checked_add(self, other: Self) -> LedgerResult<Self> {
        let prompt = self
            .prompt
            .checked_add(other.prompt)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        let cached = self
            .cached
            .checked_add(other.cached)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        let completion = self
            .completion
            .checked_add(other.completion)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        let total = prompt
            .checked_add(completion)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        Ok(Self {
            prompt,
            cached,
            completion,
            total,
            accuracy: UsageAccuracy::Unknown,
        })
    }
}

struct Ledger {
    connection: Connection,
}

/// Admit one immutable Graph run identity. Replays may update lifecycle state
/// but cannot change the revision, Conversation or designated Assistant.
pub fn begin_graph_run(params: &Value) -> LedgerResult<Value> {
    let run_id = required_id(params, "runId")?;
    let revision_digest = required_id(params, "revisionDigest")?;
    let conversation_id = optional_id(params, "conversationId")?;
    let assistant_membership_id = optional_id(params, "assistantMembershipId")?;
    let status = lifecycle(
        params
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("pending"),
    )?;
    let mut ledger = open_ledger(params)?;
    let transaction = ledger
        .connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    let now = now_ms();
    transaction
        .execute(
            "INSERT INTO graph_runs(
               run_id,revision_digest,conversation_id,assistant_membership_id,
               status,created_at_ms,updated_at_ms
             ) VALUES(?1,?2,?3,?4,?5,?6,?6)
             ON CONFLICT(run_id) DO NOTHING",
            params![
                run_id,
                revision_digest,
                conversation_id,
                assistant_membership_id,
                status,
                now
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    let persisted = load_run_identity(&transaction, &run_id)?.ok_or_else(LedgerError::storage)?;
    if persisted.0 != revision_digest
        || persisted.1.as_deref() != conversation_id.as_deref()
        || persisted.2.as_deref() != assistant_membership_id.as_deref()
    {
        return Err(LedgerError::invalid("usage_ledger_run_identity_conflict"));
    }
    transaction
        .execute(
            "UPDATE graph_runs SET status=?2,updated_at_ms=?3 WHERE run_id=?1",
            params![run_id, status, now],
        )
        .map_err(|_| LedgerError::storage())?;
    prune_terminal_runs(&transaction)?;
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "runId": run_id,
        "revisionDigest": revision_digest,
        "status": status,
    }))
}

/// Record one durable Graph command and an optional normalized usage sample.
/// A later sample may fill an empty row, but conflicting non-zero samples fail.
pub fn record_graph_command(params: &Value) -> LedgerResult<Value> {
    let run_id = required_id(params, "runId")?;
    let command_id = required_id(params, "commandId")?;
    let state_id = required_id(params, "stateId")?;
    let membership_id = optional_id(params, "membershipId")?;
    let kind = command_kind(required_text(params, "kind")?)?;
    let status = command_status(required_text(params, "status")?)?;
    let attempt = params
        .get("attempt")
        .and_then(Value::as_u64)
        .filter(|value| *value <= u8::MAX as u64)
        .unwrap_or(0);
    let agent_id = optional_id(params, "agentId")?;
    let model = optional_label(params, "model")?;
    let usage = CheckedUsage::from_value(params.get("usage"))?;
    let mut ledger = open_ledger(params)?;
    let transaction = ledger
        .connection
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| LedgerError::storage())?;
    if load_run_identity(&transaction, &run_id)?.is_none() {
        return Err(LedgerError::invalid("usage_ledger_run_not_found"));
    }
    let now = now_ms();
    transaction
        .execute(
            "INSERT INTO graph_commands(
               command_id,run_id,state_id,membership_id,kind,status,attempt,
               agent_id,model,accuracy,prompt_tokens,cached_input_tokens,
               completion_tokens,total_tokens,updated_at_ms
             ) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)
             ON CONFLICT(command_id) DO NOTHING",
            params![
                command_id,
                run_id,
                state_id,
                membership_id,
                kind,
                status,
                attempt,
                agent_id,
                model,
                usage.accuracy.as_str(),
                usage.prompt,
                usage.cached,
                usage.completion,
                usage.total,
                now,
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    let current = load_command(&transaction, &command_id)?.ok_or_else(LedgerError::storage)?;
    if current.run_id != run_id
        || current.state_id != state_id
        || current.membership_id.as_deref() != membership_id.as_deref()
        || current.kind != kind
        || current.agent_id.as_deref() != agent_id.as_deref()
        || current.model.as_deref() != model.as_deref()
    {
        return Err(LedgerError::invalid(
            "usage_ledger_command_identity_conflict",
        ));
    }
    if current.usage.total > 0 && current.usage != usage && usage.total > 0 {
        return Err(LedgerError::invalid("usage_ledger_command_usage_conflict"));
    }
    let settled = if current.usage.total == 0 && usage.total > 0 {
        usage
    } else {
        current.usage
    };
    transaction
        .execute(
            "UPDATE graph_commands SET status=?2,attempt=?3,accuracy=?4,
               prompt_tokens=?5,cached_input_tokens=?6,completion_tokens=?7,
               total_tokens=?8,updated_at_ms=?9 WHERE command_id=?1",
            params![
                command_id,
                status,
                attempt,
                settled.accuracy.as_str(),
                settled.prompt,
                settled.cached,
                settled.completion,
                settled.total,
                now,
            ],
        )
        .map_err(|_| LedgerError::storage())?;
    transaction
        .execute(
            "UPDATE graph_runs SET updated_at_ms=?2 WHERE run_id=?1",
            params![run_id, now],
        )
        .map_err(|_| LedgerError::storage())?;
    transaction.commit().map_err(|_| LedgerError::storage())?;
    Ok(json!({
        "runId": run_id,
        "commandId": command_id,
        "usage": settled.to_value(),
    }))
}

/// Project a bounded Graph run/command usage report. Every public string is
/// an allowlisted opaque identity or lifecycle enum.
pub fn workflow_report(params: &Value) -> LedgerResult<Value> {
    let ledger = open_ledger(params)?;
    let requested_run = optional_id(params, "runId")?;
    let mut statement = ledger
        .connection
        .prepare(
            "SELECT run_id,revision_digest,conversation_id,assistant_membership_id,status
             FROM graph_runs
             WHERE (?1 IS NULL OR run_id=?1)
             ORDER BY updated_at_ms DESC,run_id DESC LIMIT ?2",
        )
        .map_err(|_| LedgerError::storage())?;
    let rows = statement
        .query_map(params![requested_run, WORKFLOW_LEDGER_MAX_RUNS], |row| {
            Ok(RunRow {
                run_id: row.get(0)?,
                revision_digest: row.get(1)?,
                conversation_id: row.get(2)?,
                assistant_membership_id: row.get(3)?,
                status: row.get(4)?,
            })
        })
        .map_err(|_| LedgerError::storage())?;
    let mut runs = Vec::new();
    let mut summary = CheckedUsage::default();
    let mut exact_count = 0u64;
    let mut estimated_count = 0u64;
    for row in rows {
        let row = row.map_err(|_| LedgerError::storage())?;
        let commands = load_commands_for_run(&ledger.connection, &row.run_id)?;
        let mut totals = CheckedUsage::default();
        let mut run_exact = 0u64;
        let mut run_estimated = 0u64;
        let command_values = commands
            .into_iter()
            .map(|command| {
                totals = totals.checked_add(command.usage)?;
                match command.usage.accuracy {
                    UsageAccuracy::Exact if command.usage.total > 0 => run_exact += 1,
                    UsageAccuracy::Estimated if command.usage.total > 0 => run_estimated += 1,
                    _ => {}
                }
                Ok(command.to_value())
            })
            .collect::<LedgerResult<Vec<_>>>()?;
        summary = summary.checked_add(totals)?;
        exact_count = exact_count
            .checked_add(run_exact)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        estimated_count = estimated_count
            .checked_add(run_estimated)
            .ok_or_else(|| LedgerError::invalid("usage_ledger_counter_overflow"))?;
        runs.push(json!({
            "runId": row.run_id,
            "revisionDigest": row.revision_digest,
            "conversationId": row.conversation_id,
            "assistantMembershipId": row.assistant_membership_id,
            "status": row.status,
            "totals": totals.to_value_with_counts(run_exact, run_estimated),
            "commands": command_values,
        }));
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": WORKFLOW_LEDGER_REPORT_SCHEMA,
        "ledgerSchemaVersion": WORKFLOW_LEDGER_SCHEMA_VERSION,
        "resultKind": WORKFLOW_LEDGER_RESULT_KIND,
        "summary": summary.to_value_with_counts(exact_count, estimated_count),
        "runs": runs,
    }))
}

#[derive(Debug)]
struct RunRow {
    run_id: String,
    revision_digest: String,
    conversation_id: Option<String>,
    assistant_membership_id: Option<String>,
    status: String,
}

#[derive(Debug)]
struct CommandRow {
    command_id: String,
    run_id: String,
    state_id: String,
    membership_id: Option<String>,
    kind: String,
    status: String,
    attempt: u64,
    agent_id: Option<String>,
    model: Option<String>,
    usage: CheckedUsage,
}

impl CommandRow {
    fn to_value(&self) -> Value {
        json!({
            "commandId": self.command_id,
            "stateId": self.state_id,
            "membershipId": self.membership_id,
            "kind": self.kind,
            "status": self.status,
            "attempt": self.attempt,
            "agentId": self.agent_id,
            "model": self.model,
            "accuracy": self.usage.accuracy.as_str(),
            "usage": self.usage.to_value(),
        })
    }
}

fn open_ledger(params: &Value) -> LedgerResult<Ledger> {
    let store = client_state_store(params).map_err(|_| LedgerError::storage())?;
    let root = store.root().join("agent-usage");
    fs::create_dir_all(&root).map_err(|_| LedgerError::storage())?;
    #[cfg(unix)]
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700))
        .map_err(|_| LedgerError::storage())?;
    let connection = Connection::open(root.join(WORKFLOW_LEDGER_FILE_NAME))
        .map_err(|_| LedgerError::storage())?;
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA foreign_keys=ON;
             PRAGMA busy_timeout=5000;
             CREATE TABLE IF NOT EXISTS graph_usage_schema (
               singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL
             );
             INSERT OR IGNORE INTO graph_usage_schema(singleton,version) VALUES(1,2);
             CREATE TABLE IF NOT EXISTS graph_runs (
               run_id TEXT PRIMARY KEY,
               revision_digest TEXT NOT NULL,
               conversation_id TEXT,
               assistant_membership_id TEXT,
               status TEXT NOT NULL,
               created_at_ms INTEGER NOT NULL,
               updated_at_ms INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS graph_runs_updated
               ON graph_runs(updated_at_ms DESC,run_id DESC);
             CREATE TABLE IF NOT EXISTS graph_commands (
               command_id TEXT PRIMARY KEY,
               run_id TEXT NOT NULL REFERENCES graph_runs(run_id) ON DELETE CASCADE,
               state_id TEXT NOT NULL,
               membership_id TEXT,
               kind TEXT NOT NULL,
               status TEXT NOT NULL,
               attempt INTEGER NOT NULL,
               agent_id TEXT,
               model TEXT,
               accuracy TEXT NOT NULL,
               prompt_tokens INTEGER NOT NULL,
               cached_input_tokens INTEGER NOT NULL,
               completion_tokens INTEGER NOT NULL,
               total_tokens INTEGER NOT NULL,
               updated_at_ms INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS graph_commands_run
               ON graph_commands(run_id,command_id);",
        )
        .map_err(|_| LedgerError::storage())?;
    let version: i64 = connection
        .query_row(
            "SELECT version FROM graph_usage_schema WHERE singleton=1",
            [],
            |row| row.get(0),
        )
        .map_err(|_| LedgerError::storage())?;
    if version != WORKFLOW_LEDGER_SCHEMA_VERSION {
        return Err(LedgerError::invalid("usage_ledger_schema_unsupported"));
    }
    Ok(Ledger { connection })
}

fn load_run_identity(
    connection: &Connection,
    run_id: &str,
) -> LedgerResult<Option<(String, Option<String>, Option<String>)>> {
    connection
        .query_row(
            "SELECT revision_digest,conversation_id,assistant_membership_id
             FROM graph_runs WHERE run_id=?1",
            params![run_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|_| LedgerError::storage())
}

fn load_command(connection: &Connection, command_id: &str) -> LedgerResult<Option<CommandRow>> {
    connection
        .query_row(
            "SELECT command_id,run_id,state_id,membership_id,kind,status,attempt,
                    agent_id,model,accuracy,prompt_tokens,cached_input_tokens,
                    completion_tokens,total_tokens
             FROM graph_commands WHERE command_id=?1",
            params![command_id],
            command_from_row,
        )
        .optional()
        .map_err(|_| LedgerError::storage())
}

fn load_commands_for_run(connection: &Connection, run_id: &str) -> LedgerResult<Vec<CommandRow>> {
    let mut statement = connection
        .prepare(
            "SELECT command_id,run_id,state_id,membership_id,kind,status,attempt,
                    agent_id,model,accuracy,prompt_tokens,cached_input_tokens,
                    completion_tokens,total_tokens
             FROM graph_commands WHERE run_id=?1 ORDER BY command_id",
        )
        .map_err(|_| LedgerError::storage())?;
    statement
        .query_map(params![run_id], command_from_row)
        .map_err(|_| LedgerError::storage())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|_| LedgerError::storage())
}

fn command_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<CommandRow> {
    let accuracy: String = row.get(9)?;
    Ok(CommandRow {
        command_id: row.get(0)?,
        run_id: row.get(1)?,
        state_id: row.get(2)?,
        membership_id: row.get(3)?,
        kind: row.get(4)?,
        status: row.get(5)?,
        attempt: row.get(6)?,
        agent_id: row.get(7)?,
        model: row.get(8)?,
        usage: CheckedUsage {
            accuracy: match accuracy.as_str() {
                "exact" => UsageAccuracy::Exact,
                "estimated" => UsageAccuracy::Estimated,
                _ => UsageAccuracy::Unknown,
            },
            prompt: row.get(10)?,
            cached: row.get(11)?,
            completion: row.get(12)?,
            total: row.get(13)?,
        },
    })
}

fn prune_terminal_runs(connection: &Connection) -> LedgerResult<()> {
    connection
        .execute(
            "DELETE FROM graph_runs
             WHERE status IN ('blocked','cancelled','failed','completed')
               AND run_id NOT IN (
                 SELECT run_id FROM graph_runs
                 WHERE status IN ('blocked','cancelled','failed','completed')
                 ORDER BY updated_at_ms DESC,run_id DESC LIMIT ?1
               )",
            params![WORKFLOW_LEDGER_MAX_RUNS],
        )
        .map_err(|_| LedgerError::storage())?;
    Ok(())
}

fn required_text<'a>(params: &'a Value, key: &str) -> LedgerResult<&'a str> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| LedgerError::invalid("usage_ledger_request_invalid"))
}

fn required_id(params: &Value, key: &str) -> LedgerResult<String> {
    let value = required_text(params, key)?;
    validate_id(value)?;
    Ok(value.to_owned())
}

fn optional_id(params: &Value, key: &str) -> LedgerResult<Option<String>> {
    let Some(value) = params.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let value = value
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| LedgerError::invalid("usage_ledger_request_invalid"))?;
    validate_id(value)?;
    Ok(Some(value.to_owned()))
}

fn optional_label(params: &Value, key: &str) -> LedgerResult<Option<String>> {
    let Some(value) = params.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let value = value
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| LedgerError::invalid("usage_ledger_request_invalid"))?;
    if value.len() > 256 || value.chars().any(|character| character.is_control()) {
        return Err(LedgerError::invalid("usage_ledger_label_invalid"));
    }
    Ok(Some(value.to_owned()))
}

fn validate_id(value: &str) -> LedgerResult<()> {
    if value.len() > 256
        || !value.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'@' | b'+' | b'-')
        })
    {
        return Err(LedgerError::invalid("usage_ledger_identity_invalid"));
    }
    Ok(())
}

fn lifecycle(value: &str) -> LedgerResult<&str> {
    if matches!(
        value,
        "pending"
            | "authorization-required"
            | "runtime-missing"
            | "running"
            | "waiting"
            | "retryable"
            | "cancel-requested"
            | "cancel-in-doubt"
            | "blocked"
            | "cancelled"
            | "failed"
            | "completed"
    ) {
        Ok(value)
    } else {
        Err(LedgerError::invalid("usage_ledger_status_invalid"))
    }
}

fn command_kind(value: &str) -> LedgerResult<&str> {
    if matches!(value, "authorization" | "actor" | "script" | "workset-item") {
        Ok(value)
    } else {
        Err(LedgerError::invalid("usage_ledger_command_kind_invalid"))
    }
}

fn command_status(value: &str) -> LedgerResult<&str> {
    if matches!(
        value,
        "pending"
            | "claimed"
            | "running"
            | "succeeded"
            | "failed"
            | "retryable"
            | "cancel-requested"
            | "cancelled"
            | "in-doubt"
    ) {
        Ok(value)
    } else {
        Err(LedgerError::invalid("usage_ledger_command_status_invalid"))
    }
}

fn numeric_field(object: &Map<String, Value>, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| object.get(*key)?.as_u64())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        std::env::temp_dir().join(format!("lico-graph-usage-{}", uuid::Uuid::new_v4()))
    }

    fn begin(root: &PathBuf) -> Value {
        json!({
            "stateRoot": root.to_string_lossy(),
            "runId": "run:one",
            "revisionDigest": "revision:one",
            "conversationId": "conversation:one",
            "assistantMembershipId": "membership:assistant",
            "status": "running",
        })
    }

    #[test]
    fn graph_command_usage_is_checked_and_idempotent() {
        let root = root();
        begin_graph_run(&begin(&root)).unwrap();
        let command = json!({
            "stateRoot": root.to_string_lossy(),
            "runId": "run:one",
            "commandId": "command:one",
            "stateId": "state:actor",
            "membershipId": "membership:worker",
            "kind": "actor",
            "status": "succeeded",
            "attempt": 1,
            "agentId": "codex",
            "model": "gpt-model",
            "usage": {
                "promptTokens": 11,
                "cachedInputTokens": 3,
                "completionTokens": 5,
                "totalTokens": 16,
                "accuracy": "exact",
                "prompt": "not persisted",
            }
        });
        record_graph_command(&command).unwrap();
        record_graph_command(&command).unwrap();
        let report = workflow_report(&json!({"stateRoot": root.to_string_lossy()})).unwrap();
        assert_eq!(report["summary"]["totalTokens"], 16);
        assert_eq!(report["summary"]["exactCount"], 1);
        assert_eq!(report["runs"][0]["commands"].as_array().unwrap().len(), 1);
        let serialized = report.to_string();
        assert!(!serialized.contains("not persisted"));
        assert!(!serialized.contains("\"prompt\":"));
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn conflicting_identity_and_invalid_totals_fail_closed() {
        let root = root();
        begin_graph_run(&begin(&root)).unwrap();
        let conflict = begin_graph_run(&json!({
            "stateRoot": root.to_string_lossy(),
            "runId": "run:one",
            "revisionDigest": "revision:other",
            "status": "running",
        }))
        .unwrap_err();
        assert_eq!(conflict.code, "usage_ledger_run_identity_conflict");
        let invalid = record_graph_command(&json!({
            "stateRoot": root.to_string_lossy(),
            "runId": "run:one",
            "commandId": "command:one",
            "stateId": "state:actor",
            "kind": "actor",
            "status": "succeeded",
            "usage": {"promptTokens": 2, "completionTokens": 3, "totalTokens": 6},
        }))
        .unwrap_err();
        assert_eq!(invalid.code, "usage_ledger_total_mismatch");
        let _ = fs::remove_dir_all(root);
    }
}
