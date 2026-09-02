use super::{
    Conversation, ConversationDispatch, ConversationEvent, ConversationSummary,
    DEFAULT_LOCAL_AGENT_GROUP_ID, DEFAULT_LOCAL_AGENT_GROUP_TITLE, DirectTurn, DispatchSessionMode,
    DispatchState, EventKind, EventPage, EventPart, EventPartKind, Membership, MembershipAccess,
    Principal, PrincipalKind, RuntimeBinding, SourceLink, TurnState,
};
use anyhow::{Result, anyhow};
use rusqlite::{
    Connection, OptionalExtension, Row, Statement, TransactionBehavior, params, params_from_iter,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use std::collections::HashMap;
use std::ops::{Deref, DerefMut};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub const DEFAULT_EVENT_PAGE_SIZE: usize = 50;
pub const MAX_EVENT_PAGE_SIZE: usize = 100;
/// Bounded conversation SQLite pool size. Long-running processes reuse at
/// most this many configured connections; acquisition blocks on a condition
/// variable instead of opening unbounded connections.
pub const DEFAULT_CONVERSATION_POOL_SIZE: usize = 4;
pub type StoreError = anyhow::Error;
pub type StoreResult<T> = Result<T, StoreError>;

const DATABASE_FILE: &str = "conversations.sqlite3";

/// Canonical Conversation table and index layout. Shared by the schema
/// initializer and the synthetic versioned fixtures used by migration tests.
const CONVERSATION_SCHEMA_TABLES: &str = "
         CREATE TABLE IF NOT EXISTS principals (
           id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('human','agent')),
           display_name TEXT NOT NULL, agent_id TEXT, created_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS conversations (
           id TEXT PRIMARY KEY, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
           pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
           is_group INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1)), strategy_revision TEXT,
           revision INTEGER NOT NULL DEFAULT 0,
           created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS conversations_updated_idx ON conversations(updated_at DESC, id DESC);
         CREATE TABLE IF NOT EXISTS memberships (
           id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           principal_id TEXT NOT NULL REFERENCES principals(id), access TEXT NOT NULL CHECK(access IN ('owner','member')),
           status TEXT NOT NULL CHECK(status IN ('active','left')), joined_at INTEGER NOT NULL, left_at INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS memberships_active_unique ON memberships(conversation_id, principal_id) WHERE status='active';
         CREATE INDEX IF NOT EXISTS memberships_conversation_idx ON memberships(conversation_id, status, joined_at);
         CREATE TABLE IF NOT EXISTS events (
           id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           sequence INTEGER NOT NULL, author_membership_id TEXT REFERENCES memberships(id), kind TEXT NOT NULL,
           causation_id TEXT, correlation_id TEXT,
           created_at INTEGER NOT NULL, finalized INTEGER NOT NULL DEFAULT 0 CHECK(finalized IN (0,1)),
           UNIQUE(conversation_id, sequence)
         );
         CREATE INDEX IF NOT EXISTS events_conversation_idx ON events(conversation_id, sequence);
         CREATE TABLE IF NOT EXISTS event_parts (
           id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
           ordinal INTEGER NOT NULL, kind TEXT NOT NULL, content TEXT NOT NULL,
           runtime_cursor INTEGER, created_at INTEGER NOT NULL,
           UNIQUE(event_id, ordinal)
         );
         CREATE INDEX IF NOT EXISTS event_parts_event_idx ON event_parts(event_id, ordinal);
         CREATE TABLE IF NOT EXISTS direct_turns (
           id TEXT PRIMARY KEY,
           conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           source_event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
           membership_id TEXT NOT NULL REFERENCES memberships(id),
           state TEXT NOT NULL, ordinal INTEGER NOT NULL,
           UNIQUE(source_event_id, membership_id)
         );
         CREATE INDEX IF NOT EXISTS direct_turns_pending_idx
           ON direct_turns(state, conversation_id, ordinal);
         CREATE VIRTUAL TABLE IF NOT EXISTS event_search USING fts5(event_id UNINDEXED, conversation_id UNINDEXED, content);
         CREATE TABLE IF NOT EXISTS source_links (
           id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           source_kind TEXT NOT NULL, native_identity TEXT NOT NULL,
           UNIQUE(source_kind, native_identity)
         );
         CREATE TABLE IF NOT EXISTS runtime_bindings (
           id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           membership_id TEXT NOT NULL REFERENCES memberships(id) ON DELETE CASCADE, lane TEXT NOT NULL,
           availability TEXT NOT NULL, safe_reason TEXT,
           runtime_session_id TEXT, runtime_conversation_path TEXT, working_directory TEXT,
           UNIQUE(conversation_id, membership_id, lane)
         );
         CREATE TABLE IF NOT EXISTS conversation_dispatches (
           id TEXT PRIMARY KEY,
           conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           membership_id TEXT NOT NULL REFERENCES memberships(id),
           operation TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN ('accepted','running','completed','failed','cancel-requested','cancelled')),
           session_mode TEXT NOT NULL CHECK(session_mode IN ('new','resume')),
           runtime_conversation_path TEXT, error_code TEXT,
           created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS conversation_dispatches_resume_idx
           ON conversation_dispatches(conversation_id, membership_id, state, updated_at DESC);
         CREATE TABLE IF NOT EXISTS migration_provenance (
           source_kind TEXT NOT NULL, source_identity TEXT NOT NULL,
           conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           PRIMARY KEY(source_kind, source_identity)
         );";

#[derive(Clone, Debug)]
pub struct ConversationStore {
    pool: Arc<ConversationPool>,
}

/// Owned bounded SQLite state for one long-running Conversation authority.
/// Connections are configured (WAL, foreign keys, timeout, hardening) once at
/// creation and are checked out only for local database work; a checkout can
/// never escape into agent, network, or subprocess callbacks because it is
/// scoped to the `with_connection` closure.
#[derive(Debug)]
struct ConversationPool {
    db_path: PathBuf,
    state: Mutex<PoolState>,
    available: Condvar,
    #[cfg(test)]
    counters: Arc<ConversationCounters>,
}

#[derive(Debug, Default)]
struct PoolState {
    idle: Vec<Connection>,
    in_flight: usize,
    opened: usize,
}

/// Privacy-safe counters for the focused suite: connection opens, SQL query
/// statements, pool leases, and in-flight direct turns. They never carry
/// content, paths, credentials, or runtime data, and their read accessors are
/// test-only so production never reports them.
#[cfg(test)]
#[derive(Debug, Default)]
pub(crate) struct ConversationCounters {
    opens: AtomicUsize,
    queries: AtomicUsize,
    leases: AtomicUsize,
    peak_in_flight: AtomicUsize,
    in_flight_turns: AtomicUsize,
    peak_in_flight_turns: AtomicUsize,
}

#[cfg(test)]
impl ConversationCounters {
    pub(crate) fn opens(&self) -> usize {
        self.opens.load(Ordering::Relaxed)
    }

    pub(crate) fn queries(&self) -> usize {
        self.queries.load(Ordering::Relaxed)
    }

    pub(crate) fn leases(&self) -> usize {
        self.leases.load(Ordering::Relaxed)
    }

    pub(crate) fn peak_in_flight(&self) -> usize {
        self.peak_in_flight.load(Ordering::Relaxed)
    }

    pub(crate) fn in_flight_turns(&self) -> usize {
        self.in_flight_turns.load(Ordering::Relaxed)
    }

    pub(crate) fn peak_in_flight_turns(&self) -> usize {
        self.peak_in_flight_turns.load(Ordering::Relaxed)
    }

    pub(crate) fn begin_turn(&self) {
        let in_flight = self.in_flight_turns.fetch_add(1, Ordering::Relaxed) + 1;
        self.peak_in_flight_turns
            .fetch_max(in_flight, Ordering::Relaxed);
    }

    pub(crate) fn end_turn(&self) {
        self.in_flight_turns.fetch_sub(1, Ordering::Relaxed);
    }
}

/// RAII checkout of one pooled connection. Returning the connection to the
/// pool happens on drop, so a lease can never span a runtime callback.
struct PooledConnection {
    pool: Arc<ConversationPool>,
    connection: Option<Connection>,
}

impl Deref for PooledConnection {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        self.connection.as_ref().expect("pooled connection present")
    }
}

impl DerefMut for PooledConnection {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.connection.as_mut().expect("pooled connection present")
    }
}

impl Drop for PooledConnection {
    fn drop(&mut self) {
        if let Some(connection) = self.connection.take() {
            self.pool.release(connection);
        }
    }
}

impl ConversationPool {
    fn new(db_path: PathBuf) -> Arc<Self> {
        Arc::new(Self {
            db_path,
            state: Mutex::new(PoolState::default()),
            available: Condvar::new(),
            #[cfg(test)]
            counters: Arc::new(ConversationCounters::default()),
        })
    }

    fn acquire(self: &Arc<Self>) -> StoreResult<PooledConnection> {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let connection = loop {
            if let Some(connection) = state.idle.pop() {
                break connection;
            }
            if state.in_flight < DEFAULT_CONVERSATION_POOL_SIZE {
                let connection = match open_pooled_connection(&self.db_path) {
                    Ok(connection) => connection,
                    Err(error) => {
                        self.available.notify_all();
                        return Err(error);
                    }
                };
                state.opened += 1;
                #[cfg(test)]
                self.counters.opens.fetch_add(1, Ordering::Relaxed);
                break connection;
            }
            state = self
                .available
                .wait(state)
                .unwrap_or_else(|poison| poison.into_inner());
        };
        state.in_flight += 1;
        #[cfg(test)]
        {
            self.counters.leases.fetch_add(1, Ordering::Relaxed);
            self.counters
                .peak_in_flight
                .fetch_max(state.in_flight, Ordering::Relaxed);
        }
        Ok(PooledConnection {
            pool: Arc::clone(self),
            connection: Some(connection),
        })
    }

    fn release(&self, connection: Connection) {
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        state.idle.push(connection);
        state.in_flight -= 1;
        self.available.notify_one();
    }
}

fn open_pooled_connection(db_path: &Path) -> StoreResult<Connection> {
    let connection = Connection::open(db_path)
        .map_err(|error| anyhow!("conversation_database_open_failed: {error}"))?;
    configure_connection(&connection)?;
    crate::platform::file_security::harden_private_path(db_path)?;
    for suffix in ["-wal", "-shm"] {
        let mut sidecar = db_path.as_os_str().to_os_string();
        sidecar.push(suffix);
        crate::platform::file_security::harden_private_path(Path::new(&sidecar))?;
    }
    Ok(connection)
}

/// Query-counting view over one checked-out connection. It counts every SQL
/// statement preparation or execution on the pooled connection so the focused
/// suite can prove query counts are independent of page size.
struct CountedConnection<'a> {
    connection: &'a mut Connection,
    #[cfg(test)]
    counters: &'a ConversationCounters,
}

impl<'a> CountedConnection<'a> {
    fn new(
        connection: &'a mut Connection,
        #[cfg(test)] counters: &'a ConversationCounters,
    ) -> Self {
        Self {
            connection,
            #[cfg(test)]
            counters,
        }
    }

    fn count(&self) {
        #[cfg(test)]
        self.counters.queries.fetch_add(1, Ordering::Relaxed);
    }

    fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> rusqlite::Result<T>
    where
        P: rusqlite::Params,
        F: FnOnce(&Row<'_>) -> rusqlite::Result<T>,
    {
        self.count();
        self.connection.query_row(sql, params, f)
    }

    fn execute<P: rusqlite::Params>(&self, sql: &str, params: P) -> rusqlite::Result<usize> {
        self.count();
        self.connection.execute(sql, params)
    }

    fn transaction_with_behavior(
        &mut self,
        behavior: TransactionBehavior,
    ) -> rusqlite::Result<CountedTransaction<'_>> {
        self.count();
        let transaction = self.connection.transaction_with_behavior(behavior)?;
        Ok(CountedTransaction {
            transaction,
            #[cfg(test)]
            counters: self.counters,
        })
    }

    fn unchecked_transaction(&mut self) -> rusqlite::Result<CountedTransaction<'_>> {
        self.count();
        let transaction = self.connection.unchecked_transaction()?;
        Ok(CountedTransaction {
            transaction,
            #[cfg(test)]
            counters: self.counters,
        })
    }
}

impl<'a> Deref for CountedConnection<'a> {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        self.connection
    }
}

impl<'a> DerefMut for CountedConnection<'a> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.connection
    }
}

struct CountedTransaction<'a> {
    transaction: rusqlite::Transaction<'a>,
    #[cfg(test)]
    counters: &'a ConversationCounters,
}

impl<'a> CountedTransaction<'a> {
    fn count(&self) {
        #[cfg(test)]
        self.counters.queries.fetch_add(1, Ordering::Relaxed);
    }

    fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> rusqlite::Result<T>
    where
        P: rusqlite::Params,
        F: FnOnce(&Row<'_>) -> rusqlite::Result<T>,
    {
        self.count();
        self.transaction.query_row(sql, params, f)
    }

    fn execute<P: rusqlite::Params>(&self, sql: &str, params: P) -> rusqlite::Result<usize> {
        self.count();
        self.transaction.execute(sql, params)
    }

    fn commit(self) -> rusqlite::Result<()> {
        self.count();
        self.transaction.commit()
    }
}

impl Deref for CountedTransaction<'_> {
    type Target = Connection;

    fn deref(&self) -> &Self::Target {
        &self.transaction
    }
}

/// Counting view shared by checked-out connections and their transactions so
/// inner helpers accept either without bypassing statement counting. Every
/// SQL statement prepared or executed through this view increments the
/// privacy-safe query counter once; the counter carries no content.
trait CountedSqlite {
    fn prepare(&self, sql: &str) -> rusqlite::Result<Statement<'_>>;
    fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> rusqlite::Result<T>
    where
        P: rusqlite::Params,
        F: FnOnce(&Row<'_>) -> rusqlite::Result<T>;
    fn execute<P: rusqlite::Params>(&self, sql: &str, params: P) -> rusqlite::Result<usize>;
}

impl CountedSqlite for CountedConnection<'_> {
    fn prepare(&self, sql: &str) -> rusqlite::Result<Statement<'_>> {
        self.count();
        self.connection.prepare(sql)
    }

    fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> rusqlite::Result<T>
    where
        P: rusqlite::Params,
        F: FnOnce(&Row<'_>) -> rusqlite::Result<T>,
    {
        self.count();
        self.connection.query_row(sql, params, f)
    }

    fn execute<P: rusqlite::Params>(&self, sql: &str, params: P) -> rusqlite::Result<usize> {
        self.count();
        self.connection.execute(sql, params)
    }
}

impl CountedSqlite for CountedTransaction<'_> {
    fn prepare(&self, sql: &str) -> rusqlite::Result<Statement<'_>> {
        self.count();
        self.transaction.prepare(sql)
    }

    fn query_row<T, P, F>(&self, sql: &str, params: P, f: F) -> rusqlite::Result<T>
    where
        P: rusqlite::Params,
        F: FnOnce(&Row<'_>) -> rusqlite::Result<T>,
    {
        self.count();
        self.transaction.query_row(sql, params, f)
    }

    fn execute<P: rusqlite::Params>(&self, sql: &str, params: P) -> rusqlite::Result<usize> {
        self.count();
        self.transaction.execute(sql, params)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct DirectTurnExecutionContext {
    pub turn: DirectTurn,
    pub agent_id: String,
    pub source_content: String,
    pub runtime_session_id: Option<String>,
    pub runtime_conversation_path: Option<String>,
    pub working_directory: Option<String>,
}

/// Private canonical ownership for one persistent desktop Agent turn. The
/// dispatch id is also the opaque transport handle; conversation and
/// membership ids are required on every later attach or control operation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationRuntimeScope {
    pub dispatch_id: String,
    pub conversation_id: String,
    pub membership_id: String,
    pub event_id: String,
}

impl ConversationStore {
    pub fn open(portable_root: &Path) -> StoreResult<Self> {
        let root = portable_root.join("client-state").join("conversations");
        crate::platform::file_security::ensure_private_dir(&root)?;
        let db_path = root.join(DATABASE_FILE);
        let store = Self {
            pool: ConversationPool::new(db_path),
        };
        store.with_connection(|connection| initialize_schema(connection))?;
        Ok(store)
    }

    /// Open an isolated in-memory store for deterministic domain tests.
    pub fn open_in_memory() -> StoreResult<Self> {
        let path =
            std::env::temp_dir().join(format!("lico-conversation-{}.sqlite3", Uuid::new_v4()));
        let store = Self {
            pool: ConversationPool::new(path),
        };
        store.with_connection(|connection| initialize_schema(connection))?;
        Ok(store)
    }

    /// Reuse the idempotent reserved-default-group normalization after a
    /// legacy import may have adopted the historical default group, before
    /// the legacy completion marker is written. Naturally idempotent: events
    /// already removed stay absent, already-active memberships stay active,
    /// already-contiguous sequences are rewritten to the same values, and the
    /// retired default title is migrated once to the current product name.
    pub(crate) fn normalize_reserved_default_group_after_legacy_import(&self) -> StoreResult<()> {
        self.with_connection(|connection| normalize_reserved_group_after_legacy_import(connection))
    }

    /// Ensure the product-owned Local group exists in the canonical
    /// Conversation store. Legacy imports are adopted into the stable identity
    /// instead of creating a second group or reopening the retired JSON store.
    pub(crate) fn ensure_default_local_group(&self) -> StoreResult<Conversation> {
        self.with_connection(ensure_default_local_group_inner)
    }

    pub fn db_path(&self) -> &Path {
        &self.pool.db_path
    }

    fn with_connection<T>(
        &self,
        operation: impl FnOnce(&mut CountedConnection<'_>) -> StoreResult<T>,
    ) -> StoreResult<T> {
        let mut connection = self.pool.acquire()?;
        let mut counted = CountedConnection::new(
            &mut connection,
            #[cfg(test)]
            &self.pool.counters,
        );
        operation(&mut counted)
    }

    /// Test-only view of the pool counters shared by every clone of this
    /// store, so the focused suite can assert reuse and query bounds.
    #[cfg(test)]
    pub(crate) fn counters(&self) -> &Arc<ConversationCounters> {
        &self.pool.counters
    }

    pub fn ensure_principal(&self, principal: &Principal) -> StoreResult<()> {
        validate_identifier(&principal.id, "principal_id")?;
        validate_required_text(&principal.display_name, "principal_display_name")?;
        self.with_connection(|connection| upsert_principal(connection, principal))
    }

    /// Prepare one persistent runtime dispatch and commit its owning
    /// Conversation facts before native execution starts. Direct Agent sends
    /// receive (or reuse) a canonical one-Agent Conversation; group sends pass
    /// their existing Conversation and Membership and therefore do not create
    /// a competing transcript.
    pub fn prepare_runtime_dispatch(
        &self,
        agent_id: &str,
        session_id: &str,
        text: &str,
        conversation_id: Option<&str>,
        membership_id: Option<&str>,
        causation_id: Option<&str>,
        requested_dispatch_id: Option<&str>,
    ) -> StoreResult<ConversationRuntimeScope> {
        validate_identifier(agent_id, "runtime_agent_id")?;
        validate_required_text(text, "runtime_user_text")?;
        if conversation_id.is_some() != membership_id.is_some() {
            return Err(anyhow!("runtime_scope_incomplete"));
        }
        let dispatch_id = if let Some(requested) = requested_dispatch_id {
            validate_identifier(requested, "dispatch_id")?;
            requested.to_owned()
        } else {
            new_id("dispatch")
        };
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let (conversation_id, membership_id, append_user) =
                if let (Some(conversation_id), Some(membership_id)) =
                    (conversation_id, membership_id)
                {
                    validate_identifier(conversation_id, "conversation_id")?;
                    validate_identifier(membership_id, "membership_id")?;
                    let eligible: Option<i64> = transaction
                        .query_row(
                            "SELECT 1 FROM memberships m JOIN principals p ON p.id=m.principal_id
                             WHERE m.id=?1 AND m.conversation_id=?2 AND m.status='active'
                               AND p.kind='agent' AND p.agent_id=?3",
                            params![membership_id, conversation_id, agent_id],
                            |row| row.get(0),
                        )
                        .optional()?;
                    if eligible.is_none() {
                        return Err(anyhow!("runtime_scope_mismatch"));
                    }
                    (
                        conversation_id.to_owned(),
                        membership_id.to_owned(),
                        causation_id.is_none(),
                    )
                } else {
                    let source_identity = runtime_source_identity(agent_id, session_id, &dispatch_id)?;
                    let existing: Option<String> = if session_id.trim().is_empty() {
                        None
                    } else {
                        transaction
                            .query_row(
                                "SELECT conversation_id FROM migration_provenance
                                 WHERE source_kind='projection' AND source_identity=?1
                                 UNION ALL
                                 SELECT conversation_id FROM source_links
                                 WHERE source_kind='agent-runtime' AND native_identity=?1
                                 LIMIT 1",
                                params![source_identity],
                                |row| row.get(0),
                            )
                            .optional()?
                    };
                    let conversation_id = existing.unwrap_or_else(|| new_id("conversation"));
                    let owner_principal = Principal {
                        id: "human:local".to_owned(),
                        kind: PrincipalKind::Human,
                        display_name: "human:local".to_owned(),
                        agent_id: None,
                        created_at_unix_ms: now,
                    };
                    let agent_principal = Principal {
                        id: format!("agent:{agent_id}"),
                        kind: PrincipalKind::Agent,
                        display_name: agent_id.to_owned(),
                        agent_id: Some(agent_id.to_owned()),
                        created_at_unix_ms: now,
                    };
                    upsert_principal(&transaction, &owner_principal)?;
                    upsert_principal(&transaction, &agent_principal)?;
                    let exists: Option<i64> = transaction
                        .query_row(
                            "SELECT 1 FROM conversations WHERE id=?1",
                            params![conversation_id],
                            |row| row.get(0),
                        )
                        .optional()?;
                    if exists.is_none() {
                        transaction.execute(
                            "INSERT INTO conversations(
                               id, title, archived, pinned, is_group, revision, created_at, updated_at
                             ) VALUES (?1, ?2, 0, 0, 0, 0, ?3, ?3)",
                            params![conversation_id, agent_id, now],
                        )?;
                        transaction.execute(
                            "INSERT INTO memberships(
                               id, conversation_id, principal_id, access, status, joined_at, left_at
                             ) VALUES (?1, ?2, ?3, 'owner', 'active', ?4, NULL)",
                            params![new_id("membership"), conversation_id, owner_principal.id, now],
                        )?;
                    }
                    let membership_id: Option<String> = transaction
                        .query_row(
                            "SELECT m.id FROM memberships m JOIN principals p ON p.id=m.principal_id
                             WHERE m.conversation_id=?1 AND m.status='active'
                               AND p.kind='agent' AND p.agent_id=?2 LIMIT 1",
                            params![conversation_id, agent_id],
                            |row| row.get(0),
                        )
                        .optional()?;
                    let membership_id = membership_id.unwrap_or_else(|| new_id("membership"));
                    let membership_exists: Option<i64> = transaction
                        .query_row(
                            "SELECT 1 FROM memberships WHERE id=?1",
                            params![membership_id],
                            |row| row.get(0),
                        )
                        .optional()?;
                    if membership_exists.is_none() {
                        transaction.execute(
                            "INSERT INTO memberships(
                               id, conversation_id, principal_id, access, status, joined_at, left_at
                             ) VALUES (?1, ?2, ?3, 'member', 'active', ?4, NULL)",
                            params![membership_id, conversation_id, agent_principal.id, now],
                        )?;
                    }
                    if !session_id.trim().is_empty() {
                        transaction.execute(
                            "INSERT INTO migration_provenance(source_kind, source_identity, conversation_id)
                             VALUES ('projection', ?1, ?2)
                             ON CONFLICT(source_kind, source_identity) DO NOTHING",
                            params![source_identity, conversation_id],
                        )?;
                        transaction.execute(
                            "INSERT INTO source_links(id, conversation_id, source_kind, native_identity)
                             VALUES (?1, ?2, 'agent-runtime', ?3)
                             ON CONFLICT(source_kind, native_identity) DO NOTHING",
                            params![new_id("source"), conversation_id, source_identity],
                        )?;
                    }
                    (conversation_id, membership_id, true)
                };

            transaction.execute(
                "INSERT INTO conversation_dispatches(
                   id, conversation_id, membership_id, operation, state, session_mode,
                   runtime_conversation_path, error_code, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, 'send', 'accepted', ?4, NULL, NULL, ?5, ?5)",
                params![
                    dispatch_id,
                    conversation_id,
                    membership_id,
                    if session_id.trim().is_empty() { "new" } else { "resume" },
                    now,
                ],
            )?;
            let turn_causation_id = if append_user {
                let owner_membership: Option<String> = transaction
                    .query_row(
                        "SELECT m.id FROM memberships m JOIN principals p ON p.id=m.principal_id
                         WHERE m.conversation_id=?1 AND m.status='active' AND p.kind='human'
                         ORDER BY m.joined_at, m.id LIMIT 1",
                        params![conversation_id],
                        |row| row.get(0),
                    )
                    .optional()?;
                let user_event_id = new_id("event");
                insert_event(
                    &transaction,
                    &user_event_id,
                    &conversation_id,
                    owner_membership.as_deref(),
                    EventKind::Message,
                    &[NewEventPart {
                        id: String::new(),
                        kind: EventPartKind::Text,
                        content: text.to_owned(),
                    }],
                    causation_id,
                    Some(&dispatch_id),
                    true,
                    false,
                    now,
                )?;
                Some(user_event_id)
            } else {
                causation_id.map(str::to_owned)
            };
            let event_id = new_id("event");
            insert_event(
                &transaction,
                &event_id,
                &conversation_id,
                Some(&membership_id),
                EventKind::Message,
                &[],
                turn_causation_id.as_deref(),
                Some(&dispatch_id),
                false,
                false,
                now,
            )?;
            transaction.commit()?;
            Ok(ConversationRuntimeScope {
                dispatch_id,
                conversation_id,
                membership_id,
                event_id,
            })
        })
    }

    /// Commit one replayable frame before it is published to any observer.
    /// Large frames are split across canonical metadata parts while preserving
    /// one runtime cursor.
    pub fn append_runtime_frame(
        &self,
        scope: &ConversationRuntimeScope,
        cursor: u64,
        frame: &Value,
    ) -> StoreResult<()> {
        if cursor == 0 || cursor > i64::MAX as u64 {
            return Err(anyhow!("runtime_cursor_invalid"));
        }
        let encoded = serde_json::to_string(frame)?;
        let parts = runtime_frame_parts(&encoded);
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let state: Option<(String, i64)> = transaction
                .query_row(
                    "SELECT d.state, e.finalized FROM conversation_dispatches d
                     JOIN events e ON e.id=?4 AND e.conversation_id=d.conversation_id
                       AND e.correlation_id=d.id AND e.author_membership_id=d.membership_id
                     WHERE d.id=?1 AND d.conversation_id=?2 AND d.membership_id=?3",
                    params![
                        scope.dispatch_id,
                        scope.conversation_id,
                        scope.membership_id,
                        scope.event_id,
                    ],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?;
            if !matches!(state.as_ref(), Some((state, 0)) if matches!(state.as_str(), "accepted" | "running")) {
                return Err(anyhow!("runtime_dispatch_not_active"));
            }
            let cursor_exists: Option<i64> = transaction
                .query_row(
                    "SELECT 1 FROM event_parts WHERE event_id=?1 AND runtime_cursor=?2 LIMIT 1",
                    params![scope.event_id, cursor as i64],
                    |row| row.get(0),
                )
                .optional()?;
            if cursor_exists.is_some() {
                return Err(anyhow!("runtime_cursor_duplicate"));
            }
            let mut ordinal: i64 = transaction.query_row(
                "SELECT COALESCE(MAX(ordinal), -1)+1 FROM event_parts WHERE event_id=?1",
                params![scope.event_id],
                |row| row.get(0),
            )?;
            for part in runtime_semantic_parts(frame) {
                insert_runtime_event_part(
                    &transaction,
                    &scope.conversation_id,
                    &scope.event_id,
                    ordinal,
                    &part,
                    None,
                    now,
                )?;
                ordinal += 1;
            }
            for part in parts {
                insert_runtime_event_part(
                    &transaction,
                    &scope.conversation_id,
                    &scope.event_id,
                    ordinal,
                    &part,
                    Some(cursor),
                    now,
                )?;
                ordinal += 1;
            }
            transaction.execute(
                "UPDATE conversation_dispatches SET state='running', updated_at=?2
                 WHERE id=?1 AND state='accepted'",
                params![scope.dispatch_id, now],
            )?;
            bump_revision(&transaction, &scope.conversation_id, now)?;
            transaction.commit()?;
            Ok(())
        })
    }

    /// Page committed frames for a single canonical turn. The composite
    /// correlation/cursor index makes fallback proportional to returned data.
    pub fn runtime_frames_after(
        &self,
        scope: &ConversationRuntimeScope,
        after_cursor: u64,
        through_cursor: u64,
        limit: usize,
    ) -> StoreResult<Vec<Value>> {
        if after_cursor > through_cursor || through_cursor > i64::MAX as u64 {
            return Err(anyhow!("runtime_cursor_invalid"));
        }
        let limit = limit.clamp(1, 512);
        self.with_connection(|connection| {
            let mut statement = connection.prepare(
                "SELECT selected.runtime_cursor, p.ordinal, p.content
                  FROM (
                   SELECT parts.runtime_cursor FROM event_parts parts
                   JOIN events event ON event.id=parts.event_id
                   WHERE parts.event_id=?1 AND event.correlation_id=?2
                     AND parts.runtime_cursor IS NOT NULL
                     AND runtime_cursor>?3 AND runtime_cursor<=?4
                   GROUP BY parts.runtime_cursor
                   ORDER BY parts.runtime_cursor ASC LIMIT ?5
                  ) selected
                 JOIN event_parts p ON p.event_id=?1
                   AND p.runtime_cursor=selected.runtime_cursor
                 ORDER BY selected.runtime_cursor ASC, p.ordinal ASC",
            )?;
            let rows = statement.query_map(
                params![
                    scope.event_id,
                    scope.dispatch_id,
                    after_cursor as i64,
                    through_cursor as i64,
                    limit as i64,
                ],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(2)?)),
            )?;
            let mut frames = Vec::new();
            let mut current_cursor = None;
            let mut encoded = String::new();
            for row in rows {
                let (cursor, content) = row?;
                if current_cursor.is_some_and(|current| current != cursor) {
                    frames.push(serde_json::from_str(&encoded)?);
                    encoded.clear();
                }
                current_cursor = Some(cursor);
                encoded.push_str(&content);
            }
            if current_cursor.is_some() {
                frames.push(serde_json::from_str(&encoded)?);
            }
            Ok(frames)
        })
    }

    /// Persist the terminal lifecycle and dispatch state in one canonical
    /// transaction. Terminal metadata is not a replay cursor frame.
    pub fn finish_runtime_dispatch(
        &self,
        scope: &ConversationRuntimeScope,
        terminal: &Value,
        state: DispatchState,
        error_code: Option<&str>,
    ) -> StoreResult<()> {
        if !matches!(
            state,
            DispatchState::Completed | DispatchState::Failed | DispatchState::Cancelled
        ) {
            return Err(anyhow!("runtime_terminal_state_invalid"));
        }
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let finalized: Option<i64> = transaction
                .query_row(
                    "SELECT finalized FROM events
                     WHERE id=?1 AND conversation_id=?2 AND correlation_id=?3
                       AND author_membership_id=?4 AND kind='message'",
                    params![
                        scope.event_id,
                        scope.conversation_id,
                        scope.dispatch_id,
                        scope.membership_id,
                    ],
                    |row| row.get(0),
                )
                .optional()?;
            if finalized != Some(0) {
                return Err(anyhow!("runtime_dispatch_not_active"));
            }
            let changed = transaction.execute(
                "UPDATE conversation_dispatches SET state=?2, error_code=?3, updated_at=?4
                 WHERE id=?1 AND state IN ('accepted','running','cancel-requested')",
                params![scope.dispatch_id, enum_wire(state)?, error_code, now],
            )?;
            if changed != 1 {
                return Err(anyhow!("runtime_dispatch_not_active"));
            }
            let direct_turn_state = match state {
                DispatchState::Completed => TurnState::Succeeded,
                DispatchState::Cancelled => TurnState::Cancelled,
                DispatchState::Failed => TurnState::Failed,
                _ => unreachable!("terminal dispatch state validated above"),
            };
            transaction.execute(
                "UPDATE direct_turns SET state=?2
                 WHERE id=?1 AND conversation_id=?3 AND membership_id=?4 AND state='running'",
                params![
                    scope.dispatch_id,
                    enum_wire(direct_turn_state)?,
                    scope.conversation_id,
                    scope.membership_id,
                ],
            )?;
            let mut ordinal: i64 = transaction.query_row(
                "SELECT COALESCE(MAX(ordinal), -1)+1 FROM event_parts WHERE event_id=?1",
                params![scope.event_id],
                |row| row.get(0),
            )?;
            let has_text: bool = transaction.query_row(
                "SELECT EXISTS(SELECT 1 FROM event_parts WHERE event_id=?1 AND kind='text')",
                params![scope.event_id],
                |row| row.get(0),
            )?;
            if state == DispatchState::Completed && !has_text {
                if let Some(output) = terminal
                    .get("output")
                    .and_then(Value::as_str)
                    .filter(|output| !output.is_empty())
                {
                    insert_runtime_event_part(
                        &transaction,
                        &scope.conversation_id,
                        &scope.event_id,
                        ordinal,
                        &NewEventPart {
                            id: String::new(),
                            kind: EventPartKind::Text,
                            content: output.to_owned(),
                        },
                        None,
                        now,
                    )?;
                    ordinal += 1;
                }
            } else if state != DispatchState::Completed {
                insert_runtime_event_part(
                    &transaction,
                    &scope.conversation_id,
                    &scope.event_id,
                    ordinal,
                    &NewEventPart {
                        id: String::new(),
                        kind: EventPartKind::Diagnostic,
                        content: runtime_terminal_diagnostic(terminal, error_code),
                    },
                    None,
                    now,
                )?;
                ordinal += 1;
            }
            let lifecycle = serde_json::to_string(&serde_json::json!({
                "lifecycle": enum_wire(state)?,
            }))?;
            insert_runtime_event_part(
                &transaction,
                &scope.conversation_id,
                &scope.event_id,
                ordinal,
                &NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Metadata,
                    content: lifecycle,
                },
                None,
                now,
            )?;
            transaction.execute(
                "UPDATE events SET finalized=1 WHERE id=?1 AND finalized=0",
                params![scope.event_id],
            )?;
            bump_revision(&transaction, &scope.conversation_id, now)?;
            transaction.commit()?;
            Ok(())
        })
    }

    /// Bind the native session discovered after dispatch to the same canonical
    /// Conversation without exposing it through public projections.
    pub fn bind_runtime_session(
        &self,
        scope: &ConversationRuntimeScope,
        agent_id: &str,
        session_id: &str,
        runtime_conversation_path: Option<&str>,
        working_directory: Option<&str>,
    ) -> StoreResult<()> {
        if session_id.trim().is_empty() {
            return Ok(());
        }
        let source_identity = runtime_source_identity(agent_id, session_id, &scope.dispatch_id)?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            transaction.execute(
                "INSERT INTO migration_provenance(source_kind, source_identity, conversation_id)
                 VALUES ('projection', ?1, ?2)
                 ON CONFLICT(source_kind, source_identity) DO NOTHING",
                params![source_identity, scope.conversation_id],
            )?;
            transaction.execute(
                "INSERT INTO source_links(id, conversation_id, source_kind, native_identity)
                 VALUES (?1, ?2, 'agent-runtime', ?3)
                 ON CONFLICT(source_kind, native_identity) DO NOTHING",
                params![new_id("source"), scope.conversation_id, source_identity],
            )?;
            transaction.execute(
                "INSERT INTO runtime_bindings(
                   id, conversation_id, membership_id, lane, availability, safe_reason,
                   runtime_session_id, runtime_conversation_path, working_directory
                 ) VALUES (?1, ?2, ?3, 'conversation', 'available', NULL, ?4, ?5, ?6)
                 ON CONFLICT(conversation_id, membership_id, lane) DO UPDATE SET
                   availability='available', safe_reason=NULL,
                   runtime_session_id=excluded.runtime_session_id,
                   runtime_conversation_path=COALESCE(excluded.runtime_conversation_path, runtime_bindings.runtime_conversation_path),
                   working_directory=COALESCE(excluded.working_directory, runtime_bindings.working_directory)",
                params![
                    new_id("runtime"),
                    scope.conversation_id,
                    scope.membership_id,
                    session_id,
                    runtime_conversation_path,
                    working_directory,
                ],
            )?;
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn create_conversation(&self, title: &str, owner: Principal) -> StoreResult<Conversation> {
        self.create_conversation_record(title, owner, &[], false)
    }

    /// Create one Conversation and its initial peer Memberships in one writer
    /// transaction. The client uses this for a user-confirmed group so a
    /// failed member insert can never leave a hidden partial direct chat.
    pub fn create_conversation_with_members(
        &self,
        title: &str,
        owner: Principal,
        members: &[(Principal, MembershipAccess)],
    ) -> StoreResult<Conversation> {
        self.create_conversation_record(title, owner, members, true)
    }

    fn create_conversation_record(
        &self,
        title: &str,
        owner: Principal,
        members: &[(Principal, MembershipAccess)],
        is_group: bool,
    ) -> StoreResult<Conversation> {
        let id = new_id("conversation");
        validate_required_text(title, "conversation_title")?;
        validate_identifier(&owner.id, "principal_id")?;
        if is_group
            && !members
                .iter()
                .any(|(principal, _)| principal.kind == PrincipalKind::Agent)
        {
            return Err(anyhow!("invalid_request"));
        }
        let mut principal_ids = std::collections::HashSet::new();
        principal_ids.insert(owner.id.as_str());
        for (principal, _) in members {
            validate_identifier(&principal.id, "principal_id")?;
            validate_required_text(&principal.display_name, "principal_display_name")?;
            if !principal_ids.insert(principal.id.as_str()) {
                return Err(anyhow!("membership_principal_duplicate"));
            }
        }
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            upsert_principal(&transaction, &owner)?;
            transaction.execute(
                "INSERT INTO conversations(
                   id, title, archived, pinned, is_group, revision, created_at, updated_at
                 ) VALUES (?1, ?2, 0, 0, ?3, 0, ?4, ?4)",
                params![id, title, is_group as i64, now],
            )?;
            transaction.execute(
                "INSERT INTO memberships(id, conversation_id, principal_id, access, status, joined_at)
                 VALUES (?1, ?2, ?3, 'owner', 'active', ?4)",
                params![new_id("membership"), id, owner.id, now],
            )?;
            for (principal, access) in members {
                upsert_principal(&transaction, principal)?;
                let membership_id = new_id("membership");
                transaction.execute(
                    "INSERT INTO memberships(id, conversation_id, principal_id, access, status, joined_at)
                     VALUES (?1, ?2, ?3, ?4, 'active', ?5)",
                    params![membership_id, id, principal.id, enum_wire(*access)?, now],
                )?;
                append_domain_event(
                    &transaction,
                    &id,
                    EventKind::MembershipChanged,
                    serde_json::json!({
                        "membershipId": membership_id,
                        "principalId": principal.id,
                        "change": "joined",
                    }),
                    now,
                )?;
            }
            if !members.is_empty() {
                bump_revision(&transaction, &id, now)?;
            }
            transaction.commit()?;
            self.get(&id)
        })
    }

    /// Create a Conversation with a caller-supplied stable identity. This is
    /// reserved for one-time migration/source adoption; normal product calls
    /// should use `create_conversation`.
    pub fn create_conversation_with_id(
        &self,
        id: &str,
        title: &str,
        owner: Principal,
    ) -> StoreResult<Conversation> {
        self.create_conversation_with_id_and_group(id, title, owner, false)
    }

    pub(super) fn create_group_with_id(
        &self,
        id: &str,
        title: &str,
        owner: Principal,
    ) -> StoreResult<Conversation> {
        self.create_conversation_with_id_and_group(id, title, owner, true)
    }

    fn create_conversation_with_id_and_group(
        &self,
        id: &str,
        title: &str,
        owner: Principal,
        is_group: bool,
    ) -> StoreResult<Conversation> {
        validate_required_text(title, "conversation_title")?;
        validate_identifier(id, "conversation_id")?;
        validate_identifier(&owner.id, "principal_id")?;
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            upsert_principal(&transaction, &owner)?;
            transaction.execute(
                "INSERT INTO conversations(
                   id, title, archived, pinned, is_group, revision, created_at, updated_at
                 ) VALUES (?1, ?2, 0, 0, ?3, 0, ?4, ?4)",
                params![id, title, is_group as i64, now],
            )?;
            transaction.execute(
                "INSERT INTO memberships(id, conversation_id, principal_id, access, status, joined_at)
                 VALUES (?1, ?2, ?3, 'owner', 'active', ?4)",
                params![new_id("membership"), id, owner.id, now],
            )?;
            transaction.commit()?;
            self.get(id)
        })
    }

    pub fn rename_conversation(&self, id: &str, title: &str) -> StoreResult<()> {
        validate_identifier(id, "conversation_id")?;
        validate_required_text(title, "conversation_title")?;
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE conversations SET title=?2, revision=revision+1, updated_at=?3 WHERE id=?1",
                params![id, title, now_ms()],
            )?;
            if changed == 0 {
                return Err(anyhow!("conversation_not_found"));
            }
            Ok(())
        })
    }

    pub fn archive_conversation(&self, id: &str, archived: bool) -> StoreResult<()> {
        validate_identifier(id, "conversation_id")?;
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE conversations SET archived=?2, revision=revision+1, updated_at=?3 WHERE id=?1",
                params![id, archived as i64, now_ms()],
            )?;
            if changed == 0 {
                return Err(anyhow!("conversation_not_found"));
            }
            Ok(())
        })
    }

    pub fn set_conversation_pinned(&self, id: &str, pinned: bool) -> StoreResult<()> {
        validate_identifier(id, "conversation_id")?;
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE conversations
                 SET revision=revision + CASE WHEN pinned=?2 THEN 0 ELSE 1 END,
                     pinned=?2
                 WHERE id=?1",
                params![id, pinned as i64],
            )?;
            if changed == 0 {
                return Err(anyhow!("conversation_not_found"));
            }
            Ok(())
        })
    }

    pub fn set_conversation_strategy_revision(
        &self,
        id: &str,
        strategy_revision: Option<&str>,
    ) -> StoreResult<()> {
        validate_identifier(id, "conversation_id")?;
        let strategy_revision = strategy_revision
            .map(str::trim)
            .filter(|revision| !revision.is_empty());
        if let Some(revision) = strategy_revision {
            validate_identifier(revision, "strategy_revision")?;
        }
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE conversations
                 SET revision=revision + CASE WHEN strategy_revision IS ?2 THEN 0 ELSE 1 END,
                     updated_at=CASE WHEN strategy_revision IS ?2 THEN updated_at ELSE ?3 END,
                     strategy_revision=?2
                 WHERE id=?1 AND is_group=1",
                params![id, strategy_revision, now_ms()],
            )?;
            if changed == 0 {
                let exists: bool = connection.query_row(
                    "SELECT EXISTS(SELECT 1 FROM conversations WHERE id=?1)",
                    params![id],
                    |row| row.get(0),
                )?;
                return Err(anyhow!(if exists {
                    "invalid_request"
                } else {
                    "conversation_not_found"
                }));
            }
            Ok(())
        })
    }

    pub fn add_member(
        &self,
        conversation_id: &str,
        principal: Principal,
        access: MembershipAccess,
    ) -> StoreResult<Membership> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(&principal.id, "principal_id")?;
        validate_required_text(&principal.display_name, "principal_display_name")?;
        let membership_id = new_id("membership");
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            ensure_conversation(&transaction, conversation_id)?;
            upsert_principal(&transaction, &principal)?;
            let existing: Option<String> = transaction
                .query_row(
                    "SELECT id FROM memberships WHERE conversation_id=?1 AND principal_id=?2 AND status='active'",
                    params![conversation_id, principal.id],
                    |row| row.get(0),
                )
                .optional()?;
            if existing.is_some() {
                return Err(anyhow!("membership_already_active"));
            }
            transaction.execute(
                "INSERT INTO memberships(id, conversation_id, principal_id, access, status, joined_at)
                 VALUES (?1, ?2, ?3, ?4, 'active', ?5)",
                params![membership_id, conversation_id, principal.id, enum_wire(access)?, now],
            )?;
            append_domain_event(
                &transaction,
                conversation_id,
                EventKind::MembershipChanged,
                serde_json::json!({
                    "membershipId": membership_id,
                    "principalId": principal.id,
                    "change": "joined",
                }),
                now,
            )?;
            bump_revision(&transaction, conversation_id, now)?;
            transaction.commit()?;
            self.membership(conversation_id, &membership_id)
        })
    }

    pub fn leave_member(&self, conversation_id: &str, membership_id: &str) -> StoreResult<()> {
        self.with_connection(|connection| {
            let transaction = connection.unchecked_transaction()?;
            let principal_kind: Option<String> = transaction
                .query_row(
                    "SELECT p.kind FROM memberships m JOIN principals p ON p.id=m.principal_id
                     WHERE m.id=?1 AND m.conversation_id=?2 AND m.status='active'",
                    params![membership_id, conversation_id],
                    |row| row.get(0),
                )
                .optional()?;
            if principal_kind.is_none() {
                return Err(anyhow!("membership_not_found"));
            }
            let owners: i64 = transaction.query_row(
                "SELECT COUNT(*) FROM memberships WHERE conversation_id=?1 AND access='owner' AND status='active'",
                params![conversation_id], |row| row.get(0))?;
            let access: String = transaction.query_row(
                "SELECT access FROM memberships WHERE id=?1", params![membership_id], |row| row.get(0))?;
            if access == "owner" && owners <= 1 {
                return Err(anyhow!("conversation_requires_owner"));
            }
            let now = now_ms();
            transaction.execute(
                "UPDATE memberships SET status='left', left_at=?3 WHERE id=?1 AND conversation_id=?2",
                params![membership_id, conversation_id, now],
            )?;
            append_domain_event(
                &transaction,
                conversation_id,
                EventKind::MembershipChanged,
                serde_json::json!({
                    "membershipId": membership_id,
                    "change": "left",
                }),
                now,
            )?;
            bump_revision(&transaction, conversation_id, now)?;
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn set_member_access(
        &self,
        conversation_id: &str,
        membership_id: &str,
        access: MembershipAccess,
    ) -> StoreResult<Membership> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(membership_id, "membership_id")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let current: Option<String> = transaction
                .query_row(
                    "SELECT access FROM memberships
                     WHERE id=?1 AND conversation_id=?2 AND status='active'",
                    params![membership_id, conversation_id],
                    |row| row.get(0),
                )
                .optional()?;
            let Some(current) = current else {
                return Err(anyhow!("membership_not_found"));
            };
            let next = enum_wire(access)?;
            if current == next {
                transaction.commit()?;
                return self.membership(conversation_id, membership_id);
            }
            if current == "owner" && next == "member" {
                let owners: i64 = transaction.query_row(
                    "SELECT COUNT(*) FROM memberships
                     WHERE conversation_id=?1 AND access='owner' AND status='active'",
                    params![conversation_id],
                    |row| row.get(0),
                )?;
                if owners <= 1 {
                    return Err(anyhow!("conversation_requires_owner"));
                }
            }
            let now = now_ms();
            transaction.execute(
                "UPDATE memberships SET access=?3 WHERE id=?1 AND conversation_id=?2",
                params![membership_id, conversation_id, next],
            )?;
            append_domain_event(
                &transaction,
                conversation_id,
                EventKind::MembershipChanged,
                serde_json::json!({
                    "membershipId": membership_id,
                    "change": "access-set",
                    "access": next,
                }),
                now,
            )?;
            bump_revision(&transaction, conversation_id, now)?;
            transaction.commit()?;
            self.membership(conversation_id, membership_id)
        })
    }

    pub fn list(&self, include_archived: bool) -> StoreResult<Vec<ConversationSummary>> {
        self.with_connection(|connection| list_inner(connection, include_archived))
    }

    pub fn get(&self, id: &str) -> StoreResult<Conversation> {
        validate_identifier(id, "conversation_id")?;
        self.with_connection(|connection| get_inner(connection, id))
    }

    pub fn page_events(
        &self,
        conversation_id: &str,
        after_sequence: Option<i64>,
        requested_limit: usize,
    ) -> StoreResult<EventPage> {
        validate_identifier(conversation_id, "conversation_id")?;
        let limit = requested_limit.clamp(1, MAX_EVENT_PAGE_SIZE);
        self.with_connection(|connection| {
            page_events_inner(connection, conversation_id, after_sequence, limit)
        })
    }

    pub fn search(&self, query: &str, limit: usize) -> StoreResult<Vec<ConversationEvent>> {
        validate_text(query, "search_query")?;
        if query.trim().is_empty() {
            return Ok(Vec::new());
        }
        let limit = limit.clamp(1, MAX_EVENT_PAGE_SIZE);
        let fts_query = format!("\"{}\"", query.trim().replace('"', "\"\""));
        self.with_connection(|connection| search_inner(connection, &fts_query, limit))
    }

    pub fn append_event(
        &self,
        conversation_id: &str,
        author_membership_id: Option<&str>,
        kind: EventKind,
        parts: &[NewEventPart],
        causation_id: Option<&str>,
        correlation_id: Option<&str>,
        finalized: bool,
    ) -> StoreResult<ConversationEvent> {
        validate_identifier(conversation_id, "conversation_id")?;
        if let Some(author) = author_membership_id {
            validate_identifier(author, "membership_id")?;
        }
        if parts.len() > 4096 {
            return Err(anyhow!("event_parts_limit_exceeded"));
        }
        let event_id = new_id("event");
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let event = insert_event(
                &transaction,
                &event_id,
                conversation_id,
                author_membership_id,
                kind,
                parts,
                causation_id,
                correlation_id,
                finalized,
                true,
                now,
            )?;
            transaction.commit()?;
            Ok(event)
        })
    }

    /// Persist one human Message and its exact structured mention work in one
    /// writer transaction. A committed Message can therefore never point at a
    /// partially created Direct Turn set.
    pub fn post_message_with_mentions(
        &self,
        conversation_id: &str,
        author_membership_id: Option<&str>,
        content: &str,
        correlation_id: Option<&str>,
        membership_ids: &[String],
    ) -> StoreResult<(ConversationEvent, Vec<DirectTurn>)> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_required_text(content, "message_content")?;
        if let Some(author) = author_membership_id {
            validate_identifier(author, "membership_id")?;
        }
        if membership_ids.len() > 100 {
            return Err(anyhow!("mention_limit_exceeded"));
        }
        let event_id = new_id("event");
        let now = now_ms();
        let parts = [NewEventPart {
            id: String::new(),
            kind: EventPartKind::Text,
            content: content.to_owned(),
        }];
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let event = insert_event(
                &transaction,
                &event_id,
                conversation_id,
                author_membership_id,
                EventKind::Message,
                &parts,
                None,
                correlation_id,
                true,
                true,
                now,
            )?;
            let turns = enqueue_mention_turns_in_transaction(
                &transaction,
                conversation_id,
                &event.id,
                membership_ids,
            )?;
            transaction.commit()?;
            Ok((event, turns))
        })
    }

    pub fn append_event_part(&self, event_id: &str, part: NewEventPart) -> StoreResult<EventPart> {
        validate_identifier(event_id, "event_id")?;
        validate_text(&part.content, "event_part_content")?;
        self.with_connection(|connection| {
            let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let (conversation_id, finalized): (String, bool) = transaction.query_row(
                "SELECT conversation_id, finalized FROM events WHERE id=?1",
                params![event_id],
                |row| Ok((row.get(0)?, row.get::<_, i64>(1)? != 0)),
            )?;
            if finalized {
                return Err(anyhow!("event_already_finalized"));
            }
            let ordinal: i64 = transaction.query_row(
                "SELECT COALESCE(MAX(ordinal), -1)+1 FROM event_parts WHERE event_id=?1", params![event_id], |row| row.get(0))?;
            let now = now_ms();
            let id = if part.id.trim().is_empty() { new_id("part") } else { part.id };
            transaction.execute(
                "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![id, event_id, ordinal, enum_wire(part.kind)?, part.content, now],
            )?;
            if matches!(part.kind, super::EventPartKind::Text | super::EventPartKind::Reasoning) {
                transaction.execute(
                    "INSERT INTO event_search(event_id, conversation_id, content) VALUES (?1, ?2, ?3)",
                    params![event_id, conversation_id, part.content],
                )?;
            }
            bump_revision(&transaction, &conversation_id, now)?;
            transaction.commit()?;
            Ok(EventPart { id, event_id: event_id.to_owned(), ordinal, kind: part.kind, content: part.content, created_at_unix_ms: now })
        })
    }

    pub fn enqueue_mention_turns(
        &self,
        conversation_id: &str,
        source_event_id: &str,
        membership_ids: &[String],
    ) -> StoreResult<Vec<DirectTurn>> {
        if membership_ids.len() > 100 {
            return Err(anyhow!("mention_limit_exceeded"));
        }
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let turns = enqueue_mention_turns_in_transaction(
                &transaction,
                conversation_id,
                source_event_id,
                membership_ids,
            )?;
            transaction.commit()?;
            Ok(turns)
        })
    }

    /// Claim exactly one pending Direct Turn and load all private execution
    /// context inside the same transaction. A second claimant receives None.
    pub(super) fn claim_direct_turn(
        &self,
        turn_id: &str,
    ) -> StoreResult<Option<DirectTurnExecutionContext>> {
        validate_identifier(turn_id, "direct_turn_id")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let changed = transaction.execute(
                "UPDATE direct_turns SET state='claimed' WHERE id=?1 AND state='pending'",
                params![turn_id],
            )?;
            if changed == 0 {
                transaction.commit()?;
                return Ok(None);
            }
            let context = transaction.query_row(
                "SELECT t.id, t.conversation_id, t.source_event_id, t.membership_id,
                        t.state, t.ordinal, p.agent_id,
                        (SELECT ep.content FROM event_parts ep
                         WHERE ep.event_id=t.source_event_id AND ep.kind='text'
                         ORDER BY ep.ordinal ASC LIMIT 1),
                        rb.runtime_session_id, rb.runtime_conversation_path,
                        rb.working_directory
                 FROM direct_turns t
                 JOIN memberships m ON m.id=t.membership_id
                    AND m.conversation_id=t.conversation_id
                    AND m.status='active'
                 JOIN principals p ON p.id=m.principal_id
                    AND p.kind='agent' AND p.agent_id IS NOT NULL AND p.agent_id<>''
                 LEFT JOIN runtime_bindings rb
                    ON rb.conversation_id=t.conversation_id
                    AND rb.membership_id=t.membership_id AND rb.lane='conversation'
                 WHERE t.id=?1",
                params![turn_id],
                |row| {
                    Ok(DirectTurnExecutionContext {
                        turn: DirectTurn {
                            id: row.get(0)?,
                            conversation_id: row.get(1)?,
                            source_event_id: row.get(2)?,
                            membership_id: row.get(3)?,
                            state: decode(row.get(4)?)?,
                            ordinal: row.get(5)?,
                        },
                        agent_id: row.get(6)?,
                        source_content: row.get(7)?,
                        runtime_session_id: row.get(8)?,
                        runtime_conversation_path: row.get(9)?,
                        working_directory: row.get(10)?,
                    })
                },
            )?;
            transaction.commit()?;
            Ok(Some(context))
        })
    }

    pub(super) fn mark_direct_turn_running(&self, turn_id: &str) -> StoreResult<bool> {
        validate_identifier(turn_id, "direct_turn_id")?;
        self.with_connection(|connection| {
            Ok(connection.execute(
                "UPDATE direct_turns SET state='running' WHERE id=?1 AND state='claimed'",
                params![turn_id],
            )? == 1)
        })
    }

    pub(super) fn complete_direct_turn(
        &self,
        turn_id: &str,
        output: &str,
        runtime_session_id: Option<&str>,
        runtime_conversation_path: Option<&str>,
        working_directory: Option<&str>,
    ) -> StoreResult<ConversationEvent> {
        validate_identifier(turn_id, "direct_turn_id")?;
        self.finish_direct_turn(
            turn_id,
            TurnState::Succeeded,
            EventPartKind::Text,
            output,
            runtime_session_id,
            runtime_conversation_path,
            working_directory,
        )
    }

    pub(super) fn fail_direct_turn(
        &self,
        turn_id: &str,
        diagnostic: &str,
    ) -> StoreResult<ConversationEvent> {
        validate_identifier(turn_id, "direct_turn_id")?;
        validate_required_text(diagnostic, "direct_turn_diagnostic")?;
        self.finish_direct_turn(
            turn_id,
            TurnState::Failed,
            EventPartKind::Diagnostic,
            diagnostic,
            None,
            None,
            None,
        )
    }

    fn finish_direct_turn(
        &self,
        turn_id: &str,
        terminal_state: TurnState,
        part_kind: EventPartKind,
        content: &str,
        runtime_session_id: Option<&str>,
        runtime_conversation_path: Option<&str>,
        working_directory: Option<&str>,
    ) -> StoreResult<ConversationEvent> {
        let event_id = new_id("event");
        let now = now_ms();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let (conversation_id, source_event_id, membership_id, current_state): (
                String,
                String,
                String,
                String,
            ) = transaction.query_row(
                "SELECT conversation_id, source_event_id, membership_id, state
                 FROM direct_turns WHERE id=?1",
                params![turn_id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )?;
            let terminal_state_wire = enum_wire(terminal_state)?;
            if current_state == "running" {
                let changed = transaction.execute(
                    "UPDATE direct_turns SET state=?2 WHERE id=?1 AND state='running'",
                    params![turn_id, terminal_state_wire],
                )?;
                if changed != 1 {
                    return Err(anyhow!("direct_turn_not_running"));
                }
            } else if current_state != terminal_state_wire {
                return Err(anyhow!("direct_turn_not_running"));
            }
            let runtime_event_id: Option<String> = transaction
                .query_row(
                    "SELECT id FROM events
                     WHERE conversation_id=?1 AND author_membership_id=?2
                       AND causation_id=?3 AND correlation_id=?4
                       AND kind='message' AND finalized=1
                     ORDER BY sequence DESC LIMIT 1",
                    params![conversation_id, membership_id, source_event_id, turn_id],
                    |row| row.get(0),
                )
                .optional()?;
            let event = if let Some(runtime_event_id) = runtime_event_id {
                event_by_id(&transaction, &runtime_event_id)?
            } else {
                insert_event(
                    &transaction,
                    &event_id,
                    &conversation_id,
                    Some(&membership_id),
                    EventKind::Message,
                    &[NewEventPart {
                        id: String::new(),
                        kind: part_kind,
                        content: content.to_owned(),
                    }],
                    Some(&source_event_id),
                    Some(turn_id),
                    true,
                    false,
                    now,
                )?
            };
            if terminal_state == TurnState::Succeeded
                && (runtime_session_id.is_some()
                    || runtime_conversation_path.is_some()
                    || working_directory.is_some())
            {
                transaction.execute(
                    "INSERT INTO runtime_bindings(
                       id, conversation_id, membership_id, lane, availability, safe_reason,
                       runtime_session_id, runtime_conversation_path, working_directory
                     ) VALUES (?1, ?2, ?3, 'conversation', 'available', NULL, ?4, ?5, ?6)
                     ON CONFLICT(conversation_id, membership_id, lane) DO UPDATE SET
                       availability='available', safe_reason=NULL,
                       runtime_session_id=COALESCE(excluded.runtime_session_id, runtime_bindings.runtime_session_id),
                       runtime_conversation_path=COALESCE(excluded.runtime_conversation_path, runtime_bindings.runtime_conversation_path),
                       working_directory=COALESCE(excluded.working_directory, runtime_bindings.working_directory)",
                    params![
                        new_id("runtime"),
                        conversation_id,
                        membership_id,
                        runtime_session_id,
                        runtime_conversation_path,
                        working_directory,
                    ],
                )?;
            }
            transaction.commit()?;
            Ok(event)
        })
    }

    pub(super) fn direct_turn(&self, turn_id: &str) -> StoreResult<DirectTurn> {
        validate_identifier(turn_id, "direct_turn_id")?;
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT id, conversation_id, source_event_id, membership_id, state, ordinal
                     FROM direct_turns WHERE id=?1",
                    params![turn_id],
                    direct_turn_from_row,
                )
                .map_err(Into::into)
        })
    }

    pub fn finalize_event(&self, event_id: &str) -> StoreResult<()> {
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let conversation_id: String = transaction.query_row(
                "SELECT conversation_id FROM events WHERE id=?1",
                params![event_id],
                |row| row.get(0),
            )?;
            let changed = transaction.execute(
                "UPDATE events SET finalized=1 WHERE id=?1 AND finalized=0",
                params![event_id],
            )?;
            if changed == 0 {
                return Err(anyhow!("event_already_finalized"));
            }
            bump_revision(&transaction, &conversation_id, now_ms())?;
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn source_link(
        &self,
        conversation_id: &str,
        source_kind: &str,
        native_identity: &str,
    ) -> StoreResult<SourceLink> {
        validate_required_text(source_kind, "source_kind")?;
        validate_required_text(native_identity, "native_identity")?;
        let id = new_id("source");
        self.with_connection(|connection| {
            connection.execute(
                "INSERT INTO source_links(id, conversation_id, source_kind, native_identity)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(source_kind, native_identity) DO NOTHING",
                params![id, conversation_id, source_kind, native_identity],
            )?;
            connection
                .query_row(
                    "SELECT id, conversation_id, source_kind, native_identity FROM source_links
                 WHERE source_kind=?1 AND native_identity=?2",
                    params![source_kind, native_identity],
                    source_link_from_row,
                )
                .map_err(Into::into)
        })
    }

    pub fn runtime_binding(&self, binding: RuntimeBinding) -> StoreResult<()> {
        validate_identifier(&binding.conversation_id, "conversation_id")?;
        validate_identifier(&binding.membership_id, "membership_id")?;
        self.with_connection(|connection| {
            connection.execute(
                "INSERT INTO runtime_bindings(id, conversation_id, membership_id, lane, availability, safe_reason)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(conversation_id, membership_id, lane) DO UPDATE SET
                 availability=excluded.availability, safe_reason=excluded.safe_reason",
                params![binding.id, binding.conversation_id, binding.membership_id, binding.lane,
                    binding.availability, binding.safe_reason],
            )?;
            Ok(())
        })
    }

    pub(super) fn runtime_binding_with_private_location(
        &self,
        binding: RuntimeBinding,
        runtime_session_id: Option<&str>,
        runtime_conversation_path: Option<&str>,
        working_directory: Option<&str>,
    ) -> StoreResult<()> {
        validate_identifier(&binding.conversation_id, "conversation_id")?;
        validate_identifier(&binding.membership_id, "membership_id")?;
        self.with_connection(|connection| {
            connection.execute(
                "INSERT INTO runtime_bindings(
                   id, conversation_id, membership_id, lane, availability, safe_reason,
                   runtime_session_id, runtime_conversation_path, working_directory
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                 ON CONFLICT(conversation_id, membership_id, lane) DO UPDATE SET
                   availability=excluded.availability,
                   safe_reason=excluded.safe_reason,
                   runtime_session_id=excluded.runtime_session_id,
                   runtime_conversation_path=excluded.runtime_conversation_path,
                   working_directory=excluded.working_directory",
                params![
                    binding.id,
                    binding.conversation_id,
                    binding.membership_id,
                    binding.lane,
                    binding.availability,
                    binding.safe_reason,
                    runtime_session_id,
                    runtime_conversation_path,
                    working_directory,
                ],
            )?;
            Ok(())
        })
    }

    pub fn create_dispatch(
        &self,
        conversation_id: &str,
        membership_id: &str,
        operation: &str,
        session_mode: DispatchSessionMode,
    ) -> StoreResult<ConversationDispatch> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(membership_id, "membership_id")?;
        validate_required_text(operation, "dispatch_operation")?;
        let dispatch_id = new_id("dispatch");
        let now = now_ms();
        self.with_connection(|connection| {
            let eligible: Option<i64> = connection
                .query_row(
                    "SELECT 1 FROM memberships m JOIN principals p ON p.id=m.principal_id
                     WHERE m.id=?1 AND m.conversation_id=?2 AND m.status='active' AND p.kind='agent'",
                    params![membership_id, conversation_id],
                    |row| row.get(0),
                )
                .optional()?;
            if eligible.is_none() {
                return Err(anyhow!("dispatch_membership_unavailable"));
            }
            connection.execute(
                "INSERT INTO conversation_dispatches(
                   id, conversation_id, membership_id, operation, state, session_mode,
                   runtime_conversation_path, error_code, created_at, updated_at
                 ) VALUES (?1, ?2, ?3, ?4, 'accepted', ?5, NULL, NULL, ?6, ?6)",
                params![
                    dispatch_id,
                    conversation_id,
                    membership_id,
                    operation,
                    enum_wire(session_mode)?,
                    now,
                ],
            )?;
            dispatch_by_id(connection, &dispatch_id)
        })
    }

    pub fn update_dispatch(
        &self,
        dispatch_id: &str,
        state: DispatchState,
        runtime_conversation_path: Option<&str>,
        error_code: Option<&str>,
    ) -> StoreResult<()> {
        validate_identifier(dispatch_id, "dispatch_id")?;
        if runtime_conversation_path.is_some_and(|value| value.trim().is_empty()) {
            return Err(anyhow!("dispatch_runtime_location_invalid"));
        }
        self.with_connection(|connection| {
            let changed = connection.execute(
                "UPDATE conversation_dispatches SET state=?2,
                   runtime_conversation_path=COALESCE(?3, runtime_conversation_path),
                   error_code=?4, updated_at=?5 WHERE id=?1",
                params![
                    dispatch_id,
                    enum_wire(state)?,
                    runtime_conversation_path,
                    error_code,
                    now_ms(),
                ],
            )?;
            if changed == 0 {
                return Err(anyhow!("dispatch_not_found"));
            }
            Ok(())
        })
    }

    pub fn latest_resumable_dispatch(
        &self,
        conversation_id: &str,
        membership_id: &str,
    ) -> StoreResult<Option<ConversationDispatch>> {
        validate_identifier(conversation_id, "conversation_id")?;
        validate_identifier(membership_id, "membership_id")?;
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT id, conversation_id, membership_id, operation, state, session_mode,
                       runtime_conversation_path, error_code, created_at, updated_at
                     FROM conversation_dispatches
                     WHERE conversation_id=?1 AND membership_id=?2 AND state='completed'
                       AND runtime_conversation_path IS NOT NULL
                     ORDER BY updated_at DESC, id DESC LIMIT 1",
                    params![conversation_id, membership_id],
                    dispatch_from_row,
                )
                .optional()
                .map_err(Into::into)
        })
    }

    pub fn migration_conversation(
        &self,
        source_kind: &str,
        source_identity: &str,
    ) -> StoreResult<Option<String>> {
        self.with_connection(|connection| {
            connection
                .query_row(
                    "SELECT conversation_id FROM migration_provenance WHERE source_kind=?1 AND source_identity=?2",
                    params![source_kind, source_identity],
                    |row| row.get(0),
                )
                .optional()
                .map_err(Into::into)
        })
    }

    /// Remove a partially written deterministic migration target before the
    /// source is replayed. A completed provenance row always wins and is never
    /// modified here.
    pub(super) fn reset_incomplete_migration_conversation(
        &self,
        source_kind: &str,
        source_identity: &str,
        conversation_id: &str,
    ) -> StoreResult<()> {
        validate_required_text(source_kind, "migration_source_kind")?;
        validate_required_text(source_identity, "migration_source_identity")?;
        validate_identifier(conversation_id, "conversation_id")?;
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let completed: Option<i64> = transaction
                .query_row(
                    "SELECT 1 FROM migration_provenance
                     WHERE source_kind=?1 AND source_identity=?2",
                    params![source_kind, source_identity],
                    |row| row.get(0),
                )
                .optional()?;
            if completed.is_none() {
                transaction.execute(
                    "DELETE FROM event_search WHERE conversation_id=?1",
                    params![conversation_id],
                )?;
                transaction.execute(
                    "DELETE FROM event_parts WHERE event_id IN
                     (SELECT id FROM events WHERE conversation_id=?1)",
                    params![conversation_id],
                )?;
                transaction.execute(
                    "DELETE FROM direct_turns WHERE conversation_id=?1",
                    params![conversation_id],
                )?;
                transaction.execute(
                    "DELETE FROM events WHERE conversation_id=?1",
                    params![conversation_id],
                )?;
                for table in [
                    "conversation_dispatches",
                    "runtime_bindings",
                    "source_links",
                    "memberships",
                ] {
                    transaction.execute(
                        &format!("DELETE FROM {table} WHERE conversation_id=?1"),
                        params![conversation_id],
                    )?;
                }
                transaction.execute(
                    "DELETE FROM conversations WHERE id=?1",
                    params![conversation_id],
                )?;
            }
            transaction.commit()?;
            Ok(())
        })
    }

    pub fn record_migration(
        &self,
        source_kind: &str,
        source_identity: &str,
        conversation_id: &str,
    ) -> StoreResult<()> {
        self.with_connection(|connection| {
            connection.execute(
                "INSERT INTO migration_provenance(source_kind, source_identity, conversation_id)
                 VALUES (?1, ?2, ?3) ON CONFLICT(source_kind, source_identity) DO NOTHING",
                params![source_kind, source_identity, conversation_id],
            )?;
            Ok(())
        })
    }

    /// Export public Conversation facts without runtime handles, executor
    /// claims, absolute paths, or migration internals.
    pub fn export_bundle(
        &self,
        destination: &Path,
        conversation_ids: &[String],
    ) -> StoreResult<serde_json::Value> {
        crate::platform::file_security::validate_export_destination(destination)?;
        self.with_connection(|connection| {
            let selected_ids = if conversation_ids.is_empty() {
                list_inner(connection, false)?
                    .into_iter()
                    .map(|summary| summary.id)
                    .collect::<Vec<_>>()
            } else {
                conversation_ids
                    .iter()
                    .map(|id| id.trim().to_owned())
                    .filter(|id| !id.is_empty())
                    .collect::<Vec<_>>()
            };
            if selected_ids.is_empty() {
                return Err(anyhow!("conversation_export_empty"));
            }
            if selected_ids.len() > 500 {
                return Err(anyhow!("conversation_export_entry_limit_exceeded"));
            }
            let mut conversations = Vec::new();
            for id in &selected_ids {
                let conversation = get_inner(connection, id)?;
                let mut events = Vec::new();
                let mut cursor = None;
                loop {
                    let page = page_events_inner(connection, id, cursor, MAX_EVENT_PAGE_SIZE)?;
                    let done = page.next_cursor.is_none() || page.events.is_empty();
                    cursor = page.next_cursor.and_then(|value| value.parse::<i64>().ok());
                    events.extend(page.events);
                    if done {
                        break;
                    }
                }
                conversations
                    .push(serde_json::json!({ "conversation": conversation, "events": events }));
            }
            let bundle = serde_json::json!({
                "kind": "lico-conversation-bundle",
                "schemaVersion": super::CONVERSATION_SCHEMA_VERSION,
                "conversations": conversations,
            });
            let text = serde_json::to_string_pretty(&bundle)?;
            crate::platform::file_security::atomic_write_private_text(destination, &text)?;
            Ok(serde_json::json!({ "ok": true, "count": conversations.len() }))
        })
    }

    /// Import one current-schema public bundle. Identity collisions never
    /// overwrite existing local facts.
    pub fn import_bundle(&self, source: &Path) -> StoreResult<serde_json::Value> {
        let bytes = std::fs::read(source)?;
        if bytes.len() > 64 * 1024 * 1024 {
            return Err(anyhow!("conversation_import_too_large"));
        }
        let bundle: serde_json::Value = serde_json::from_slice(&bytes)?;
        if bundle.get("kind").and_then(serde_json::Value::as_str)
            != Some("lico-conversation-bundle")
            || bundle
                .get("schemaVersion")
                .and_then(serde_json::Value::as_str)
                != Some(super::CONVERSATION_SCHEMA_VERSION)
        {
            return Err(anyhow!("conversation_import_schema_invalid"));
        }
        let entries = bundle
            .get("conversations")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(|| anyhow!("conversation_import_payload_invalid"))?;
        if entries.len() > 500 {
            return Err(anyhow!("conversation_import_entry_limit_exceeded"));
        }
        let mut parsed = Vec::with_capacity(entries.len());
        let mut already_present = 0usize;
        for entry in entries {
            let conversation: Conversation = serde_json::from_value(
                entry
                    .get("conversation")
                    .cloned()
                    .ok_or_else(|| anyhow!("conversation_import_payload_invalid"))?,
            )?;
            let raw_events = entry
                .get("events")
                .and_then(serde_json::Value::as_array)
                .ok_or_else(|| anyhow!("conversation_import_payload_invalid"))?;
            if raw_events.len() > 100_000 {
                return Err(anyhow!("conversation_import_event_limit_exceeded"));
            }
            let events = raw_events
                .iter()
                .cloned()
                .map(serde_json::from_value::<ConversationEvent>)
                .collect::<std::result::Result<Vec<_>, _>>()?;
            validate_import_entry(&conversation, &events)?;
            match self.get(&conversation.id) {
                Ok(existing) if existing == conversation => {
                    if self.all_events(&conversation.id)? != events {
                        return Err(anyhow!("conversation_import_identity_conflict"));
                    }
                    already_present += 1;
                }
                Ok(_) => return Err(anyhow!("conversation_import_identity_conflict")),
                Err(error) if error.to_string() == "conversation_not_found" => {
                    parsed.push((conversation, events));
                }
                Err(error) => return Err(error),
            }
        }
        let imported = parsed.len();
        self.with_connection(|connection| {
            let transaction =
                connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
            for (conversation, events) in &parsed {
                insert_import_entry(&transaction, conversation, events)?;
            }
            transaction.commit()?;
            Ok(())
        })?;
        Ok(serde_json::json!({
            "ok": true,
            "imported": imported,
            "alreadyPresent": already_present
        }))
    }

    fn all_events(&self, conversation_id: &str) -> StoreResult<Vec<ConversationEvent>> {
        self.with_connection(|connection| all_events_inner(connection, conversation_id))
    }

    fn membership(&self, conversation_id: &str, membership_id: &str) -> StoreResult<Membership> {
        self.with_connection(|connection| connection.query_row("SELECT m.id, m.conversation_id, p.id, p.kind, p.display_name, p.agent_id, p.created_at, m.access, m.status, m.joined_at, m.left_at FROM memberships m JOIN principals p ON p.id=m.principal_id WHERE m.conversation_id=?1 AND m.id=?2", params![conversation_id, membership_id], membership_from_row).map_err(Into::into))
    }
}

fn all_events_inner(
    connection: &impl CountedSqlite,
    conversation_id: &str,
) -> StoreResult<Vec<ConversationEvent>> {
    let mut events = Vec::new();
    let mut cursor = None;
    loop {
        let page = page_events_inner(connection, conversation_id, cursor, MAX_EVENT_PAGE_SIZE)?;
        let Some(last) = page.events.last() else {
            break;
        };
        cursor = Some(last.sequence);
        events.extend(page.events);
        if events.len() >= page.total_count as usize {
            break;
        }
    }
    Ok(events)
}

fn memberships(
    connection: &impl CountedSqlite,
    conversation_id: &str,
) -> StoreResult<Vec<Membership>> {
    let mut statement = connection.prepare("SELECT m.id, m.conversation_id, p.id, p.kind, p.display_name, p.agent_id, p.created_at, m.access, m.status, m.joined_at, m.left_at FROM memberships m JOIN principals p ON p.id=m.principal_id WHERE m.conversation_id=?1 ORDER BY m.joined_at ASC, m.id ASC")?;
    let rows = statement.query_map(params![conversation_id], membership_from_row)?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NewEventPart {
    #[serde(default)]
    pub id: String,
    pub kind: EventPartKind,
    pub content: String,
}
fn configure_connection(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "PRAGMA foreign_keys=ON;
         PRAGMA journal_mode=WAL;
         PRAGMA synchronous=NORMAL;
         PRAGMA busy_timeout=5000;
         PRAGMA trusted_schema=OFF;",
    )?;
    Ok(())
}

fn initialize_schema(connection: &mut Connection) -> StoreResult<()> {
    configure_connection(connection)?;
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    )?;
    let prior_schema_version: Option<String> = connection
        .query_row(
            "SELECT value FROM schema_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    connection.execute_batch(CONVERSATION_SCHEMA_TABLES)?;
    match prior_schema_version.as_deref() {
        None => {
            connection.execute_batch(
                "INSERT INTO schema_meta(key, value) VALUES ('version', '6')
                 ON CONFLICT(key) DO UPDATE SET value='6';",
            )?;
        }
        Some("1") => {
            connection.execute_batch(
                "DELETE FROM event_search WHERE event_id IN (
               SELECT id FROM events WHERE kind IN (
                 'role-changed','flywheel-changed','run-started','run-progress',
                 'run-completed','run-failed','run-cancelled'
               )
             );
             DELETE FROM events WHERE kind IN (
               'role-changed','flywheel-changed','run-started','run-progress',
               'run-completed','run-failed','run-cancelled'
             );
             DROP TABLE IF EXISTS idempotency;
             DROP TABLE IF EXISTS run_candidate_snapshots;
             DROP TABLE IF EXISTS run_stage_snapshots;
             DROP TABLE IF EXISTS turns;
             DROP TABLE IF EXISTS runs;
             DROP TABLE IF EXISTS round_robin_cursors;
             DROP TABLE IF EXISTS flywheel_stages;
             DROP TABLE IF EXISTS flywheels;
             DROP TABLE IF EXISTS role_candidates;
             DROP TABLE IF EXISTS conversation_roles;
             INSERT INTO schema_meta(key, value) VALUES ('version', '2')
               ON CONFLICT(key) DO UPDATE SET value='2';",
            )?;
            migrate_reserved_group_v3(connection)?;
            migrate_reserved_group_v4(connection)?;
        }
        Some("2") => {
            migrate_reserved_group_v3(connection)?;
            migrate_reserved_group_v4(connection)?;
        }
        Some("3") => {
            migrate_reserved_group_v4(connection)?;
        }
        Some("4" | "5" | "6") => {}
        Some(other) => {
            return Err(anyhow!("conversation_schema_unsupported_version: {other}"));
        }
    }
    let current_schema_version: String = connection.query_row(
        "SELECT value FROM schema_meta WHERE key='version'",
        [],
        |row| row.get(0),
    )?;
    if current_schema_version == "4" {
        migrate_runtime_replay_v5(connection)?;
    }
    let current_schema_version: String = connection.query_row(
        "SELECT value FROM schema_meta WHERE key='version'",
        [],
        |row| row.get(0),
    )?;
    if current_schema_version == "5" {
        migrate_strategy_selection_v6(connection)?;
    }
    ensure_column(connection, "runtime_bindings", "runtime_session_id", "TEXT")?;
    ensure_column(
        connection,
        "conversations",
        "pinned",
        "INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1))",
    )?;
    ensure_column(
        connection,
        "conversations",
        "is_group",
        "INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1))",
    )?;
    connection.execute(
        "UPDATE conversations SET is_group=1
         WHERE is_group=0 AND (
           pinned=1 OR id=?1 OR
           EXISTS (
             SELECT 1 FROM migration_provenance p
             WHERE p.conversation_id=conversations.id AND p.source_kind='group'
           ) OR
           (SELECT COUNT(*) FROM memberships m
            WHERE m.conversation_id=conversations.id AND m.status='active') > 2
         )",
        params![DEFAULT_LOCAL_AGENT_GROUP_ID],
    )?;
    connection.execute_batch(
        "CREATE INDEX IF NOT EXISTS conversations_pinned_updated_idx
         ON conversations(pinned DESC, updated_at DESC, id DESC);",
    )?;
    ensure_column(
        connection,
        "runtime_bindings",
        "runtime_conversation_path",
        "TEXT",
    )?;
    ensure_column(connection, "runtime_bindings", "working_directory", "TEXT")?;
    Ok(())
}

/// One-time schema transition to version 3: normalize the pre-cutover
/// reserved default local group inside one immediate transaction that also
/// records the new schema version. A failure rolls back both the cleanup and
/// the version write, leaving the store at version 2.
fn migrate_reserved_group_v3(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    normalize_reserved_group(&transaction)?;
    transaction.execute(
        "INSERT INTO schema_meta(key, value) VALUES ('version', '3')
         ON CONFLICT(key) DO UPDATE SET value='3'",
        [],
    )?;
    transaction.commit()?;
    Ok(())
}

/// One-time schema transition to version 4: rename only the reserved local
/// group's retired built-in title. Custom group names and recency timestamps
/// are preserved.
fn migrate_reserved_group_v4(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    rename_reserved_group(&transaction)?;
    transaction.execute(
        "INSERT INTO schema_meta(key, value) VALUES ('version', '4')
         ON CONFLICT(key) DO UPDATE SET value='4'",
        [],
    )?;
    transaction.commit()?;
    Ok(())
}

/// One-time schema transition to version 5: add the private per-part cursor
/// used to reconstruct active-turn transport frames from their owning
/// canonical Message Event. Existing Event content and ordering are untouched.
fn migrate_runtime_replay_v5(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let has_runtime_cursor = {
        let mut statement = transaction.prepare("PRAGMA table_info(event_parts)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .iter()
            .any(|column| column == "runtime_cursor")
    };
    if !has_runtime_cursor {
        transaction.execute_batch("ALTER TABLE event_parts ADD COLUMN runtime_cursor INTEGER;")?;
    }
    transaction.execute_batch(
        "CREATE INDEX IF NOT EXISTS event_parts_runtime_replay_idx
         ON event_parts(event_id, runtime_cursor, ordinal)
         WHERE runtime_cursor IS NOT NULL;",
    )?;
    transaction.execute(
        "INSERT INTO schema_meta(key, value) VALUES ('version', '5')
         ON CONFLICT(key) DO UPDATE SET value='5'",
        [],
    )?;
    transaction.commit()?;
    Ok(())
}

/// One-time schema transition to version 6: persist the strategy explicitly
/// selected for each group Conversation. A nullable column preserves the
/// existing no-strategy state for all prior conversations.
fn migrate_strategy_selection_v6(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let has_strategy_revision = {
        let mut statement = transaction.prepare("PRAGMA table_info(conversations)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .iter()
            .any(|column| column == "strategy_revision")
    };
    if !has_strategy_revision {
        transaction
            .execute_batch("ALTER TABLE conversations ADD COLUMN strategy_revision TEXT;")?;
    }
    transaction.execute(
        "INSERT INTO schema_meta(key, value) VALUES ('version', '6')
         ON CONFLICT(key) DO UPDATE SET value='6'",
        [],
    )?;
    transaction.commit()?;
    Ok(())
}

fn normalize_reserved_group_after_legacy_import(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    normalize_reserved_group(&transaction)?;
    rename_reserved_group(&transaction)?;
    transaction.commit()?;
    Ok(())
}

fn ensure_default_local_group_inner(
    connection: &mut CountedConnection<'_>,
) -> StoreResult<Conversation> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let canonical_exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM conversations WHERE id=?1)",
        params![DEFAULT_LOCAL_AGENT_GROUP_ID],
        |row| row.get(0),
    )?;

    if !canonical_exists {
        if let Some(existing_id) = reserved_group_conversation_id(&transaction)? {
            transaction.execute(
                "INSERT INTO conversations(
                   id, title, archived, pinned, is_group, strategy_revision,
                   revision, created_at, updated_at
                 ) SELECT ?2, title, archived, pinned, 1, strategy_revision,
                          revision, created_at, updated_at
                   FROM conversations WHERE id=?1",
                params![existing_id, DEFAULT_LOCAL_AGENT_GROUP_ID],
            )?;
            for table in [
                "memberships",
                "events",
                "direct_turns",
                "source_links",
                "runtime_bindings",
                "conversation_dispatches",
                "migration_provenance",
            ] {
                transaction.execute(
                    &format!("UPDATE {table} SET conversation_id=?2 WHERE conversation_id=?1"),
                    params![existing_id, DEFAULT_LOCAL_AGENT_GROUP_ID],
                )?;
            }
            transaction.execute(
                "UPDATE event_search SET conversation_id=?2 WHERE conversation_id=?1",
                params![existing_id, DEFAULT_LOCAL_AGENT_GROUP_ID],
            )?;
            transaction.execute(
                "DELETE FROM conversations WHERE id=?1",
                params![existing_id],
            )?;
        } else {
            let now = now_ms();
            transaction.execute(
                "INSERT INTO conversations(
                   id, title, archived, pinned, is_group, revision, created_at, updated_at
                 ) VALUES (?1, ?2, 0, 1, 1, 0, ?3, ?3)",
                params![
                    DEFAULT_LOCAL_AGENT_GROUP_ID,
                    DEFAULT_LOCAL_AGENT_GROUP_TITLE,
                    now
                ],
            )?;
        }
    }

    let now = now_ms();
    let owner = Principal {
        id: "human:local".into(),
        kind: PrincipalKind::Human,
        display_name: "Local User".into(),
        agent_id: None,
        created_at_unix_ms: now,
    };
    upsert_principal(&transaction, &owner)?;
    let active_owner: Option<String> = transaction
        .query_row(
            "SELECT id FROM memberships
             WHERE conversation_id=?1 AND principal_id=?2 AND status='active'
             ORDER BY joined_at ASC, id ASC LIMIT 1",
            params![DEFAULT_LOCAL_AGENT_GROUP_ID, owner.id],
            |row| row.get(0),
        )
        .optional()?;
    let membership_changed = if let Some(membership_id) = active_owner {
        transaction.execute(
            "UPDATE memberships SET access='owner'
             WHERE id=?1 AND access<>'owner'",
            params![membership_id],
        )? > 0
    } else {
        let left_membership: Option<String> = transaction
            .query_row(
                "SELECT id FROM memberships
                 WHERE conversation_id=?1 AND principal_id=?2 AND status='left'
                 ORDER BY joined_at ASC, id ASC LIMIT 1",
                params![DEFAULT_LOCAL_AGENT_GROUP_ID, owner.id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(membership_id) = left_membership {
            transaction.execute(
                "UPDATE memberships
                 SET access='owner', status='active', left_at=NULL
                 WHERE id=?1",
                params![membership_id],
            )?;
        } else {
            transaction.execute(
                "INSERT INTO memberships(
                   id, conversation_id, principal_id, access, status, joined_at
                 ) VALUES (?1, ?2, ?3, 'owner', 'active', ?4)",
                params![
                    new_id("membership"),
                    DEFAULT_LOCAL_AGENT_GROUP_ID,
                    owner.id,
                    now
                ],
            )?;
        }
        true
    };
    let conversation_changed = transaction.execute(
        "UPDATE conversations
         SET title=CASE
               WHEN trim(title)='' OR lower(trim(title)) IN ('lico', 'lico-group-default')
               THEN ?2 ELSE title END,
             archived=0, pinned=1, is_group=1,
             revision=revision+1, updated_at=?3
         WHERE id=?1 AND (
           trim(title)='' OR lower(trim(title)) IN ('lico', 'lico-group-default') OR
           archived<>0 OR pinned<>1 OR is_group<>1
         )",
        params![
            DEFAULT_LOCAL_AGENT_GROUP_ID,
            DEFAULT_LOCAL_AGENT_GROUP_TITLE,
            now
        ],
    )? > 0;
    if membership_changed && !conversation_changed {
        bump_revision(&transaction, DEFAULT_LOCAL_AGENT_GROUP_ID, now)?;
    }
    transaction.commit()?;
    self::get_inner(connection, DEFAULT_LOCAL_AGENT_GROUP_ID)
}

fn reserved_group_conversation_id(connection: &Connection) -> StoreResult<Option<String>> {
    for query in [
        "SELECT conversation_id FROM migration_provenance
         WHERE source_kind='group' AND source_identity=?1",
        "SELECT conversation_id FROM source_links
         WHERE source_kind='group' AND native_identity=?1",
        "SELECT id FROM conversations WHERE id=?1",
    ] {
        let found: Option<String> = connection
            .query_row(query, params![DEFAULT_LOCAL_AGENT_GROUP_ID], |row| {
                row.get(0)
            })
            .optional()?;
        if found.is_some() {
            return Ok(found);
        }
    }
    Ok(None)
}

fn rename_reserved_group(connection: &Connection) -> StoreResult<()> {
    let Some(conversation_id) = reserved_group_conversation_id(connection)? else {
        return Ok(());
    };
    connection.execute(
        "UPDATE conversations SET title=?2, revision=revision+1
         WHERE id=?1 AND lower(trim(title)) IN ('lico', 'lico-group-default')",
        params![conversation_id, DEFAULT_LOCAL_AGENT_GROUP_TITLE],
    )?;
    Ok(())
}

/// Deterministic reserved-default-group normalization. Resolves at most one
/// conversation by the historical identity order (migration provenance, then
/// group source link, then the direct default-group id), removes only strictly
/// classified automatic joined/left membership-changed events, retains exactly
/// one active durable membership per historically known Agent principal, and
/// resequences the surviving events contiguously in their original order.
/// A missing reserved group is a successful no-op and never creates anything.
fn normalize_reserved_group(connection: &Connection) -> StoreResult<()> {
    let Some(conversation_id) = reserved_group_conversation_id(connection)? else {
        return Ok(());
    };

    let mut membership_events: Vec<(String, String)> = Vec::new();
    {
        let mut statement = connection.prepare(
            "SELECT e.id, p.content FROM events e
             JOIN event_parts p ON p.event_id=e.id AND p.ordinal=0 AND p.kind='metadata'
             WHERE e.conversation_id=?1
               AND e.kind='membership-changed'
               AND e.finalized=1
               AND e.author_membership_id IS NULL
               AND e.causation_id IS NULL
               AND e.correlation_id IS NULL
               AND (SELECT COUNT(*) FROM event_parts ep WHERE ep.event_id=e.id)=1",
        )?;
        let rows = statement.query_map(params![conversation_id], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?;
        for row in rows {
            membership_events.push(row?);
        }
    }

    let mut historically_known: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();
    let mut automatic: Vec<String> = Vec::new();
    for (event_id, content) in &membership_events {
        if let Some((membership_id, principal_id)) = automatic_membership_churn(content) {
            let matches_agent_membership: Option<i64> = connection
                .query_row(
                    "SELECT 1 FROM memberships m
                     JOIN principals p ON p.id=m.principal_id
                     WHERE m.id=?1 AND m.conversation_id=?2
                       AND m.principal_id=?3 AND p.kind='agent'",
                    params![membership_id, conversation_id, principal_id],
                    |row| row.get(0),
                )
                .optional()?;
            if matches_agent_membership.is_some() {
                automatic.push(event_id.clone());
            }
        }
    }
    {
        let mut statement = connection.prepare(
            "SELECT p.id FROM principals p
             JOIN memberships m ON m.principal_id=p.id
             WHERE m.conversation_id=?1 AND p.kind='agent'",
        )?;
        let rows = statement.query_map(params![conversation_id], |row| row.get::<_, String>(0))?;
        for principal in rows {
            historically_known.insert(principal?);
        }
    }

    if !automatic.is_empty() {
        let placeholders = std::iter::repeat("?")
            .take(automatic.len())
            .collect::<Vec<_>>()
            .join(",");
        connection.execute(
            &format!("DELETE FROM event_search WHERE event_id IN ({placeholders})"),
            rusqlite::params_from_iter(automatic.iter()),
        )?;
        connection.execute(
            &format!("DELETE FROM events WHERE id IN ({placeholders})"),
            rusqlite::params_from_iter(automatic.iter()),
        )?;
    }

    for principal_id in historically_known {
        let active: Option<String> = connection
            .query_row(
                "SELECT id FROM memberships
                 WHERE conversation_id=?1 AND principal_id=?2 AND status='active'",
                params![conversation_id, principal_id],
                |row| row.get(0),
            )
            .optional()?;
        if active.is_some() {
            continue;
        }
        let left: Option<String> = connection
            .query_row(
                "SELECT id FROM memberships
                 WHERE conversation_id=?1 AND principal_id=?2 AND status='left'
                 ORDER BY joined_at DESC, id DESC LIMIT 1",
                params![conversation_id, principal_id],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(membership_id) = left {
            connection.execute(
                "UPDATE memberships SET status='active', left_at=NULL
                 WHERE id=?1 AND conversation_id=?2",
                params![membership_id, conversation_id],
            )?;
            continue;
        }
    }

    let mut sequence = 0i64;
    let mut statement = connection
        .prepare("SELECT id FROM events WHERE conversation_id=?1 ORDER BY sequence ASC, id ASC")?;
    let rows = statement.query_map(params![conversation_id], |row| row.get::<_, String>(0))?;
    let event_ids: Vec<String> = rows.collect::<rusqlite::Result<Vec<_>>>()?;
    for event_id in event_ids {
        sequence += 1;
        connection.execute(
            "UPDATE events SET sequence=?2 WHERE id=?1 AND conversation_id=?3",
            params![event_id, sequence, conversation_id],
        )?;
    }
    Ok(())
}

/// Parse the exact retired metadata envelope. Event-level system/finalization
/// predicates and the same-group Agent Membership match are checked by the
/// caller; any missing or additional field is preserved.
fn automatic_membership_churn(content: &str) -> Option<(String, String)> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(content) else {
        return None;
    };
    let Some(object) = value.as_object() else {
        return None;
    };
    if object.len() != 3 {
        return None;
    }
    let Some(membership_id) = object
        .get("membershipId")
        .and_then(serde_json::Value::as_str)
    else {
        return None;
    };
    let Some(principal_id) = object
        .get("principalId")
        .and_then(serde_json::Value::as_str)
    else {
        return None;
    };
    let Some(change) = object.get("change").and_then(serde_json::Value::as_str) else {
        return None;
    };
    if membership_id.is_empty()
        || principal_id.is_empty()
        || (change != "joined" && change != "left")
    {
        return None;
    }
    Some((membership_id.to_owned(), principal_id.to_owned()))
}

fn ensure_column(
    connection: &Connection,
    table: &str,
    column: &str,
    declaration: &str,
) -> StoreResult<()> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let existing = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !existing.iter().any(|name| name == column) {
        connection.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {declaration}"
        ))?;
    }
    Ok(())
}

fn list_inner(
    connection: &impl CountedSqlite,
    include_archived: bool,
) -> StoreResult<Vec<ConversationSummary>> {
    let mut statement = connection.prepare(
        "SELECT c.id, c.title, c.archived, c.pinned, c.is_group, c.revision, c.updated_at,
         (SELECT COUNT(*) FROM memberships m WHERE m.conversation_id=c.id AND m.status='active'),
         (SELECT COUNT(*) FROM events e WHERE e.conversation_id=c.id)
         FROM conversations c WHERE (?1=1 OR c.archived=0)
         ORDER BY c.pinned DESC, c.updated_at DESC, c.id DESC",
    )?;
    let rows = statement.query_map(params![include_archived as i64], summary_from_row)?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
        .map_err(Into::into)
}

fn get_inner(connection: &impl CountedSqlite, id: &str) -> StoreResult<Conversation> {
    let base = connection
        .query_row(
            "SELECT id, title, archived, pinned, is_group, strategy_revision,
             revision, created_at, updated_at,
             (SELECT COUNT(*) FROM events WHERE conversation_id=c.id)
             FROM conversations c WHERE id=?1",
            params![id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)? != 0,
                    row.get::<_, i64>(3)? != 0,
                    row.get::<_, i64>(4)? != 0,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, i64>(8)?,
                    row.get::<_, i64>(9)?,
                ))
            },
        )
        .optional()?;
    let Some((
        id,
        title,
        archived,
        pinned,
        is_group,
        strategy_revision,
        revision,
        created,
        updated,
        event_count,
    )) = base
    else {
        return Err(anyhow!("conversation_not_found"));
    };
    let memberships = memberships(connection, &id)?;
    Ok(Conversation {
        id,
        title,
        archived,
        pinned,
        is_group,
        strategy_revision,
        revision,
        created_at_unix_ms: created,
        updated_at_unix_ms: updated,
        memberships,
        event_count,
    })
}

fn page_events_inner(
    connection: &impl CountedSqlite,
    conversation_id: &str,
    after_sequence: Option<i64>,
    limit: usize,
) -> StoreResult<EventPage> {
    ensure_conversation(connection, conversation_id)?;
    let cursor = after_sequence.unwrap_or(0);
    let mut statement = connection.prepare(
        "SELECT id, conversation_id, sequence, author_membership_id, kind,
         causation_id, correlation_id, created_at, finalized
         FROM events WHERE conversation_id=?1 AND sequence>?2
         ORDER BY sequence ASC LIMIT ?3",
    )?;
    let rows = statement.query_map(
        params![conversation_id, cursor, limit as i64],
        event_from_row,
    )?;
    let mut events = rows.collect::<rusqlite::Result<Vec<_>>>()?;
    let event_ids = events
        .iter()
        .map(|event| event.id.clone())
        .collect::<Vec<_>>();
    let parts_by_event = parts_batch(connection, &event_ids)?;
    for event in &mut events {
        if let Some(parts) = parts_by_event.get(&event.id) {
            event.parts.clone_from(parts);
        }
    }
    let total_count: i64 = connection.query_row(
        "SELECT COUNT(*) FROM events WHERE conversation_id=?1",
        params![conversation_id],
        |row| row.get(0),
    )?;
    let next_cursor = events.last().map(|event| event.sequence.to_string());
    Ok(EventPage {
        events,
        next_cursor,
        total_count,
    })
}

fn search_inner(
    connection: &impl CountedSqlite,
    fts_query: &str,
    limit: usize,
) -> StoreResult<Vec<ConversationEvent>> {
    let mut statement = connection.prepare(
        "SELECT e.id, e.conversation_id, e.sequence, e.author_membership_id,
         e.kind, e.causation_id, e.correlation_id, e.created_at, e.finalized
         FROM event_search s JOIN events e ON e.id=s.event_id
         WHERE s.content MATCH ?1 ORDER BY e.created_at DESC LIMIT ?2",
    )?;
    let rows = statement.query_map(params![fts_query, limit as i64], event_from_row)?;
    let mut events = rows.collect::<rusqlite::Result<Vec<_>>>()?;
    let event_ids = events
        .iter()
        .map(|event| event.id.clone())
        .collect::<Vec<_>>();
    let parts_by_event = parts_batch(connection, &event_ids)?;
    for event in &mut events {
        if let Some(parts) = parts_by_event.get(&event.id) {
            event.parts.clone_from(parts);
        }
    }
    Ok(events)
}

fn event_by_id(connection: &impl CountedSqlite, event_id: &str) -> StoreResult<ConversationEvent> {
    let mut event = connection.query_row(
        "SELECT id, conversation_id, sequence, author_membership_id, kind,
         causation_id, correlation_id, created_at, finalized
         FROM events WHERE id=?1",
        params![event_id],
        event_from_row,
    )?;
    if let Some(parts) = parts_batch(connection, &[event_id.to_owned()])?.remove(event_id) {
        event.parts = parts;
    }
    Ok(event)
}

/// Load all event parts for one bounded event set with a single indexed
/// query, folded by stable event identity and part ordinal.
fn parts_batch(
    connection: &impl CountedSqlite,
    event_ids: &[String],
) -> StoreResult<HashMap<String, Vec<EventPart>>> {
    let mut parts_by_event = HashMap::with_capacity(event_ids.len());
    if event_ids.is_empty() {
        return Ok(parts_by_event);
    }
    let placeholders = vec!["?"; event_ids.len()].join(",");
    let sql = format!(
        "SELECT id, event_id, ordinal, kind, content, created_at
         FROM event_parts WHERE event_id IN ({placeholders})
           AND runtime_cursor IS NULL
         ORDER BY event_id ASC, ordinal ASC"
    );
    let mut statement = connection.prepare(&sql)?;
    let rows = statement.query_map(
        params_from_iter(event_ids.iter().map(String::as_str)),
        part_from_row,
    )?;
    for part in rows {
        let part = part?;
        parts_by_event
            .entry(part.event_id.clone())
            .or_default()
            .push(part);
    }
    Ok(parts_by_event)
}

fn ensure_conversation(connection: &impl CountedSqlite, id: &str) -> StoreResult<()> {
    let exists: Option<i64> = connection
        .query_row(
            "SELECT 1 FROM conversations WHERE id=?1",
            params![id],
            |row| row.get(0),
        )
        .optional()?;
    if exists.is_none() {
        return Err(anyhow!("conversation_not_found"));
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn insert_event(
    connection: &impl CountedSqlite,
    event_id: &str,
    conversation_id: &str,
    author_membership_id: Option<&str>,
    kind: EventKind,
    parts: &[NewEventPart],
    causation_id: Option<&str>,
    correlation_id: Option<&str>,
    finalized: bool,
    require_active_author: bool,
    now: i64,
) -> StoreResult<ConversationEvent> {
    ensure_conversation(connection, conversation_id)?;
    if let Some(author) = author_membership_id {
        let author_status: Option<String> = connection
            .query_row(
                "SELECT status FROM memberships WHERE id=?1 AND conversation_id=?2",
                params![author, conversation_id],
                |row| row.get(0),
            )
            .optional()?;
        match author_status.as_deref() {
            None => return Err(anyhow!("event_author_not_found")),
            Some("active") => {}
            Some(_) if require_active_author => return Err(anyhow!("event_author_not_active")),
            Some(_) => {}
        }
    }
    let sequence: i64 = connection.query_row(
        "SELECT COALESCE(MAX(sequence), 0)+1 FROM events WHERE conversation_id=?1",
        params![conversation_id],
        |row| row.get(0),
    )?;
    connection.execute(
        "INSERT INTO events(id, conversation_id, sequence, author_membership_id, kind,
         causation_id, correlation_id, created_at, finalized)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            event_id,
            conversation_id,
            sequence,
            author_membership_id,
            enum_wire(kind)?,
            causation_id,
            correlation_id,
            now,
            finalized as i64,
        ],
    )?;
    let mut stored_parts = Vec::with_capacity(parts.len());
    for (ordinal, part) in parts.iter().enumerate() {
        if require_active_author || part.kind != EventPartKind::Text {
            validate_text(&part.content, "event_part_content")?;
        }
        let part_id = if part.id.trim().is_empty() {
            new_id("part")
        } else {
            part.id.clone()
        };
        connection.execute(
            "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                part_id,
                event_id,
                ordinal as i64,
                enum_wire(part.kind)?,
                part.content,
                now,
            ],
        )?;
        if matches!(part.kind, EventPartKind::Text | EventPartKind::Reasoning) {
            connection.execute(
                "INSERT INTO event_search(event_id, conversation_id, content) VALUES (?1, ?2, ?3)",
                params![event_id, conversation_id, part.content],
            )?;
        }
        stored_parts.push(EventPart {
            id: part_id,
            event_id: event_id.to_owned(),
            ordinal: ordinal as i64,
            kind: part.kind,
            content: part.content.clone(),
            created_at_unix_ms: now,
        });
    }
    bump_revision(connection, conversation_id, now)?;
    Ok(ConversationEvent {
        id: event_id.to_owned(),
        conversation_id: conversation_id.to_owned(),
        sequence,
        author_membership_id: author_membership_id.map(str::to_owned),
        kind,
        causation_id: causation_id.map(str::to_owned),
        correlation_id: correlation_id.map(str::to_owned),
        created_at_unix_ms: now,
        finalized,
        parts: stored_parts,
    })
}

fn enqueue_mention_turns_in_transaction(
    connection: &impl CountedSqlite,
    conversation_id: &str,
    source_event_id: &str,
    membership_ids: &[String],
) -> StoreResult<Vec<DirectTurn>> {
    let event_conversation: String = connection.query_row(
        "SELECT conversation_id FROM events WHERE id=?1",
        params![source_event_id],
        |row| row.get(0),
    )?;
    if event_conversation != conversation_id {
        return Err(anyhow!("mention_event_mismatch"));
    }
    let mut seen = std::collections::HashSet::with_capacity(membership_ids.len());
    let mut turns = Vec::new();
    for membership_id in membership_ids {
        if !seen.insert(membership_id.as_str()) {
            continue;
        }
        let runnable: Option<i64> = connection
            .query_row(
                "SELECT 1 FROM memberships m
                 JOIN principals p ON p.id=m.principal_id
                 WHERE m.id=?1 AND m.conversation_id=?2
                   AND m.status='active' AND p.kind='agent'
                   AND p.agent_id IS NOT NULL AND p.agent_id<>''",
                params![membership_id, conversation_id],
                |row| row.get(0),
            )
            .optional()?;
        if runnable.is_none() {
            continue;
        }
        let turn = DirectTurn {
            id: new_id("turn"),
            conversation_id: conversation_id.to_owned(),
            source_event_id: source_event_id.to_owned(),
            membership_id: membership_id.to_owned(),
            state: TurnState::Pending,
            ordinal: turns.len() as i64,
        };
        connection.execute(
            "INSERT INTO direct_turns(
               id, conversation_id, source_event_id, membership_id, state, ordinal
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                turn.id,
                turn.conversation_id,
                turn.source_event_id,
                turn.membership_id,
                enum_wire(turn.state)?,
                turn.ordinal,
            ],
        )?;
        turns.push(turn);
    }
    Ok(turns)
}

fn upsert_principal(connection: &impl CountedSqlite, principal: &Principal) -> StoreResult<()> {
    let kind = enum_wire(principal.kind)?;
    let existing_kind: Option<String> = connection
        .query_row(
            "SELECT kind FROM principals WHERE id=?1",
            params![principal.id],
            |row| row.get(0),
        )
        .optional()?;
    if existing_kind
        .as_deref()
        .is_some_and(|existing| existing != kind)
    {
        return Err(anyhow!("principal_kind_immutable"));
    }
    connection.execute(
        "INSERT INTO principals(id, kind, display_name, agent_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5)
         ON CONFLICT(id) DO UPDATE SET display_name=excluded.display_name,
           agent_id=excluded.agent_id",
        params![
            principal.id,
            kind,
            principal.display_name,
            principal.agent_id,
            principal.created_at_unix_ms,
        ],
    )?;
    Ok(())
}

fn validate_import_entry(
    conversation: &Conversation,
    events: &[ConversationEvent],
) -> StoreResult<()> {
    validate_identifier(&conversation.id, "conversation_id")?;
    validate_text(&conversation.title, "conversation_title")?;
    if conversation.event_count != events.len() as i64 {
        return Err(anyhow!("conversation_import_count_mismatch"));
    }
    let mut membership_ids = std::collections::HashSet::new();
    let mut active_owners = 0usize;
    for membership in &conversation.memberships {
        if membership.conversation_id != conversation.id
            || !membership_ids.insert(membership.id.as_str())
        {
            return Err(anyhow!("conversation_import_membership_invalid"));
        }
        validate_identifier(&membership.id, "membership_id")?;
        validate_identifier(&membership.principal.id, "principal_id")?;
        validate_text(&membership.principal.display_name, "principal_display_name")?;
        if membership.status == super::MembershipStatus::Active
            && membership.access == MembershipAccess::Owner
        {
            active_owners += 1;
        }
    }
    if active_owners == 0 {
        return Err(anyhow!("conversation_import_owner_missing"));
    }
    let mut event_ids = std::collections::HashSet::new();
    let mut last_sequence = 0;
    for event in events {
        if event.conversation_id != conversation.id
            || event.sequence <= last_sequence
            || !event_ids.insert(event.id.as_str())
            || event
                .author_membership_id
                .as_deref()
                .is_some_and(|id| !membership_ids.contains(id))
        {
            return Err(anyhow!("conversation_import_event_invalid"));
        }
        last_sequence = event.sequence;
        for (ordinal, part) in event.parts.iter().enumerate() {
            if part.event_id != event.id || part.ordinal != ordinal as i64 {
                return Err(anyhow!("conversation_import_part_invalid"));
            }
            validate_text(&part.content, "event_part_content")?;
        }
    }
    Ok(())
}

fn insert_import_entry(
    connection: &impl CountedSqlite,
    conversation: &Conversation,
    events: &[ConversationEvent],
) -> StoreResult<()> {
    for membership in &conversation.memberships {
        let principal = &membership.principal;
        let existing: Option<(String, String, Option<String>, i64)> = connection
            .query_row(
                "SELECT kind, display_name, agent_id, created_at FROM principals WHERE id=?1",
                params![principal.id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let expected = (
            enum_wire(principal.kind)?,
            principal.display_name.clone(),
            principal.agent_id.clone(),
            principal.created_at_unix_ms,
        );
        if existing.as_ref().is_some_and(|value| value != &expected) {
            return Err(anyhow!("conversation_import_principal_conflict"));
        }
        connection.execute(
            "INSERT INTO principals(id, kind, display_name, agent_id, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(id) DO NOTHING",
            params![
                principal.id,
                expected.0,
                principal.display_name,
                principal.agent_id,
                principal.created_at_unix_ms,
            ],
        )?;
    }
    connection.execute(
        "INSERT INTO conversations(
           id, title, archived, pinned, is_group, strategy_revision,
           revision, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            conversation.id,
            conversation.title,
            conversation.archived as i64,
            conversation.pinned as i64,
            conversation.is_group as i64,
            conversation.strategy_revision,
            conversation.revision,
            conversation.created_at_unix_ms,
            conversation.updated_at_unix_ms,
        ],
    )?;
    for membership in &conversation.memberships {
        connection.execute(
            "INSERT INTO memberships(
               id, conversation_id, principal_id, access, status, joined_at, left_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                membership.id,
                conversation.id,
                membership.principal.id,
                enum_wire(membership.access)?,
                enum_wire(membership.status)?,
                membership.joined_at_unix_ms,
                membership.left_at_unix_ms,
            ],
        )?;
    }
    for event in events {
        connection.execute(
            "INSERT INTO events(
               id, conversation_id, sequence, author_membership_id, kind,
               causation_id, correlation_id, created_at, finalized
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                event.id,
                conversation.id,
                event.sequence,
                event.author_membership_id,
                enum_wire(event.kind)?,
                event.causation_id,
                event.correlation_id,
                event.created_at_unix_ms,
                event.finalized as i64,
            ],
        )?;
        for part in &event.parts {
            connection.execute(
                "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    part.id,
                    event.id,
                    part.ordinal,
                    enum_wire(part.kind)?,
                    part.content,
                    part.created_at_unix_ms,
                ],
            )?;
            if matches!(part.kind, EventPartKind::Text | EventPartKind::Reasoning) {
                connection.execute(
                    "INSERT INTO event_search(event_id, conversation_id, content)
                     VALUES (?1, ?2, ?3)",
                    params![event.id, conversation.id, part.content],
                )?;
            }
        }
    }
    Ok(())
}

fn bump_revision(
    connection: &impl CountedSqlite,
    conversation_id: &str,
    now: i64,
) -> StoreResult<()> {
    let changed = connection.execute(
        "UPDATE conversations SET revision=revision+1, updated_at=?2 WHERE id=?1",
        params![conversation_id, now],
    )?;
    if changed == 0 {
        return Err(anyhow!("conversation_not_found"));
    }
    Ok(())
}

fn validate_identifier(value: &str, label: &str) -> StoreResult<()> {
    if value.is_empty()
        || value.len() > 160
        || value
            .chars()
            .any(|character| character.is_control() || character.is_whitespace())
    {
        return Err(anyhow!("{label}_invalid"));
    }
    Ok(())
}

fn validate_text(value: &str, label: &str) -> StoreResult<()> {
    if value.len() > 1_048_576 || value.chars().any(|character| character == '\0') {
        return Err(anyhow!("{label}_invalid"));
    }
    Ok(())
}

fn validate_required_text(value: &str, label: &str) -> StoreResult<()> {
    validate_text(value, label)?;
    if value.trim().is_empty() {
        return Err(anyhow!("{label}_invalid"));
    }
    Ok(())
}

fn new_id(prefix: &str) -> String {
    format!("{prefix}:{}", Uuid::new_v4())
}

fn runtime_source_identity(
    agent_id: &str,
    session_id: &str,
    dispatch_id: &str,
) -> StoreResult<String> {
    let identity = if session_id.trim().is_empty() {
        format!("pending:{dispatch_id}")
    } else {
        format!("{}:{agent_id}:{session_id}", agent_id.len())
    };
    validate_identifier(&identity, "runtime_source_identity")?;
    Ok(identity)
}

fn runtime_frame_parts(encoded: &str) -> Vec<NewEventPart> {
    const CHUNK_BYTES: usize = 512 * 1024;
    if encoded.is_empty() {
        return vec![NewEventPart {
            id: String::new(),
            kind: EventPartKind::Metadata,
            content: String::new(),
        }];
    }
    let mut parts = Vec::with_capacity(encoded.len().div_ceil(CHUNK_BYTES));
    let mut start = 0;
    while start < encoded.len() {
        let mut end = (start + CHUNK_BYTES).min(encoded.len());
        while end > start && !encoded.is_char_boundary(end) {
            end -= 1;
        }
        parts.push(NewEventPart {
            id: String::new(),
            kind: EventPartKind::Metadata,
            content: encoded[start..end].to_owned(),
        });
        start = end;
    }
    parts
}

fn runtime_semantic_parts(frame: &Value) -> Vec<NewEventPart> {
    let event = frame
        .get("event")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload = frame.get("payload").unwrap_or(&Value::Null);
    let text = payload
        .get("text")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    let part = match event {
        "agent.turn.accepted" => Some((
            EventPartKind::Metadata,
            serde_json::json!({"lifecycle": "accepted"}).to_string(),
        )),
        "agent.message.completed" => text.map(|value| (EventPartKind::Text, value.to_owned())),
        "agent.turn.processing" => {
            let evidence = payload
                .get("evidenceKind")
                .and_then(Value::as_str)
                .unwrap_or("activity");
            match evidence {
                "reasoning" | "plan" => Some((
                    EventPartKind::Reasoning,
                    text.unwrap_or(evidence).to_owned(),
                )),
                "tool" => Some((
                    EventPartKind::ToolCall,
                    payload
                        .get("toolName")
                        .and_then(Value::as_str)
                        .filter(|value| !value.is_empty())
                        .or(text)
                        .unwrap_or("tool")
                        .to_owned(),
                )),
                _ => Some((
                    EventPartKind::Metadata,
                    serde_json::json!({
                        "lifecycle": "running",
                        "evidenceKind": evidence,
                    })
                    .to_string(),
                )),
            }
        }
        "permission.denied" => Some((
            EventPartKind::Diagnostic,
            text.unwrap_or("permission denied").to_owned(),
        )),
        _ if event.contains("tool") && event.contains("result") => Some((
            EventPartKind::ToolResult,
            text.unwrap_or("tool result").to_owned(),
        )),
        _ if event.contains("tool") => Some((
            EventPartKind::ToolCall,
            payload
                .get("toolName")
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .or(text)
                .unwrap_or("tool")
                .to_owned(),
        )),
        _ if event.contains("artifact") => Some((
            EventPartKind::Artifact,
            text.unwrap_or("artifact").to_owned(),
        )),
        _ if event.contains("diagnostic") || event.contains("failed") => Some((
            EventPartKind::Diagnostic,
            text.unwrap_or("runtime diagnostic").to_owned(),
        )),
        _ => None,
    };
    part.into_iter()
        .map(|(kind, content)| NewEventPart {
            id: String::new(),
            kind,
            content,
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn insert_runtime_event_part(
    connection: &impl CountedSqlite,
    conversation_id: &str,
    event_id: &str,
    ordinal: i64,
    part: &NewEventPart,
    runtime_cursor: Option<u64>,
    now: i64,
) -> StoreResult<()> {
    if runtime_cursor.is_some_and(|cursor| cursor == 0 || cursor > i64::MAX as u64) {
        return Err(anyhow!("runtime_cursor_invalid"));
    }
    if part.kind != EventPartKind::Text {
        validate_text(&part.content, "event_part_content")?;
    }
    let part_id = if part.id.trim().is_empty() {
        new_id("part")
    } else {
        part.id.clone()
    };
    connection.execute(
        "INSERT INTO event_parts(
           id, event_id, ordinal, kind, content, runtime_cursor, created_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            part_id,
            event_id,
            ordinal,
            enum_wire(part.kind)?,
            part.content,
            runtime_cursor.map(|cursor| cursor as i64),
            now,
        ],
    )?;
    if matches!(part.kind, EventPartKind::Text | EventPartKind::Reasoning) {
        connection.execute(
            "INSERT INTO event_search(event_id, conversation_id, content) VALUES (?1, ?2, ?3)",
            params![event_id, conversation_id, part.content],
        )?;
    }
    Ok(())
}

fn runtime_terminal_diagnostic(terminal: &Value, error_code: Option<&str>) -> String {
    let nested = terminal.get("error").unwrap_or(terminal);
    let code = error_code
        .or_else(|| nested.get("code").and_then(Value::as_str))
        .unwrap_or("agent_conversation_dispatch_failed");
    let stage = nested
        .get("stage")
        .and_then(Value::as_str)
        .unwrap_or("conversation/dispatch");
    serde_json::json!({"code": code, "stage": stage}).to_string()
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

fn enum_wire<T: Serialize>(value: T) -> StoreResult<String> {
    Ok(serde_json::to_value(value)?
        .as_str()
        .unwrap_or_default()
        .to_owned())
}
fn decode<T: DeserializeOwned>(value: String) -> rusqlite::Result<T> {
    serde_json::from_str(&format!("\"{value}\"")).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(error))
    })
}

fn summary_from_row(row: &Row<'_>) -> rusqlite::Result<ConversationSummary> {
    Ok(ConversationSummary {
        id: row.get(0)?,
        title: row.get(1)?,
        archived: row.get::<_, i64>(2)? != 0,
        pinned: row.get::<_, i64>(3)? != 0,
        is_group: row.get::<_, i64>(4)? != 0,
        revision: row.get(5)?,
        updated_at_unix_ms: row.get(6)?,
        membership_count: row.get(7)?,
        event_count: row.get(8)?,
    })
}
fn principal_from_row(row: &Row<'_>, offset: usize) -> rusqlite::Result<Principal> {
    Ok(Principal {
        id: row.get(offset)?,
        kind: decode(row.get(offset + 1)?)?,
        display_name: row.get(offset + 2)?,
        agent_id: row.get(offset + 3)?,
        created_at_unix_ms: row.get(offset + 4)?,
    })
}
fn membership_from_row(row: &Row<'_>) -> rusqlite::Result<Membership> {
    Ok(Membership {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        principal: principal_from_row(row, 2)?,
        access: decode(row.get(7)?)?,
        status: decode(row.get(8)?)?,
        joined_at_unix_ms: row.get(9)?,
        left_at_unix_ms: row.get(10)?,
    })
}
fn event_from_row(row: &Row<'_>) -> rusqlite::Result<ConversationEvent> {
    Ok(ConversationEvent {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        sequence: row.get(2)?,
        author_membership_id: row.get(3)?,
        kind: decode(row.get(4)?)?,
        causation_id: row.get(5)?,
        correlation_id: row.get(6)?,
        created_at_unix_ms: row.get(7)?,
        finalized: row.get::<_, i64>(8)? != 0,
        parts: Vec::new(),
    })
}
fn direct_turn_from_row(row: &Row<'_>) -> rusqlite::Result<DirectTurn> {
    Ok(DirectTurn {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        source_event_id: row.get(2)?,
        membership_id: row.get(3)?,
        state: decode(row.get(4)?)?,
        ordinal: row.get(5)?,
    })
}
fn part_from_row(row: &Row<'_>) -> rusqlite::Result<EventPart> {
    Ok(EventPart {
        id: row.get(0)?,
        event_id: row.get(1)?,
        ordinal: row.get(2)?,
        kind: decode(row.get(3)?)?,
        content: row.get(4)?,
        created_at_unix_ms: row.get(5)?,
    })
}
fn source_link_from_row(row: &Row<'_>) -> rusqlite::Result<SourceLink> {
    Ok(SourceLink {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        source_kind: row.get(2)?,
        native_identity: row.get(3)?,
    })
}

fn dispatch_by_id(
    connection: &impl CountedSqlite,
    dispatch_id: &str,
) -> StoreResult<ConversationDispatch> {
    connection
        .query_row(
            "SELECT id, conversation_id, membership_id, operation, state, session_mode,
               runtime_conversation_path, error_code, created_at, updated_at
             FROM conversation_dispatches WHERE id=?1",
            params![dispatch_id],
            dispatch_from_row,
        )
        .map_err(Into::into)
}

fn dispatch_from_row(row: &Row<'_>) -> rusqlite::Result<ConversationDispatch> {
    Ok(ConversationDispatch {
        id: row.get(0)?,
        conversation_id: row.get(1)?,
        membership_id: row.get(2)?,
        operation: row.get(3)?,
        state: decode(row.get(4)?)?,
        session_mode: decode(row.get(5)?)?,
        runtime_conversation_path: row.get(6)?,
        error_code: row.get(7)?,
        created_at_unix_ms: row.get(8)?,
        updated_at_unix_ms: row.get(9)?,
    })
}

fn append_domain_event(
    connection: &impl CountedSqlite,
    conversation_id: &str,
    kind: EventKind,
    metadata: serde_json::Value,
    now: i64,
) -> StoreResult<()> {
    let sequence: i64 = connection.query_row(
        "SELECT COALESCE(MAX(sequence), 0)+1 FROM events WHERE conversation_id=?1",
        params![conversation_id],
        |row| row.get(0),
    )?;
    let event_id = new_id("event");
    connection.execute(
        "INSERT INTO events(id, conversation_id, sequence, kind, created_at, finalized)
         VALUES (?1, ?2, ?3, ?4, ?5, 1)",
        params![event_id, conversation_id, sequence, enum_wire(kind)?, now],
    )?;
    connection.execute(
        "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
         VALUES (?1, ?2, 0, ?3, ?4, ?5)",
        params![
            new_id("part"),
            event_id,
            enum_wire(EventPartKind::Metadata)?,
            serde_json::to_string(&metadata)?,
            now,
        ],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::client_conversation::{
        EventPartKind, MembershipStatus, NewEventPart, PrincipalKind,
    };

    fn owner() -> Principal {
        Principal {
            id: "human:local".into(),
            kind: PrincipalKind::Human,
            display_name: "You".into(),
            agent_id: None,
            created_at_unix_ms: 1,
        }
    }

    #[test]
    fn creates_peer_conversation_and_pages_structured_events() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Project", owner()).unwrap();
        assert!(!conversation.is_group);
        let agent = Principal {
            id: "agent:one".into(),
            kind: PrincipalKind::Agent,
            display_name: "One".into(),
            agent_id: Some("one".into()),
            created_at_unix_ms: 1,
        };
        let member = store
            .add_member(&conversation.id, agent, MembershipAccess::Member)
            .unwrap();
        let event = store
            .append_event(
                &conversation.id,
                Some(&member.id),
                EventKind::Message,
                &[NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Text,
                    content: "hello".into(),
                }],
                None,
                None,
                true,
            )
            .unwrap();
        assert_eq!(event.sequence, 2);
        assert_eq!(
            store
                .page_events(&conversation.id, None, 50)
                .unwrap()
                .events
                .into_iter()
                .find(|event| event.kind == EventKind::Message)
                .unwrap()
                .parts[0]
                .content,
            "hello"
        );
        assert_eq!(store.get(&conversation.id).unwrap().memberships.len(), 2);
    }

    #[test]
    fn pooled_connections_are_bounded_and_reused_across_operations() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Pool", owner()).unwrap();
        let agent = Principal {
            id: "agent:one".into(),
            kind: PrincipalKind::Agent,
            display_name: "One".into(),
            agent_id: Some("one".into()),
            created_at_unix_ms: 1,
        };
        let member = store
            .add_member(&conversation.id, agent, MembershipAccess::Member)
            .unwrap();
        for index in 0..3 {
            store
                .append_event(
                    &conversation.id,
                    Some(&member.id),
                    EventKind::Message,
                    &[NewEventPart {
                        id: String::new(),
                        kind: EventPartKind::Text,
                        content: format!("seed {index}"),
                    }],
                    None,
                    None,
                    true,
                )
                .unwrap();
        }
        let opens_after_warmup = store.counters().opens();
        assert!(
            opens_after_warmup <= DEFAULT_CONVERSATION_POOL_SIZE,
            "pool opened {opens_after_warmup} connections"
        );
        for _ in 0..5 {
            let _ = store.list(false).unwrap();
            let _ = store.get(&conversation.id).unwrap();
            let _ = store.page_events(&conversation.id, None, 50).unwrap();
            let _ = store.search("seed", 50).unwrap();
        }
        assert_eq!(store.counters().opens(), opens_after_warmup);
        assert!(store.counters().opens() <= DEFAULT_CONVERSATION_POOL_SIZE);
    }

    #[test]
    fn page_and_search_query_counts_do_not_grow_with_page_size() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Query", owner()).unwrap();
        let agent = Principal {
            id: "agent:one".into(),
            kind: PrincipalKind::Agent,
            display_name: "One".into(),
            agent_id: Some("one".into()),
            created_at_unix_ms: 1,
        };
        let member = store
            .add_member(&conversation.id, agent, MembershipAccess::Member)
            .unwrap();
        for index in 0..120 {
            store
                .append_event(
                    &conversation.id,
                    Some(&member.id),
                    EventKind::Message,
                    &[
                        NewEventPart {
                            id: String::new(),
                            kind: EventPartKind::Text,
                            content: format!("needle {index}"),
                        },
                        NewEventPart {
                            id: String::new(),
                            kind: EventPartKind::Reasoning,
                            content: format!("reasoning {index}"),
                        },
                    ],
                    None,
                    None,
                    true,
                )
                .unwrap();
        }
        let mut page_delta: Option<usize> = None;
        for limit in [10usize, 50, 100] {
            let before = store.counters().queries();
            let page = store.page_events(&conversation.id, None, limit).unwrap();
            let delta = store.counters().queries() - before;
            assert_eq!(page.events.len(), limit.min(120));
            for event in &page.events {
                if event.kind == EventKind::Message {
                    assert_eq!(event.parts.len(), 2);
                }
            }
            assert_eq!(delta, 4, "page of {limit} events must cost 4 statements");
            page_delta = Some(delta);
        }
        let mut search_delta: Option<usize> = None;
        for limit in [10usize, 50, 100] {
            let before = store.counters().queries();
            let events = store.search("needle", limit).unwrap();
            let delta = store.counters().queries() - before;
            assert_eq!(events.len(), limit.min(120));
            assert!(events.iter().all(|event| event.parts.len() == 2));
            assert_eq!(delta, 2, "search of {limit} events must cost 2 statements");
            search_delta = Some(delta);
        }
        assert_eq!(page_delta, Some(4));
        assert_eq!(search_delta, Some(2));
    }

    #[test]
    fn creates_initial_group_memberships_atomically() {
        let store = ConversationStore::open_in_memory().unwrap();
        let agent = |id: &str| Principal {
            id: format!("agent:{id}"),
            kind: PrincipalKind::Agent,
            display_name: id.to_owned(),
            agent_id: Some(id.to_owned()),
            created_at_unix_ms: 1,
        };
        let conversation = store
            .create_conversation_with_members(
                "Group",
                owner(),
                &[(agent("one"), MembershipAccess::Member)],
            )
            .unwrap();

        assert!(conversation.is_group);
        assert_eq!(conversation.memberships.len(), 2);
        assert_eq!(conversation.event_count, 1);
        assert_eq!(store.list(false).unwrap()[0].membership_count, 2);

        assert!(
            store
                .create_conversation_with_members("Empty", owner(), &[])
                .is_err()
        );

        let failure = store.create_conversation_with_members(
            "Invalid",
            owner(),
            &[
                (agent("duplicate"), MembershipAccess::Member),
                (agent("duplicate"), MembershipAccess::Member),
            ],
        );
        assert!(failure.is_err());
        assert_eq!(store.list(false).unwrap().len(), 1);
    }

    #[test]
    fn schema_upgrade_recovers_existing_multi_member_groups() {
        let store = ConversationStore::open_in_memory().unwrap();
        let agent = |id: &str| Principal {
            id: format!("agent:{id}"),
            kind: PrincipalKind::Agent,
            display_name: id.to_owned(),
            agent_id: Some(id.to_owned()),
            created_at_unix_ms: 1,
        };
        let conversation = store
            .create_conversation_with_members(
                "Existing group",
                owner(),
                &[
                    (agent("one"), MembershipAccess::Member),
                    (agent("two"), MembershipAccess::Member),
                ],
            )
            .unwrap();
        store
            .with_connection(|connection| {
                connection.execute(
                    "UPDATE conversations SET is_group=0 WHERE id=?1",
                    params![conversation.id],
                )?;
                initialize_schema(connection)
            })
            .unwrap();

        assert!(store.get(&conversation.id).unwrap().is_group);
    }

    #[test]
    fn structured_mentions_are_exact_deduplicated_direct_turns() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Project", owner()).unwrap();
        let first = store
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:one".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "One".into(),
                    agent_id: Some("one".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        let second = store
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:two".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Two".into(),
                    agent_id: Some("two".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        let event = store
            .append_event(
                &conversation.id,
                None,
                EventKind::Message,
                &[NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Text,
                    content: "Names in text are not authority".into(),
                }],
                None,
                None,
                true,
            )
            .unwrap();
        let turns = store
            .enqueue_mention_turns(
                &conversation.id,
                &event.id,
                &[first.id.clone(), first.id.clone(), second.id.clone()],
            )
            .unwrap();
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0].membership_id, first.id);
        assert_eq!(turns[1].membership_id, second.id);
    }

    #[test]
    fn message_and_mentions_commit_together_and_only_pending_turns_are_claimable() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Project", owner()).unwrap();
        let agent = store
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:claim".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Claim".into(),
                    agent_id: Some("claim".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        let owner_id = store
            .get(&conversation.id)
            .unwrap()
            .memberships
            .into_iter()
            .find(|membership| membership.principal.kind == PrincipalKind::Human)
            .unwrap()
            .id;

        let (event, turns) = store
            .post_message_with_mentions(
                &conversation.id,
                Some(&owner_id),
                "run once",
                None,
                &[agent.id],
            )
            .unwrap();
        assert_eq!(turns.len(), 1);
        assert!(
            store
                .page_events(&conversation.id, None, 50)
                .unwrap()
                .events
                .iter()
                .any(|candidate| candidate.id == event.id)
        );

        let claimed = store.claim_direct_turn(&turns[0].id).unwrap().unwrap();
        assert_eq!(claimed.turn.state, TurnState::Claimed);
        assert!(store.claim_direct_turn(&turns[0].id).unwrap().is_none());
        assert!(store.mark_direct_turn_running(&turns[0].id).unwrap());
        assert!(store.claim_direct_turn(&turns[0].id).unwrap().is_none());
        assert!(!store.mark_direct_turn_running(&turns[0].id).unwrap());
        assert_eq!(
            store.direct_turn(&turns[0].id).unwrap().state,
            TurnState::Running
        );
    }

    #[test]
    fn access_changes_preserve_an_owner_and_finalized_events_are_immutable() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Project", owner()).unwrap();
        let agent = store
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:owner".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Owner Agent".into(),
                    agent_id: Some("owner".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        assert_eq!(
            store
                .set_member_access(&conversation.id, &agent.id, MembershipAccess::Owner)
                .unwrap()
                .access,
            MembershipAccess::Owner
        );
        let local_owner = store
            .get(&conversation.id)
            .unwrap()
            .memberships
            .into_iter()
            .find(|membership| membership.principal.id == "human:local")
            .unwrap();
        store
            .set_member_access(&conversation.id, &local_owner.id, MembershipAccess::Member)
            .unwrap();
        assert_eq!(
            store
                .set_member_access(&conversation.id, &agent.id, MembershipAccess::Member)
                .unwrap_err()
                .to_string(),
            "conversation_requires_owner"
        );

        let event = store
            .append_event(
                &conversation.id,
                Some(&agent.id),
                EventKind::Message,
                &[],
                None,
                None,
                false,
            )
            .unwrap();
        store
            .append_event_part(
                &event.id,
                NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Text,
                    content: "streamed".into(),
                },
            )
            .unwrap();
        store.finalize_event(&event.id).unwrap();
        assert_eq!(
            store
                .append_event_part(
                    &event.id,
                    NewEventPart {
                        id: String::new(),
                        kind: EventPartKind::Text,
                        content: "late".into(),
                    },
                )
                .unwrap_err()
                .to_string(),
            "event_already_finalized"
        );
    }

    #[test]
    fn event_pages_are_bounded_and_search_uses_persisted_parts() {
        let store = ConversationStore::open_in_memory().unwrap();
        let conversation = store.create_conversation("Project", owner()).unwrap();
        for index in 0..105 {
            store
                .append_event(
                    &conversation.id,
                    None,
                    EventKind::Message,
                    &[NewEventPart {
                        id: String::new(),
                        kind: EventPartKind::Text,
                        content: format!("event {index} searchable-token"),
                    }],
                    None,
                    None,
                    true,
                )
                .unwrap();
        }
        let first = store
            .page_events(&conversation.id, None, usize::MAX)
            .unwrap();
        assert_eq!(first.events.len(), MAX_EVENT_PAGE_SIZE);
        assert_eq!(first.total_count, 105);
        let second = store
            .page_events(
                &conversation.id,
                first.next_cursor.and_then(|value| value.parse().ok()),
                DEFAULT_EVENT_PAGE_SIZE,
            )
            .unwrap();
        assert_eq!(second.events.len(), 5);
        assert_eq!(store.search("searchable-token", 1).unwrap().len(), 1);
    }

    #[test]
    fn export_import_preserves_stable_ids_and_rejects_conflicts_atomically() {
        let source_root = std::env::temp_dir().join(format!("lico-export-{}", Uuid::new_v4()));
        let destination_root = std::env::temp_dir().join(format!("lico-import-{}", Uuid::new_v4()));
        crate::platform::file_security::ensure_private_dir(&source_root).unwrap();
        crate::platform::file_security::ensure_private_dir(&destination_root).unwrap();
        let source = ConversationStore::open(&source_root).unwrap();
        let conversation = source.create_conversation("Transfer", owner()).unwrap();
        let agent = source
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:transfer".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Transfer Agent".into(),
                    agent_id: Some("transfer".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        let event = source
            .append_event(
                &conversation.id,
                Some(&agent.id),
                EventKind::Message,
                &[NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Reasoning,
                    content: "complete structured output".into(),
                }],
                None,
                None,
                true,
            )
            .unwrap();
        let bundle = source_root.join("bundle.json");
        source
            .export_bundle(&bundle, std::slice::from_ref(&conversation.id))
            .unwrap();

        let destination = ConversationStore::open(&destination_root).unwrap();
        assert_eq!(destination.import_bundle(&bundle).unwrap()["imported"], 1);
        let imported = destination.get(&conversation.id).unwrap();
        assert_eq!(imported.memberships[1].id, agent.id);
        assert_eq!(
            destination
                .page_events(&conversation.id, None, 50)
                .unwrap()
                .events
                .into_iter()
                .find(|candidate| candidate.id == event.id)
                .unwrap()
                .id,
            event.id,
        );
        assert_eq!(
            destination.import_bundle(&bundle).unwrap()["alreadyPresent"],
            1
        );

        let mut conflicting: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&bundle).unwrap()).unwrap();
        conflicting["conversations"][0]["conversation"]["title"] = serde_json::json!("Conflicting");
        std::fs::write(&bundle, serde_json::to_vec(&conflicting).unwrap()).unwrap();
        assert_eq!(
            destination.import_bundle(&bundle).unwrap_err().to_string(),
            "conversation_import_identity_conflict"
        );
        assert_eq!(destination.get(&conversation.id).unwrap().title, "Transfer");
        let _ = std::fs::remove_dir_all(source_root);
        let _ = std::fs::remove_dir_all(destination_root);
    }

    #[test]
    fn dispatch_runtime_locations_stay_private_and_membership_scoped() {
        let root = std::env::temp_dir().join(format!("lico-dispatch-{}", Uuid::new_v4()));
        crate::platform::file_security::ensure_private_dir(&root).unwrap();
        let store = ConversationStore::open(&root).unwrap();
        let conversation = store.create_conversation("Dispatch", owner()).unwrap();
        let agent = store
            .add_member(
                &conversation.id,
                Principal {
                    id: "agent:dispatch".into(),
                    kind: PrincipalKind::Agent,
                    display_name: "Dispatch Agent".into(),
                    agent_id: Some("dispatch".into()),
                    created_at_unix_ms: 1,
                },
                MembershipAccess::Member,
            )
            .unwrap();
        let dispatch = store
            .create_dispatch(
                &conversation.id,
                &agent.id,
                "subagent.delegate",
                DispatchSessionMode::New,
            )
            .unwrap();
        assert!(
            store
                .latest_resumable_dispatch(&conversation.id, &agent.id)
                .unwrap()
                .is_none()
        );
        let private_location = "opaque-runtime-session-location";
        store
            .update_dispatch(
                &dispatch.id,
                DispatchState::Completed,
                Some(private_location),
                None,
            )
            .unwrap();
        assert_eq!(
            store
                .latest_resumable_dispatch(&conversation.id, &agent.id)
                .unwrap()
                .unwrap()
                .runtime_conversation_path
                .as_deref(),
            Some(private_location)
        );
        let bundle = root.join("bundle.json");
        store
            .export_bundle(&bundle, std::slice::from_ref(&conversation.id))
            .unwrap();
        assert!(
            !std::fs::read_to_string(bundle)
                .unwrap()
                .contains(private_location)
        );
        let _ = std::fs::remove_dir_all(root);
    }

    // ---- durable reserved-group cutover (schema v2 -> v3) ----

    fn seed_v2_database(connection: &Connection, block_version_three: bool) {
        if block_version_three {
            connection
                .execute_batch(
                    "CREATE TABLE schema_meta (
                       key TEXT PRIMARY KEY, value TEXT NOT NULL, CHECK(value <> '3')
                     );",
                )
                .unwrap();
        } else {
            connection
                .execute_batch(
                    "CREATE TABLE schema_meta (
                       key TEXT PRIMARY KEY, value TEXT NOT NULL
                     );",
                )
                .unwrap();
        }
        connection
            .execute(
                "INSERT INTO schema_meta(key, value) VALUES ('version', '2')",
                [],
            )
            .unwrap();
        connection
            .execute_batch(CONVERSATION_SCHEMA_TABLES)
            .unwrap();

        for (id, kind, name, agent_id, created) in [
            ("human:local", "human", "You", None::<&str>, 100),
            ("agent:one", "agent", "One", Some("one"), 200),
            ("agent:two", "agent", "Two", Some("two"), 300),
        ] {
            connection
                .execute(
                    "INSERT INTO principals(id, kind, display_name, agent_id, created_at)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![id, kind, name, agent_id, created],
                )
                .unwrap();
        }
        for (id, title, archived, pinned, is_group, revision, created, updated) in [
            ("legacy-reserved-group", "Lico", 0, 1, 0, 7, 1000, 9000),
            ("custom-group", "Custom Group", 0, 0, 1, 3, 1000, 8000),
        ] {
            connection
                .execute(
                    "INSERT INTO conversations(id, title, archived, pinned, is_group,
                     revision, created_at, updated_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                    params![
                        id, title, archived, pinned, is_group, revision, created, updated
                    ],
                )
                .unwrap();
        }
        for (id, conversation_id, principal_id, access, status, joined, left) in [
            (
                "m-owner",
                "legacy-reserved-group",
                "human:local",
                "owner",
                "active",
                1000,
                None::<i64>,
            ),
            (
                "m-one",
                "legacy-reserved-group",
                "agent:one",
                "member",
                "active",
                2000,
                None,
            ),
            (
                "m-two",
                "legacy-reserved-group",
                "agent:two",
                "member",
                "left",
                3000,
                Some(9000),
            ),
            (
                "mc-owner",
                "custom-group",
                "human:local",
                "owner",
                "active",
                1000,
                None,
            ),
            (
                "mc-one",
                "custom-group",
                "agent:one",
                "member",
                "active",
                2000,
                None,
            ),
            (
                "mc-two",
                "custom-group",
                "agent:two",
                "member",
                "left",
                3000,
                Some(8000),
            ),
        ] {
            connection
                .execute(
                    "INSERT INTO memberships(id, conversation_id, principal_id, access,
                     status, joined_at, left_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![
                        id,
                        conversation_id,
                        principal_id,
                        access,
                        status,
                        joined,
                        left
                    ],
                )
                .unwrap();
        }

        let event = |id: &str,
                     conversation_id: &str,
                     sequence: i64,
                     author: Option<&str>,
                     kind: &str,
                     created_at: i64| {
            connection
                .execute(
                    "INSERT INTO events(id, conversation_id, sequence, author_membership_id,
                     kind, causation_id, correlation_id, created_at, finalized)
                     VALUES (?1, ?2, ?3, ?4, ?5, NULL, NULL, ?6, 1)",
                    params![id, conversation_id, sequence, author, kind, created_at],
                )
                .unwrap();
        };
        let metadata_part = |event_id: &str, content: &str, created_at: i64| {
            connection
                .execute(
                    "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
                     VALUES (?1, ?2, 0, 'metadata', ?3, ?4)",
                    params![format!("{event_id}-part"), event_id, content, created_at],
                )
                .unwrap();
        };
        let message_part =
            |event_id: &str, conversation_id: &str, content: &str, created_at: i64| {
                connection
                    .execute(
                        "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
                         VALUES (?1, ?2, 0, 'text', ?3, ?4)",
                        params![format!("{event_id}-part"), event_id, content, created_at],
                    )
                    .unwrap();
                connection
                    .execute(
                        "INSERT INTO event_search(event_id, conversation_id, content)
                         VALUES (?1, ?2, ?3)",
                        params![event_id, conversation_id, content],
                    )
                    .unwrap();
            };

        event(
            "e1",
            "legacy-reserved-group",
            1,
            Some("m-owner"),
            "message",
            1100,
        );
        message_part("e1", "legacy-reserved-group", "first hello", 1100);
        event(
            "e2",
            "legacy-reserved-group",
            2,
            None,
            "membership-changed",
            2000,
        );
        metadata_part(
            "e2",
            r#"{"membershipId":"m-one","principalId":"agent:one","change":"joined"}"#,
            2000,
        );
        event(
            "e3",
            "legacy-reserved-group",
            3,
            None,
            "membership-changed",
            3000,
        );
        metadata_part(
            "e3",
            r#"{"membershipId":"m-two","principalId":"agent:two","change":"joined"}"#,
            3000,
        );
        event(
            "e4",
            "legacy-reserved-group",
            4,
            Some("m-owner"),
            "message",
            4000,
        );
        message_part("e4", "legacy-reserved-group", "middle message", 4000);
        event(
            "e5",
            "legacy-reserved-group",
            5,
            None,
            "membership-changed",
            9000,
        );
        metadata_part(
            "e5",
            r#"{"membershipId":"m-two","principalId":"agent:two","change":"left"}"#,
            9000,
        );
        event(
            "e6",
            "legacy-reserved-group",
            6,
            None,
            "membership-changed",
            9100,
        );
        metadata_part(
            "e6",
            r#"{"membershipId":"m-x","principalId":"agent:ghost","change":"left","reason":"retired"}"#,
            9100,
        );
        event(
            "e7",
            "legacy-reserved-group",
            7,
            None,
            "membership-changed",
            9200,
        );
        metadata_part(
            "e7",
            r#"{"membershipId":"m-two","change":"access-set","access":"member"}"#,
            9200,
        );
        event(
            "e8",
            "legacy-reserved-group",
            8,
            Some("m-one"),
            "message",
            9300,
        );
        message_part("e8", "legacy-reserved-group", "final hello", 9300);
        event(
            "e9",
            "legacy-reserved-group",
            9,
            Some("m-owner"),
            "membership-changed",
            9400,
        );
        metadata_part(
            "e9",
            r#"{"membershipId":"m-one","principalId":"agent:one","change":"joined"}"#,
            9400,
        );
        event(
            "e10",
            "legacy-reserved-group",
            10,
            None,
            "membership-changed",
            9500,
        );
        metadata_part(
            "e10",
            r#"{"membershipId":"m-one","principalId":"agent:one","change":"joined"}"#,
            9500,
        );
        connection
            .execute(
                "INSERT INTO event_parts(id, event_id, ordinal, kind, content, created_at)
                 VALUES ('e10-extra', 'e10', 1, 'text', 'preserve this near-match', 9500)",
                [],
            )
            .unwrap();
        event(
            "e11",
            "legacy-reserved-group",
            11,
            None,
            "membership-changed",
            9600,
        );
        metadata_part(
            "e11",
            r#"{"membershipId":"m-one","principalId":"agent:two","change":"joined"}"#,
            9600,
        );
        event(
            "e12",
            "legacy-reserved-group",
            12,
            None,
            "membership-changed",
            9700,
        );
        metadata_part(
            "e12",
            r#"{"membershipId":"m-owner","principalId":"human:local","change":"joined"}"#,
            9700,
        );

        event("ce1", "custom-group", 1, Some("mc-owner"), "message", 1100);
        message_part("ce1", "custom-group", "custom message", 1100);
        event("ce2", "custom-group", 2, None, "membership-changed", 2000);
        metadata_part(
            "ce2",
            r#"{"membershipId":"mc-two","principalId":"agent:two","change":"joined"}"#,
            2000,
        );

        connection
            .execute(
                "INSERT INTO migration_provenance(source_kind, source_identity, conversation_id)
                 VALUES ('group', 'lico-group-default', 'legacy-reserved-group')",
                [],
            )
            .unwrap();
    }

    fn fixture_database(root: &Path) -> std::path::PathBuf {
        root.join("client-state")
            .join("conversations")
            .join("conversations.sqlite3")
    }

    fn open_fixture_connection(root: &Path) -> rusqlite::Connection {
        let connection = rusqlite::Connection::open(fixture_database(root)).unwrap();
        configure_connection(&connection).unwrap();
        connection
    }

    fn snapshot_group(root: &Path, conversation_id: &str) -> String {
        let connection = open_fixture_connection(root);
        let mut out = String::new();
        let queries: Vec<(&str, &str)> = vec![
            (
                "conversations",
                "SELECT id, title, archived, pinned, is_group, revision, created_at, updated_at
                 FROM conversations WHERE id=?1",
            ),
            (
                "memberships",
                "SELECT id, conversation_id, principal_id, access, status, joined_at, left_at
                 FROM memberships WHERE conversation_id=?1",
            ),
            (
                "events",
                "SELECT id, conversation_id, sequence, author_membership_id, kind, causation_id,
                 correlation_id, created_at, finalized
                 FROM events WHERE conversation_id=?1",
            ),
            (
                "event_parts",
                "SELECT id, event_id, ordinal, kind, content, created_at FROM event_parts
                 WHERE event_id IN (SELECT id FROM events WHERE conversation_id=?1)",
            ),
            (
                "event_search",
                "SELECT event_id, conversation_id, content FROM event_search
                 WHERE conversation_id=?1",
            ),
        ];
        for (table, sql) in queries {
            let mut statement = connection.prepare(sql).unwrap();
            let mut rows = statement.query(params![conversation_id]).unwrap();
            while let Some(row) = rows.next().unwrap() {
                let mut values = Vec::new();
                for index in 0..row.as_ref().column_count() {
                    values.push(format!(
                        "{:?}",
                        row.get::<_, rusqlite::types::Value>(index).unwrap()
                    ));
                }
                out.push_str(&format!(
                    "{table}|{}
",
                    values.join("|")
                ));
            }
        }
        out
    }

    fn snapshot_database(root: &Path) -> String {
        let connection = open_fixture_connection(root);
        let mut out = String::new();
        let tables = [
            "principals",
            "conversations",
            "memberships",
            "events",
            "event_parts",
            "event_search",
            "source_links",
            "runtime_bindings",
            "conversation_dispatches",
            "migration_provenance",
            "schema_meta",
        ];
        for table in tables {
            let mut statement = connection
                .prepare(&format!("SELECT * FROM {table} ORDER BY rowid"))
                .unwrap();
            let mut rows = statement.query([]).unwrap();
            while let Some(row) = rows.next().unwrap() {
                let mut values = Vec::new();
                for index in 0..row.as_ref().column_count() {
                    values.push(format!(
                        "{:?}",
                        row.get::<_, rusqlite::types::Value>(index).unwrap()
                    ));
                }
                out.push_str(&format!(
                    "{table}|{}
",
                    values.join("|")
                ));
            }
        }
        out
    }

    fn schema_version(root: &Path) -> String {
        let connection = open_fixture_connection(root);
        connection
            .query_row(
                "SELECT value FROM schema_meta WHERE key='version'",
                [],
                |row| row.get(0),
            )
            .unwrap()
    }

    #[test]
    fn migrates_v2_reserved_group_and_preserves_everything_else() {
        let root = std::env::temp_dir().join(format!("lico-conv-v2-{}", Uuid::new_v4()));
        std::fs::create_dir_all(fixture_database(&root).parent().unwrap()).unwrap();
        let fixture = open_fixture_connection(&root);
        seed_v2_database(&fixture, false);
        fixture.close().unwrap();

        let custom_before = snapshot_group(&root, "custom-group");
        let store = ConversationStore::open(&root).unwrap();
        assert_eq!(schema_version(&root), "6");

        let conversation = store.get("legacy-reserved-group").unwrap();
        assert_eq!(conversation.title, DEFAULT_LOCAL_AGENT_GROUP_TITLE);
        assert!(conversation.pinned);
        assert!(conversation.is_group);
        assert_eq!(conversation.event_count, 9);
        assert_eq!(conversation.memberships.len(), 3);
        let mut by_principal = std::collections::HashMap::new();
        for membership in &conversation.memberships {
            by_principal.insert(membership.principal.id.as_str(), membership);
        }
        assert_eq!(by_principal.len(), 3);
        for principal_id in ["human:local", "agent:one", "agent:two"] {
            let membership = by_principal[principal_id];
            assert_eq!(membership.status, MembershipStatus::Active);
            assert_eq!(membership.left_at_unix_ms, None);
        }

        let remaining: Vec<(String, String, i64)> = store
            .with_connection(|connection| {
                let mut statement = connection
                    .prepare(
                        "SELECT id, kind, sequence FROM events
                         WHERE conversation_id=?1 ORDER BY sequence ASC",
                    )
                    .unwrap();
                let rows = statement
                    .query_map(params!["legacy-reserved-group"], |row| {
                        Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                    })
                    .unwrap();
                rows.collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(Into::into)
            })
            .unwrap();
        assert_eq!(
            remaining,
            vec![
                ("e1".to_owned(), "message".to_owned(), 1),
                ("e4".to_owned(), "message".to_owned(), 2),
                ("e6".to_owned(), "membership-changed".to_owned(), 3),
                ("e7".to_owned(), "membership-changed".to_owned(), 4),
                ("e8".to_owned(), "message".to_owned(), 5),
                ("e9".to_owned(), "membership-changed".to_owned(), 6),
                ("e10".to_owned(), "membership-changed".to_owned(), 7),
                ("e11".to_owned(), "membership-changed".to_owned(), 8),
                ("e12".to_owned(), "membership-changed".to_owned(), 9),
            ]
        );

        let search: Vec<(String, String)> = store
            .with_connection(|connection| {
                let mut statement = connection
                    .prepare(
                        "SELECT event_id, content FROM event_search
                         WHERE conversation_id=?1 ORDER BY rowid",
                    )
                    .unwrap();
                let rows = statement
                    .query_map(params!["legacy-reserved-group"], |row| {
                        Ok((row.get(0)?, row.get(1)?))
                    })
                    .unwrap();
                rows.collect::<rusqlite::Result<Vec<_>>>()
                    .map_err(Into::into)
            })
            .unwrap();
        assert_eq!(
            search,
            vec![
                ("e1".to_owned(), "first hello".to_owned()),
                ("e4".to_owned(), "middle message".to_owned()),
                ("e8".to_owned(), "final hello".to_owned()),
            ]
        );

        assert_eq!(snapshot_group(&root, "custom-group"), custom_before);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reopening_current_schema_and_legacy_import_closure_are_no_ops() {
        let root = std::env::temp_dir().join(format!("lico-conv-v4-{}", Uuid::new_v4()));
        std::fs::create_dir_all(fixture_database(&root).parent().unwrap()).unwrap();
        let fixture = open_fixture_connection(&root);
        seed_v2_database(&fixture, false);
        fixture.close().unwrap();

        let store = ConversationStore::open(&root).unwrap();
        let after_first_open = snapshot_database(&root);
        drop(store);
        let reopened = ConversationStore::open(&root).unwrap();
        assert_eq!(snapshot_database(&root), after_first_open);
        reopened
            .normalize_reserved_default_group_after_legacy_import()
            .unwrap();
        assert_eq!(snapshot_database(&root), after_first_open);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn failed_v3_migration_rolls_back_and_retry_succeeds() {
        let root = std::env::temp_dir().join(format!("lico-conv-rollback-{}", Uuid::new_v4()));
        std::fs::create_dir_all(fixture_database(&root).parent().unwrap()).unwrap();
        let fixture = open_fixture_connection(&root);
        seed_v2_database(&fixture, true);
        fixture.close().unwrap();

        assert!(ConversationStore::open(&root).is_err());
        assert_eq!(schema_version(&root), "2");
        let check = open_fixture_connection(&root);
        let event_count: i64 = check
            .query_row(
                "SELECT COUNT(*) FROM events WHERE conversation_id='legacy-reserved-group'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(event_count, 12);
        let m_two: String = check
            .query_row(
                "SELECT status FROM memberships WHERE id='m-two'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(m_two, "left");
        let automatic_survived: i64 = check
            .query_row(
                "SELECT COUNT(*) FROM events WHERE id IN ('e2','e3','e5')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(automatic_survived, 3);
        check
            .execute_batch(
                "DROP TABLE schema_meta;
                 CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO schema_meta(key, value) VALUES ('version', '2');",
            )
            .unwrap();
        drop(check);

        let store = ConversationStore::open(&root).unwrap();
        assert_eq!(schema_version(&root), "6");
        let conversation = store.get("legacy-reserved-group").unwrap();
        assert_eq!(conversation.event_count, 9);
        for membership in conversation.memberships {
            assert_eq!(membership.status, MembershipStatus::Active);
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn migrates_v5_conversations_to_durable_strategy_selection() {
        let root = std::env::temp_dir().join(format!("lico-conv-v5-{}", Uuid::new_v4()));
        std::fs::create_dir_all(fixture_database(&root).parent().unwrap()).unwrap();
        let fixture = open_fixture_connection(&root);
        fixture
            .execute_batch(
                "CREATE TABLE schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO schema_meta(key, value) VALUES ('version', '5');
                 CREATE TABLE conversations (
                   id TEXT PRIMARY KEY, title TEXT NOT NULL,
                   archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
                   pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
                   is_group INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1)),
                   revision INTEGER NOT NULL DEFAULT 0,
                   created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
                 );",
            )
            .unwrap();
        fixture.close().unwrap();

        let store = ConversationStore::open(&root).unwrap();
        assert_eq!(schema_version(&root), "6");
        let has_strategy_revision = store
            .with_connection(|connection| {
                let mut statement = connection.prepare("PRAGMA table_info(conversations)")?;
                Ok(statement
                    .query_map([], |row| row.get::<_, String>(1))?
                    .collect::<rusqlite::Result<Vec<_>>>()?
                    .iter()
                    .any(|column| column == "strategy_revision"))
            })
            .unwrap();
        assert!(has_strategy_revision);

        drop(store);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn fresh_install_stays_empty_and_closure_is_a_no_op() {
        let root = std::env::temp_dir().join(format!("lico-conv-fresh-{}", Uuid::new_v4()));
        let store = ConversationStore::open(&root).unwrap();
        assert!(store.list(false).unwrap().is_empty());
        assert!(store.get(DEFAULT_LOCAL_AGENT_GROUP_ID).is_err());
        store
            .normalize_reserved_default_group_after_legacy_import()
            .unwrap();
        assert!(store.list(false).unwrap().is_empty());
        assert!(store.get(DEFAULT_LOCAL_AGENT_GROUP_ID).is_err());
        assert_eq!(schema_version(&root), "6");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn default_local_group_adopts_legacy_identity_without_losing_content() {
        let store = ConversationStore::open_in_memory().unwrap();
        let legacy = store
            .create_group_with_id("legacy-local-group", "Lico", owner())
            .unwrap();
        store
            .source_link(&legacy.id, "group", DEFAULT_LOCAL_AGENT_GROUP_ID)
            .unwrap();
        let owner = legacy.memberships[0].id.clone();
        store
            .append_event(
                &legacy.id,
                Some(&owner),
                EventKind::Message,
                &[NewEventPart {
                    id: String::new(),
                    kind: EventPartKind::Text,
                    content: "kept".into(),
                }],
                None,
                None,
                true,
            )
            .unwrap();

        let local = store.ensure_default_local_group().unwrap();

        assert_eq!(local.id, DEFAULT_LOCAL_AGENT_GROUP_ID);
        assert_eq!(local.title, DEFAULT_LOCAL_AGENT_GROUP_TITLE);
        assert_eq!(local.event_count, 1);
        assert_eq!(local.memberships.len(), 1);
        assert_eq!(store.list(false).unwrap().len(), 1);
        assert!(store.get("legacy-local-group").is_err());
        assert_eq!(
            store
                .page_events(DEFAULT_LOCAL_AGENT_GROUP_ID, None, 10)
                .unwrap()
                .events[0]
                .parts[0]
                .content,
            "kept"
        );
    }
}
