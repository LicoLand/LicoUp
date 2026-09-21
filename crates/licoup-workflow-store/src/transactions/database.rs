//! Connections, the write gate, and what one write transaction cost.

use anyhow::{Result, anyhow};
use rusqlite::{Connection, Transaction, TransactionBehavior};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};

use super::gate::FairWriteGate;
use crate::schema;

/// One database file, one gated write connection, one ungated read connection.
///
/// Reads are on a separate connection on purpose: a read never takes the write
/// gate, so a slow read cannot delay a commit and a queued commit cannot delay
/// a read. The cost is that a read may see the state just before a commit
/// rather than just after, which is exactly what a checkpoint read followed by
/// a compare-and-set write is built to detect.
pub struct WorkflowDatabase {
    path: PathBuf,
    writer: FairWriteGate<Connection>,
    reader: Mutex<Connection>,
}

impl std::fmt::Debug for WorkflowDatabase {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The path is user data; the shape of the connection is not.
        formatter
            .debug_struct("WorkflowDatabase")
            .field("writer", &self.writer)
            .finish_non_exhaustive()
    }
}

/// What one write transaction did.
///
/// `rows_changed` is SQLite's own count of rows the committed statements
/// modified; `bytes_written` is the serialized size of the payloads this
/// change produced (the event, the checkpoint, the commands, the intents),
/// not of the tables it touched. Both describe *this change*, which is what
/// makes them useful: a store whose per-change cost grows with its history
/// shows up here as a number that grows, because a number that stays put
/// cannot be produced by rewriting history.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct WriteStats {
    pub rows_changed: usize,
    pub bytes_written: usize,
}

impl WorkflowDatabase {
    /// Open (or create) the workflow database at `path`.
    pub fn open(path: &Path) -> Result<Self> {
        let mut writer =
            Connection::open(path).map_err(|_| anyhow!("workflow_database_open_failed"))?;
        // A file that already holds this format is validated and only added to;
        // a new file is created. `schema` owns which of the two happened.
        schema::prepare(&mut writer)?;
        let reader =
            Connection::open(path).map_err(|_| anyhow!("workflow_database_open_failed"))?;
        reader.execute_batch(schema::CONNECTION_PRAGMAS)?;
        Ok(Self {
            path: path.to_path_buf(),
            writer: FairWriteGate::new(writer),
            reader: Mutex::new(reader),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Run a read on the read connection. No gate, no write lock, no ordering
    /// guarantee beyond "committed rows are visible".
    pub fn read<T>(&self, operation: impl FnOnce(&Connection) -> Result<T>) -> Result<T> {
        let reader = self.reader.lock().unwrap_or_else(PoisonError::into_inner);
        operation(&reader)
    }

    /// Run one short write transaction and report what it cost.
    ///
    /// The body receives the open transaction and a [`WriteStats`] to add its
    /// payload sizes to. It receives nothing else: no compiler, no effect port,
    /// and no way to reach one, so "no compilation and no external call inside a
    /// write transaction" is a property of the signature rather than a rule
    /// someone has to remember.
    ///
    /// An `Err` from the body rolls the transaction back and the error is
    /// returned unchanged.
    ///
    /// Not reentrant: a body that called back into `write` would wait for a gate
    /// its own caller is holding. Nothing in this crate does, and nothing should
    /// need to — a transition is one transaction, not a nested one.
    pub fn write<T>(
        &self,
        operation: impl FnOnce(&Transaction<'_>, &mut WriteStats) -> Result<T>,
    ) -> Result<(T, WriteStats)> {
        let mut writer = self.writer.enter();
        let transaction = writer.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let before = transaction.total_changes();
        let mut stats = WriteStats::default();
        let value = operation(&transaction, &mut stats)?;
        transaction.commit()?;
        // Counted from the connection that just committed, and only after the
        // commit, so a rolled-back transaction never reports its statements as
        // a change anyone can see.
        stats.rows_changed = (writer.total_changes() - before) as usize;
        Ok((value, stats))
    }

    /// How many write transactions this database has taken a ticket for.
    /// Telemetry for admission wait, and what lets a test stage writers in a
    /// known order instead of racing them.
    pub fn tickets_taken(&self) -> u64 {
        self.writer.tickets_taken()
    }
}
