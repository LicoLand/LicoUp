//! SQLite durability boundary. Every accepted command is one IMMEDIATE transaction.
use super::{
    CrashBoundary, CrashBoundaryInjector, EngineErrorCode, WorkflowEvent, WorkflowReceipt,
    WorkflowSnapshot,
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::{
    path::{Path, PathBuf},
    sync::Mutex,
};

#[derive(Clone, Debug)]
pub struct StoreLimits {
    pub max_journal_entries: usize,
    pub max_journal_bytes: usize,
    pub max_snapshot_bytes: usize,
    pub max_idempotency_entries: usize,
    pub max_events: usize,
    pub max_database_bytes: usize,
}
impl Default for StoreLimits {
    fn default() -> Self {
        Self {
            max_journal_entries: 4096,
            max_journal_bytes: 4 * 1024 * 1024,
            max_snapshot_bytes: 1024 * 1024,
            max_idempotency_entries: 4096,
            max_events: 4096,
            max_database_bytes: 64 * 1024 * 1024,
        }
    }
}

pub struct DurableWorkflowStore {
    connection: Mutex<Connection>,
    limits: StoreLimits,
    owner_id: String,
    owner_fence: u64,
}
impl DurableWorkflowStore {
    pub fn database_path(root: &Path) -> PathBuf {
        root.join("agent-orchestration.sqlite3")
    }
    pub fn open(root: &Path, limits: StoreLimits) -> Result<Self, EngineErrorCode> {
        Self::open_with_owner_recovery(root, limits, false)
    }

    /// Opens the store after the caller has acquired the orchestrator's
    /// process-wide exclusive lifecycle lock. That stronger ownership proof is
    /// the only authority allowed to retire a lease left by a killed process.
    pub(crate) fn open_after_exclusive_process_lock(
        root: &Path,
        limits: StoreLimits,
    ) -> Result<Self, EngineErrorCode> {
        Self::open_with_owner_recovery(root, limits, true)
    }

    fn open_with_owner_recovery(
        root: &Path,
        limits: StoreLimits,
        recover_stale_owner: bool,
    ) -> Result<Self, EngineErrorCode> {
        std::fs::create_dir_all(root).map_err(|_| EngineErrorCode::Storage)?;
        let path = Self::database_path(root);
        let mut c = Connection::open(&path)?;
        c.pragma_update(None, "journal_mode", "WAL")?;
        c.pragma_update(None, "synchronous", "FULL")?;
        c.busy_timeout(std::time::Duration::from_millis(100))?;
        schema(&c)?;
        let owner_id = uuid::Uuid::new_v4().to_string();
        let tx = c
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|_| EngineErrorCode::LeaseHeld)?;
        let held: i64 = tx.query_row(
            "SELECT COUNT(*) FROM workflow_leases WHERE workflow_id='__store_owner__'",
            [],
            |r| r.get(0),
        )?;
        if held > 0 && !recover_stale_owner {
            return Err(EngineErrorCode::LeaseHeld);
        }
        if held > 0 {
            tx.execute(
                "DELETE FROM workflow_leases WHERE workflow_id='__store_owner__'",
                [],
            )?;
        }
        let fence:u64=tx.query_row("SELECT COALESCE(CAST(value AS INTEGER),0)+1 FROM store_metadata WHERE key='owner_fence'",[],|r|r.get(0)).optional()?.unwrap_or(1);
        tx.execute("INSERT INTO store_metadata(key,value) VALUES('owner_fence',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[fence.to_string()])?;
        tx.execute("INSERT INTO workflow_leases(workflow_id,owner_id,owner_fence,expires_at_ms,generation) VALUES('__store_owner__',?1,?2,9223372036854775807,0)",params![owner_id,fence])?;
        tx.commit()?;
        Ok(Self {
            connection: Mutex::new(c),
            limits,
            owner_id,
            owner_fence: fence,
        })
    }
    pub fn owner_fence(&self) -> u64 {
        self.owner_fence
    }
    pub fn registered_policy(&self, revision: &str) -> Result<Option<String>, EngineErrorCode> {
        let c = self
            .connection
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        Ok(c.query_row(
            "SELECT policy_json FROM policy_revisions WHERE revision=?1",
            [revision],
            |row| row.get(0),
        )
        .optional()?)
    }
    pub fn register_policy(
        &self,
        revision: &str,
        policy_json: &str,
    ) -> Result<(), EngineErrorCode> {
        if policy_json.len() > self.limits.max_snapshot_bytes {
            return Err(EngineErrorCode::CapacityExceeded);
        }
        let c = self
            .connection
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        c.execute(
            "INSERT INTO policy_revisions(revision,policy_json,state) VALUES(?1,?2,'registered') ON CONFLICT(revision) DO NOTHING",
            params![revision, policy_json],
        )?;
        Ok(())
    }
    pub fn activate_policy(&self, revision: &str) -> Result<bool, EngineErrorCode> {
        let mut c = self
            .connection
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let exists: i64 = tx.query_row(
            "SELECT COUNT(*) FROM policy_revisions WHERE revision=?1",
            [revision],
            |row| row.get(0),
        )?;
        if exists == 0 {
            return Ok(false);
        }
        tx.execute(
            "UPDATE policy_revisions SET state='registered' WHERE state='active'",
            [],
        )?;
        tx.execute(
            "UPDATE policy_revisions SET state='active' WHERE revision=?1",
            [revision],
        )?;
        tx.execute(
            "INSERT INTO store_metadata(key,value) VALUES('active_policy_revision',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [revision],
        )?;
        tx.commit()?;
        Ok(true)
    }
    pub fn policy_is_active(&self, revision: &str) -> Result<bool, EngineErrorCode> {
        let c = self
            .connection
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let active: Option<String> = c
            .query_row(
                "SELECT value FROM store_metadata WHERE key='active_policy_revision'",
                [],
                |row| row.get(0),
            )
            .optional()?;
        Ok(active.as_deref() == Some(revision))
    }
    pub fn control_receipt(&self, key: &str) -> Result<Option<(String, String)>, EngineErrorCode> {
        let c = self
            .connection
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        Ok(c.query_row(
            "SELECT request_digest,receipt_json FROM control_idempotency WHERE idempotency_key=?1",
            [key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?)
    }
    pub fn save_control_receipt(
        &self,
        key: &str,
        request_digest: &str,
        receipt_json: &str,
    ) -> Result<(), EngineErrorCode> {
        if receipt_json.len() > self.limits.max_snapshot_bytes {
            return Err(EngineErrorCode::CapacityExceeded);
        }
        let c = self
            .connection
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let count: usize = c.query_row("SELECT COUNT(*) FROM control_idempotency", [], |row| {
            row.get(0)
        })?;
        if count >= self.limits.max_idempotency_entries {
            return Err(EngineErrorCode::CapacityExceeded);
        }
        c.execute(
            "INSERT INTO control_idempotency(idempotency_key,request_digest,receipt_json) VALUES(?1,?2,?3) ON CONFLICT(idempotency_key) DO NOTHING",
            params![key, request_digest, receipt_json],
        )?;
        Ok(())
    }
    pub fn load_snapshot(&self, id: &str) -> Result<Option<WorkflowSnapshot>, EngineErrorCode> {
        let c = self.connection.lock().unwrap();
        let json: Option<String> = c
            .query_row(
                "SELECT snapshot_json FROM workflow_snapshots WHERE workflow_id=?1",
                [id],
                |r| r.get(0),
            )
            .optional()?;
        json.map(|x| serde_json::from_str(&x).map_err(Into::into))
            .transpose()
    }
    pub fn load_policy(&self, id: &str) -> Result<Option<String>, EngineErrorCode> {
        let c = self.connection.lock().unwrap();
        Ok(c.query_row(
            "SELECT policy_json FROM workflow_policies WHERE workflow_id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()?)
    }
    pub fn all_snapshots(&self) -> Result<Vec<WorkflowSnapshot>, EngineErrorCode> {
        let c = self.connection.lock().unwrap();
        let mut q =
            c.prepare("SELECT snapshot_json FROM workflow_snapshots ORDER BY workflow_id")?;
        let rows = q.query_map([], |r| r.get::<_, String>(0))?;
        rows.map(|r| Ok(serde_json::from_str(&r?)?)).collect()
    }
    pub fn events(&self, id: &str) -> Result<Vec<WorkflowEvent>, EngineErrorCode> {
        let c = self.connection.lock().unwrap();
        let mut q = c.prepare(
            "SELECT event_json FROM workflow_journal WHERE workflow_id=?1 ORDER BY sequence",
        )?;
        let rows = q.query_map([id], |r| r.get::<_, String>(0))?;
        rows.map(|r| Ok(serde_json::from_str(&r?)?)).collect()
    }
    pub fn receipt(&self, key: &str) -> Result<Option<WorkflowReceipt>, EngineErrorCode> {
        let c = self.connection.lock().unwrap();
        let json: Option<String> = c
            .query_row(
                "SELECT receipt_json FROM workflow_idempotency WHERE idempotency_key=?1",
                [key],
                |r| r.get(0),
            )
            .optional()?;
        json.map(|x| serde_json::from_str(&x).map_err(Into::into))
            .transpose()
    }
    pub fn event_rows(
        &self,
        id: &str,
        after: u64,
        limit: usize,
    ) -> Result<Vec<(u64, WorkflowEvent)>, EngineErrorCode> {
        let c = self.connection.lock().unwrap();
        let mut q=c.prepare("SELECT cursor,event_json FROM workflow_events WHERE workflow_id=?1 AND cursor>?2 ORDER BY cursor LIMIT ?3")?;
        let rows = q.query_map(params![id, after, limit], |r| {
            Ok((r.get::<_, u64>(0)?, r.get::<_, String>(1)?))
        })?;
        rows.map(|r| {
            let (a, b) = r?;
            Ok((a, serde_json::from_str(&b)?))
        })
        .collect()
    }
    pub fn commit(
        &self,
        id: &str,
        key: &str,
        policy_json: Option<&str>,
        before: &WorkflowSnapshot,
        events: &[WorkflowEvent],
        after: &WorkflowSnapshot,
        crash: Option<&dyn CrashBoundaryInjector>,
    ) -> Result<WorkflowReceipt, EngineErrorCode> {
        let mut c = self.connection.lock().unwrap();
        let tx = c.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let unreceipted = key.starts_with("__dispatch__");
        if !unreceipted {
            if let Some(existing) = tx
                .query_row(
                    "SELECT receipt_json FROM workflow_idempotency WHERE idempotency_key=?1",
                    [key],
                    |r| r.get::<_, String>(0),
                )
                .optional()?
            {
                return Ok(serde_json::from_str(&existing)?);
            }
        }
        if crash.is_some_and(|x| x.should_crash(CrashBoundary::BeforeJournalAppend)) {
            return Err(EngineErrorCode::CrashInjected);
        }
        let counts = (
            count(&tx, "workflow_journal")?,
            count(&tx, "workflow_events")?,
            count(&tx, "workflow_idempotency")?,
        );
        if counts.0 + events.len() > self.limits.max_journal_entries
            || counts.1 + events.len() > self.limits.max_events
            || counts.2 + usize::from(!unreceipted) > self.limits.max_idempotency_entries
        {
            return Err(EngineErrorCode::CapacityExceeded);
        }
        let generation: i64 = tx.query_row(
            "SELECT COALESCE(MAX(generation),0)+1 FROM workflow_snapshots",
            [],
            |r| r.get(0),
        )?;
        let sequence: i64 = tx.query_row(
            "SELECT COALESCE(MAX(sequence),0) FROM workflow_journal WHERE workflow_id=?1",
            [id],
            |r| r.get(0),
        )?;
        let cursor: i64 = tx.query_row(
            "SELECT COALESCE(MAX(cursor),0) FROM workflow_events WHERE workflow_id=?1",
            [id],
            |r| r.get(0),
        )?;
        for (offset, event) in events.iter().enumerate() {
            let json = serde_json::to_string(event)?;
            if json.len() > self.limits.max_journal_bytes {
                return Err(EngineErrorCode::CapacityExceeded);
            };
            tx.execute("INSERT INTO workflow_journal(workflow_id,sequence,generation,event_json) VALUES(?1,?2,?3,?4)",params![id,sequence+offset as i64+1,generation,json])?;
            tx.execute("INSERT INTO workflow_events(workflow_id,cursor,generation,event_json) VALUES(?1,?2,?3,?4)",params![id,cursor+offset as i64+1,generation,json])?;
        }
        if crash.is_some_and(|x| x.should_crash(CrashBoundary::AfterJournalAppend)) {
            return Err(EngineErrorCode::CrashInjected);
        }
        if crash.is_some_and(|x| x.should_crash(CrashBoundary::BeforeSnapshotReplace)) {
            return Err(EngineErrorCode::CrashInjected);
        }
        let snapshot = serde_json::to_string(after)?;
        if snapshot.len() > self.limits.max_snapshot_bytes {
            return Err(EngineErrorCode::CapacityExceeded);
        };
        tx.execute("INSERT INTO workflow_snapshots(workflow_id,generation,snapshot_json) VALUES(?1,?2,?3) ON CONFLICT(workflow_id) DO UPDATE SET generation=excluded.generation,snapshot_json=excluded.snapshot_json",params![id,generation,snapshot])?;
        if let Some(policy) = policy_json {
            tx.execute("INSERT INTO workflow_policies(workflow_id,policy_json) VALUES(?1,?2) ON CONFLICT(workflow_id) DO UPDATE SET policy_json=excluded.policy_json",params![id,policy])?;
        }
        if crash.is_some_and(|x| x.should_crash(CrashBoundary::AfterSnapshotReplace)) {
            return Err(EngineErrorCode::CrashInjected);
        }
        let receipt = WorkflowReceipt::from(after);
        let receipt_json = serde_json::to_string(&receipt)?;
        if !unreceipted {
            tx.execute("INSERT INTO workflow_idempotency(scope,idempotency_key,generation,receipt_json) VALUES(?1,?2,?3,?4)",params![id,key,generation,receipt_json])?;
            tx.execute("INSERT INTO workflow_receipts(workflow_id,idempotency_key,generation,receipt_json) VALUES(?1,?2,?3,?4)",params![id,key,generation,receipt_json])?;
        }
        tx.commit()?;
        let _ = before;
        Ok(receipt)
    }
}
impl Drop for DurableWorkflowStore {
    fn drop(&mut self) {
        if let Ok(c) = self.connection.lock() {
            let _ = c.execute(
                "DELETE FROM workflow_leases WHERE workflow_id='__store_owner__' AND owner_id=?1",
                [&self.owner_id],
            );
            let _ = c.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)");
        }
    }
}
fn count(c: &Connection, table: &str) -> Result<usize, EngineErrorCode> {
    Ok(
        c.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| {
            r.get::<_, usize>(0)
        })?,
    )
}
fn schema(c: &Connection) -> Result<(), EngineErrorCode> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS workflow_journal(workflow_id TEXT NOT NULL,sequence INTEGER NOT NULL,generation INTEGER NOT NULL,event_json TEXT NOT NULL);CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_journal_workflow_sequence ON workflow_journal(workflow_id,sequence);CREATE TABLE IF NOT EXISTS workflow_snapshots(workflow_id TEXT PRIMARY KEY,generation INTEGER NOT NULL,snapshot_json TEXT NOT NULL);CREATE TABLE IF NOT EXISTS workflow_events(workflow_id TEXT NOT NULL,cursor INTEGER NOT NULL,generation INTEGER NOT NULL,event_json TEXT NOT NULL);CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_events_workflow_cursor ON workflow_events(workflow_id,cursor);CREATE TABLE IF NOT EXISTS workflow_idempotency(scope TEXT NOT NULL,idempotency_key TEXT PRIMARY KEY,generation INTEGER NOT NULL,receipt_json TEXT NOT NULL);CREATE UNIQUE INDEX IF NOT EXISTS idx_workflow_idempotency_scope_key ON workflow_idempotency(scope,idempotency_key);CREATE TABLE IF NOT EXISTS workflow_receipts(workflow_id TEXT NOT NULL,idempotency_key TEXT PRIMARY KEY,generation INTEGER NOT NULL,receipt_json TEXT NOT NULL);CREATE INDEX IF NOT EXISTS idx_workflow_receipts_workflow ON workflow_receipts(workflow_id);CREATE TABLE IF NOT EXISTS workflow_leases(workflow_id TEXT PRIMARY KEY,owner_id TEXT NOT NULL,owner_fence INTEGER NOT NULL,expires_at_ms INTEGER NOT NULL,generation INTEGER NOT NULL);CREATE TABLE IF NOT EXISTS store_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);CREATE TABLE IF NOT EXISTS workflow_policies(workflow_id TEXT PRIMARY KEY,policy_json TEXT NOT NULL);CREATE TABLE IF NOT EXISTS policy_revisions(revision TEXT PRIMARY KEY,policy_json TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('registered','active')));CREATE TABLE IF NOT EXISTS control_idempotency(idempotency_key TEXT PRIMARY KEY,request_digest TEXT NOT NULL,receipt_json TEXT NOT NULL);")?;
    Ok(())
}
