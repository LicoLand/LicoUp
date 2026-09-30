use super::*;
use crate::state_machines::security_command_replay_execution::{
    self, Event as ReplayEvent, State as ReplayState,
};

#[derive(Default)]
pub struct SecureCommandReplayLedger {
    records: BTreeMap<String, InMemoryReplayRecord>,
    idempotency_command_ids: BTreeMap<String, String>,
    insertion_order: VecDeque<String>,
    max_entries: usize,
}

struct InMemoryReplayRecord {
    idempotency_key: String,
    fingerprint: String,
    phase: ReplayState,
    completed_outcome: Option<Value>,
}

impl SecureCommandReplayLedger {
    pub fn with_max_entries(max_entries: usize) -> Result<Self> {
        ensure!(
            max_entries > 0,
            "secure mesh command replay ledger max entries must be positive"
        );
        Ok(Self {
            records: BTreeMap::new(),
            idempotency_command_ids: BTreeMap::new(),
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
        while self.records.len() > self.effective_max_entries() {
            let Some(old_command_id) = self.insertion_order.pop_front() else {
                break;
            };
            if let Some(old_record) = self.records.remove(&old_command_id) {
                self.idempotency_command_ids
                    .remove(&old_record.idempotency_key);
            }
        }
    }

    #[cfg(test)]
    pub(super) fn phase_for_command(&self, command_id: &str) -> Option<ReplayState> {
        self.records.get(command_id).map(|record| record.phase)
    }
}

impl SecureCommandReplayStore for SecureCommandReplayLedger {
    fn has_command_id(&self, command_id: &str) -> Result<bool> {
        Ok(self.records.contains_key(command_id))
    }

    fn record_execution(
        &mut self,
        payload: &SecureCommandPayload,
        _now: OffsetDateTime,
    ) -> Result<SecureCommandReplayRecordStatus> {
        if self.records.contains_key(&payload.command_id) {
            return Ok(SecureCommandReplayRecordStatus::CommandReplay);
        }
        let fingerprint = payload.idempotency_fingerprint()?;
        if let Some(existing_command_id) =
            self.idempotency_command_ids.get(&payload.idempotency_key)
        {
            let existing = self.records.get(existing_command_id).ok_or_else(|| {
                anyhow!("secure mesh command idempotency index references a missing execution")
            })?;
            if existing.fingerprint == fingerprint {
                return Ok(SecureCommandReplayRecordStatus::IdempotentReplay);
            }
            return Ok(SecureCommandReplayRecordStatus::IdempotencyConflict);
        }
        let reserved = security_command_replay_execution::transition(
            security_command_replay_execution::INITIAL,
            ReplayEvent::Reserve,
        )
        .ok_or_else(|| anyhow!("secure mesh command reservation transition is not configured"))?;
        self.records.insert(
            payload.command_id.clone(),
            InMemoryReplayRecord {
                idempotency_key: payload.idempotency_key.clone(),
                fingerprint,
                phase: reserved,
                completed_outcome: None,
            },
        );
        self.idempotency_command_ids
            .insert(payload.idempotency_key.clone(), payload.command_id.clone());
        self.insertion_order.push_back(payload.command_id.clone());
        self.prune_to_limit();
        Ok(SecureCommandReplayRecordStatus::Fresh)
    }

    fn entry_count(&self) -> Result<usize> {
        Ok(self.records.len())
    }

    fn prior_execution(
        &self,
        payload: &SecureCommandPayload,
    ) -> Result<SecureCommandPriorExecution> {
        let Some(record) = self.records.get(&payload.command_id) else {
            return Ok(SecureCommandPriorExecution::Missing);
        };
        let fingerprint = payload.idempotency_fingerprint()?;
        if record.idempotency_key != payload.idempotency_key || record.fingerprint != fingerprint {
            return Ok(SecureCommandPriorExecution::Conflict);
        }
        match (record.phase, record.completed_outcome.as_ref()) {
            (ReplayState::Reserved, None) => Ok(SecureCommandPriorExecution::Reserved),
            (ReplayState::Completed, Some(outcome)) => {
                Ok(SecureCommandPriorExecution::Completed(outcome.clone()))
            }
            _ => Err(anyhow!(
                "secure mesh command execution ledger state is invalid"
            )),
        }
    }

    fn record_completed_outcome(
        &mut self,
        payload: &SecureCommandPayload,
        outcome: &Value,
    ) -> Result<()> {
        let fingerprint = payload.idempotency_fingerprint()?;
        let record = self.records.get_mut(&payload.command_id).ok_or_else(|| {
            anyhow!("secure mesh command completion does not match a reserved execution")
        })?;
        ensure!(
            record.idempotency_key == payload.idempotency_key
                && record.fingerprint == fingerprint
                && record.completed_outcome.is_none(),
            "secure mesh command completion does not match a reserved execution"
        );
        let completed =
            security_command_replay_execution::transition(record.phase, ReplayEvent::Complete)
                .ok_or_else(|| {
                    anyhow!("secure mesh command completion does not match a reserved execution")
                })?;
        record.phase = completed;
        record.completed_outcome = Some(outcome.clone());
        Ok(())
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
        self.connection
            .execute_batch("PRAGMA secure_delete = ON;")?;
        let schema_version: u32 = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))?;
        let table_exists: bool = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'secure_mesh_command_replay')",
            [],
            |row| row.get(0),
        )?;
        if table_exists && schema_version != 2 {
            self.connection.execute_batch(
                "DROP TABLE secure_mesh_command_replay; PRAGMA user_version = 0; VACUUM;",
            )?;
        }
        let schema = format!(
            r#"
            CREATE TABLE IF NOT EXISTS secure_mesh_command_replay (
                command_id TEXT PRIMARY KEY,
                idempotency_key TEXT NOT NULL UNIQUE,
                fingerprint TEXT NOT NULL,
                execution_state TEXT NOT NULL CHECK (
                    execution_state IN ('{}', '{}')
                ),
                outcome_json TEXT,
                recorded_at_unix INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS secure_mesh_command_replay_recorded_at_idx
                ON secure_mesh_command_replay(recorded_at_unix, command_id);
            PRAGMA user_version = 2;
            "#,
            ReplayState::Reserved.as_str(),
            ReplayState::Completed.as_str(),
        );
        self.connection.execute_batch(&schema)?;
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
                execution_state,
                outcome_json,
                recorded_at_unix
            ) VALUES (?1, ?2, ?3, ?4, NULL, ?5)
            "#,
            params![
                payload.command_id,
                payload.idempotency_key,
                fingerprint,
                security_command_replay_execution::transition(
                    security_command_replay_execution::INITIAL,
                    ReplayEvent::Reserve,
                )
                .ok_or_else(|| anyhow!(
                    "secure mesh command reservation transition is not configured"
                ))?
                .as_str(),
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

    fn prior_execution(
        &self,
        payload: &SecureCommandPayload,
    ) -> Result<SecureCommandPriorExecution> {
        let row = self
            .connection
            .query_row(
                r#"
                SELECT idempotency_key, fingerprint, execution_state, outcome_json
                FROM secure_mesh_command_replay
                WHERE command_id = ?1
                "#,
                params![payload.command_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((idempotency_key, fingerprint, state, outcome_json)) = row else {
            return Ok(SecureCommandPriorExecution::Missing);
        };
        if idempotency_key != payload.idempotency_key
            || fingerprint != payload.idempotency_fingerprint()?
        {
            return Ok(SecureCommandPriorExecution::Conflict);
        }
        match (ReplayState::from_name(&state), outcome_json) {
            (Some(ReplayState::Reserved), None) => Ok(SecureCommandPriorExecution::Reserved),
            (Some(ReplayState::Completed), Some(outcome)) => {
                Ok(SecureCommandPriorExecution::Completed(
                    serde_json::from_str(&outcome)
                        .context("secure mesh command cached outcome is invalid")?,
                ))
            }
            _ => Err(anyhow!(
                "secure mesh command execution ledger state is invalid"
            )),
        }
    }

    fn record_completed_outcome(
        &mut self,
        payload: &SecureCommandPayload,
        outcome: &Value,
    ) -> Result<()> {
        let encoded = serde_json::to_string(outcome)?;
        ensure!(
            encoded.len() <= MAX_COMMAND_BODY_BYTES.saturating_add(64 * 1024),
            "secure mesh command cached outcome is too large"
        );
        let completed = security_command_replay_execution::transition(
            ReplayState::Reserved,
            ReplayEvent::Complete,
        )
        .ok_or_else(|| anyhow!("secure mesh command completion transition is not configured"))?;
        let changed = self.connection.execute(
            r#"
            UPDATE secure_mesh_command_replay
            SET execution_state = ?1, outcome_json = ?2
            WHERE command_id = ?3
              AND idempotency_key = ?4
              AND fingerprint = ?5
              AND execution_state = ?6
              AND outcome_json IS NULL
            "#,
            params![
                completed.as_str(),
                encoded,
                payload.command_id,
                payload.idempotency_key,
                payload.idempotency_fingerprint()?,
                ReplayState::Reserved.as_str(),
            ],
        )?;
        ensure!(
            changed == 1,
            "secure mesh command completion does not match a reserved execution"
        );
        Ok(())
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
    fn prior_execution(
        &self,
        payload: &SecureCommandPayload,
    ) -> Result<SecureCommandPriorExecution>;
    fn record_completed_outcome(
        &mut self,
        payload: &SecureCommandPayload,
        outcome: &Value,
    ) -> Result<()>;
}

pub enum SecureCommandPriorExecution {
    Missing,
    Reserved,
    Completed(Value),
    Conflict,
}

pub enum SecureCommandReplayRecordStatus {
    Fresh,
    CommandReplay,
    IdempotentReplay,
    IdempotencyConflict,
}
