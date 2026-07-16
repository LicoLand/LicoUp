use super::*;

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
