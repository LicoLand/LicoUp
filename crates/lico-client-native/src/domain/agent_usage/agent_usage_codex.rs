use super::{
    HistoryUsageSummary, UNATTRIBUTED_MODEL, UsageWindow, bool_param, client_state_store,
    estimate_tokens, expand_user_path, number_field, resolve_codex_home, text_field, text_param,
};
use crate::domain::conversations;
use anyhow::{Context, Result};
use rusqlite::{
    Connection, ErrorCode, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};
#[cfg(windows)]
use std::os::windows::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const CACHE_SCHEMA_VERSION: i64 = 7;
const PARSER_REVISION: &str = "codex-token-events-v8";
const CACHE_REFRESH_INTERVAL: Duration = Duration::from_secs(60);
const CACHE_DATABASE_PREFIX: &str = "agent-usage-cache-v2";
const LEGACY_CACHE_DATABASE_NAME: &str = "agent-usage-cache.sqlite3";
const CONTENT_GUARD_BUFFER_BYTES: usize = 256 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct TokenTotals {
    input: u64,
    cached: u64,
    output: u64,
}

impl TokenTotals {
    fn from_value(value: &Value) -> Option<Self> {
        let input = number_field(
            value,
            &[
                "input_tokens",
                "inputTokens",
                "prompt_tokens",
                "promptTokens",
            ],
        );
        let cached = number_field(
            value,
            &[
                "cached_input_tokens",
                "cachedInputTokens",
                "cache_read_input_tokens",
                "cacheReadInputTokens",
            ],
        );
        let output = number_field(
            value,
            &[
                "output_tokens",
                "outputTokens",
                "completion_tokens",
                "completionTokens",
            ],
        );
        if input.is_none() && cached.is_none() && output.is_none() {
            return None;
        }
        let input = input.unwrap_or(0);
        Some(Self {
            input,
            cached: cached.unwrap_or(0).min(input),
            output: output.unwrap_or(0),
        })
    }

    fn saturating_delta(self, baseline: Self) -> Self {
        Self {
            input: self.input.saturating_sub(baseline.input),
            cached: self.cached.saturating_sub(baseline.cached),
            output: self.output.saturating_sub(baseline.output),
        }
    }

    fn add(self, delta: Self) -> Self {
        Self {
            input: self.input.saturating_add(delta.input),
            cached: self.cached.saturating_add(delta.cached),
            output: self.output.saturating_add(delta.output),
        }
    }

    fn is_zero(self) -> bool {
        self.input == 0 && self.cached == 0 && self.output == 0
    }

    fn at_least(self, other: Self) -> bool {
        self.input >= other.input && self.cached >= other.cached && self.output >= other.output
    }

    fn at_most(self, other: Self) -> bool {
        self.input <= other.input && self.cached <= other.cached && self.output <= other.output
    }
}

#[derive(Clone, Debug, Default)]
struct ParserState {
    session_id: Option<String>,
    forked_from_id: Option<String>,
    current_model: Option<String>,
    current_turn_id: Option<String>,
    raw_totals: Option<TokenTotals>,
    counted_totals: Option<TokenTotals>,
    has_divergent_totals: bool,
    next_event_index: u64,
    next_estimate_index: u64,
    token_chain_hash: String,
    estimate_chain_hash: String,
}

#[derive(Clone, Debug)]
struct CachedFile {
    modified_ns: u64,
    size: u64,
    file_id: Option<String>,
    parsed_bytes: u64,
    append_guard: String,
    state: ParserState,
}

#[derive(Clone, Debug)]
struct FileMetadata {
    modified_ns: u64,
    size: u64,
    file_id: Option<String>,
}

#[derive(Clone, Debug, Default)]
struct ScanStats {
    discovered_files: u64,
    reused_files: u64,
    appended_files: u64,
    rescanned_files: u64,
    parsed_bytes: u64,
    cache_fresh: bool,
    refresh_deferred: bool,
}

impl ScanStats {
    fn to_json(&self) -> Value {
        json!({
            "schemaVersion": CACHE_SCHEMA_VERSION,
            "parserRevision": PARSER_REVISION,
            "fresh": self.cache_fresh,
            "discoveredFiles": self.discovered_files,
            "reusedFiles": self.reused_files,
            "appendedFiles": self.appended_files,
            "rescannedFiles": self.rescanned_files,
            "parsedBytes": self.parsed_bytes,
            "refreshDeferred": self.refresh_deferred
        })
    }
}

#[derive(Debug)]
struct UsageRow {
    source_key: String,
    session_id: Option<String>,
    day: String,
    model: Option<String>,
    input: u64,
    cached: u64,
    output: u64,
}

#[derive(Debug)]
struct UsageEstimateRow {
    source_key: String,
    session_id: Option<String>,
    day: String,
    model: Option<String>,
    role: String,
    tokens: u64,
}

pub(super) fn summarize(
    scan_params: &Value,
    window: &UsageWindow,
    warnings: &mut Vec<Value>,
) -> Option<HistoryUsageSummary> {
    match summarize_inner(scan_params, window) {
        Ok(summary) if summary.explicit_records > 0 || summary.estimated_records > 0 => {
            Some(summary)
        }
        Ok(_) => None,
        Err(_) => {
            warnings.push(json!({
                "code": "codex_local_token_event_scan_failed",
                "agentId": "codex"
            }));
            None
        }
    }
}

fn summarize_inner(scan_params: &Value, window: &UsageWindow) -> Result<HistoryUsageSummary> {
    let roots = usage_roots(scan_params);
    if roots.is_empty() {
        return Ok(HistoryUsageSummary::default());
    }
    let root_key = roots_fingerprint(&roots, &window.cache_timezone_key());
    let store = client_state_store(scan_params)?;
    retire_legacy_cache(store.root());
    let database_path = store
        .root()
        .join(format!("{CACHE_DATABASE_PREFIX}-{root_key}.sqlite3"));
    let mut connection = open_cache_database(&database_path)?;
    let force_refresh = bool_param(scan_params, "forceRefresh").unwrap_or(false);
    let now_ms = unix_millis();

    if !force_refresh && cache_is_fresh(&connection, &root_key, now_ms)? {
        let stats = ScanStats {
            cache_fresh: true,
            ..ScanStats::default()
        };
        return aggregate_cached_usage(&mut connection, &root_key, window, stats);
    }

    let mut files = Vec::<PathBuf>::new();
    for root in &roots {
        collect_usage_files(root, &mut files);
    }
    files.sort();
    files.dedup();

    let mut stats = ScanStats {
        discovered_files: files.len() as u64,
        ..ScanStats::default()
    };
    let has_cached_snapshot = cache_snapshot_exists(&connection, &root_key)?;
    connection.busy_timeout(if has_cached_snapshot {
        Duration::from_millis(500)
    } else {
        Duration::from_secs(30)
    })?;
    let transaction_result = connection.transaction_with_behavior(TransactionBehavior::Immediate);
    let refresh_deferred = matches!(
        &transaction_result,
        Err(error) if has_cached_snapshot && sqlite_is_busy(error)
    );
    if refresh_deferred {
        drop(transaction_result);
        stats.refresh_deferred = true;
        return aggregate_cached_usage(&mut connection, &root_key, window, stats);
    }
    let transaction = transaction_result.context("agent usage cache transaction failed")?;

    let mut seen_source_keys = BTreeSet::<String>::new();
    for path in files {
        let Some(metadata) = file_metadata(&path) else {
            continue;
        };
        let source_key = source_key(&root_key, &path);
        seen_source_keys.insert(source_key.clone());
        let cached = load_cached_file(&transaction, &root_key, &source_key)?;
        if let Some(cached) = &cached
            && cached.modified_ns == metadata.modified_ns
            && cached.size == metadata.size
            && cached.file_id == metadata.file_id
            && (!force_refresh || append_guard_matches(&path, cached))
        {
            stats.reused_files += 1;
            continue;
        }

        let append_state = cached.as_ref().and_then(|cached| {
            if cached.file_id.is_none()
                || cached.file_id != metadata.file_id
                || metadata.size <= cached.size
                || cached.parsed_bytes > cached.size
            {
                return None;
            }
            let guard_state = content_guard_state(&path, cached.size).ok()?;
            (content_guard_digest(&guard_state) == cached.append_guard)
                .then_some((guard_state, cached.size))
        });
        let (start_offset, mut state, append_state) = if let Some(append_state) = append_state {
            stats.appended_files += 1;
            let cached = cached.expect("append cache checked above");
            (cached.parsed_bytes, cached.state, Some(append_state))
        } else {
            stats.rescanned_files += 1;
            transaction.execute(
                "DELETE FROM usage_rows WHERE root_key=?1 AND source_key=?2",
                params![root_key, source_key],
            )?;
            transaction.execute(
                "DELETE FROM usage_estimates WHERE root_key=?1 AND source_key=?2",
                params![root_key, source_key],
            )?;
            transaction.execute(
                "DELETE FROM usage_estimate_coverage WHERE root_key=?1 AND source_key=?2",
                params![root_key, source_key],
            )?;
            (0, ParserState::default(), None)
        };

        let parsed_bytes = parse_file(
            &transaction,
            &root_key,
            &source_key,
            &path,
            start_offset,
            window,
            &mut state,
        )?;
        stats.parsed_bytes = stats
            .parsed_bytes
            .saturating_add(parsed_bytes.saturating_sub(start_offset));
        let append_guard = if let Some((mut guard_state, guarded_bytes)) = append_state {
            extend_content_guard(&path, guarded_bytes, metadata.size, &mut guard_state)?;
            content_guard_digest(&guard_state)
        } else {
            append_guard(&path, metadata.size)?
        };
        save_cached_file(
            &transaction,
            &root_key,
            &source_key,
            &metadata,
            parsed_bytes,
            &append_guard,
            &state,
        )?;
    }

    let cached_keys = cached_source_keys(&transaction, &root_key)?;
    for source_key in cached_keys.difference(&seen_source_keys) {
        transaction.execute(
            "DELETE FROM usage_rows WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
        )?;
        transaction.execute(
            "DELETE FROM usage_estimates WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
        )?;
        transaction.execute(
            "DELETE FROM usage_estimate_coverage WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
        )?;
        transaction.execute(
            "DELETE FROM usage_files WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
        )?;
    }
    reconcile_lineage_scopes(&transaction, &root_key)?;
    transaction.execute(
        "INSERT INTO usage_scans(root_key, last_scan_ms) VALUES(?1, ?2) \
         ON CONFLICT(root_key) DO UPDATE SET last_scan_ms=excluded.last_scan_ms",
        params![root_key, to_i64(now_ms)],
    )?;
    transaction.commit()?;

    aggregate_cached_usage(&mut connection, &root_key, window, stats)
}

fn open_cache_database(path: &Path) -> Result<Connection> {
    let mut connection = Connection::open(path).context("agent usage cache open failed")?;
    connection.busy_timeout(Duration::from_secs(30))?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    let observed_version =
        connection.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?;
    if observed_version != CACHE_SCHEMA_VERSION {
        let migration = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .context("agent usage cache schema transaction failed")?;
        let locked_version =
            migration.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?;
        if locked_version != CACHE_SCHEMA_VERSION {
            migration.execute_batch(
                "DROP TABLE IF EXISTS usage_rows;
                 DROP TABLE IF EXISTS usage_estimates;
                 DROP TABLE IF EXISTS usage_estimate_coverage;
                 DROP TABLE IF EXISTS usage_files;
                 DROP TABLE IF EXISTS usage_scans;
                 CREATE TABLE usage_files (
                   root_key TEXT NOT NULL,
                   source_key TEXT NOT NULL,
                   modified_ns INTEGER NOT NULL,
                   size INTEGER NOT NULL,
                   file_id TEXT,
                   parsed_bytes INTEGER NOT NULL,
                   append_guard TEXT NOT NULL,
                   session_id TEXT,
                   forked_from_id TEXT,
                   lineage_scope TEXT NOT NULL,
                   last_model TEXT,
                   current_turn_id TEXT,
                   raw_input INTEGER,
                   raw_cached INTEGER,
                   raw_output INTEGER,
                   counted_input INTEGER,
                   counted_cached INTEGER,
                   counted_output INTEGER,
                   divergent INTEGER NOT NULL DEFAULT 0,
                   next_event_index INTEGER NOT NULL DEFAULT 0,
                   next_estimate_index INTEGER NOT NULL DEFAULT 0,
                   token_chain_hash TEXT NOT NULL DEFAULT '',
                   estimate_chain_hash TEXT NOT NULL DEFAULT '',
                   PRIMARY KEY(root_key, source_key)
                 );
                 CREATE TABLE usage_rows (
                   root_key TEXT NOT NULL,
                   source_key TEXT NOT NULL,
                   event_index INTEGER NOT NULL,
                   session_id TEXT,
                   turn_id TEXT,
                   day TEXT NOT NULL,
                   model TEXT,
                   input_tokens INTEGER NOT NULL,
                   cached_input_tokens INTEGER NOT NULL,
                   output_tokens INTEGER NOT NULL,
                   event_identity TEXT NOT NULL,
                   PRIMARY KEY(root_key, source_key, event_index)
                 );
                 CREATE INDEX usage_rows_window
                   ON usage_rows(root_key, day);
                 CREATE INDEX usage_rows_identity
                   ON usage_rows(root_key, event_identity);
                 CREATE TABLE usage_estimates (
                   root_key TEXT NOT NULL,
                   source_key TEXT NOT NULL,
                   estimate_index INTEGER NOT NULL,
                   session_id TEXT,
                   day TEXT NOT NULL,
                   model TEXT,
                   role TEXT NOT NULL,
                   estimated_tokens INTEGER NOT NULL,
                   event_identity TEXT NOT NULL,
                   PRIMARY KEY(root_key, source_key, estimate_index)
                 );
                 CREATE INDEX usage_estimates_window
                   ON usage_estimates(root_key, day);
                 CREATE INDEX usage_estimates_identity
                   ON usage_estimates(root_key, event_identity);
                 CREATE TABLE usage_estimate_coverage (
                   root_key TEXT NOT NULL,
                   source_key TEXT NOT NULL,
                   event_identity TEXT NOT NULL,
                   PRIMARY KEY(root_key, source_key, event_identity)
                 );
                 CREATE INDEX usage_estimate_coverage_identity
                   ON usage_estimate_coverage(root_key, event_identity);
                 CREATE TABLE usage_scans (
                   root_key TEXT PRIMARY KEY,
                   last_scan_ms INTEGER NOT NULL
                 );",
            )?;
            migration.pragma_update(None, "user_version", CACHE_SCHEMA_VERSION)?;
        }
        migration
            .commit()
            .context("agent usage cache schema commit failed")?;
    }
    #[cfg(unix)]
    if path.exists() {
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(connection)
}

fn retire_legacy_cache(root: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let path = root.join(format!("{LEGACY_CACHE_DATABASE_NAME}{suffix}"));
        match fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => {}
        }
    }
}

fn sqlite_is_busy(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(code, _)
            if matches!(code.code, ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
    )
}

fn cache_snapshot_exists(connection: &Connection, root_key: &str) -> Result<bool> {
    connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM usage_files WHERE root_key=?1 LIMIT 1)",
            [root_key],
            |row| row.get::<_, bool>(0),
        )
        .map_err(Into::into)
}

fn cache_is_fresh(connection: &Connection, root_key: &str, now_ms: u64) -> Result<bool> {
    let last_scan = connection
        .query_row(
            "SELECT last_scan_ms FROM usage_scans WHERE root_key=?1",
            [root_key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .unwrap_or(0)
        .max(0) as u64;
    Ok(last_scan > 0
        && now_ms.saturating_sub(last_scan) < CACHE_REFRESH_INTERVAL.as_millis() as u64)
}

fn usage_roots(scan_params: &Value) -> Vec<PathBuf> {
    if let Some(root) = text_param(scan_params, &["root", "historyRoot"]) {
        return vec![expand_user_path(&root)];
    }
    let Some(home) = resolve_codex_home(scan_params) else {
        return Vec::new();
    };
    vec![home.join("sessions"), home.join("archived_sessions")]
}

fn roots_fingerprint(roots: &[PathBuf], timezone_key: &str) -> String {
    let mut values = roots
        .iter()
        .map(|path| path.to_string_lossy().to_string())
        .collect::<Vec<_>>();
    values.sort();
    hash_text(&format!("tz={timezone_key};roots={}", values.join("\n")))
}

fn source_key(root_key: &str, path: &Path) -> String {
    hash_text(&format!("{root_key}\n{}", path.to_string_lossy()))
}

fn hash_text(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn collect_usage_files(path: &Path, files: &mut Vec<PathBuf>) {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return;
    };
    if metadata.file_type().is_symlink() {
        return;
    }
    if metadata.is_dir() {
        let Ok(entries) = fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            collect_usage_files(&entry.path(), files);
        }
        return;
    }
    if !metadata.is_file() {
        return;
    }
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if matches!(extension.as_str(), "jsonl" | "ndjson") {
        files.push(path.to_path_buf());
    }
}

fn file_metadata(path: &Path) -> Option<FileMetadata> {
    let metadata = fs::metadata(path).ok()?;
    let modified_ns = metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_nanos()
        .min(u64::MAX as u128) as u64;
    #[cfg(unix)]
    let file_id = Some(format!("{}:{}", metadata.dev(), metadata.ino()));
    #[cfg(windows)]
    let file_id =
        (metadata.creation_time() > 0).then(|| format!("windows:{}", metadata.creation_time()));
    #[cfg(not(any(unix, windows)))]
    let file_id = None;
    Some(FileMetadata {
        modified_ns,
        size: metadata.len(),
        file_id,
    })
}

fn append_guard_matches(path: &Path, cached: &CachedFile) -> bool {
    !cached.append_guard.is_empty()
        && content_guard_state(path, cached.size)
            .map(|state| content_guard_digest(&state) == cached.append_guard)
            .unwrap_or(false)
}

fn append_guard(path: &Path, guarded_bytes: u64) -> Result<String> {
    content_guard_state(path, guarded_bytes).map(|state| content_guard_digest(&state))
}

fn content_guard_state(path: &Path, guarded_bytes: u64) -> Result<Sha256> {
    let mut file = fs::File::open(path).context("Codex usage append guard open failed")?;
    let file_size = file.metadata()?.len();
    if guarded_bytes > file_size {
        anyhow::bail!("Codex usage append guard exceeds file length");
    }
    let mut hasher = Sha256::new();
    hasher.update(b"codex-content-guard-v2\0");
    read_content_guard(&mut file, guarded_bytes, &mut hasher)?;
    Ok(hasher)
}

fn extend_content_guard(
    path: &Path,
    guarded_bytes: u64,
    target_bytes: u64,
    hasher: &mut Sha256,
) -> Result<()> {
    if target_bytes < guarded_bytes {
        anyhow::bail!("Codex usage append guard target precedes cached length");
    }
    let mut file = fs::File::open(path).context("Codex usage append guard open failed")?;
    if file.metadata()?.len() < target_bytes {
        anyhow::bail!("Codex usage append guard exceeds file length");
    }
    file.seek(SeekFrom::Start(guarded_bytes))?;
    read_content_guard(
        &mut file,
        target_bytes.saturating_sub(guarded_bytes),
        hasher,
    )
}

fn read_content_guard(file: &mut fs::File, mut remaining: u64, hasher: &mut Sha256) -> Result<()> {
    let mut buffer = vec![0_u8; CONTENT_GUARD_BUFFER_BYTES];
    while remaining > 0 {
        let requested = remaining.min(buffer.len() as u64) as usize;
        file.read_exact(&mut buffer[..requested])?;
        hasher.update(&buffer[..requested]);
        remaining = remaining.saturating_sub(requested as u64);
    }
    Ok(())
}

fn content_guard_digest(hasher: &Sha256) -> String {
    format!("{:x}", hasher.clone().finalize())
}

fn load_cached_file(
    transaction: &Transaction<'_>,
    root_key: &str,
    source_key: &str,
) -> Result<Option<CachedFile>> {
    transaction
        .query_row(
            "SELECT modified_ns, size, file_id, parsed_bytes, append_guard, session_id, forked_from_id,
                    last_model, current_turn_id, raw_input, raw_cached, raw_output,
                    counted_input, counted_cached, counted_output, divergent, next_event_index,
                    next_estimate_index, token_chain_hash, estimate_chain_hash
             FROM usage_files WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
            |row| {
                let raw_values = (
                    row.get::<_, Option<i64>>(9)?,
                    row.get::<_, Option<i64>>(10)?,
                    row.get::<_, Option<i64>>(11)?,
                );
                let counted_values = (
                    row.get::<_, Option<i64>>(12)?,
                    row.get::<_, Option<i64>>(13)?,
                    row.get::<_, Option<i64>>(14)?,
                );
                Ok(CachedFile {
                    modified_ns: from_i64(row.get(0)?),
                    size: from_i64(row.get(1)?),
                    file_id: row.get(2)?,
                    parsed_bytes: from_i64(row.get(3)?),
                    append_guard: row.get(4)?,
                    state: ParserState {
                        session_id: row.get(5)?,
                        forked_from_id: row.get(6)?,
                        current_model: row.get(7)?,
                        current_turn_id: row.get(8)?,
                        raw_totals: totals_from_columns(raw_values),
                        counted_totals: totals_from_columns(counted_values),
                        has_divergent_totals: row.get::<_, i64>(15)? != 0,
                        next_event_index: from_i64(row.get(16)?),
                        next_estimate_index: from_i64(row.get(17)?),
                        token_chain_hash: row.get(18)?,
                        estimate_chain_hash: row.get(19)?,
                    },
                })
            },
        )
        .optional()
        .map_err(Into::into)
}

fn save_cached_file(
    transaction: &Transaction<'_>,
    root_key: &str,
    source_key: &str,
    metadata: &FileMetadata,
    parsed_bytes: u64,
    append_guard: &str,
    state: &ParserState,
) -> Result<()> {
    let (raw_input, raw_cached, raw_output) = totals_columns(state.raw_totals);
    let (counted_input, counted_cached, counted_output) = totals_columns(state.counted_totals);
    let initial_lineage_scope = state
        .forked_from_id
        .as_deref()
        .or(state.session_id.as_deref())
        .map(|session_id| format!("session:{session_id}"))
        .unwrap_or_else(|| format!("source:{source_key}"));
    transaction.execute(
        "INSERT INTO usage_files(
           root_key, source_key, modified_ns, size, file_id, parsed_bytes, append_guard, session_id,
           forked_from_id, lineage_scope, last_model, current_turn_id, raw_input, raw_cached, raw_output,
           counted_input, counted_cached, counted_output, divergent, next_event_index,
           next_estimate_index, token_chain_hash, estimate_chain_hash
         ) VALUES(
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23
         ) ON CONFLICT(root_key, source_key) DO UPDATE SET
           modified_ns=excluded.modified_ns,
           size=excluded.size,
           file_id=excluded.file_id,
           parsed_bytes=excluded.parsed_bytes,
           append_guard=excluded.append_guard,
           session_id=excluded.session_id,
           forked_from_id=excluded.forked_from_id,
           lineage_scope=excluded.lineage_scope,
           last_model=excluded.last_model,
           current_turn_id=excluded.current_turn_id,
           raw_input=excluded.raw_input,
           raw_cached=excluded.raw_cached,
           raw_output=excluded.raw_output,
           counted_input=excluded.counted_input,
           counted_cached=excluded.counted_cached,
           counted_output=excluded.counted_output,
           divergent=excluded.divergent,
           next_event_index=excluded.next_event_index,
           next_estimate_index=excluded.next_estimate_index,
           token_chain_hash=excluded.token_chain_hash,
           estimate_chain_hash=excluded.estimate_chain_hash",
        params![
            root_key,
            source_key,
            to_i64(metadata.modified_ns),
            to_i64(metadata.size),
            metadata.file_id,
            to_i64(parsed_bytes),
            append_guard,
            state.session_id,
            state.forked_from_id,
            initial_lineage_scope,
            state.current_model,
            state.current_turn_id,
            raw_input,
            raw_cached,
            raw_output,
            counted_input,
            counted_cached,
            counted_output,
            i64::from(state.has_divergent_totals),
            to_i64(state.next_event_index),
            to_i64(state.next_estimate_index),
            state.token_chain_hash,
            state.estimate_chain_hash,
        ],
    )?;
    Ok(())
}

fn cached_source_keys(transaction: &Transaction<'_>, root_key: &str) -> Result<BTreeSet<String>> {
    let mut statement = transaction
        .prepare("SELECT source_key FROM usage_files WHERE root_key=?1 ORDER BY source_key")?;
    let rows = statement.query_map([root_key], |row| row.get::<_, String>(0))?;
    Ok(rows.filter_map(std::result::Result::ok).collect())
}

fn parse_file(
    transaction: &Transaction<'_>,
    root_key: &str,
    source_key: &str,
    path: &Path,
    start_offset: u64,
    window: &UsageWindow,
    state: &mut ParserState,
) -> Result<u64> {
    let mut file = fs::File::open(path).context("Codex usage file open failed")?;
    file.seek(SeekFrom::Start(start_offset))?;
    let mut reader = BufReader::new(file);
    let mut line = String::new();
    let mut parsed_bytes = start_offset;
    loop {
        line.clear();
        let line_start = reader.stream_position()?;
        let read = reader.read_line(&mut line)?;
        if read == 0 {
            break;
        }
        let complete_line =
            line.ends_with('\n') || serde_json::from_str::<Value>(line.trim()).is_ok();
        if !complete_line {
            return Ok(line_start);
        }
        parse_line(transaction, root_key, source_key, &line, window, state)?;
        parsed_bytes = reader.stream_position()?;
    }
    Ok(parsed_bytes)
}

fn parse_line(
    transaction: &Transaction<'_>,
    root_key: &str,
    source_key: &str,
    line: &str,
    window: &UsageWindow,
    state: &mut ParserState,
) -> Result<()> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
        return Ok(());
    };
    let event_type = value
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let payload = value.get("payload").unwrap_or(&Value::Null);
    if event_type == "session_meta" {
        if state.session_id.is_none() {
            state.session_id = text_field(payload, &["session_id", "sessionId", "id"])
                .or_else(|| text_field(&value, &["session_id", "sessionId", "id"]));
        }
        if state.forked_from_id.is_none() {
            state.forked_from_id = text_field(
                payload,
                &[
                    "forked_from_id",
                    "forkedFromId",
                    "parent_session_id",
                    "parentSessionId",
                ],
            );
        }
        return Ok(());
    }
    record_usage_estimate(transaction, root_key, source_key, &value, window, state)?;
    match event_type {
        "turn_context" => {
            if let Some(model) = text_field(
                payload,
                &["model", "model_name", "modelName", "model_id", "modelId"],
            ) {
                state.current_model = Some(model);
            }
            return Ok(());
        }
        "event_msg" => {}
        _ => return Ok(()),
    }
    let payload_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if payload_type == "task_started" {
        state.current_turn_id = turn_id(payload);
        return Ok(());
    }
    if payload_type != "token_count" {
        return Ok(());
    }
    let Some(info) = payload.get("info") else {
        return Ok(());
    };
    let total = info
        .get("total_token_usage")
        .and_then(TokenTotals::from_value);
    let last = info
        .get("last_token_usage")
        .and_then(TokenTotals::from_value);
    if total.is_none() && last.is_none() {
        return Ok(());
    }
    let Some(day) = text_field(&value, &["timestamp", "createdAt", "created_at"])
        .or_else(|| text_field(payload, &["timestamp", "createdAt", "created_at"]))
        .and_then(|value| window.date_key(&value))
    else {
        return Ok(());
    };
    let model = state
        .current_model
        .clone()
        .or_else(|| text_field(info, &["model", "model_name", "modelName"]))
        .or_else(|| text_field(payload, &["model", "model_name", "modelName"]));
    let raw_baseline = state.raw_totals;
    let counted_baseline = state.counted_totals.unwrap_or_default();
    let delta = match (last, total) {
        (Some(last), Some(total)) => {
            let total_delta = total.saturating_delta(raw_baseline.unwrap_or_default());
            if raw_baseline == Some(total) {
                TokenTotals::default()
            } else if raw_baseline.is_some()
                && !state.has_divergent_totals
                && total.at_least(raw_baseline.unwrap_or_default())
                && total_delta.at_most(last)
            {
                total_delta
            } else {
                last
            }
        }
        (Some(last), None) => last,
        (None, Some(total)) => {
            if let Some(raw_baseline) = raw_baseline {
                total.saturating_delta(raw_baseline)
            } else if state.forked_from_id.is_some() {
                TokenTotals::default()
            } else {
                total
            }
        }
        (None, None) => TokenTotals::default(),
    };
    if let Some(total) = total {
        state.raw_totals = Some(total);
    } else {
        state.raw_totals = Some(counted_baseline.add(delta));
    }
    state.counted_totals = Some(counted_baseline.add(delta));
    state.has_divergent_totals = state.raw_totals != state.counted_totals;
    if !delta.is_zero() || (raw_baseline.is_none() && total.is_some()) {
        transaction.execute(
            "INSERT OR IGNORE INTO usage_estimate_coverage(root_key, source_key, event_identity)
             SELECT root_key, source_key, event_identity
             FROM usage_estimates
             WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
        )?;
        transaction.execute(
            "DELETE FROM usage_estimates WHERE root_key=?1 AND source_key=?2",
            params![root_key, source_key],
        )?;
    }
    if delta.is_zero() {
        return Ok(());
    }
    let event_index = state.next_event_index;
    state.next_event_index = state.next_event_index.saturating_add(1);
    let event_identity = advance_event_chain(
        &mut state.token_chain_hash,
        b"codex-token-chain-v1\0",
        &value,
    );
    let session_id = state.session_id.clone();
    let turn_id = turn_id(payload).or_else(|| state.current_turn_id.clone());
    transaction.execute(
        "INSERT OR REPLACE INTO usage_rows(
           root_key, source_key, event_index, session_id, turn_id, day, model,
           input_tokens, cached_input_tokens, output_tokens, event_identity
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            root_key,
            source_key,
            to_i64(event_index),
            session_id,
            turn_id,
            day,
            model,
            to_i64(delta.input),
            to_i64(delta.cached.min(delta.input)),
            to_i64(delta.output),
            event_identity,
        ],
    )?;
    Ok(())
}

fn record_usage_estimate(
    transaction: &Transaction<'_>,
    root_key: &str,
    source_key: &str,
    value: &Value,
    window: &UsageWindow,
    state: &mut ParserState,
) -> Result<()> {
    let Some((role, text)) = conversations::codex_usage_estimate_message(value) else {
        return Ok(());
    };
    let Some(day) = text_field(value, &["timestamp", "createdAt", "created_at"])
        .and_then(|value| window.date_key(&value))
    else {
        return Ok(());
    };
    let tokens = estimate_tokens(&text);
    if tokens == 0 {
        return Ok(());
    }
    let estimate_index = state.next_estimate_index;
    state.next_estimate_index = state.next_estimate_index.saturating_add(1);
    let event_identity = advance_event_chain(
        &mut state.estimate_chain_hash,
        b"codex-estimate-chain-v1\0",
        value,
    );
    transaction.execute(
        "INSERT OR REPLACE INTO usage_estimates(
           root_key, source_key, estimate_index, session_id, day, model, role,
           estimated_tokens, event_identity
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
        params![
            root_key,
            source_key,
            to_i64(estimate_index),
            state.session_id,
            day,
            state.current_model,
            role,
            to_i64(tokens),
            event_identity,
        ],
    )?;
    Ok(())
}

fn advance_event_chain(chain_hash: &mut String, domain: &[u8], value: &Value) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hash_bytes(&mut hasher, b'p', chain_hash.as_bytes());
    hash_rollout_item(&mut hasher, value);
    let next = format!("{:x}", hasher.finalize());
    chain_hash.clone_from(&next);
    next
}

fn hash_rollout_item(hasher: &mut Sha256, value: &Value) {
    let Some(object) = value.as_object() else {
        hash_canonical_json(hasher, value);
        return;
    };
    let response_item = object.get("type").and_then(Value::as_str) == Some("response_item");
    let mut keys = object
        .keys()
        .filter(|key| key.as_str() != "timestamp")
        .collect::<Vec<_>>();
    keys.sort();
    hasher.update(b"o");
    hasher.update((keys.len() as u64).to_be_bytes());
    for key in keys {
        hash_bytes(hasher, b'k', key.as_bytes());
        let child = object.get(key).unwrap_or(&Value::Null);
        if response_item && key == "payload" {
            hash_response_payload(hasher, child);
        } else {
            hash_canonical_json(hasher, child);
        }
    }
}

fn hash_response_payload(hasher: &mut Sha256, value: &Value) {
    let Some(object) = value.as_object() else {
        hash_canonical_json(hasher, value);
        return;
    };
    let mut keys = object
        .keys()
        .filter(|key| key.as_str() != "id")
        .collect::<Vec<_>>();
    keys.sort();
    hasher.update(b"o");
    hasher.update((keys.len() as u64).to_be_bytes());
    for key in keys {
        hash_bytes(hasher, b'k', key.as_bytes());
        hash_canonical_json(hasher, object.get(key).unwrap_or(&Value::Null));
    }
}

fn hash_canonical_json(hasher: &mut Sha256, value: &Value) {
    match value {
        Value::Null => hasher.update(b"n"),
        Value::Bool(value) => hasher.update(if *value { b"t" } else { b"f" }),
        Value::Number(value) => hash_bytes(hasher, b'#', value.to_string().as_bytes()),
        Value::String(value) => hash_bytes(hasher, b's', value.as_bytes()),
        Value::Array(values) => {
            hasher.update(b"a");
            hasher.update((values.len() as u64).to_be_bytes());
            for value in values {
                hash_canonical_json(hasher, value);
            }
        }
        Value::Object(object) => {
            let mut keys = object.keys().collect::<Vec<_>>();
            keys.sort();
            hasher.update(b"o");
            hasher.update((keys.len() as u64).to_be_bytes());
            for key in keys {
                hash_bytes(hasher, b'k', key.as_bytes());
                hash_canonical_json(hasher, object.get(key).unwrap_or(&Value::Null));
            }
        }
    }
}

fn hash_bytes(hasher: &mut Sha256, tag: u8, value: &[u8]) {
    hasher.update([tag]);
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value);
}

fn session_lineage_parents(
    transaction: &Transaction<'_>,
    root_key: &str,
) -> Result<BTreeMap<String, String>> {
    let mut statement = transaction.prepare(
        "SELECT session_id, forked_from_id
         FROM usage_files
         WHERE root_key=?1 AND session_id IS NOT NULL AND forked_from_id IS NOT NULL
         ORDER BY source_key",
    )?;
    let rows = statement.query_map([root_key], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut candidates = BTreeMap::<String, BTreeSet<String>>::new();
    for row in rows {
        let (session_id, parent_id) = row?;
        if session_id.is_empty() || parent_id.is_empty() || session_id == parent_id {
            continue;
        }
        candidates.entry(session_id).or_default().insert(parent_id);
    }
    Ok(candidates
        .into_iter()
        .filter_map(|(session_id, parents)| {
            if parents.len() != 1 {
                return None;
            }
            parents
                .into_iter()
                .next()
                .map(|parent_id| (session_id, parent_id))
        })
        .collect())
}

fn reconcile_lineage_scopes(transaction: &Transaction<'_>, root_key: &str) -> Result<()> {
    let parents = session_lineage_parents(transaction, root_key)?;
    let files = {
        let mut statement = transaction.prepare(
            "SELECT source_key, session_id FROM usage_files WHERE root_key=?1 ORDER BY source_key",
        )?;
        let rows = statement.query_map([root_key], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (source_key, session_id) in files {
        let scope = lineage_scope(session_id.as_deref(), &source_key, &parents);
        transaction.execute(
            "UPDATE usage_files SET lineage_scope=?3 WHERE root_key=?1 AND source_key=?2 AND lineage_scope<>?3",
            params![root_key, source_key, scope],
        )?;
    }
    Ok(())
}

fn lineage_scope(
    session_id: Option<&str>,
    source_key: &str,
    parents: &BTreeMap<String, String>,
) -> String {
    let Some(session_id) = session_id.filter(|value| !value.is_empty()) else {
        return format!("source:{source_key}");
    };
    let mut current = session_id.to_string();
    let mut visited = BTreeSet::<String>::new();
    loop {
        if !visited.insert(current.clone()) {
            let root = visited
                .into_iter()
                .min()
                .unwrap_or_else(|| session_id.to_string());
            return format!("session:{root}");
        }
        let Some(parent) = parents.get(&current) else {
            return format!("session:{current}");
        };
        current.clone_from(parent);
    }
}

fn aggregate_cached_usage(
    connection: &mut Connection,
    root_key: &str,
    window: &UsageWindow,
    stats: ScanStats,
) -> Result<HistoryUsageSummary> {
    let snapshot = connection
        .transaction_with_behavior(TransactionBehavior::Deferred)
        .context("agent usage cache snapshot transaction failed")?;
    let mut summary = HistoryUsageSummary {
        source: Some("codex-local-token-events"),
        scan_cache: Some(stats.to_json()),
        ..HistoryUsageSummary::default()
    };
    let mut sessions = BTreeSet::<String>::new();
    {
        let mut statement = snapshot.prepare(
            "SELECT r.source_key, r.session_id, r.day, r.model,
                    r.input_tokens, r.cached_input_tokens, r.output_tokens
             FROM usage_rows r
             INNER JOIN usage_files f
               ON f.root_key=r.root_key AND f.source_key=r.source_key
             WHERE r.root_key=?1 AND r.day>=?2 AND r.day<=?3
               AND NOT EXISTS (
                 SELECT 1
                 FROM usage_rows prior
                 INNER JOIN usage_files prior_file
                   ON prior_file.root_key=prior.root_key
                  AND prior_file.source_key=prior.source_key
                 WHERE prior.root_key=r.root_key
                   AND prior.event_identity=r.event_identity
                   AND prior_file.lineage_scope=f.lineage_scope
                   AND (
                     CASE WHEN prior_file.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     prior.day,
                     prior.source_key,
                     prior.event_index
                   ) < (
                     CASE WHEN f.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     r.day,
                     r.source_key,
                     r.event_index
                   )
               )
             ORDER BY r.day, r.source_key, r.event_index",
        )?;
        let rows = statement.query_map(params![root_key, &window.start, &window.end], |row| {
            Ok(UsageRow {
                source_key: row.get(0)?,
                session_id: row.get(1)?,
                day: row.get(2)?,
                model: row.get(3)?,
                input: from_i64(row.get(4)?),
                cached: from_i64(row.get(5)?),
                output: from_i64(row.get(6)?),
            })
        })?;
        for row in rows {
            let row = row?;
            let session_identity = row
                .session_id
                .clone()
                .unwrap_or_else(|| row.source_key.clone());
            sessions.insert(session_identity);
            let total = row.input.saturating_add(row.output);
            summary.explicit_prompt_tokens =
                summary.explicit_prompt_tokens.saturating_add(row.input);
            summary.explicit_cached_input_tokens = summary
                .explicit_cached_input_tokens
                .saturating_add(row.cached.min(row.input));
            summary.explicit_completion_tokens = summary
                .explicit_completion_tokens
                .saturating_add(row.output);
            summary.explicit_total_tokens = summary.explicit_total_tokens.saturating_add(total);
            summary.explicit_records = summary.explicit_records.saturating_add(1);
            summary.message_count = summary.message_count.saturating_add(1);
            let daily = summary.daily_usage.entry(row.day).or_default();
            daily.prompt_tokens = daily.prompt_tokens.saturating_add(row.input);
            daily.cached_input_tokens = daily
                .cached_input_tokens
                .saturating_add(row.cached.min(row.input));
            daily.completion_tokens = daily.completion_tokens.saturating_add(row.output);
            daily.total_tokens = daily.total_tokens.saturating_add(total);
            daily.message_count = daily.message_count.saturating_add(1);
            daily.explicit_records = daily.explicit_records.saturating_add(1);
            let model = row
                .model
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_string());
            daily.add_model_usage(model, row.input, row.cached, row.output, total);
        }
    }

    {
        let mut estimate_statement = snapshot.prepare(
            "SELECT e.source_key, e.session_id, e.day, e.model, e.role,
                    e.estimated_tokens
             FROM usage_estimates e
             INNER JOIN usage_files f
               ON f.root_key=e.root_key AND f.source_key=e.source_key
             WHERE e.root_key=?1 AND e.day>=?2 AND e.day<=?3
               AND NOT EXISTS (
                 SELECT 1
                 FROM usage_estimates prior
                 INNER JOIN usage_files prior_file
                   ON prior_file.root_key=prior.root_key
                  AND prior_file.source_key=prior.source_key
                 WHERE prior.root_key=e.root_key
                   AND prior.event_identity=e.event_identity
                   AND prior_file.lineage_scope=f.lineage_scope
                   AND (
                     CASE WHEN prior_file.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     prior.day,
                     prior.source_key,
                     prior.estimate_index
                   ) < (
                     CASE WHEN f.forked_from_id IS NULL THEN 0 ELSE 1 END,
                     e.day,
                     e.source_key,
                     e.estimate_index
                   )
               )
               AND NOT EXISTS (
                 SELECT 1
                 FROM usage_estimate_coverage coverage
                 INNER JOIN usage_files coverage_file
                   ON coverage_file.root_key=coverage.root_key
                  AND coverage_file.source_key=coverage.source_key
                 WHERE coverage.root_key=e.root_key
                   AND coverage.event_identity=e.event_identity
                   AND coverage_file.lineage_scope=f.lineage_scope
               )
             ORDER BY e.day, e.source_key, e.estimate_index",
        )?;
        let estimate_rows =
            estimate_statement.query_map(params![root_key, &window.start, &window.end], |row| {
                Ok(UsageEstimateRow {
                    source_key: row.get(0)?,
                    session_id: row.get(1)?,
                    day: row.get(2)?,
                    model: row.get(3)?,
                    role: row.get(4)?,
                    tokens: from_i64(row.get(5)?),
                })
            })?;
        for row in estimate_rows {
            let row = row?;
            let session_identity = row
                .session_id
                .clone()
                .unwrap_or_else(|| row.source_key.clone());
            let completion = matches!(row.role.as_str(), "agent" | "assistant");
            if completion {
                summary.estimated_completion_tokens = summary
                    .estimated_completion_tokens
                    .saturating_add(row.tokens);
            } else {
                summary.estimated_prompt_tokens =
                    summary.estimated_prompt_tokens.saturating_add(row.tokens);
            }
            summary.estimated_total_tokens =
                summary.estimated_total_tokens.saturating_add(row.tokens);
            summary.estimated_records = summary.estimated_records.saturating_add(1);
            summary.message_count = summary.message_count.saturating_add(1);
            sessions.insert(session_identity);
            let daily = summary.daily_usage.entry(row.day).or_default();
            if completion {
                daily.completion_tokens = daily.completion_tokens.saturating_add(row.tokens);
            } else {
                daily.prompt_tokens = daily.prompt_tokens.saturating_add(row.tokens);
            }
            daily.total_tokens = daily.total_tokens.saturating_add(row.tokens);
            daily.message_count = daily.message_count.saturating_add(1);
            daily.estimated_records = daily.estimated_records.saturating_add(1);
            let model = row
                .model
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| UNATTRIBUTED_MODEL.to_string());
            daily.add_model_usage(
                model,
                if completion { 0 } else { row.tokens },
                0,
                if completion { row.tokens } else { 0 },
                row.tokens,
            );
        }
    }
    snapshot
        .commit()
        .context("agent usage cache snapshot commit failed")?;
    summary.session_count = sessions.len() as u64;
    summary.source = match (summary.explicit_records > 0, summary.estimated_records > 0) {
        (true, true) => Some("codex-local-token-events+history-estimate"),
        (true, false) => Some("codex-local-token-events"),
        (false, true) => Some("codex-local-history-estimate"),
        (false, false) => None,
    };
    if summary.explicit_records > 0 || summary.estimated_records > 0 {
        summary
            .source_paths
            .insert("codex-local-usage-store".to_string());
    }
    Ok(summary)
}

fn turn_id(value: &Value) -> Option<String> {
    text_field(value, &["turn_id", "turnId", "id"]).or_else(|| {
        value
            .get("info")
            .and_then(|info| text_field(info, &["turn_id", "turnId", "id"]))
    })
}

fn totals_columns(value: Option<TokenTotals>) -> (Option<i64>, Option<i64>, Option<i64>) {
    match value {
        Some(value) => (
            Some(to_i64(value.input)),
            Some(to_i64(value.cached)),
            Some(to_i64(value.output)),
        ),
        None => (None, None, None),
    }
}

fn totals_from_columns(values: (Option<i64>, Option<i64>, Option<i64>)) -> Option<TokenTotals> {
    if values.0.is_none() && values.1.is_none() && values.2.is_none() {
        return None;
    }
    Some(TokenTotals {
        input: values.0.map(from_i64).unwrap_or(0),
        cached: values.1.map(from_i64).unwrap_or(0),
        output: values.2.map(from_i64).unwrap_or(0),
    })
}

fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn to_i64(value: u64) -> i64 {
    value.min(i64::MAX as u64) as i64
}

fn from_i64(value: i64) -> u64 {
    value.max(0) as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env;

    #[test]
    fn missing_explicit_model_is_attributed_to_others_without_losing_tokens() {
        let history_root = temp_dir("missing-explicit-model-history");
        fs::write(
            history_root.join("rollout.jsonl"),
            [
                r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"missing-model-explicit"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":6,"cached_input_tokens":2,"output_tokens":4},"last_token_usage":{"input_tokens":6,"cached_input_tokens":2,"output_tokens":4}}}}"#,
                r#"{"timestamp":"2026-07-08T10:00:02Z","type":"turn_context","payload":{"model":"gpt-real-model"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8,"cached_input_tokens":2,"output_tokens":5},"last_token_usage":{"input_tokens":2,"cached_input_tokens":0,"output_tokens":1}}}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("missing-explicit-model-state");

        let result = super::super::scan(&json!({
            "agent": "codex",
            "root": history_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "forceRefresh": true,
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        let daily = &history["dailyUsage"][0];
        assert_eq!(history["totalTokens"], 13);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 2);
        assert_eq!(daily["totalTokens"], 13);
        assert_eq!(daily["modelUsage"][UNATTRIBUTED_MODEL], 10);
        assert_eq!(daily["modelUsage"]["gpt-real-model"], 3);
        assert_eq!(daily["modelUsage"].as_object().unwrap().len(), 2);
        assert_eq!(
            daily["modelTokenUsage"][UNATTRIBUTED_MODEL]["promptTokens"],
            6
        );
        assert_eq!(
            daily["modelTokenUsage"][UNATTRIBUTED_MODEL]["cachedInputTokens"],
            2
        );
        assert_eq!(
            daily["modelTokenUsage"][UNATTRIBUTED_MODEL]["completionTokens"],
            4
        );
        assert_eq!(daily["modelTokenUsage"]["gpt-real-model"]["totalTokens"], 3);
        assert_eq!(history["scanCache"]["schemaVersion"], CACHE_SCHEMA_VERSION);
        assert_eq!(history["scanCache"]["parserRevision"], PARSER_REVISION);
    }

    #[test]
    fn missing_estimated_model_is_attributed_to_others_without_losing_tokens() {
        let history_root = temp_dir("missing-estimated-model-history");
        fs::write(
            history_root.join("rollout.jsonl"),
            [
                r#"{"timestamp":"2026-07-08T10:00:00Z","type":"session_meta","payload":{"id":"missing-model-estimated"}}"#,
                r#"{"timestamp":"2026-07-08T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"estimated prompt"}]}}"#,
                r#"{"timestamp":"2026-07-08T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"estimated answer"}]}}"#,
            ]
            .join("\n"),
        )
        .unwrap();
        let state_root = temp_dir("missing-estimated-model-state");

        let result = super::super::scan(&json!({
            "agent": "codex",
            "root": history_root.to_string_lossy(),
            "stateRoot": state_root.to_string_lossy(),
            "forceRefresh": true,
            "now": "2026-07-10T12:00:00Z"
        }))
        .unwrap();

        let history = &result["agents"][0]["history"];
        let daily = &history["dailyUsage"][0];
        let total = history["totalTokens"].as_u64().unwrap();
        assert!(total > 0);
        assert_eq!(history["tokenSourceBreakdown"]["explicitRecords"], 0);
        assert_eq!(history["tokenSourceBreakdown"]["estimatedRecords"], 2);
        assert_eq!(daily["modelUsage"][UNATTRIBUTED_MODEL], total);
        assert_eq!(daily["modelUsage"].as_object().unwrap().len(), 1);
        assert_eq!(
            daily["modelTokenUsage"][UNATTRIBUTED_MODEL]["totalTokens"],
            total
        );
    }

    #[test]
    fn cache_schema_upgrade_removes_stale_pseudo_model_rows() {
        let cache_root = temp_dir("pseudo-model-cache-migration");
        let database_path = cache_root.join("usage.sqlite3");
        {
            let legacy = Connection::open(&database_path).unwrap();
            legacy
                .execute_batch(
                    "PRAGMA user_version=6;
                     CREATE TABLE usage_rows (model TEXT NOT NULL);
                     INSERT INTO usage_rows(model) VALUES('stale-pseudo-model');",
                )
                .unwrap();
        }

        let migrated = open_cache_database(&database_path).unwrap();
        let version = migrated
            .pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
            .unwrap();
        let rows = migrated
            .query_row("SELECT COUNT(*) FROM usage_rows", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap();
        let model_is_nullable = migrated
            .query_row(
                "SELECT \"notnull\" FROM pragma_table_info('usage_rows') WHERE name='model'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();

        assert_eq!(version, CACHE_SCHEMA_VERSION);
        assert_eq!(rows, 0);
        assert_eq!(model_is_nullable, 0);
    }

    fn temp_dir(name: &str) -> PathBuf {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let dir = env::temp_dir().join(format!(
            "lico-codex-usage-{name}-{}-{}-{}",
            std::process::id(),
            now.as_secs(),
            now.subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
