//! Tiered, metadata-only session catalogs for browse-mode conversation lists.
//!
//! Browse lists never parse conversation content up front. Each adapter contributes
//! native catalog metadata (agent-owned sqlite state, per-session state files, or
//! plain file metadata) inside a bounded recency window: active sessions from the
//! last few days (the head tier of the recency sort) are served first, deeper
//! paging progressively extends coverage to [`CATALOG_WINDOW_DAYS`], and anything
//! older (or natively archived) is left out. Only sessions that land in the
//! returned page are hydrated from their content files. Explicit searches
//! (match terms), archive discovery, single-session readback, and root overrides
//! keep the legacy full-scan path in `query.rs`.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use rusqlite::Connection;
use serde_json::{Value, json};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use super::codex::rollout_session_id_from_filename;
use super::cursor_openagent::codec::{open_read_only_connection, sqlite_table_exists};
use super::query_filter::{epoch_number_to_rfc3339, system_time, title_from_text};
use super::session_metadata::{meaningful_explicit_title, session_from_messages_with_title};
use super::{CONVERSATION_SCHEMA_VERSION, HistoryScanConfig, finalize_history_sessions};
use crate::domain::conversation::adapter_dispatch::parse_history_file;
use crate::domain::conversation::history_discovery::{
    HistoryDiscoveryOptions, discover_history_files,
};
use crate::domain::conversation::source_catalog::{HistoryAdapter, HistoryRoot, history_roots};

/// Browse lists never cover sessions older than this many days. The most recent
/// seven days form the head tier of the recency-sorted window: short pages are
/// served from them alone and deeper paging progressively reaches the rest of
/// the window.
pub(crate) const CATALOG_WINDOW_DAYS: u64 = 30;

const MAX_CATALOG_DIRECTORY_ENTRIES: usize = 16_000;
const MAX_CATALOG_WALK_DEPTH: usize = 8;
const MAX_STATE_FILE_BYTES: u64 = 1024 * 1024;
const MAX_TITLE_PROBE_LINES: usize = 200;
const MAX_TITLE_PROBE_LINE_BYTES: usize = 1024 * 1024;
const MAX_TITLE_PROBE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug)]
pub(crate) struct CatalogSession {
    pub(crate) native_session_id: String,
    pub(crate) source_path: PathBuf,
    pub(crate) source_kind: String,
    pub(crate) title: Option<String>,
    pub(crate) created_at: Option<SystemTime>,
    pub(crate) updated_at: Option<SystemTime>,
    pub(crate) working_directory: Option<String>,
    pub(crate) message_count: Option<usize>,
    pub(crate) model: Option<String>,
    pub(crate) hydrate: CatalogHydration,
}

#[derive(Clone, Debug)]
pub(crate) enum CatalogHydration {
    /// Parse this content file when the session lands in the returned page.
    File(PathBuf),
    /// Parse every `agents/*/wire.jsonl` below this session directory.
    KimiWireDirectory(PathBuf),
    /// Metadata-only entry; the page keeps a stub session.
    None,
}

#[derive(Default)]
pub(crate) struct SessionCatalog {
    pub(crate) sessions: Vec<CatalogSession>,
    pub(crate) files_seen: usize,
    pub(crate) directory_entries_seen: usize,
    pub(crate) skipped: Vec<Value>,
}

impl CatalogSession {
    fn recency(&self) -> SystemTime {
        self.updated_at.or(self.created_at).unwrap_or(UNIX_EPOCH)
    }
}

/// Browse-mode list entry point: catalog metadata within the recency window,
/// sorted by last activity, paginated, with content hydration for the page only.
pub(crate) fn conversation_list_from_catalog(
    adapter: HistoryAdapter,
    agent_id: &str,
    params: &Value,
    scan_config: &HistoryScanConfig,
) -> Result<Value> {
    let catalog = load_session_catalog(adapter, params, SystemTime::now());
    let total_sessions = catalog.sessions.len();
    let offset = scan_config.page.offset;
    let end = scan_config
        .page
        .end()
        .map(|end| end.min(total_sessions))
        .unwrap_or(total_sessions);
    let page_entries: Vec<CatalogSession> = if offset >= total_sessions {
        Vec::new()
    } else {
        catalog.sessions[offset..end].to_vec()
    };
    let sessions = hydrate_catalog_page(adapter, &page_entries, &mut Vec::new());
    let returned_sessions = sessions.len();
    let has_more = scan_config.page.has_more(total_sessions);

    Ok(json!({
        "ok": true,
        "schemaVersion": CONVERSATION_SCHEMA_VERSION,
        "mode": "native-history",
        "scanMode": "browse",
        "importMode": "precise-adapter",
        "readOnly": true,
        "agentId": agent_id,
        "adapterId": adapter.id(),
        "adapterLabel": adapter.label(),
        "sessions": sessions,
        "page": {
            "offset": offset,
            "limit": scan_config.page.limit,
            "returned": returned_sessions,
            "totalSessions": total_sessions,
            "hasMore": has_more
        },
        "sources": {
            "filesSeen": catalog.files_seen,
            "directoryEntriesSeen": catalog.directory_entries_seen,
            "skipped": catalog.skipped
        }
    }))
}

pub(crate) fn load_session_catalog(
    adapter: HistoryAdapter,
    params: &Value,
    now: SystemTime,
) -> SessionCatalog {
    let cutoff = now
        .checked_sub(Duration::from_secs(CATALOG_WINDOW_DAYS * 86_400))
        .unwrap_or(UNIX_EPOCH);
    let roots = history_roots(adapter, params);
    let mut catalog = SessionCatalog::default();
    match adapter {
        HistoryAdapter::Codex => codex_catalog(&roots, cutoff, &mut catalog),
        HistoryAdapter::OpenCode | HistoryAdapter::KiloCode => {
            openagent_catalog(adapter, &roots, cutoff, &mut catalog);
        }
        HistoryAdapter::Copilot => copilot_catalog(&roots, cutoff, &mut catalog),
        HistoryAdapter::KimiCode => kimi_code_catalog(&roots, cutoff, &mut catalog),
        HistoryAdapter::Cursor => cursor_catalog(&roots, cutoff, &mut catalog),
        HistoryAdapter::ClaudeCode => claude_catalog(&roots, cutoff, &mut catalog),
        HistoryAdapter::Pi => pi_catalog(&roots, cutoff, &mut catalog),
        _ => generic_file_catalog(adapter, &roots, cutoff, &mut catalog),
    }
    sort_and_dedupe_catalog(adapter, &mut catalog.sessions);
    catalog
}

fn sort_and_dedupe_catalog(adapter: HistoryAdapter, sessions: &mut Vec<CatalogSession>) {
    sessions.sort_by(|left, right| {
        right
            .recency()
            .cmp(&left.recency())
            .then_with(|| left.source_path.cmp(&right.source_path))
            .then_with(|| left.native_session_id.cmp(&right.native_session_id))
    });
    let mut seen = HashSet::<String>::new();
    sessions.retain(|entry| seen.insert(catalog_dedupe_key(adapter, entry)));
}

fn catalog_dedupe_key(adapter: HistoryAdapter, entry: &CatalogSession) -> String {
    if adapter == HistoryAdapter::Codex && !entry.native_session_id.is_empty() {
        return format!("{}\n{}", adapter.id(), entry.native_session_id);
    }
    format!(
        "{}\n{}\n{}",
        adapter.id(),
        entry.source_path.display(),
        entry.native_session_id
    )
}

// ---------------------------------------------------------------------------
// Page hydration: parse content files for the returned page only.
// ---------------------------------------------------------------------------

/// Browse pages bound their payload: hydrated sessions keep only the newest
/// messages in the list projection (`messageCount` still reports the full
/// transcript size), and each message text is truncated to a browse-sized
/// prefix. The complete transcript stays available through the
/// single-session read path.
const CATALOG_HYDRATED_MESSAGE_CAP: usize = 50;
const CATALOG_HYDRATED_MESSAGE_TEXT_CAP: usize = 2000;

fn hydrate_catalog_page(
    adapter: HistoryAdapter,
    page: &[CatalogSession],
    skipped: &mut Vec<Value>,
) -> Vec<Value> {
    let mut units = BTreeMap::<PathBuf, (String, CatalogHydration, Vec<usize>)>::new();
    for (index, entry) in page.iter().enumerate() {
        match &entry.hydrate {
            CatalogHydration::File(path) => {
                let unit = units.entry(path.clone()).or_insert_with(|| {
                    (
                        entry.source_kind.clone(),
                        CatalogHydration::File(path.clone()),
                        Vec::new(),
                    )
                });
                unit.2.push(index);
            }
            CatalogHydration::KimiWireDirectory(directory) => {
                let unit = units.entry(directory.clone()).or_insert_with(|| {
                    (
                        entry.source_kind.clone(),
                        CatalogHydration::KimiWireDirectory(directory.clone()),
                        Vec::new(),
                    )
                });
                unit.2.push(index);
            }
            CatalogHydration::None => {}
        }
    }

    let mut resolved = BTreeMap::<usize, Value>::new();
    for (unit_path, (source_kind, hydration, indexes)) in &units {
        let sessions = parse_catalog_unit(adapter, unit_path, source_kind, hydration);
        for index in indexes {
            let wanted = page[*index].native_session_id.as_str();
            let Some(session) = sessions.iter().find(|session| {
                session
                    .get("nativeSessionId")
                    .and_then(Value::as_str)
                    .is_some_and(|native_id| native_id == wanted)
            }) else {
                continue;
            };
            let mut session = session.clone();
            if let Some(object) = session.as_object_mut() {
                // Native catalog metadata wins over content-derived projection.
                if let Some(title) = page[*index]
                    .title
                    .as_deref()
                    .filter(|title| meaningful_explicit_title(title))
                {
                    object.insert("title".to_string(), json!(title_from_text(title)));
                }
                if let Some(working_directory) = page[*index]
                    .working_directory
                    .as_deref()
                    .filter(|value| !value.trim().is_empty())
                {
                    object.insert("workingDirectory".to_string(), json!(working_directory));
                }
                if let Some(model) = page[*index]
                    .model
                    .as_deref()
                    .filter(|value| !value.trim().is_empty())
                {
                    object.insert("model".to_string(), json!(model));
                }
                if let Some(messages) = object.get_mut("messages").and_then(Value::as_array_mut) {
                    let overflow = messages.len().saturating_sub(CATALOG_HYDRATED_MESSAGE_CAP);
                    if overflow > 0 {
                        messages.drain(0..overflow);
                    }
                    for message in messages.iter_mut() {
                        let Some(text_value) = message.get_mut("text") else {
                            continue;
                        };
                        let Some(text) = text_value.as_str() else {
                            continue;
                        };
                        if text.chars().count() > CATALOG_HYDRATED_MESSAGE_TEXT_CAP {
                            let truncated: String = text
                                .chars()
                                .take(CATALOG_HYDRATED_MESSAGE_TEXT_CAP)
                                .collect();
                            *text_value = Value::String(truncated);
                        }
                    }
                }
                // Long execution traces follow the same browse bound as the
                // message list; the full trace stays in the session read path.
                if let Some(semantic) = object.get_mut("semantic").and_then(Value::as_object_mut) {
                    for key in ["execution", "thread"] {
                        if let Some(entries) = semantic.get_mut(key).and_then(Value::as_array_mut) {
                            let overflow =
                                entries.len().saturating_sub(CATALOG_HYDRATED_MESSAGE_CAP);
                            if overflow > 0 {
                                entries.drain(0..overflow);
                            }
                        }
                    }
                }
            }
            resolved.insert(*index, session);
        }
    }

    page.iter()
        .enumerate()
        .filter_map(|(index, entry)| {
            resolved.remove(&index).or_else(|| {
                catalog_session_stub(adapter, entry).or_else(|| {
                    skipped.push(json!({
                        "path": entry.source_path.to_string_lossy(),
                        "reason": "catalog_metadata_unavailable"
                    }));
                    None
                })
            })
        })
        .collect()
}

fn parse_catalog_unit(
    adapter: HistoryAdapter,
    unit_path: &Path,
    source_kind: &str,
    hydration: &CatalogHydration,
) -> Vec<Value> {
    let scan_config = HistoryScanConfig::from_params(&json!({}));
    let mut sessions = Vec::<Value>::new();
    match hydration {
        CatalogHydration::File(path) => {
            if let Ok(metadata) = fs::metadata(path) {
                sessions.extend(parse_history_file(
                    adapter,
                    path,
                    source_kind,
                    &metadata,
                    scan_config.clone(),
                ));
            }
        }
        CatalogHydration::KimiWireDirectory(directory) => {
            for wire in kimi_wire_files(directory) {
                if let Ok(metadata) = fs::metadata(&wire) {
                    sessions.extend(parse_history_file(
                        adapter,
                        &wire,
                        source_kind,
                        &metadata,
                        scan_config.clone(),
                    ));
                }
            }
        }
        CatalogHydration::None => {
            let _ = unit_path;
        }
    }
    if sessions.is_empty() {
        return sessions;
    }
    finalize_history_sessions(sessions, &scan_config)
}

fn kimi_wire_files(session_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = fs::read_dir(session_dir.join("agents")) else {
        return Vec::new();
    };
    let mut wires = entries
        .flatten()
        .map(|entry| entry.path().join("wire.jsonl"))
        .filter(|path| path.is_file())
        .collect::<Vec<_>>();
    wires.sort();
    wires
}

/// Build the full session JSON shape from catalog metadata alone, with an empty
/// message list; content stays deferred until the session is expanded or searched.
fn catalog_session_stub(adapter: HistoryAdapter, entry: &CatalogSession) -> Option<Value> {
    let metadata = fs::metadata(&entry.source_path)
        .or_else(|_| {
            entry
                .source_path
                .parent()
                .map_or_else(|| fs::metadata("."), fs::metadata)
        })
        .or_else(|_| fs::metadata(std::env::temp_dir()))
        .ok()?;
    let mut session = session_from_messages_with_title(
        adapter,
        &entry.source_path,
        &metadata,
        &entry.source_kind,
        entry.native_session_id.clone(),
        Vec::new(),
        entry.title.clone(),
    );
    if let Some(object) = session.as_object_mut() {
        if let Some(updated_at) = entry.updated_at {
            object.insert("updatedAt".to_string(), json!(system_time(updated_at)));
        }
        if let Some(created_at) = entry.created_at {
            object.insert("createdAt".to_string(), json!(system_time(created_at)));
        }
        if let Some(working_directory) = entry
            .working_directory
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            object.insert("workingDirectory".to_string(), json!(working_directory));
        }
        if let Some(model) = entry
            .model
            .as_deref()
            .filter(|value| !value.trim().is_empty())
        {
            object.insert("model".to_string(), json!(model));
        }
        object.insert(
            "messageCount".to_string(),
            json!(entry.message_count.unwrap_or(0)),
        );
    }
    Some(session)
}

// ---------------------------------------------------------------------------
// Codex: state_*.sqlite threads (fail-closed) + fresh rollout supplement.
// ---------------------------------------------------------------------------

fn codex_catalog(roots: &[HistoryRoot], cutoff: SystemTime, catalog: &mut SessionCatalog) {
    let Some(sessions_root) = roots
        .iter()
        .find(|root| root.source_kind == "codex-session-store")
    else {
        return;
    };
    let sessions_dir = sessions_root.path.clone();
    let mut known_ids = HashSet::<String>::new();
    if let Some(state_db) = newest_codex_state_database(&sessions_dir) {
        match read_codex_state_threads(&state_db, cutoff) {
            Ok(entries) => {
                catalog.files_seen += 1;
                for entry in entries {
                    known_ids.insert(entry.native_session_id.clone());
                    catalog.sessions.push(entry);
                }
            }
            Err(skip) => catalog.skipped.push(skip),
        }
    }
    // Rollouts the state database has not indexed yet (including every rollout
    // when the schema was rejected) still surface from the session store itself.
    // The archived session store is intentionally left out of browse lists.
    let discovery = discover_history_files(
        HistoryAdapter::Codex,
        &[HistoryRoot {
            path: sessions_dir,
            source_kind: sessions_root.source_kind.clone(),
        }],
        HistoryDiscoveryOptions::default(),
    );
    catalog.files_seen += discovery.files_seen;
    catalog.directory_entries_seen += discovery.directory_entries_seen;
    catalog.skipped.extend(discovery.skipped);
    for candidate in discovery.candidates {
        if candidate.modified_at < cutoff {
            continue;
        }
        let Some(session_id) = rollout_session_id_from_filename(&candidate.path) else {
            continue;
        };
        if !known_ids.insert(session_id.clone()) {
            continue;
        }
        catalog.sessions.push(CatalogSession {
            native_session_id: session_id,
            source_path: candidate.path.clone(),
            source_kind: candidate.source_kind,
            title: None,
            created_at: None,
            updated_at: Some(candidate.modified_at),
            working_directory: None,
            message_count: None,
            model: None,
            hydrate: CatalogHydration::File(candidate.path),
        });
    }
}

fn newest_codex_state_database(sessions_dir: &Path) -> Option<PathBuf> {
    let codex_dir = sessions_dir.parent()?;
    fs::read_dir(codex_dir)
        .ok()?
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_str()?.to_string();
            let version = name
                .strip_prefix("state_")?
                .strip_suffix(".sqlite")?
                .parse::<u64>()
                .ok()?;
            Some((version, entry.path()))
        })
        .max_by_key(|(version, _)| *version)
        .map(|(_, path)| path)
}

/// Read the codex app-server thread catalog. The database is codex-internal and
/// versioned by filename, so any schema drift is rejected as a whole and the
/// caller falls back to rollout files instead of trusting partial rows.
fn read_codex_state_threads(
    db_path: &Path,
    cutoff: SystemTime,
) -> std::result::Result<Vec<CatalogSession>, Value> {
    let fail = |reason: &str| json!({"path": db_path.to_string_lossy(), "reason": reason});
    let connection =
        open_read_only_connection(db_path).ok_or_else(|| fail("codex_state_open_failed"))?;
    if !sqlite_table_exists(&connection, "threads") {
        return Err(fail("codex_state_schema_unrecognized"));
    }
    let columns = sqlite_columns(&connection, "threads")
        .map_err(|_| fail("codex_state_schema_unrecognized"))?;
    for required in [
        "id",
        "rollout_path",
        "created_at",
        "updated_at",
        "title",
        "archived",
    ] {
        if !columns.contains(required) {
            return Err(fail("codex_state_schema_unrecognized"));
        }
    }
    let cutoff_seconds = cutoff
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0);
    let mut statement = connection
        .prepare(
            "SELECT id, rollout_path, created_at, updated_at, title, cwd, model \
             FROM threads WHERE COALESCE(archived, 0) = 0 AND updated_at >= ?1 \
             ORDER BY updated_at DESC, id ASC",
        )
        .map_err(|_| fail("codex_state_schema_unrecognized"))?;
    let rows = statement
        .query_map([cutoff_seconds], |row| {
            let rollout_path: String = row.get(1)?;
            Ok(CatalogSession {
                native_session_id: row.get(0)?,
                source_path: PathBuf::from(&rollout_path),
                source_kind: "codex-session-store".to_string(),
                title: row
                    .get::<_, Option<String>>(4)?
                    .filter(|value| !value.trim().is_empty()),
                created_at: row.get::<_, Option<i64>>(2)?.and_then(epoch_to_system_time),
                updated_at: row.get::<_, Option<i64>>(3)?.and_then(epoch_to_system_time),
                working_directory: row
                    .get::<_, Option<String>>(5)?
                    .filter(|value| !value.trim().is_empty()),
                message_count: None,
                model: row
                    .get::<_, Option<String>>(6)?
                    .filter(|value| !value.trim().is_empty()),
                hydrate: CatalogHydration::File(PathBuf::from(rollout_path)),
            })
        })
        .map_err(|_| fail("codex_state_read_failed"))?;
    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(|_| fail("codex_state_read_failed"))?);
    }
    Ok(entries)
}

// ---------------------------------------------------------------------------
// OpenCode / Kilo Code: native session table with archive and window filters.
// ---------------------------------------------------------------------------

fn openagent_catalog(
    adapter: HistoryAdapter,
    roots: &[HistoryRoot],
    cutoff: SystemTime,
    catalog: &mut SessionCatalog,
) {
    for root in roots {
        let db_path = match (adapter, root.source_kind.as_str()) {
            (HistoryAdapter::KiloCode, "kilo-session-database") => root.path.clone(),
            (HistoryAdapter::OpenCode, "opencode-data") => root.path.join("opencode.db"),
            _ => continue,
        };
        match read_openagent_sessions(adapter, &db_path, cutoff) {
            Ok(entries) => {
                catalog.files_seen += 1;
                catalog.sessions.extend(entries);
            }
            Err(skip) => {
                if db_path.exists() {
                    catalog.skipped.push(skip);
                }
            }
        }
    }
}

fn read_openagent_sessions(
    adapter: HistoryAdapter,
    db_path: &Path,
    cutoff: SystemTime,
) -> std::result::Result<Vec<CatalogSession>, Value> {
    let fail = |reason: &str| json!({"path": db_path.to_string_lossy(), "reason": reason});
    let connection =
        open_read_only_connection(db_path).ok_or_else(|| fail("openagent_state_open_failed"))?;
    if !sqlite_table_exists(&connection, "session") {
        return Err(fail("openagent_state_schema_unrecognized"));
    }
    let columns = sqlite_columns(&connection, "session")
        .map_err(|_| fail("openagent_state_schema_unrecognized"))?;
    for required in ["id", "time_updated"] {
        if !columns.contains(required) {
            return Err(fail("openagent_state_schema_unrecognized"));
        }
    }
    let optional_column = |name: &str| {
        if columns.contains(name) {
            name.to_string()
        } else {
            "NULL".to_string()
        }
    };
    let mut sql = format!(
        "SELECT id, {}, {}, {}, {}, time_updated FROM session WHERE time_updated >= ?1",
        optional_column("title"),
        optional_column("directory"),
        optional_column("model"),
        optional_column("time_created"),
    );
    if columns.contains("time_archived") {
        sql.push_str(" AND (time_archived IS NULL OR time_archived = 0)");
    }
    if matches!(adapter, HistoryAdapter::KiloCode | HistoryAdapter::OpenCode)
        && columns.contains("parent_id")
    {
        // Sub-agent sessions stay reachable through their parent's transcript.
        sql.push_str(" AND parent_id IS NULL");
    }
    sql.push_str(" ORDER BY time_updated DESC, id ASC");
    let cutoff_millis = cutoff
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0);
    let mut statement = connection
        .prepare(&sql)
        .map_err(|_| fail("openagent_state_schema_unrecognized"))?;
    let rows = statement
        .query_map([cutoff_millis], |row| {
            Ok(CatalogSession {
                native_session_id: row.get(0)?,
                source_path: db_path.to_path_buf(),
                source_kind: match adapter {
                    HistoryAdapter::KiloCode => "kilo-session-database".to_string(),
                    _ => "opencode-session-database".to_string(),
                },
                title: row
                    .get::<_, Option<String>>(1)?
                    .filter(|value| !value.trim().is_empty()),
                created_at: row.get::<_, Option<i64>>(4)?.and_then(epoch_to_system_time),
                updated_at: row.get::<_, Option<i64>>(5)?.and_then(epoch_to_system_time),
                working_directory: row
                    .get::<_, Option<String>>(2)?
                    .filter(|value| !value.trim().is_empty()),
                message_count: None,
                model: row
                    .get::<_, Option<String>>(3)?
                    .filter(|value| !value.trim().is_empty()),
                hydrate: CatalogHydration::None,
            })
        })
        .map_err(|_| fail("openagent_state_read_failed"))?;
    let mut entries = Vec::new();
    for row in rows {
        entries.push(row.map_err(|_| fail("openagent_state_read_failed"))?);
    }
    Ok(entries)
}

// ---------------------------------------------------------------------------
// Copilot: session-store.db rows backed by an on-disk session-state directory.
// ---------------------------------------------------------------------------

fn copilot_catalog(roots: &[HistoryRoot], cutoff: SystemTime, catalog: &mut SessionCatalog) {
    for root in roots {
        match root.source_kind.as_str() {
            "copilot-cli-session-store" => copilot_sqlite_catalog(root, cutoff, catalog),
            _ => generic_file_root_catalog(HistoryAdapter::Copilot, root, cutoff, catalog),
        }
    }
}

fn copilot_sqlite_catalog(root: &HistoryRoot, cutoff: SystemTime, catalog: &mut SessionCatalog) {
    let session_state_dir = &root.path;
    let Some(copilot_home) = session_state_dir.parent() else {
        return;
    };
    let db_path = copilot_home.join("session-store.db");
    if !db_path.is_file() {
        return;
    }
    match read_copilot_sessions(&db_path, session_state_dir, cutoff) {
        Ok(entries) => {
            catalog.files_seen += 1;
            catalog.sessions.extend(entries);
        }
        Err(skip) => catalog.skipped.push(skip),
    }
}

fn read_copilot_sessions(
    db_path: &Path,
    session_state_dir: &Path,
    cutoff: SystemTime,
) -> std::result::Result<Vec<CatalogSession>, Value> {
    let fail = |reason: &str| json!({"path": db_path.to_string_lossy(), "reason": reason});
    let connection =
        open_read_only_connection(db_path).ok_or_else(|| fail("copilot_state_open_failed"))?;
    if !sqlite_table_exists(&connection, "sessions") {
        return Err(fail("copilot_state_schema_unrecognized"));
    }
    let columns = sqlite_columns(&connection, "sessions")
        .map_err(|_| fail("copilot_state_schema_unrecognized"))?;
    for required in ["id", "updated_at"] {
        if !columns.contains(required) {
            return Err(fail("copilot_state_schema_unrecognized"));
        }
    }
    let optional_column = |name: &str| {
        if columns.contains(name) {
            name.to_string()
        } else {
            "NULL".to_string()
        }
    };
    let sql = format!(
        "SELECT id, {}, {}, {}, updated_at FROM sessions WHERE updated_at >= ?1 ORDER BY updated_at DESC, id ASC",
        optional_column("cwd"),
        optional_column("summary"),
        optional_column("created_at"),
    );
    let cutoff_text = system_time(cutoff);
    let mut statement = connection
        .prepare(&sql)
        .map_err(|_| fail("copilot_state_schema_unrecognized"))?;
    let rows = statement
        .query_map([cutoff_text], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })
        .map_err(|_| fail("copilot_state_read_failed"))?;
    let mut entries = Vec::new();
    for row in rows {
        let (id, cwd, summary, created_at, updated_at) =
            row.map_err(|_| fail("copilot_state_read_failed"))?;
        // The store can hold sessions whose on-disk state is gone (for example
        // remote sessions); only locally resumable sessions are listed.
        let state_dir = session_state_dir.join(&id);
        if !state_dir.is_dir() {
            continue;
        }
        let title = summary
            .filter(|value| !value.trim().is_empty())
            .or_else(|| workspace_yaml_title(&state_dir.join("workspace.yaml")));
        entries.push(CatalogSession {
            native_session_id: id,
            source_path: state_dir,
            source_kind: "copilot-cli-session-store".to_string(),
            title,
            created_at: created_at.as_deref().and_then(rfc3339_to_system_time),
            updated_at: updated_at.as_deref().and_then(rfc3339_to_system_time),
            working_directory: cwd.filter(|value| !value.trim().is_empty()),
            message_count: None,
            model: None,
            hydrate: CatalogHydration::None,
        });
    }
    Ok(entries)
}

fn workspace_yaml_title(path: &Path) -> Option<String> {
    let raw = fs::read_to_string(path).ok()?;
    for line in raw.lines().take(64) {
        let trimmed = line.trim();
        for key in ["name:", "title:"] {
            if let Some(value) = trimmed.strip_prefix(key) {
                let value = value.trim().trim_matches('"').trim_matches('\'');
                if !value.is_empty() {
                    return Some(value.to_string());
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Kimi Code: one state.json per session directory; wire files only for pages.
// ---------------------------------------------------------------------------

fn kimi_code_catalog(roots: &[HistoryRoot], cutoff: SystemTime, catalog: &mut SessionCatalog) {
    for root in roots {
        if root.source_kind != "kimi-code-session-store" {
            continue;
        }
        let mut state_files = Vec::<PathBuf>::new();
        collect_named_files(&root.path, "state.json", 0, catalog, &mut state_files);
        for path in state_files {
            catalog.files_seen += 1;
            match read_kimi_state(&path) {
                Some(entry) => {
                    if entry.recency() >= cutoff {
                        catalog.sessions.push(entry);
                    }
                }
                None => catalog.skipped.push(json!({
                    "path": path.to_string_lossy(),
                    "reason": "kimi_state_unreadable"
                })),
            }
        }
    }
}

fn read_kimi_state(path: &Path) -> Option<CatalogSession> {
    if fs::metadata(path).ok()?.len() > MAX_STATE_FILE_BYTES {
        return None;
    }
    let raw = fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&raw).ok()?;
    let session_dir = path.parent()?.to_path_buf();
    let native_session_id = session_dir.file_name()?.to_str()?.to_string();
    let wire = kimi_wire_files(&session_dir).into_iter().next();
    Some(CatalogSession {
        native_session_id,
        source_path: wire.unwrap_or_else(|| path.to_path_buf()),
        source_kind: "kimi-code-session-store".to_string(),
        title: value
            .get("title")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string),
        created_at: value
            .get("createdAt")
            .and_then(Value::as_str)
            .and_then(rfc3339_to_system_time),
        updated_at: value
            .get("updatedAt")
            .and_then(Value::as_str)
            .and_then(rfc3339_to_system_time),
        working_directory: value
            .get("workDir")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string),
        message_count: None,
        model: None,
        hydrate: CatalogHydration::KimiWireDirectory(session_dir),
    })
}

// ---------------------------------------------------------------------------
// Cursor CLI: per-chat meta.json catalogs (content blobs stay deferred).
// ---------------------------------------------------------------------------

fn cursor_catalog(roots: &[HistoryRoot], cutoff: SystemTime, catalog: &mut SessionCatalog) {
    // Prefer roots that already know the project path before walking IDE
    // storage trees that share the catalog directory-entry budget.
    for root in roots {
        match root.source_kind.as_str() {
            "cursor-cli-chats" => cursor_cli_meta_catalog(root, cutoff, catalog),
            "cursor-cli-projects" => cursor_cli_projects_catalog(root, cutoff, catalog),
            _ => {}
        }
    }
    for root in roots {
        match root.source_kind.as_str() {
            "cursor-workspace-storage" | "cursor-global-storage" => {
                generic_file_root_catalog(HistoryAdapter::Cursor, root, cutoff, catalog);
            }
            _ => {}
        }
    }
}

fn cursor_cli_projects_catalog(root: &HistoryRoot, cutoff: SystemTime, catalog: &mut SessionCatalog) {
    let discovery = discover_history_files(
        HistoryAdapter::Cursor,
        std::slice::from_ref(root),
        HistoryDiscoveryOptions::default(),
    );
    catalog.files_seen += discovery.files_seen;
    catalog.directory_entries_seen += discovery.directory_entries_seen;
    catalog.skipped.extend(discovery.skipped);
    for candidate in discovery.candidates {
        if candidate.modified_at < cutoff {
            continue;
        }
        let native_session_id = candidate
            .path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        catalog.sessions.push(CatalogSession {
            native_session_id,
            source_path: candidate.path.clone(),
            source_kind: candidate.source_kind,
            title: None,
            created_at: None,
            updated_at: Some(candidate.modified_at),
            working_directory: cursor_project_workspace_path(&candidate.path),
            message_count: None,
            model: None,
            hydrate: CatalogHydration::File(candidate.path),
        });
    }
}

/// Cursor CLI project trees record the trusted workspace in
/// `.workspace-trusted`. Walk from the history file up to that marker so agent
/// transcripts inherit the real project path instead of leaving cwd empty.
fn cursor_project_workspace_path(source_path: &Path) -> Option<String> {
    for ancestor in source_path.ancestors().take(8) {
        let trusted = ancestor.join(".workspace-trusted");
        if !trusted.is_file() {
            continue;
        }
        if fs::metadata(&trusted)
            .ok()
            .is_some_and(|metadata| metadata.len() > MAX_STATE_FILE_BYTES)
        {
            continue;
        }
        let raw = fs::read_to_string(&trusted).ok()?;
        let value = serde_json::from_str::<Value>(&raw).ok()?;
        let path = value
            .get("workspacePath")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())?;
        return Some(path.to_string());
    }
    None
}

fn cursor_cli_meta_catalog(root: &HistoryRoot, cutoff: SystemTime, catalog: &mut SessionCatalog) {
    let mut meta_files = Vec::<PathBuf>::new();
    collect_named_files(&root.path, "meta.json", 0, catalog, &mut meta_files);
    for path in meta_files {
        catalog.files_seen += 1;
        let Some(entry) = read_cursor_cli_meta(&path) else {
            catalog.skipped.push(json!({
                "path": path.to_string_lossy(),
                "reason": "cursor_cli_meta_unreadable"
            }));
            continue;
        };
        if entry.recency() >= cutoff {
            catalog.sessions.push(entry);
        }
    }
}

fn read_cursor_cli_meta(path: &Path) -> Option<CatalogSession> {
    if fs::metadata(path).ok()?.len() > MAX_STATE_FILE_BYTES {
        return None;
    }
    let raw = fs::read_to_string(path).ok()?;
    let value = serde_json::from_str::<Value>(&raw).ok()?;
    if value.get("hasConversation").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let native_session_id = path.parent()?.file_name()?.to_str()?.to_string();
    Some(CatalogSession {
        native_session_id,
        source_path: path.to_path_buf(),
        source_kind: "cursor-cli-chats".to_string(),
        title: None,
        created_at: value
            .get("createdAtMs")
            .and_then(Value::as_i64)
            .and_then(epoch_to_system_time),
        updated_at: value
            .get("updatedAtMs")
            .and_then(Value::as_i64)
            .and_then(epoch_to_system_time),
        working_directory: value
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_string),
        message_count: None,
        model: None,
        hydrate: CatalogHydration::None,
    })
}

// ---------------------------------------------------------------------------
// Claude Code: one transcript per session; titles from a bounded head probe.
// ---------------------------------------------------------------------------

fn claude_catalog(roots: &[HistoryRoot], cutoff: SystemTime, catalog: &mut SessionCatalog) {
    for root in roots {
        let discovery = discover_history_files(
            HistoryAdapter::ClaudeCode,
            std::slice::from_ref(root),
            HistoryDiscoveryOptions::default(),
        );
        catalog.files_seen += discovery.files_seen;
        catalog.directory_entries_seen += discovery.directory_entries_seen;
        catalog.skipped.extend(discovery.skipped);
        for candidate in discovery.candidates {
            if candidate.modified_at < cutoff {
                continue;
            }
            let native_session_id = candidate
                .path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or_default()
                .to_string();
            catalog.sessions.push(CatalogSession {
                native_session_id,
                source_path: candidate.path.clone(),
                source_kind: candidate.source_kind,
                title: claude_head_title(&candidate.path),
                created_at: None,
                updated_at: Some(candidate.modified_at),
                working_directory: None,
                message_count: None,
                model: None,
                hydrate: CatalogHydration::File(candidate.path),
            });
        }
    }
}

/// Cheap title probe: scan only a bounded head prefix of the transcript for the
/// first summary or user line instead of parsing the session content.
fn claude_head_title(path: &Path) -> Option<String> {
    let file = fs::File::open(path).ok()?;
    let mut reader = BufReader::new(file);
    let mut head = Vec::new();
    reader
        .by_ref()
        .take(MAX_TITLE_PROBE_BYTES)
        .read_to_end(&mut head)
        .ok()?;
    let head = String::from_utf8_lossy(&head);
    for line in head.lines().take(MAX_TITLE_PROBE_LINES) {
        if line.len() > MAX_TITLE_PROBE_LINE_BYTES {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("summary") => {
                if let Some(summary) = value
                    .get("summary")
                    .and_then(Value::as_str)
                    .filter(|value| !value.trim().is_empty())
                {
                    return Some(title_from_text(summary));
                }
            }
            Some("user") => {
                let message = value.get("message")?;
                let text = match message.get("content") {
                    Some(Value::String(text)) => Some(text.clone()),
                    Some(Value::Array(blocks)) => blocks.iter().find_map(|block| {
                        (block.get("type").and_then(Value::as_str) == Some("text"))
                            .then(|| block.get("text").and_then(Value::as_str))
                            .flatten()
                            .map(str::to_string)
                    }),
                    _ => None,
                };
                if let Some(text) = text.filter(|value| !value.trim().is_empty()) {
                    return Some(title_from_text(&text));
                }
            }
            _ => {}
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Pi: first-line session header plus file mtime.
// ---------------------------------------------------------------------------

fn pi_catalog(roots: &[HistoryRoot], cutoff: SystemTime, catalog: &mut SessionCatalog) {
    for root in roots {
        let discovery = discover_history_files(
            HistoryAdapter::Pi,
            std::slice::from_ref(root),
            HistoryDiscoveryOptions::default(),
        );
        catalog.files_seen += discovery.files_seen;
        catalog.directory_entries_seen += discovery.directory_entries_seen;
        catalog.skipped.extend(discovery.skipped);
        for candidate in discovery.candidates {
            if candidate.modified_at < cutoff {
                continue;
            }
            let (native_session_id, created_at, working_directory) = pi_header(&candidate.path);
            catalog.sessions.push(CatalogSession {
                native_session_id,
                source_path: candidate.path.clone(),
                source_kind: candidate.source_kind,
                title: None,
                created_at,
                updated_at: Some(candidate.modified_at),
                working_directory,
                message_count: None,
                model: None,
                hydrate: CatalogHydration::File(candidate.path),
            });
        }
    }
}

fn pi_header(path: &Path) -> (String, Option<SystemTime>, Option<String>) {
    let fallback_id = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_string();
    let Some(file) = fs::File::open(path).ok() else {
        return (fallback_id, None, None);
    };
    let Some(Ok(line)) = BufReader::new(file).lines().next() else {
        return (fallback_id, None, None);
    };
    let Ok(value) = serde_json::from_str::<Value>(&line) else {
        return (fallback_id, None, None);
    };
    if value.get("type").and_then(Value::as_str) != Some("session") {
        return (fallback_id, None, None);
    }
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .unwrap_or(&fallback_id)
        .to_string();
    let created_at = value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(rfc3339_to_system_time);
    let cwd = value
        .get("cwd")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string);
    (id, created_at, cwd)
}

// ---------------------------------------------------------------------------
// Generic file-metadata catalog for adapters without a native index.
// ---------------------------------------------------------------------------

fn generic_file_catalog(
    adapter: HistoryAdapter,
    roots: &[HistoryRoot],
    cutoff: SystemTime,
    catalog: &mut SessionCatalog,
) {
    for root in roots {
        generic_file_root_catalog(adapter, root, cutoff, catalog);
    }
}

fn generic_file_root_catalog(
    adapter: HistoryAdapter,
    root: &HistoryRoot,
    cutoff: SystemTime,
    catalog: &mut SessionCatalog,
) {
    let discovery = discover_history_files(
        adapter,
        std::slice::from_ref(root),
        HistoryDiscoveryOptions::default(),
    );
    catalog.files_seen += discovery.files_seen;
    catalog.directory_entries_seen += discovery.directory_entries_seen;
    catalog.skipped.extend(discovery.skipped);
    for candidate in discovery.candidates {
        if candidate.modified_at < cutoff {
            continue;
        }
        let native_session_id = candidate
            .path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_string();
        catalog.sessions.push(CatalogSession {
            native_session_id,
            source_path: candidate.path.clone(),
            source_kind: candidate.source_kind,
            title: None,
            created_at: None,
            updated_at: Some(candidate.modified_at),
            working_directory: None,
            message_count: None,
            model: None,
            hydrate: CatalogHydration::File(candidate.path),
        });
    }
}

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

fn collect_named_files(
    dir: &Path,
    name: &str,
    depth: usize,
    catalog: &mut SessionCatalog,
    out: &mut Vec<PathBuf>,
) {
    if depth >= MAX_CATALOG_WALK_DEPTH
        || catalog.directory_entries_seen >= MAX_CATALOG_DIRECTORY_ENTRIES
    {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        if catalog.directory_entries_seen >= MAX_CATALOG_DIRECTORY_ENTRIES {
            return;
        }
        catalog.directory_entries_seen += 1;
        let path = entry.path();
        if path.is_dir() {
            collect_named_files(&path, name, depth + 1, catalog, out);
        } else if entry.file_name().to_str() == Some(name) {
            out.push(path);
        }
    }
}

fn sqlite_columns(
    connection: &Connection,
    table: &str,
) -> std::result::Result<HashSet<String>, rusqlite::Error> {
    // Table names are compile-time constants at every call site.
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect()
}

fn rfc3339_to_system_time(value: &str) -> Option<SystemTime> {
    OffsetDateTime::parse(value.trim(), &Rfc3339)
        .ok()
        .map(SystemTime::from)
}

fn epoch_to_system_time(value: i64) -> Option<SystemTime> {
    epoch_number_to_rfc3339(value).and_then(|text| rfc3339_to_system_time(&text))
}
