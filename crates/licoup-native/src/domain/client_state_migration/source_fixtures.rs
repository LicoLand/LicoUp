//! Faithful fixtures for the state the last published client leaves.
//!
//! Provenance is the immutable release tag v0.2.1
//! (db0fc4d7ae875332f8b0cab28cda3f3337ac3c9e), not the current frontier and not
//! a developer build:
//!
//! * Its embedded `resources/client-state-migration-frontier.json` names
//!   `licoup-state-0.1.1`, lists eleven domains (there is no
//!   `gateway-credential-custody`), every domain sits at target version 1, and
//!   every domain's only step is `<domainId>.absent-to-1`.
//! * Its packaged product version is `0.2.1`, so a root admitted by it records
//!   `highestAdmittedProductVersion = 0.2.1`.
//! * Its Conversation owner (`crates/licoup-conversation/src/store/mod.rs`)
//!   writes inner schema `12`. `RELEASED_CONVERSATION_SCHEMA_12` below is that
//!   owner's complete table layout, not the current layout with a stamped
//!   number: the current layout has columns and tables this one does not.
//!   Development schemas 13-17 are rejected by the current owner's upgrade
//!   path and are not represented here.
//! * Its strategy owner
//!   (`crates/licoup-native/src/domain/adaptive_flywheel/store.rs`) creates the
//!   seven `strategy_*` tables and stamps `strategy_meta.version = '2'`.
//!   `RELEASED_STRATEGY_SCHEMA_2` below is that owner's complete statement
//!   batch, not a version stamp on a truncated database.
//! * A published root may hold `<root>/llm-api-key-inventory.json` and no
//!   gateway-custody marker. The file is credential metadata, not custody
//!   proof: no fixture here fabricates a completed custody marker, and the
//!   released inventory document shape is used as-is.
//!
//! Migration and recovery fixtures downstream should reuse these statements and
//! facts instead of re-deriving a source root from the current catalog.

use super::strategy_store::STRATEGY_STORE_DATABASE;
use super::*;
use rusqlite::Connection;
use std::{fs, path::Path};

/// The frontier identity the released client embedded.
pub(super) const SOURCE_FRONTIER_ID: &str = "licoup-state-0.1.1";
/// The product version the released client packaged.
pub(super) const SOURCE_PRODUCT_VERSION: &str = "0.2.1";
/// The released client's eleven domains, in catalog order.
pub(super) const RELEASED_DOMAINS: &[&str] = &[
    "adaptive-flywheel",
    "agent-tab-order",
    "agent-tool-allowlist",
    "appearance-presentation",
    "canonical-conversation",
    "client-state",
    "current-view",
    "mobile-home-layout",
    "mobile-relay",
    "skill-hub-preferences",
    "workspace-manifest",
];

pub(super) fn released_step_id(domain_id: &str) -> String {
    format!("{domain_id}.absent-to-1")
}

/// The released Conversation owner's complete table layout.
const RELEASED_CONVERSATION_SCHEMA_12: &str = r#"
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
         CREATE TABLE IF NOT EXISTS migration_provenance (
           source_kind TEXT NOT NULL, source_identity TEXT NOT NULL,
           conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
           PRIMARY KEY(source_kind, source_identity)
         );"#;

/// The released strategy writer's complete statement batch.
const RELEASED_STRATEGY_SCHEMA_2: &str = r#"CREATE TABLE IF NOT EXISTS strategy_meta(
           key TEXT PRIMARY KEY, value TEXT NOT NULL
         );
         INSERT INTO strategy_meta(key, value) VALUES ('version', '2')
           ON CONFLICT(key) DO NOTHING;
         CREATE TABLE IF NOT EXISTS strategy_definitions(
           definition_id TEXT NOT NULL,
           revision_digest TEXT PRIMARY KEY,
           semantics_digest TEXT NOT NULL,
           name TEXT NOT NULL,
           version TEXT NOT NULL,
           workflow_json TEXT NOT NULL,
           asset_count INTEGER NOT NULL,
           imported_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS strategy_definitions_id_idx
           ON strategy_definitions(definition_id, imported_at DESC);
         CREATE TABLE IF NOT EXISTS strategy_bindings(
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
           slot_id TEXT NOT NULL,
           ordinal INTEGER NOT NULL DEFAULT 0,
           value_id TEXT NOT NULL,
           model TEXT NOT NULL DEFAULT '',
           reasoning_effort TEXT NOT NULL DEFAULT '',
           revision INTEGER NOT NULL,
           PRIMARY KEY(revision_digest, slot_id, ordinal)
         );
         CREATE TABLE IF NOT EXISTS strategy_authorizations(
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest) ON DELETE CASCADE,
           revision INTEGER NOT NULL,
           semantics_digest TEXT NOT NULL,
           binding_digest TEXT NOT NULL,
           authorization_digest TEXT NOT NULL,
           active INTEGER NOT NULL,
           created_at INTEGER NOT NULL,
           PRIMARY KEY(revision_digest, revision)
         );
         CREATE UNIQUE INDEX IF NOT EXISTS strategy_authorization_active_idx
           ON strategy_authorizations(revision_digest) WHERE active=1;
         CREATE TABLE IF NOT EXISTS strategy_runs(
           run_id TEXT PRIMARY KEY,
           revision_digest TEXT NOT NULL REFERENCES strategy_definitions(revision_digest),
           semantics_digest TEXT NOT NULL,
           idempotency_key TEXT NOT NULL UNIQUE,
           request_digest TEXT NOT NULL,
           snapshot_json TEXT NOT NULL,
           conversation_id TEXT,
           terminal INTEGER NOT NULL,
           created_at INTEGER NOT NULL,
           updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS strategy_runs_revision_idx
           ON strategy_runs(revision_digest, updated_at DESC);
         CREATE TABLE IF NOT EXISTS strategy_run_events(
           run_id TEXT NOT NULL REFERENCES strategy_runs(run_id) ON DELETE CASCADE,
           sequence INTEGER NOT NULL,
           event_type TEXT NOT NULL,
           event_json TEXT NOT NULL,
           created_at INTEGER NOT NULL,
           PRIMARY KEY(run_id, sequence)
         );
         CREATE TABLE IF NOT EXISTS strategy_commands(
           command_id TEXT PRIMARY KEY,
           run_id TEXT NOT NULL REFERENCES strategy_runs(run_id) ON DELETE CASCADE,
           state_id TEXT NOT NULL,
           kind TEXT NOT NULL,
           status TEXT NOT NULL,
           attempt INTEGER NOT NULL,
           attempt_token TEXT NOT NULL,
           command_json TEXT NOT NULL,
           lease_owner TEXT,
           lease_until INTEGER,
           updated_at INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS strategy_commands_ready_idx
           ON strategy_commands(status, command_id);
         CREATE INDEX IF NOT EXISTS strategy_commands_lease_idx
           ON strategy_commands(lease_until) WHERE status IN ('claimed', 'running');"#;

pub(super) const RELEASED_CONVERSATION_DATABASE: &str =
    "client-state/conversations/conversations.sqlite3";
pub(super) const RELEASED_CONVERSATION_COMPLETION: &str =
    "client-state/conversations/migration-v5.complete";
pub(super) const RELEASED_CONVERSATION_COMPLETION_CONTENT: &str = "schema=v5\nstatus=complete\n";
pub(super) const RELEASED_INVENTORY_FILE: &str = "llm-api-key-inventory.json";
pub(super) const RELEASED_INVENTORY_SCHEMA: &str = "licoup.llm-api-key-inventory.v1";

/// Create the released Conversation store: the schema-12 layout, one synthetic
/// conversation, and the completion marker a released admission wrote.
pub(super) fn seed_released_conversation_store(root: &Path) {
    let database = root.join(RELEASED_CONVERSATION_DATABASE);
    fs::create_dir_all(database.parent().unwrap()).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);",
        )
        .unwrap();
    connection
        .execute_batch(RELEASED_CONVERSATION_SCHEMA_12)
        .unwrap();
    connection
        .execute_batch(
            "INSERT INTO schema_meta(key, value) VALUES ('version', '12');
             INSERT INTO principals(id, kind, display_name, agent_id, created_at)
               VALUES ('principal-1', 'human', 'Synthetic Principal', NULL, 1);
             INSERT INTO conversations(id, title, created_at, updated_at)
               VALUES ('released-conversation', 'Synthetic released conversation', 1, 1);",
        )
        .unwrap();
    drop(connection);
    fs::write(
        root.join(RELEASED_CONVERSATION_COMPLETION),
        RELEASED_CONVERSATION_COMPLETION_CONTENT,
    )
    .unwrap();
}

/// Create the released strategy store: the seven-table layout at
/// `strategy_meta.version = '2'`, with one canary row nothing in the migration
/// knows about.
pub(super) fn seed_released_strategy_store(path: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(RELEASED_STRATEGY_SCHEMA_2)
        .unwrap();
    connection
        .execute_batch(
            "CREATE TABLE preservation_canary(value TEXT NOT NULL);
             INSERT INTO preservation_canary(value) VALUES ('must-survive');",
        )
        .unwrap();
}

/// Write the root-level credential inventory document the released client
/// leaves. It is metadata; no custody marker accompanies it.
pub(super) fn seed_released_credential_inventory(root: &Path) {
    let document = serde_json::json!({
        "schemaVersion": RELEASED_INVENTORY_SCHEMA,
        "leaseDays": 7,
        "entries": [],
    });
    write_json_atomic(&root.join(RELEASED_INVENTORY_FILE), &document).unwrap();
}

/// Build the ledger a released admission wrote: source frontier identity,
/// product high-water 0.2.1, and all eleven domains at version 1 with their
/// released step.
pub(super) fn released_ledger() -> Ledger {
    Ledger {
        schema_version: LEDGER_SCHEMA.to_owned(),
        highest_admitted_product_version: SOURCE_PRODUCT_VERSION.to_owned(),
        frontier_id: SOURCE_FRONTIER_ID.to_owned(),
        domains: RELEASED_DOMAINS
            .iter()
            .map(|domain_id| {
                (
                    (*domain_id).to_owned(),
                    LedgerDomain {
                        schema_version: 1,
                        completed_step_ids: vec![released_step_id(domain_id)],
                    },
                )
            })
            .collect(),
    }
}

/// Build a complete released source root in a disposable directory: ledger,
/// domain markers, the released Conversation and strategy stores, and the
/// root-level credential inventory the released client can leave behind. No
/// gateway-custody marker is written because the released client had no such
/// domain.
pub(super) fn seed_released_source_root(root: &Path) {
    let migration_root = root.join("client-state/migrations");
    let marker_root = migration_root.join("domain-state");
    licoup_foundation::platform::file_security::ensure_private_dir(&marker_root).unwrap();
    for domain_id in RELEASED_DOMAINS {
        write_json_atomic(
            &marker_path(&marker_root, domain_id),
            &DomainMarker {
                schema_version: DOMAIN_MARKER_SCHEMA.to_owned(),
                domain_id: (*domain_id).to_owned(),
                authoritative_schema_version: 1,
            },
        )
        .unwrap();
    }
    write_json_atomic(&migration_root.join("ledger.json"), &released_ledger()).unwrap();
    seed_released_conversation_store(root);
    seed_released_strategy_store(&root.join(STRATEGY_STORE_DATABASE));
    seed_released_credential_inventory(root);
}
