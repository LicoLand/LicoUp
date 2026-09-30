//! Canonical schema creation and upgrades from published stores.

use super::*;

#[cfg(test)]
mod tests;

/// Canonical Conversation table and index layout. Shared by the schema
/// initializer and the synthetic versioned fixtures used by migration tests.
pub(super) const CONVERSATION_SCHEMA_TABLES: &str = "
         CREATE TABLE IF NOT EXISTS principals (
           id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('human','agent')),
           display_name TEXT NOT NULL, agent_id TEXT, created_at INTEGER NOT NULL
         );
         CREATE TABLE IF NOT EXISTS conversations (
           id TEXT PRIMARY KEY, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
           pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
           is_group INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1)), strategy_revision TEXT,
           assistant_membership_id TEXT REFERENCES memberships(id),
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
         CREATE TABLE IF NOT EXISTS membership_profiles (
           membership_id TEXT PRIMARY KEY REFERENCES memberships(id) ON DELETE CASCADE,
           revision INTEGER NOT NULL,
           responsibility TEXT NOT NULL DEFAULT 'member' CHECK(responsibility IN ('assistant','member')),
           required_capabilities TEXT NOT NULL DEFAULT '[]',
           preferred_capabilities TEXT NOT NULL DEFAULT '[]',
           skill_references TEXT NOT NULL DEFAULT '[]',
           preferred_model TEXT, preferred_reasoning_effort TEXT,
           preferred_environment TEXT,
           updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS membership_profiles_membership_idx
           ON membership_profiles(membership_id, revision);
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
           runtime_cursor INTEGER, execution_kind TEXT, created_at INTEGER NOT NULL,
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
           request_payload TEXT, terminal_payload TEXT, native_provenance TEXT,
           created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
         );
          CREATE INDEX IF NOT EXISTS conversation_dispatches_resume_idx
            ON conversation_dispatches(conversation_id, membership_id, state, updated_at DESC);
          CREATE TABLE IF NOT EXISTS subagent_dispatch_claims (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            caller_membership_id TEXT NOT NULL REFERENCES memberships(id),
            target_membership_id TEXT NOT NULL REFERENCES memberships(id),
            parent_dispatch_id TEXT REFERENCES subagent_dispatch_claims(id),
            depth INTEGER NOT NULL CHECK(depth BETWEEN 1 AND 8),
            state TEXT NOT NULL CHECK(state IN (
              'claimed','running','cancel-requested','reconciliation-required',
              'completed','failed','cancelled'
            )),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            watchdog_deadline_unix_ms INTEGER
          );
          CREATE UNIQUE INDEX IF NOT EXISTS subagent_dispatch_claims_active_edge
            ON subagent_dispatch_claims(conversation_id, caller_membership_id, target_membership_id)
            WHERE state IN ('claimed','running','cancel-requested','reconciliation-required');
          CREATE INDEX IF NOT EXISTS subagent_dispatch_claims_parent_idx
            ON subagent_dispatch_claims(parent_dispatch_id);
          CREATE INDEX IF NOT EXISTS subagent_dispatch_claims_target_idx
            ON subagent_dispatch_claims(conversation_id, target_membership_id, updated_at DESC);
          CREATE TABLE IF NOT EXISTS subagent_mcp_inbound (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            caller_membership_id TEXT,
            target_membership_id TEXT,
            tool TEXT NOT NULL CHECK(tool IN (
              'lico_subagent_delegate','lico_subagent_continue','lico_subagent_cancel'
            )),
            outcome TEXT NOT NULL,
            created_at INTEGER NOT NULL
          );
          CREATE INDEX IF NOT EXISTS subagent_mcp_inbound_edge_idx
            ON subagent_mcp_inbound(
              conversation_id, caller_membership_id, target_membership_id, created_at, id
            );
          CREATE TABLE IF NOT EXISTS subagent_dispatch_deliveries (
            claim_id TEXT NOT NULL REFERENCES subagent_dispatch_claims(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN ('observation','terminal')),
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            recipient_membership_id TEXT NOT NULL REFERENCES memberships(id),
            state TEXT NOT NULL CHECK(state IN ('pending','delivering','delivered','failed')),
            terminal_state TEXT,
            payload TEXT,
            attempt_count INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            delivered_at INTEGER,
            admitted_turn_id TEXT,
            PRIMARY KEY (claim_id, kind)
          );
          CREATE INDEX IF NOT EXISTS subagent_dispatch_deliveries_pending_idx
            ON subagent_dispatch_deliveries(state, conversation_id, recipient_membership_id, updated_at ASC);
         CREATE TABLE IF NOT EXISTS migration_provenance (
           source_kind TEXT NOT NULL, source_identity TEXT NOT NULL,
           conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           PRIMARY KEY(source_kind, source_identity)
         );
         CREATE TABLE IF NOT EXISTS archived_native_sessions (
           agent_id TEXT NOT NULL, native_session_id TEXT NOT NULL,
           conversation_id TEXT NOT NULL, archived_at INTEGER NOT NULL,
           PRIMARY KEY(agent_id, native_session_id)
         );";

pub(super) fn configure_connection(connection: &Connection) -> StoreResult<()> {
    // WAL + NORMAL skips fsync of the main file during checkpoint. A SIGKILL
    // in that window can leave a torn database and an empty WAL, which SQLite
    // reports as malformed. FULL fsyncs the main file before the WAL is reset.
    // On macOS, fullfsync is required because ordinary fsync does not flush
    // the drive cache.
    connection.execute_batch(
        "PRAGMA foreign_keys=ON;
         PRAGMA journal_mode=WAL;
         PRAGMA synchronous=FULL;
         PRAGMA fullfsync=ON;
         PRAGMA checkpoint_fullfsync=ON;
         PRAGMA busy_timeout=8000;
         PRAGMA trusted_schema=OFF;",
    )?;
    Ok(())
}

pub(super) fn validate_current_schema(connection: &mut Connection) -> StoreResult<()> {
    configure_connection(connection)?;
    let version: String = connection.query_row(
        "SELECT value FROM schema_meta WHERE key='version'",
        [],
        |row| row.get(0),
    )?;
    if version != CURRENT_SCHEMA_VERSION {
        return Err(anyhow!("conversation_schema_migration_required"));
    }
    ensure_search_index(connection)?;
    Ok(())
}

pub(super) fn initialize_schema(connection: &mut Connection) -> StoreResult<()> {
    configure_connection(connection)?;
    let has_metadata: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='schema_meta')",
        [],
        |row| row.get(0),
    )?;
    let prior_schema_version: Option<String> = if has_metadata {
        connection
            .query_row(
                "SELECT value FROM schema_meta WHERE key='version'",
                [],
                |row| row.get(0),
            )
            .optional()?
    } else {
        None
    };
    match prior_schema_version.as_deref() {
        None => return create_current_schema(connection),
        Some(CURRENT_SCHEMA_VERSION) => {
            normalize_existing_groups(connection)?;
            return validate_current_schema(connection);
        }
        // Only the formats a published release wrote are accepted, each moved to the current
        // format by the same upgrade path: `11` (0.1.1, 0.1.2), `12` (0.2.0, 0.2.1) and `15`
        // (the published nightly). A version between them was never released and is refused
        // rather than upgraded.
        Some("11") => {}
        Some("12" | "15") => return upgrade_published_schema(connection),
        Some(other) => return Err(anyhow!("conversation_schema_unsupported_version: {other}")),
    }
    connection.execute_batch(CONVERSATION_SCHEMA_TABLES)?;
    let current_schema_version: String = connection.query_row(
        "SELECT value FROM schema_meta WHERE key='version'",
        [],
        |row| row.get(0),
    )?;
    if current_schema_version == "11" {
        migrate_membership_convergence_v12(connection)?;
    }
    ensure_column(
        connection,
        "conversations",
        "assistant_membership_id",
        "TEXT REFERENCES memberships(id)",
    )?;
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
    ensure_column(
        connection,
        "runtime_bindings",
        "runtime_conversation_path",
        "TEXT",
    )?;
    ensure_column(connection, "runtime_bindings", "working_directory", "TEXT")?;
    ensure_column(
        connection,
        "subagent_dispatch_claims",
        "watchdog_deadline_unix_ms",
        "INTEGER",
    )?;
    upgrade_published_schema(connection)
}

/// New stores start at the complete current layout without replaying migrations.
fn create_current_schema(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
    )?;
    ensure_current_layout(&transaction)?;
    write_current_version(&transaction)?;
    transaction.commit()?;
    Ok(())
}

/// All changes since the published schema are one atomic transition. Development
/// snapshots are not additional supported formats or migration checkpoints.
fn upgrade_published_schema(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure_current_layout(&transaction)?;
    normalize_existing_groups(&transaction)?;
    update_assistant_guide_references(&transaction)?;
    native_sessions::backfill_native_sessions(&transaction)?;
    ensure_search_index(&transaction)?;
    write_current_version(&transaction)?;
    transaction.commit()?;
    Ok(())
}

fn ensure_current_layout(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(CONVERSATION_SCHEMA_TABLES)?;
    connection.execute_batch(native_sessions::TABLE)?;
    ensure_column(connection, "event_parts", "execution_kind", "TEXT")?;
    ensure_column(
        connection,
        "conversation_dispatches",
        "request_payload",
        "TEXT",
    )?;
    ensure_column(
        connection,
        "conversation_dispatches",
        "terminal_payload",
        "TEXT",
    )?;
    ensure_column(
        connection,
        "conversation_dispatches",
        "native_provenance",
        "TEXT",
    )?;
    connection.execute_batch("CREATE INDEX IF NOT EXISTS conversation_dispatches_native_provenance_idx
        ON conversation_dispatches(json_extract(native_provenance,'$.agentId'),json_extract(native_provenance,'$.nativeSessionId'))
        WHERE native_provenance IS NOT NULL;
        CREATE INDEX IF NOT EXISTS conversations_pinned_updated_idx
          ON conversations(pinned DESC, updated_at DESC, id DESC);
        CREATE INDEX IF NOT EXISTS event_parts_runtime_replay_idx
          ON event_parts(event_id, runtime_cursor, ordinal)
          WHERE runtime_cursor IS NOT NULL;")?;
    ensure_converged_membership_index(connection)?;
    Ok(())
}

fn normalize_existing_groups(connection: &Connection) -> StoreResult<()> {
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
    Ok(())
}

fn write_current_version(connection: &Connection) -> StoreResult<()> {
    connection.execute(
        "INSERT INTO schema_meta(key, value) VALUES ('version', ?1)
         ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![CURRENT_SCHEMA_VERSION],
    )?;
    Ok(())
}

/// `event_search` is a derived FTS index. Rebuild it from `event_parts` only
/// when the index is corrupt or empty while searchable parts still exist.
fn ensure_search_index(connection: &Connection) -> StoreResult<()> {
    if search_index_is_corrupt(connection) || search_index_is_empty_with_source(connection)? {
        rebuild_search_index(connection)?;
    }
    Ok(())
}

fn search_index_is_corrupt(connection: &Connection) -> bool {
    connection
        .execute(
            "INSERT INTO event_search(event_search) VALUES('integrity-check')",
            [],
        )
        .is_err()
}

fn search_index_is_empty_with_source(connection: &Connection) -> StoreResult<bool> {
    let indexed: i64 =
        connection.query_row("SELECT COUNT(*) FROM event_search", [], |row| row.get(0))?;
    if indexed > 0 {
        return Ok(false);
    }
    let source: i64 = connection.query_row(
        "SELECT COUNT(*) FROM event_parts WHERE kind IN ('text', 'reasoning')",
        [],
        |row| row.get(0),
    )?;
    Ok(source > 0)
}

fn rebuild_search_index(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "DROP TABLE IF EXISTS event_search;
         CREATE VIRTUAL TABLE event_search USING fts5(
           event_id UNINDEXED, conversation_id UNINDEXED, content
         );
         INSERT INTO event_search(event_id, conversation_id, content)
         SELECT p.event_id, e.conversation_id, p.content
           FROM event_parts p
           JOIN events e ON e.id = p.event_id
          WHERE p.kind IN ('text', 'reasoning');",
    )?;
    Ok(())
}

/// Version 12 keeps one Membership row per (conversation, principal). Join and
/// leave flip that row's status; leftover left rows from earlier churn are
/// retargeted onto the surviving id and deleted.
fn migrate_membership_convergence_v12(connection: &mut Connection) -> StoreResult<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    converge_duplicate_memberships(&transaction, None)?;
    ensure_converged_membership_index(&transaction)?;
    transaction.execute(
        "INSERT INTO schema_meta(key, value) VALUES ('version', '12')
         ON CONFLICT(key) DO UPDATE SET value='12'",
        [],
    )?;
    transaction.commit()?;
    Ok(())
}

/// Move the retired bundled Assistant Skill reference to the
/// single product-owned LicoUp guide. Only Assistant Profiles are rewritten;
/// every unrelated user-selected reference keeps its original order.
fn update_assistant_guide_references(connection: &Connection) -> StoreResult<()> {
    const RETIRED_SKILL_ID: &str = "assistant-workflow-authoring";

    let profiles = {
        let mut statement = connection.prepare(
            "SELECT membership_id, skill_references
             FROM membership_profiles
             WHERE responsibility='assistant'",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (membership_id, encoded) in profiles {
        let current = serde_json::from_str::<Vec<String>>(&encoded)?;
        let mut migrated = current
            .iter()
            .filter(|reference| {
                reference.as_str() != RETIRED_SKILL_ID
                    && reference.as_str() != LICOUP_GUIDE_SKILL_ID
            })
            .cloned()
            .collect::<Vec<_>>();
        migrated.push(LICOUP_GUIDE_SKILL_ID.to_owned());
        if migrated != current {
            connection.execute(
                "UPDATE membership_profiles
                 SET revision=revision+1, skill_references=?2
                 WHERE membership_id=?1",
                params![membership_id, serde_json::to_string(&migrated)?],
            )?;
        }
    }
    Ok(())
}

fn ensure_converged_membership_index(connection: &Connection) -> StoreResult<()> {
    connection.execute_batch(
        "DROP INDEX IF EXISTS memberships_active_unique;
         CREATE UNIQUE INDEX IF NOT EXISTS memberships_principal_unique
           ON memberships(conversation_id, principal_id);",
    )?;
    Ok(())
}
